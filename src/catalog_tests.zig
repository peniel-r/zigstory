const std = @import("std");
const sqlite = @import("sqlite");
const zigstory = @import("zigstory");
const legacy = zigstory.db;
const catalog = zigstory.catalog;
const old_search = @import("tui/search.zig");
const allocator = std.testing.allocator;

fn scalar(db: *sqlite.Db, comptime sql: []const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    var rows = try stmt.iterator(i64, .{});
    return (try rows.next(.{})).?;
}

fn fixture() !sqlite.Db {
    var db = try legacy.initSchema2Fixture(":memory:");
    errdefer db.deinit();
    try db.exec(
        \\INSERT INTO history(id,cmd,cwd,exit_code,duration_ms,timestamp,session_id,hostname,event_id)
        \\ VALUES(1,'git status','local',0,10,10,'session','host','first'),
        \\ (3,'git status','remote',7,20,20,'session','host','second'),
        \\ (5,'git status','local',0,30,20,'session','host','third'),
        \\ (7,'Git status','local',0,0,21,'session','host',NULL),
        \\ (8,'echo %_\literal','local',0,0,22,'session','host',NULL),
        \\ (9,'echo "quoted"','local',0,0,23,'session','host',NULL)
    , .{}, .{});
    return db;
}

test "catalog prototype migrates exact commands, event metadata and latest locations" {
    var db = try fixture();
    defer db.deinit();
    try db.exec("INSERT INTO history(id,cmd,cwd,timestamp) VALUES(1000,'deleted high water','local',0)", .{}, .{});
    try db.exec("DELETE FROM history WHERE id=1000", .{}, .{});
    try catalog.migratePrototype(&db);
    try std.testing.expectEqual(@as(i64, 3), try scalar(&db, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 6), try scalar(&db, "SELECT COUNT(*) FROM history_events"));
    try std.testing.expectEqual(@as(i64, 4), try scalar(&db, "SELECT COUNT(*) FROM commands"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(&db, "SELECT frequency FROM commands WHERE cmd='git status'"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT success_count FROM commands WHERE cmd='git status'"));
    try std.testing.expectEqual(@as(i64, 5), try scalar(&db, "SELECT latest_history_id FROM commands WHERE cmd='git status'"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(&db, "SELECT l.latest_history_id FROM command_locations l JOIN commands c ON c.id=l.command_id JOIN directories d ON d.id=l.directory_id WHERE c.cmd='git status' AND d.cwd='remote'"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT COUNT(*) FROM history_events WHERE id=3 AND exit_code=7 AND duration_ms=20 AND timestamp=20 AND session_id='session' AND hostname='host' AND event_id='second'"));
    try std.testing.expectEqual(@as(i64, 1000), try scalar(&db, "SELECT seq FROM sqlite_sequence WHERE name='history_events'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name IN ('history','history_fts','command_stats')"));
    try catalog.migratePrototype(&db); // Reopening an already-migrated prototype is harmless.
    try std.testing.expectEqual(@as(i64, 6), try scalar(&db, "SELECT COUNT(*) FROM history_events"));
    try legacy.ensureSchema(&db);
}

test "catalog migration failure rolls back tables and preserves schema-2 history" {
    var db = try fixture();
    defer db.deinit();
    // Duplicate event identities in a malformed version-2 fixture must fail,
    // rather than silently discarding an execution while normalizing commands.
    try db.exec("DROP INDEX idx_history_event", .{}, .{});
    try db.exec("UPDATE history SET event_id='first' WHERE id=3", .{}, .{});
    try std.testing.expectError(error.SQLiteError, catalog.migratePrototype(&db));
    try std.testing.expectEqual(@as(i64, 2), try scalar(&db, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 6), try scalar(&db, "SELECT COUNT(*) FROM history"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM sqlite_schema WHERE name IN ('commands','history_events','command_locations')"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT COUNT(*) FROM sqlite_schema WHERE name='history_fts'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "PRAGMA user_version") - 2);
}

test "catalog migration preserves nullable metadata and timestamp ordering extremes" {
    var db = try fixture();
    defer db.deinit();
    try db.exec(
        \\INSERT INTO history(id,cmd,cwd,timestamp) VALUES
        \\ (20,'null time','local',NULL),(21,'null time','local',NULL),
        \\ (22,'negative','local',NULL),(23,'negative','local',-9223372036854775808),
        \\ (24,'extreme','local',9223372036854775807),(25,'extreme','local',9223372036854775807)
    , .{}, .{});
    try catalog.migratePrototype(&db);
    try std.testing.expectEqual(@as(i64, 21), try scalar(&db, "SELECT latest_history_id FROM commands WHERE cmd='null time'"));
    try std.testing.expectEqual(@as(i64, 23), try scalar(&db, "SELECT latest_history_id FROM commands WHERE cmd='negative'"));
    try std.testing.expectEqual(@as(i64, 25), try scalar(&db, "SELECT latest_history_id FROM commands WHERE cmd='extreme'"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT COUNT(*) FROM history_events WHERE id=20 AND timestamp IS NULL AND session_id IS NULL AND hostname IS NULL AND exit_code IS NULL AND duration_ms IS NULL"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM pragma_foreign_key_check"));
}

test "catalog trigram candidates preserve literal LIKE and directory semantics" {
    var db = try fixture();
    defer db.deinit();
    const commands = [_][]const u8{
        "echo \u{e9}t\u{e9} \u{4e2d}\u{6587}\u{641c}\u{7d22}", "echo \u{c9}T\u{c9}",
        "first\nsecond",                                       "emoji \u{1f469}\u{200d}\u{1f680}",
        "two a\x00bc tail",
    };
    for (commands, 0..) |cmd, i| try db.exec("INSERT INTO history(cmd,cwd,timestamp) VALUES(?,'local',?)", .{}, .{ cmd, @as(i64, @intCast(50 + i)) });
    const queries = [_][]const u8{
        "git",                      "Git",                        "it",         "g",       "",          "%_\\", "\"quoted\"", "\u{e9}t\u{e9}", "\u{c9}T\u{c9}",
        "\u{4e2d}\u{6587}\u{641c}", "\u{1f469}\u{200d}\u{1f680}", "first\nsec", "a\x00bc", "not found",
    };
    var expected_global = [_][]i64{&.{}} ** queries.len;
    var expected_local = [_][]i64{&.{}} ** queries.len;
    defer for (expected_global, expected_local) |global, local| {
        allocator.free(global);
        allocator.free(local);
    };
    {
        var reference = old_search.SearchState.init(allocator);
        defer reference.deinit(allocator);
        for (queries, 0..) |query, i| {
            reference.query.clearRetainingCapacity();
            try reference.query.appendSlice(allocator, query);
            reference.filter_state = .{};
            try reference.loadPage(&db, 100, 0, true);
            // Empty browsing does not deduplicate; use the SQL window reference then.
            expected_global[i] = if (query.len == 0) try windowIds(&db, null) else try idsOf(reference.results);
            reference.filter_state = .{ .mode = .current_dir, .current_dir = "local" };
            try reference.loadPage(&db, 100, 0, true);
            expected_local[i] = if (query.len == 0) try windowIds(&db, "local") else try idsOf(reference.results);
        }
    } // SearchState releases its TEMP tables before history is replaced.
    try catalog.migratePrototype(&db);
    for (queries, 0..) |query, i| {
        const global = try catalog.matchIds(&db, query, null, allocator);
        defer allocator.free(global);
        try std.testing.expectEqualSlices(i64, expected_global[i], global);
        const local = try catalog.matchIds(&db, query, "local", allocator);
        defer allocator.free(local);
        try std.testing.expectEqualSlices(i64, expected_local[i], local);
    }
}

fn idsOf(entries: anytype) ![]i64 {
    const ids = try allocator.alloc(i64, entries.len);
    for (entries, ids) |entry, *id| id.* = entry.id;
    return ids;
}

fn windowIds(db: *sqlite.Db, cwd: ?[]const u8) ![]i64 {
    var stmt = try db.prepare("SELECT id FROM (SELECT id,timestamp,ROW_NUMBER() OVER(PARTITION BY cmd ORDER BY timestamp DESC,id DESC) AS n FROM history WHERE (? IS NULL OR cwd=?)) WHERE n=1 ORDER BY timestamp DESC,id DESC");
    defer stmt.deinit();
    var rows = try stmt.iterator(i64, .{ cwd, cwd });
    var ids: std.ArrayListUnmanaged(i64) = .empty;
    errdefer ids.deinit(allocator);
    while (try rows.next(.{})) |id| try ids.append(allocator, id);
    return ids.toOwnedSlice(allocator);
}

test "catalog recording is atomic, idempotent and preserves out-of-order recency" {
    var db = try fixture();
    defer db.deinit();
    try catalog.migratePrototype(&db);
    const entry = zigstory.record.Entry{
        .cmd = "git status",
        .cwd = "local",
        .exit_code = 3,
        .duration_ms = 3000000000,
        .session_id = "new-session",
        .hostname = "new-host",
        .timestamp = 5,
        .event_id = "new-event",
    };
    try std.testing.expect(try catalog.record(&db, entry));
    try std.testing.expect(!try catalog.record(&db, entry));
    var different_retry = entry;
    different_retry.cmd = "different text with the same event identity";
    different_retry.cwd = "retry must not create this directory";
    try std.testing.expect(!try catalog.record(&db, different_retry));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM commands WHERE cmd='different text with the same event identity'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM directories WHERE cwd='retry must not create this directory'"));
    try std.testing.expectEqual(@as(i64, 4), try scalar(&db, "SELECT frequency FROM commands WHERE cmd='git status'"));
    try std.testing.expectEqual(@as(i64, 5), try scalar(&db, "SELECT latest_history_id FROM commands WHERE cmd='git status'"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT COUNT(*) FROM history_events WHERE event_id='new-event' AND duration_ms=3000000000 AND session_id='new-session' AND hostname='new-host'"));
    try db.exec("CREATE TRIGGER reject_catalog BEFORE UPDATE ON commands BEGIN SELECT RAISE(ABORT,'reject'); END", .{}, .{});
    var failing = entry;
    failing.cmd = "must roll back";
    failing.cwd = "failure-only directory";
    failing.event_id = "failed-event";
    try std.testing.expectError(error.SQLiteConstraint, catalog.record(&db, failing));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM commands WHERE cmd='must roll back'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM history_events WHERE event_id='failed-event'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM directories WHERE cwd='failure-only directory'"));
}

test "catalog score halves over 30 days without rewriting rows and stays finite in log space" {
    const h: i64 = @intFromFloat(catalog.half_life_seconds);
    const key = catalog.addScore(catalog.addScore(catalog.unknown_score_key, 0), h);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), catalog.scoreNow(key, h), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), catalog.scoreNow(key, 2 * h), 1e-12);
    try std.testing.expectApproxEqAbs(key, catalog.addScore(catalog.addScore(catalog.unknown_score_key, h), 0), 1e-12);
    try std.testing.expect(std.math.isFinite(catalog.addScore(catalog.unknown_score_key, std.math.maxInt(i64))));
    try std.testing.expect(std.math.isFinite(catalog.scoreNow(catalog.addScore(catalog.unknown_score_key, std.math.maxInt(i64)), 0)));
    // 60 old uses lose to 30 recent uses after a year under the proposed policy.
    var old = catalog.unknown_score_key;
    var recent = catalog.unknown_score_key;
    for (0..60) |_| old = catalog.addScore(old, 0);
    for (0..30) |_| recent = catalog.addScore(recent, 365 * 86400);
    try std.testing.expect(recent > old);
}

test "catalog repair restores summaries and FTS after direct event mutations" {
    var db = try fixture();
    defer db.deinit();
    try catalog.migratePrototype(&db);
    try db.exec("PRAGMA foreign_keys=ON", .{}, .{});
    try db.exec("DELETE FROM history_events WHERE id IN (1,5)", .{}, .{});
    try db.exec("UPDATE commands SET frequency=999,score_key=999", .{}, .{});
    try catalog.repair(&db);
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT frequency FROM commands WHERE cmd='git status'"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(&db, "SELECT latest_history_id FROM commands WHERE cmd='git status'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM command_locations WHERE directory_id=(SELECT id FROM directories WHERE cwd='local') AND command_id=(SELECT id FROM commands WHERE cmd='git status')"));
    const matches = try catalog.matchIds(&db, "git", "local", allocator);
    defer allocator.free(matches);
    try std.testing.expectEqualSlices(i64, &.{7}, matches);
}

test "catalog pages materialize the same IDs and keep loaded rows bounded" {
    var db = try fixture();
    defer db.deinit();
    try catalog.migratePrototype(&db);
    const expected = try catalog.matchIds(&db, "git", null, allocator);
    defer allocator.free(expected);
    const count = try catalog.materializeMatches(&db, "git", null, allocator);
    try std.testing.expectEqual(expected.len, count);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    for (expected, 0..) |id, offset| {
        _ = arena.reset(.retain_capacity);
        const page = try catalog.fetchPage(&db, offset, 1, arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), page.len);
        try std.testing.expectEqual(id, page[0].id);
    }
    try std.testing.expectEqual(@as(usize, 0), try catalog.materializeMatches(&db, "missing", null, allocator));
    _ = arena.reset(.retain_capacity);
    try std.testing.expectEqual(@as(usize, 0), (try catalog.fetchPage(&db, 0, 100, arena.allocator())).len);
}

test "catalog version checks refuse unsupported versions and malformed timestamp metadata" {
    var db = try fixture();
    defer db.deinit();
    try db.exec("UPDATE history SET timestamp='not-an-integer' WHERE id=1", .{}, .{});
    try std.testing.expectError(error.InvalidLegacyTimestamp, catalog.migratePrototype(&db));
    try std.testing.expectEqual(@as(i64, 2), try scalar(&db, "PRAGMA user_version"));
    try db.exec("PRAGMA user_version=4", .{}, .{});
    try std.testing.expectError(error.PrototypeRequiresSchema2, catalog.migratePrototype(&db));
    try std.testing.expectEqual(@as(i64, 4), try scalar(&db, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 6), try scalar(&db, "SELECT COUNT(*) FROM history"));
}

test "catalog migration persists on disk and old CLI schema checks refuse it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "prototype.db", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "prototype.db", allocator);
    defer allocator.free(path);
    {
        var db = try legacy.initSchema2Fixture(path);
        defer db.deinit();
        try db.exec("INSERT INTO history(cmd,cwd,timestamp,event_id) VALUES('disk event','local',1,'disk-event')", .{}, .{});
        try catalog.migratePrototype(&db);
    }
    var reader = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{} });
    defer reader.deinit();
    try std.testing.expectEqual(@as(i64, 3), try scalar(&reader, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&reader, "SELECT COUNT(*) FROM history_events WHERE event_id='disk-event'"));
    try legacy.ensureSchema(&reader);
    try std.testing.expectEqual(@as(i64, 3), try scalar(&reader, "PRAGMA user_version"));
}

test "catalog query plans use prefix, ranking, location and FTS indexes" {
    var db = try fixture();
    defer db.deinit();
    try catalog.migratePrototype(&db);
    const queries = [_][]const u8{
        "EXPLAIN QUERY PLAN SELECT cmd FROM commands WHERE cmd LIKE 'git%' ESCAPE '\\'",
        "EXPLAIN QUERY PLAN SELECT cmd FROM commands ORDER BY score_key DESC,last_used DESC,latest_history_id DESC LIMIT 5",
        "EXPLAIN QUERY PLAN SELECT latest_history_id FROM command_locations WHERE directory_id=(SELECT id FROM directories WHERE cwd='local') ORDER BY last_used DESC,latest_history_id DESC",
        "EXPLAIN QUERY PLAN SELECT c.id FROM commands_fts f JOIN commands c ON c.id=f.rowid WHERE commands_fts MATCH '\"git\"' AND c.cmd LIKE '%git%' ESCAPE '\\'",
    };
    for (queries, [_][]const u8{ "idx_commands_prefix", "idx_commands_score", "idx_locations_time", "VIRTUAL TABLE INDEX" }) |query, index| {
        var stmt = try db.prepareDynamic(query);
        defer stmt.deinit();
        var rows = try stmt.iterator(struct { id: i64, parent: i64, unused: i64, detail: []const u8 }, .{});
        var found = false;
        while (try rows.nextAlloc(allocator, .{})) |row| {
            defer allocator.free(row.detail);
            found = found or std.mem.indexOf(u8, row.detail, index) != null;
        }
        try std.testing.expect(found);
    }
}

test "catalog recording validates metadata and does not alter an older schema" {
    var db = try fixture();
    defer db.deinit();
    var entry = zigstory.record.Entry{ .cmd = "validation", .cwd = "local", .exit_code = 0, .duration_ms = 0, .session_id = "s", .hostname = "h", .timestamp = 100 };
    try std.testing.expectError(error.UnsupportedCatalogVersion, catalog.record(&db, entry));
    try std.testing.expectEqual(@as(i64, 6), try scalar(&db, "SELECT COUNT(*) FROM history"));
    try catalog.migratePrototype(&db);
    entry.cmd = "";
    try std.testing.expectError(error.EmptyCommand, catalog.record(&db, entry));
    entry.cmd = "validation";
    entry.cwd = "";
    try std.testing.expectError(error.EmptyPath, catalog.record(&db, entry));
    entry.cwd = "local";
    entry.timestamp = -1;
    try std.testing.expectError(error.InvalidTimestamp, catalog.record(&db, entry));
    entry.timestamp = 100;
    entry.duration_ms = -1;
    try std.testing.expectError(error.InvalidDuration, catalog.record(&db, entry));
    entry.duration_ms = 0;
    entry.event_id = "";
    try std.testing.expectError(error.EmptyEventId, catalog.record(&db, entry));
    entry.event_id = null;
    try std.testing.expect(try catalog.record(&db, entry));
    try std.testing.expect(try catalog.record(&db, entry));
    try std.testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT frequency FROM commands WHERE cmd='validation'"));
}

test "catalog command edits update trigram FTS and orphan repair deletes index entries" {
    var db = try fixture();
    defer db.deinit();
    try catalog.migratePrototype(&db);
    try db.exec("PRAGMA foreign_keys=ON", .{}, .{});
    try db.exec("UPDATE commands SET cmd='new catalog text' WHERE cmd='echo \"quoted\"'", .{}, .{});
    const old = try catalog.matchIds(&db, "quoted", null, allocator);
    defer allocator.free(old);
    try std.testing.expectEqual(@as(usize, 0), old.len);
    const new = try catalog.matchIds(&db, "catalog", null, allocator);
    defer allocator.free(new);
    try std.testing.expectEqualSlices(i64, &.{9}, new);
    try db.exec("DELETE FROM history_events WHERE id=9", .{}, .{});
    try catalog.repair(&db);
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM commands WHERE cmd='new catalog text'"));
    const gone = try catalog.matchIds(&db, "catalog", null, allocator);
    defer allocator.free(gone);
    try std.testing.expectEqual(@as(usize, 0), gone.len);
}

test "catalog preserves ID high-water even when all original events were deleted" {
    var db = try fixture();
    defer db.deinit();
    try db.exec("INSERT INTO history(id,cmd,cwd,timestamp) VALUES(1000,'removed','local',1)", .{}, .{});
    try db.exec("DELETE FROM history", .{}, .{});
    try catalog.migratePrototype(&db);
    try std.testing.expectEqual(@as(i64, 1000), try scalar(&db, "SELECT seq FROM sqlite_sequence WHERE name='history_events'"));
    try std.testing.expect(try catalog.record(&db, .{ .cmd = "after empty migration", .cwd = "local", .exit_code = 0, .duration_ms = 0, .session_id = "s", .hostname = "h", .timestamp = 2 }));
    try std.testing.expectEqual(@as(i64, 1001), try scalar(&db, "SELECT id FROM history_events"));
}

test "catalog refuses incompatible ranking metadata rather than mixing score units" {
    var db = try fixture();
    defer db.deinit();
    try catalog.migratePrototype(&db);
    try db.exec("UPDATE catalog_metadata SET half_life_seconds=1", .{}, .{});
    try std.testing.expectError(error.UnsupportedRankingPolicy, catalog.migratePrototype(&db));
    try std.testing.expectError(error.UnsupportedRankingPolicy, catalog.repair(&db));
    try std.testing.expectError(error.UnsupportedRankingPolicy, catalog.record(&db, .{
        .cmd = "not inserted",
        .cwd = "local",
        .exit_code = 0,
        .duration_ms = 0,
        .session_id = "s",
        .hostname = "h",
        .timestamp = 1,
    }));
    try std.testing.expectEqual(@as(i64, 6), try scalar(&db, "SELECT COUNT(*) FROM history_events"));
    try db.exec("UPDATE catalog_metadata SET layout_version=1", .{}, .{});
    try std.testing.expectError(error.UnsupportedCatalogLayout, catalog.migratePrototype(&db));
    try std.testing.expectEqual(@as(i64, 6), try scalar(&db, "SELECT COUNT(*) FROM history_events"));
}

test "catalog directory identities preserve exact path text and case" {
    var db = try fixture();
    defer db.deinit();
    const path = "C:\\long path & quotes'\\\u{e9}\\local";
    try db.exec("INSERT INTO history(id,cmd,cwd,timestamp) VALUES(30,'path command','local',30),(31,'path command','Local',31)", .{}, .{});
    try db.exec("INSERT INTO history(id,cmd,cwd,timestamp) VALUES(32,'path command',?,32)", .{}, .{path});
    try catalog.migratePrototype(&db);
    for ([_][]const u8{ "local", "Local", path }, [_]i64{ 30, 31, 32 }) |directory, expected| {
        const ids = try catalog.matchIds(&db, "path command", directory, allocator);
        defer allocator.free(ids);
        try std.testing.expectEqualSlices(i64, &.{expected}, ids);
    }
    try std.testing.expectEqual(@as(usize, 1), try catalog.materializeMatches(&db, "path command", path, allocator));
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const page = try catalog.fetchPage(&db, 0, 1, arena.allocator());
    try std.testing.expectEqualStrings(path, page[0].cwd);
}
