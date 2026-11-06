//! Schema-3 normalized catalog and exponential frecency.
const std = @import("std");
const sqlite = @import("sqlite");
const recording = @import("record.zig");

pub const version = 3;
pub const half_life_seconds: f64 = 30 * 86400;
pub const unknown_score_key: f64 = -1e300;

/// log2(sum(2^(event_timestamp / half_life))). The current-time term is
/// common to all commands, so keys sort exactly like current decayed scores.
pub fn addScore(key: f64, timestamp: i64) f64 {
    const term = @as(f64, @floatFromInt(timestamp)) / half_life_seconds;
    if (key == unknown_score_key) return term;
    const high = @max(key, term);
    return high + @log2(1 + @exp2(-@abs(key - term)));
}

pub fn scoreNow(key: f64, timestamp: i64) f64 {
    if (key == unknown_score_key) return 0;
    // Extreme future timestamps remain sortable by key without producing an
    // infinite display value. Ordinary decayed scores are unchanged.
    return @exp2(@min(1023, key - @as(f64, @floatFromInt(timestamp)) / half_life_seconds));
}

const Latest = extern struct { timestamp: i64, id: i64, initialized: bool, present: bool };
const Decay = extern struct { key: f64, initialized: bool };

fn latestStep(ctx: ?*sqlite.c.sqlite3_context, _: c_int, args: [*c]?*sqlite.c.sqlite3_value) callconv(.c) void {
    const memory = sqlite.c.sqlite3_aggregate_context(ctx, @sizeOf(Latest)) orelse {
        sqlite.c.sqlite3_result_error_nomem(ctx);
        return;
    };
    const latest: *Latest = @ptrCast(@alignCast(memory));
    const id = sqlite.c.sqlite3_value_int64(args[0]);
    const timestamp = sqlite.c.sqlite3_value_int64(args[1]);
    const present = sqlite.c.sqlite3_value_type(args[1]) != sqlite.c.SQLITE_NULL;
    if (!latest.initialized or (present and !latest.present) or
        (present == latest.present and ((present and timestamp > latest.timestamp) or
            ((!present or timestamp == latest.timestamp) and id > latest.id))))
    {
        latest.* = .{ .timestamp = timestamp, .id = id, .initialized = true, .present = present };
    }
}

fn latestFinal(ctx: ?*sqlite.c.sqlite3_context) callconv(.c) void {
    if (sqlite.c.sqlite3_aggregate_context(ctx, 0)) |memory| {
        const latest: *Latest = @ptrCast(@alignCast(memory));
        sqlite.c.sqlite3_result_int64(ctx, latest.id);
    } else sqlite.c.sqlite3_result_null(ctx);
}

fn decayStep(ctx: ?*sqlite.c.sqlite3_context, _: c_int, args: [*c]?*sqlite.c.sqlite3_value) callconv(.c) void {
    if (sqlite.c.sqlite3_value_type(args[0]) == sqlite.c.SQLITE_NULL) return;
    const memory = sqlite.c.sqlite3_aggregate_context(ctx, @sizeOf(Decay)) orelse {
        sqlite.c.sqlite3_result_error_nomem(ctx);
        return;
    };
    const decay: *Decay = @ptrCast(@alignCast(memory));
    decay.key = addScore(if (decay.initialized) decay.key else unknown_score_key, sqlite.c.sqlite3_value_int64(args[0]));
    decay.initialized = true;
}

fn decayFinal(ctx: ?*sqlite.c.sqlite3_context) callconv(.c) void {
    if (sqlite.c.sqlite3_aggregate_context(ctx, 0)) |memory| {
        const decay: *Decay = @ptrCast(@alignCast(memory));
        sqlite.c.sqlite3_result_double(ctx, decay.key);
    } else sqlite.c.sqlite3_result_double(ctx, unknown_score_key);
}

pub fn registerAggregates(db: *sqlite.Db) !void {
    const flags = sqlite.c.SQLITE_UTF8 | sqlite.c.SQLITE_DETERMINISTIC;
    if (sqlite.c.sqlite3_create_function_v2(db.db, "zs_catalog_latest", 2, flags, null, null, latestStep, latestFinal, null) != sqlite.c.SQLITE_OK or
        sqlite.c.sqlite3_create_function_v2(db.db, "zs_catalog_decay", 1, flags, null, null, decayStep, decayFinal, null) != sqlite.c.SQLITE_OK)
        return error.CatalogAggregateRegistrationFailed;
}

fn exec(db: *sqlite.Db, sql: [:0]const u8) !void {
    if (sqlite.c.sqlite3_exec(db.db, sql.ptr, null, null, null) != sqlite.c.SQLITE_OK) return error.SQLiteError;
}

fn integer(db: *sqlite.Db, comptime sql: []const u8, values: anytype) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    var rows = try stmt.iterator(i64, values);
    return (try rows.next(.{})) orelse error.MissingCatalogMetadata;
}

pub fn checkPolicy(db: *sqlite.Db) !void {
    if (try integer(db, "SELECT COUNT(*) FROM pragma_table_info('catalog_metadata') WHERE name='layout_version'", .{}) == 0 or
        try integer(db, "SELECT layout_version FROM catalog_metadata WHERE id=1", .{}) != 2)
        return error.UnsupportedCatalogLayout;
    if (try integer(db, "SELECT half_life_seconds FROM catalog_metadata WHERE id=1", .{}) != @as(i64, @intFromFloat(half_life_seconds)) or
        try integer(db, "SELECT ranking_version FROM catalog_metadata WHERE id=1", .{}) != 1)
        return error.UnsupportedRankingPolicy;
}

pub fn checkSchema(db: *sqlite.Db) !void {
    if (try integer(db, "PRAGMA user_version", .{}) != version) return error.UnsupportedCatalogVersion;
    try checkPolicy(db);
}

/// Atomic experimental migration from schema 2; other versions are refused.
/// Freelist pages are not compacted automatically. Keep a full backup for rollback.
pub fn migratePrototype(db: *sqlite.Db) !void {
    try registerAggregates(db);
    try exec(db, "BEGIN IMMEDIATE");
    errdefer recording.rollback(db);
    const old_version = try integer(db, "PRAGMA user_version", .{});
    if (old_version == version) {
        try checkPolicy(db);
        try exec(db, "COMMIT");
        return;
    }
    if (old_version != 2) return error.PrototypeRequiresSchema2;
    try convertSchema2(db);
    try exec(db, "COMMIT");
}

/// Caller holds the migration transaction, allowing version-0/1 upgrades to roll
/// back to their original state if any normalized-schema conversion fails.
pub fn convertSchema2(db: *sqlite.Db) !void {
    try registerAggregates(db);
    // Reject malformed timestamps rather than silently changing legacy metadata.
    if (try integer(db, "SELECT COUNT(*) FROM history WHERE timestamp IS NOT NULL AND typeof(timestamp) != 'integer'", .{}) != 0)
        return error.InvalidLegacyTimestamp;
    try exec(db,
        \\CREATE TABLE catalog_metadata(id INTEGER PRIMARY KEY CHECK(id=1),
        \\ half_life_seconds INTEGER NOT NULL CHECK(typeof(half_life_seconds)='integer' AND half_life_seconds>0),
        \\ ranking_version INTEGER NOT NULL CHECK(typeof(ranking_version)='integer'),
        \\ layout_version INTEGER NOT NULL CHECK(typeof(layout_version)='integer'));
        \\INSERT INTO catalog_metadata VALUES(1,2592000,1,2);
        \\CREATE TABLE commands(
        \\ id INTEGER PRIMARY KEY,cmd TEXT NOT NULL UNIQUE COLLATE BINARY,
        \\ frequency INTEGER NOT NULL,success_count INTEGER NOT NULL,
        \\ last_used INTEGER,latest_history_id INTEGER,score_key REAL NOT NULL);
        \\INSERT INTO commands(cmd,frequency,success_count,last_used,latest_history_id,score_key)
        \\ SELECT cmd,COUNT(*),SUM(CASE WHEN exit_code=0 THEN 1 ELSE 0 END),
        \\ MAX(timestamp),zs_catalog_latest(id,timestamp),zs_catalog_decay(timestamp)
        \\ FROM history GROUP BY cmd COLLATE BINARY ORDER BY cmd COLLATE BINARY;
        \\CREATE TABLE directories(id INTEGER PRIMARY KEY,cwd TEXT NOT NULL UNIQUE COLLATE BINARY);
        \\INSERT INTO directories(cwd) SELECT DISTINCT cwd COLLATE BINARY FROM history ORDER BY cwd COLLATE BINARY;
        \\CREATE TABLE history_events(
        \\ id INTEGER PRIMARY KEY AUTOINCREMENT,command_id INTEGER NOT NULL REFERENCES commands(id),
        \\ directory_id INTEGER NOT NULL REFERENCES directories(id),exit_code INTEGER,duration_ms INTEGER,session_id TEXT,
        \\ hostname TEXT,timestamp INTEGER,event_id TEXT);
        \\INSERT INTO history_events SELECT h.id,c.id,d.id,h.exit_code,h.duration_ms,
        \\ h.session_id,h.hostname,h.timestamp,h.event_id FROM history AS h
        \\ JOIN commands AS c ON c.cmd=h.cmd COLLATE BINARY JOIN directories AS d ON d.cwd=h.cwd COLLATE BINARY;
        \\INSERT INTO sqlite_sequence(name,seq) SELECT 'history_events',0
        \\ WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='history_events');
        \\UPDATE sqlite_sequence SET seq=MAX(seq,COALESCE((SELECT seq FROM sqlite_sequence WHERE name='history'),0))
        \\ WHERE name='history_events';
        \\CREATE UNIQUE INDEX idx_events_event ON history_events(event_id);
        \\CREATE INDEX idx_events_time ON history_events(timestamp DESC,id DESC);
        \\CREATE INDEX idx_events_directory_time ON history_events(directory_id,timestamp DESC,id DESC);
        \\CREATE INDEX idx_events_command_time ON history_events(command_id,timestamp DESC,id DESC);
        \\CREATE INDEX idx_commands_prefix ON commands(cmd COLLATE NOCASE);
        \\CREATE INDEX idx_commands_time ON commands(last_used DESC,latest_history_id DESC);
        \\CREATE INDEX idx_commands_score ON commands(score_key DESC,last_used DESC,latest_history_id DESC);
        \\CREATE INDEX idx_commands_frequency ON commands(frequency DESC,last_used DESC,id DESC);
        \\CREATE TABLE command_locations(
        \\ command_id INTEGER NOT NULL REFERENCES commands(id),directory_id INTEGER NOT NULL REFERENCES directories(id),
        \\ last_used INTEGER,latest_history_id INTEGER NOT NULL,PRIMARY KEY(command_id,directory_id)) WITHOUT ROWID;
        \\INSERT INTO command_locations SELECT command_id,directory_id,MAX(timestamp),zs_catalog_latest(id,timestamp)
        \\ FROM history_events GROUP BY command_id,directory_id;
        \\CREATE INDEX idx_locations_time ON command_locations(directory_id,last_used DESC,latest_history_id DESC);
        \\CREATE VIRTUAL TABLE commands_fts USING fts5(cmd,content='commands',content_rowid='id',tokenize='trigram');
        \\INSERT INTO commands_fts(commands_fts) VALUES('rebuild');
        \\CREATE TRIGGER commands_ai AFTER INSERT ON commands BEGIN
        \\ INSERT INTO commands_fts(rowid,cmd) VALUES(new.id,new.cmd); END;
        \\CREATE TRIGGER commands_ad AFTER DELETE ON commands BEGIN
        \\ INSERT INTO commands_fts(commands_fts,rowid,cmd) VALUES('delete',old.id,old.cmd); END;
        \\CREATE TRIGGER commands_au AFTER UPDATE OF cmd ON commands WHEN old.cmd IS NOT new.cmd BEGIN
        \\ INSERT INTO commands_fts(commands_fts,rowid,cmd) VALUES('delete',old.id,old.cmd);
        \\ INSERT INTO commands_fts(rowid,cmd) VALUES(new.id,new.cmd); END;
        \\DROP TRIGGER IF EXISTS history_ai;
        \\DROP TRIGGER IF EXISTS history_ad;
        \\DROP TRIGGER IF EXISTS history_au;
        \\DROP TABLE IF EXISTS history_fts;
        \\DROP TABLE IF EXISTS command_stats;
        \\DROP TABLE history;
        \\CREATE VIEW history AS SELECT e.id,c.cmd,d.cwd,e.exit_code,e.duration_ms,
        \\ e.session_id,e.hostname,e.timestamp,e.event_id FROM history_events e
        \\ JOIN commands c ON c.id=e.command_id JOIN directories d ON d.id=e.directory_id;
        \\PRAGMA user_version=3;
    );
    if (try integer(db, "SELECT COUNT(*) FROM pragma_foreign_key_check", .{}) != 0) return error.CatalogIntegrityError;
    try checkPolicy(db);
}

/// Convenience transaction wrapper; bulk imports reuse recording.Writer instead.
pub fn record(db: *sqlite.Db, entry: recording.Entry) !bool {
    var writer = try recording.Writer.init(db);
    defer writer.deinit();
    try exec(db, "BEGIN IMMEDIATE");
    errdefer recording.rollback(db);
    const inserted = try writer.record(entry, std.heap.page_allocator, entry.timestamp);
    try exec(db, "COMMIT");
    return inserted;
}

/// Explicit prototype repair after unsupported direct SQL event mutations.
pub fn repair(db: *sqlite.Db) !void {
    try registerAggregates(db);
    try exec(db, "BEGIN IMMEDIATE");
    errdefer recording.rollback(db);
    if (try integer(db, "PRAGMA user_version", .{}) != version) return error.UnsupportedCatalogVersion;
    try checkPolicy(db);
    try exec(db,
        \\DELETE FROM command_locations;
        \\UPDATE commands SET
        \\ frequency=(SELECT COUNT(*) FROM history_events WHERE command_id=commands.id),
        \\ success_count=(SELECT COUNT(*) FROM history_events WHERE command_id=commands.id AND exit_code=0),
        \\ last_used=(SELECT MAX(timestamp) FROM history_events WHERE command_id=commands.id),
        \\ latest_history_id=(SELECT zs_catalog_latest(id,timestamp) FROM history_events WHERE command_id=commands.id),
        \\ score_key=(SELECT zs_catalog_decay(timestamp) FROM history_events WHERE command_id=commands.id);
        \\DELETE FROM commands WHERE frequency=0;
        \\DELETE FROM directories WHERE NOT EXISTS(SELECT 1 FROM history_events WHERE directory_id=directories.id);
        \\INSERT INTO command_locations SELECT command_id,directory_id,MAX(timestamp),zs_catalog_latest(id,timestamp)
        \\ FROM history_events GROUP BY command_id,directory_id;
        \\INSERT INTO commands_fts(commands_fts) VALUES('rebuild');
        \\INSERT INTO commands_fts(commands_fts,rank) VALUES('integrity-check',1);
    );
    if (try integer(db, "SELECT COUNT(*) FROM pragma_foreign_key_check", .{}) != 0) return error.CatalogIntegrityError;
    try exec(db, "COMMIT");
}

/// Literal candidate selection. Final LIKE uses exactly the current ASCII-folding
/// and escaping rules; FTS never gets to broaden Unicode/wildcard semantics.
pub fn matchIds(db: *sqlite.Db, query: []const u8, cwd: ?[]const u8, allocator: std.mem.Allocator) ![]i64 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const selection = try selectionSql(query, cwd, scratch);
    var stmt = try db.prepareDynamic(selection.sql);
    defer stmt.deinit();
    var results: std.ArrayListUnmanaged(i64) = .empty;
    errdefer results.deinit(allocator);
    if (selection.use_fts) {
        if (cwd) |directory| try collect(&stmt, .{ selection.pattern, selection.phrase, directory }, &results, allocator) else try collect(&stmt, .{ selection.pattern, selection.phrase }, &results, allocator);
    } else if (cwd) |directory| try collect(&stmt, .{ selection.pattern, directory }, &results, allocator) else try collect(&stmt, .{selection.pattern}, &results, allocator);
    return results.toOwnedSlice(allocator);
}

pub const Selection = struct { sql: []u8, pattern: []u8, phrase: []u8, use_fts: bool };

pub fn selectionSql(query: []const u8, cwd: ?[]const u8, scratch: std.mem.Allocator) !Selection {
    var pattern: std.ArrayListUnmanaged(u8) = .empty;
    try pattern.append(scratch, '%');
    for (query) |byte| {
        if (byte == '%' or byte == '_' or byte == '\\') try pattern.append(scratch, '\\');
        try pattern.append(scratch, byte);
    }
    try pattern.append(scratch, '%');
    const use_fts = std.mem.indexOfScalar(u8, query, 0) == null and
        std.unicode.utf8ValidateSlice(query) and (std.unicode.utf8CountCodepoints(query) catch 0) >= 3;
    var phrase: std.ArrayListUnmanaged(u8) = .empty;
    try phrase.append(scratch, '"');
    for (query) |byte| {
        if (byte == '"') try phrase.append(scratch, '"');
        try phrase.append(scratch, byte);
    }
    try phrase.append(scratch, '"');
    const sql = try std.fmt.allocPrint(scratch, "SELECT {s} FROM commands AS c {s} {s} WHERE c.cmd LIKE ? ESCAPE '\\' {s} {s} ORDER BY {s}", .{
        if (cwd != null) "l.latest_history_id" else "c.latest_history_id",
        if (use_fts) "JOIN commands_fts AS f ON f.rowid=c.id" else "",
        if (cwd != null) "JOIN command_locations AS l ON l.command_id=c.id" else "",
        if (use_fts) "AND commands_fts MATCH ?" else "",
        if (cwd != null) "AND l.directory_id=(SELECT id FROM directories WHERE cwd=? COLLATE BINARY)" else "",
        if (cwd != null) "l.last_used DESC,l.latest_history_id DESC" else "c.last_used DESC,c.latest_history_id DESC",
    });
    return .{ .sql = sql, .pattern = pattern.items, .phrase = phrase.items, .use_fts = use_fts };
}

fn collect(stmt: *sqlite.DynamicStatement, values: anytype, list: *std.ArrayListUnmanaged(i64), allocator: std.mem.Allocator) !void {
    var rows = try stmt.iterator(i64, values);
    while (try rows.next(.{})) |id| try list.append(allocator, id);
}

/// One benchmark cache per connection, NOT the production multi-state TUI cache.
/// Materializes IDs in SQLite (not an unbounded command-string result array).
pub fn materializeMatches(db: *sqlite.Db, query: []const u8, cwd: ?[]const u8, allocator: std.mem.Allocator) !usize {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const selection = try selectionSql(query, cwd, scratch);
    try exec(db, "CREATE TEMP TABLE IF NOT EXISTS zs_catalog_matches(position INTEGER PRIMARY KEY,history_id INTEGER NOT NULL)");
    try exec(db, "SAVEPOINT zs_catalog_page");
    errdefer {
        exec(db, "ROLLBACK TO zs_catalog_page") catch {};
        exec(db, "RELEASE zs_catalog_page") catch {};
    }
    try exec(db, "DELETE FROM temp.zs_catalog_matches");
    const sql = try std.fmt.allocPrint(scratch, "INSERT INTO temp.zs_catalog_matches(history_id) {s}", .{selection.sql});
    var stmt = try db.prepareDynamic(sql);
    defer stmt.deinit();
    defer {
        _ = sqlite.c.sqlite3_reset(stmt.stmt);
        _ = sqlite.c.sqlite3_clear_bindings(stmt.stmt);
    }
    if (selection.use_fts) {
        if (cwd) |directory| try stmt.exec(.{}, .{ selection.pattern, selection.phrase, directory }) else try stmt.exec(.{}, .{ selection.pattern, selection.phrase });
    } else if (cwd) |directory| try stmt.exec(.{}, .{ selection.pattern, directory }) else try stmt.exec(.{}, .{selection.pattern});
    const count: usize = @intCast(sqlite.c.sqlite3_changes(db.db));
    try exec(db, "RELEASE zs_catalog_page");
    return count;
}

pub const PageEntry = struct { id: i64, cmd: []const u8, cwd: []const u8, exit_code: i64, duration_ms: i64, timestamp: i64 };

/// Fetch a bounded benchmark page. Caller owns row strings via its page arena.
pub fn fetchPage(db: *sqlite.Db, offset: usize, limit: usize, allocator: std.mem.Allocator) ![]PageEntry {
    var stmt = try db.prepare(
        \\SELECT e.id,c.cmd,d.cwd,COALESCE(e.exit_code,0),COALESCE(e.duration_ms,0),COALESCE(e.timestamp,0)
        \\ FROM temp.zs_catalog_matches AS m CROSS JOIN history_events AS e ON e.id=m.history_id
        \\ CROSS JOIN commands AS c ON c.id=e.command_id
        \\ CROSS JOIN directories AS d ON d.id=e.directory_id
        \\ WHERE m.position>? AND m.position<=? ORDER BY m.position
    );
    defer stmt.deinit();
    var rows = try stmt.iterator(PageEntry, .{ @as(i64, @intCast(offset)), @as(i64, @intCast(offset +| limit)) });
    var entries: std.ArrayListUnmanaged(PageEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.cmd);
            allocator.free(entry.cwd);
        }
        entries.deinit(allocator);
    }
    while (try rows.nextAlloc(allocator, .{})) |row| {
        errdefer {
            allocator.free(row.cmd);
            allocator.free(row.cwd);
        }
        try entries.append(allocator, row);
    }
    return entries.toOwnedSlice(allocator);
}
