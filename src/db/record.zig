const std = @import("std");
const sqlite = @import("sqlite");
const catalog = @import("catalog.zig");

pub const Entry = struct {
    cmd: []const u8,
    cwd: []const u8,
    exit_code: i32,
    duration_ms: i64,
    session_id: []const u8,
    hostname: []const u8,
    timestamp: i64,
    event_id: ?[]const u8 = null,
};

/// Reuse normalized statements within a caller-owned transaction. Event retries
/// never create extra commands/directories or increment scores/statistics.
pub const Writer = struct {
    db: *sqlite.Db,
    statements: [8]sqlite.DynamicStatement,

    const Statement = enum { event_exists, directory_insert, directory_get, command_insert, command_get, event_insert, command_update, location_update };
    const queries = [_][]const u8{
        "SELECT id FROM history_events WHERE event_id=?",
        "INSERT INTO directories(cwd) VALUES(?) ON CONFLICT(cwd) DO NOTHING",
        "SELECT id FROM directories WHERE cwd=? COLLATE BINARY",
        "INSERT INTO commands(cmd,frequency,success_count,score_key) VALUES(?,0,0,?) ON CONFLICT(cmd) DO NOTHING",
        "SELECT id,score_key,last_used,latest_history_id FROM commands WHERE cmd=? COLLATE BINARY",
        "INSERT INTO history_events(command_id,directory_id,exit_code,duration_ms,session_id,hostname,timestamp,event_id) VALUES(?,?,?,?,?,?,?,?)",
        "UPDATE commands SET frequency=frequency+1,success_count=success_count+?,score_key=?,last_used=?,latest_history_id=? WHERE id=?",
        \\INSERT INTO command_locations(command_id,directory_id,last_used,latest_history_id) VALUES(?,?,?,?)
        \\ ON CONFLICT(command_id,directory_id) DO UPDATE SET
        \\ latest_history_id=CASE WHEN last_used IS NULL OR excluded.last_used>last_used OR
        \\ (excluded.last_used=last_used AND excluded.latest_history_id>latest_history_id)
        \\ THEN excluded.latest_history_id ELSE latest_history_id END,
        \\ last_used=CASE WHEN last_used IS NULL OR excluded.last_used>last_used THEN excluded.last_used ELSE last_used END
        ,
    };

    pub fn init(db: *sqlite.Db) !Writer {
        try catalog.checkSchema(db);
        var statements: [8]sqlite.DynamicStatement = undefined;
        var initialized: usize = 0;
        errdefer for (statements[0..initialized]) |*statement| statement.deinit();
        for (queries, &statements) |query, *statement| {
            statement.* = try db.prepareDynamic(query);
            initialized += 1;
        }
        return .{ .db = db, .statements = statements };
    }

    pub fn deinit(self: *Writer) void {
        for (&self.statements) |*statement| statement.deinit();
    }

    pub fn record(self: *Writer, entry: Entry, allocator: std.mem.Allocator, now: i64) !bool {
        _ = allocator; // The compatibility signature remains; hashes are no longer allocated.
        _ = now; // Score keys use execution timestamps, not import/process-launch time.
        if (entry.cmd.len == 0) return error.EmptyCommand;
        if (entry.cwd.len == 0) return error.EmptyPath;
        if (entry.duration_ms < 0) return error.InvalidDuration;
        if (entry.timestamp < 0) return error.InvalidTimestamp;
        if (entry.event_id) |id| {
            if (id.len == 0) return error.EmptyEventId;
        }
        if (sqlite.c.sqlite3_get_autocommit(self.db.db) != 0) return error.RecordingTransactionRequired;
        defer for (&self.statements) |*statement| resetStatement(statement);
        if (entry.event_id) |event| {
            if (try self.row(.event_exists, i64, .{event}) != null) return false;
        }
        try self.execute(.directory_insert, .{entry.cwd});
        const directory = (try self.row(.directory_get, i64, .{entry.cwd})) orelse return error.MissingCatalogMetadata;
        try self.execute(.command_insert, .{ entry.cmd, catalog.unknown_score_key });
        const Current = struct { id: i64, score_key: f64, last_used: ?i64, latest_history_id: ?i64 };
        const current = (try self.row(.command_get, Current, .{entry.cmd})) orelse return error.MissingCatalogMetadata;
        try self.execute(.event_insert, .{ current.id, directory, entry.exit_code, entry.duration_ms, entry.session_id, entry.hostname, entry.timestamp, entry.event_id });
        const event = sqlite.c.sqlite3_last_insert_rowid(self.db.db);
        const newest = current.last_used == null or entry.timestamp > current.last_used.? or
            (entry.timestamp == current.last_used.? and event > (current.latest_history_id orelse std.math.minInt(i64)));
        try self.execute(.command_update, .{
            @as(i64, if (entry.exit_code == 0) 1 else 0),       catalog.addScore(current.score_key, entry.timestamp),
            if (newest) entry.timestamp else current.last_used, if (newest) event else current.latest_history_id,
            current.id,
        });
        try self.execute(.location_update, .{ current.id, directory, entry.timestamp, event });
        return true;
    }

    fn execute(self: *Writer, key: Statement, values: anytype) !void {
        try self.statements[@intFromEnum(key)].exec(.{}, values);
    }

    fn row(self: *Writer, key: Statement, comptime T: type, values: anytype) !?T {
        var rows = try self.statements[@intFromEnum(key)].iterator(T, values);
        return rows.next(.{});
    }
};

fn resetStatement(stmt: *sqlite.DynamicStatement) void {
    // sqlite3_reset returns the preceding step's error, which record propagates.
    _ = sqlite.c.sqlite3_reset(stmt.stmt);
    const rc = sqlite.c.sqlite3_clear_bindings(stmt.stmt);
    if (rc != sqlite.c.SQLITE_OK) {
        std.log.err("Failed to clear recording statement bindings: {d}", .{rc});
    }
}

pub fn rollback(db: *sqlite.Db) void {
    db.exec("ROLLBACK", .{}, .{}) catch |err| {
        std.log.err("Failed to roll back history transaction: {}", .{err});
    };
}
