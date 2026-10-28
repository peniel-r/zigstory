const std = @import("std");
const sqlite = @import("sqlite");
const zigstory = @import("zigstory");
const add = @import("cli/add.zig");
const import_history = @import("cli/import.zig");
const recalc = @import("cli/recalc.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;

fn scalar(db: *sqlite.Db, comptime sql: []const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    var rows = try stmt.iterator(struct { value: i64 }, .{});
    return (try rows.next(.{})).?.value;
}

test "schema upgrades legacy history once and reopening avoids full-history scans" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "legacy.db", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "legacy.db", allocator);
    defer allocator.free(path);
    {
        var db = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{ .write = true } });
        defer db.deinit();
        try db.exec("CREATE TABLE history (id INTEGER PRIMARY KEY, cmd TEXT, cwd TEXT, exit_code INTEGER, duration_ms INTEGER, timestamp INTEGER)", .{}, .{});
        try db.exec(
            \\WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i < 10000)
            \\INSERT INTO history SELECT i, printf('legacy %06d',i), 'C:\repo', 0, 0, i FROM n
        , .{}, .{});
    }
    var schema: i64 = 0;
    {
        var db = try zigstory.db.initDb(path);
        defer db.deinit();
        try std.testing.expectEqual(@as(i64, zigstory.db.schema_version), try scalar(&db, "PRAGMA user_version"));
        try std.testing.expectEqual(@as(i64, 10000), try scalar(&db, "SELECT COUNT(*) FROM history_fts WHERE history_fts MATCH 'legacy'"));
        try std.testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT COUNT(*) FROM pragma_table_info('history') WHERE name IN ('rank','cmd_hash')"));
        schema = try scalar(&db, "PRAGMA schema_version");
    }
    var db = try zigstory.db.initDb(path);
    defer db.deinit();
    var misses: c_int = 0;
    var high_water: c_int = 0;
    try std.testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_db_status(db.db, sqlite.c.SQLITE_DBSTATUS_CACHE_MISS, &misses, &high_water, 0));
    try std.testing.expect(misses < 50);
    try std.testing.expectEqual(schema, try scalar(&db, "PRAGMA schema_version"));
}

test "explicit maintenance repairs FTS and metadata updates leave it untouched" {
    var db = try zigstory.db.initDb(":memory:");
    defer db.deinit();
    try add.addCommand(&db, .{ .cmd = "echo original", .cwd = "local", .exit_code = 0, .duration_ms = 0 }, allocator, io);
    const before = sqlite.c.sqlite3_total_changes(db.db);
    try db.exec("UPDATE history SET rank = 123, cmd_hash = 'changed' WHERE id = 1", .{}, .{});
    try std.testing.expectEqual(@as(c_int, 1), sqlite.c.sqlite3_total_changes(db.db) - before);
    try db.exec("INSERT INTO history_fts(history_fts,rowid,cmd) VALUES('delete',1,'echo original')", .{}, .{});
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM history_fts WHERE history_fts MATCH 'original'"));
    try zigstory.db.maintain(&db);
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT COUNT(*) FROM history_fts WHERE history_fts MATCH 'original'"));
    try db.exec("UPDATE history SET cmd = 'echo renamed' WHERE id = 1", .{}, .{});
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM history_fts WHERE history_fts MATCH 'original'"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT COUNT(*) FROM history_fts WHERE history_fts MATCH 'renamed'"));
    try db.exec("UPDATE history SET id = 42 WHERE id = 1", .{}, .{});
    try std.testing.expectEqual(@as(i64, 42), try scalar(&db, "SELECT rowid FROM history_fts WHERE history_fts MATCH 'renamed'"));
    try db.exec("DELETE FROM history WHERE id = 42", .{}, .{});
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM history_fts WHERE history_fts MATCH 'renamed'"));
}

test "failed migrations roll back all schema changes and preserve legacy history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.db", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "broken.db", allocator);
    defer allocator.free(path);
    {
        var db = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{ .write = true } });
        defer db.deinit();
        try db.exec("CREATE TABLE history (id INTEGER PRIMARY KEY, cmd TEXT, cwd TEXT, timestamp INTEGER)", .{}, .{});
        try db.exec("INSERT INTO history VALUES(1,'legacy','local',1)", .{}, .{});
        try db.exec("CREATE TABLE idx_rank (conflict TEXT)", .{}, .{});
    }
    try std.testing.expectError(error.SQLiteError, zigstory.db.initDb(path));
    var db = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{ .write = true } });
    defer db.deinit();
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM pragma_table_info('history') WHERE name IN ('rank','cmd_hash')"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'history_fts'"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT COUNT(*) FROM history"));
}

test "newer database versions are rejected without downgrading" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "future.db", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "future.db", allocator);
    defer allocator.free(path);
    {
        var db = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{ .write = true } });
        defer db.deinit();
        try db.exec("PRAGMA user_version=999", .{}, .{});
    }
    try std.testing.expectError(error.UnsupportedSchemaVersion, zigstory.db.initDb(path));
    try std.testing.expectError(error.UnsupportedSchemaVersion, recalc.recalcRanks(.{ .db_path = path }, allocator, io));
    var db = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{ .write = true } });
    defer db.deinit();
    try std.testing.expectEqual(@as(i64, 999), try scalar(&db, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'history'"));
}

test "time and directory indexes cover deterministic latest-entry queries" {
    var db = try zigstory.db.initDb(":memory:");
    defer db.deinit();
    for ([_][]const u8{
        "EXPLAIN QUERY PLAN SELECT * FROM history ORDER BY timestamp DESC, id DESC LIMIT 100",
        "EXPLAIN QUERY PLAN SELECT * FROM history WHERE cwd = 'C:\\repo' ORDER BY timestamp DESC, id DESC LIMIT 1",
    }, [_][]const u8{ "idx_history_time", "idx_history_cwd_time" }) |sql, index| {
        var stmt = try db.prepareDynamic(sql);
        defer stmt.deinit();
        var rows = try stmt.iterator(struct { id: i64, parent: i64, unused: i64, detail: []const u8 }, .{});
        var found = false;
        while (try rows.nextAlloc(allocator, .{})) |row| {
            defer allocator.free(row.detail);
            try std.testing.expect(std.mem.indexOf(u8, row.detail, "TEMP B-TREE") == null);
            found = found or std.mem.indexOf(u8, row.detail, index) != null;
        }
        try std.testing.expect(found);
    }
}

test "version one databases gain event identities without changing existing history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "v1.db", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "v1.db", allocator);
    defer allocator.free(path);
    {
        var db = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{ .write = true } });
        defer db.deinit();
        try db.exec("CREATE TABLE history (id INTEGER PRIMARY KEY, cmd TEXT)", .{}, .{});
        try db.exec("INSERT INTO history VALUES(1,'existing')", .{}, .{});
        try db.exec("PRAGMA user_version=1", .{}, .{});
    }
    var db = try zigstory.db.initDb(path);
    defer db.deinit();
    try std.testing.expectEqual(@as(i64, 2), try scalar(&db, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT COUNT(*) FROM history WHERE cmd='existing' AND event_id IS NULL"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT COUNT(*) FROM sqlite_schema WHERE name='idx_history_event'"));
}

test "recording imports preserve metadata and retry without incrementing history or statistics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "event.json", .data =
        \\[{"cmd":"recorded","cwd":"before","exit_code":7,"duration_ms":3000000000,
        \\ "timestamp":1234567890,"session_id":"shell-session","hostname":"shell-host","event_id":"unique-event"}]
    });
    const path = try tmp.dir.realPathFileAlloc(io, "event.json", allocator);
    defer allocator.free(path);
    var db = try zigstory.db.initDb(":memory:");
    defer db.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try import_history.importRecordingFile(&db, path, "default", allocator, io)).imported);
    try std.testing.expectEqual(@as(usize, 0), (try import_history.importRecordingFile(&db, path, "default", allocator, io)).imported);
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT COUNT(*) FROM history WHERE cwd='before' AND exit_code=7 AND duration_ms=3000000000 AND timestamp=1234567890 AND session_id='shell-session' AND hostname='shell-host'"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT frequency FROM command_stats"));
    try std.testing.expectEqual(@as(i64, 1234567890), try scalar(&db, "SELECT last_used FROM command_stats"));
    try tmp.dir.writeFile(io, .{ .sub_path = "event.json", .data = "[{\"cmd\":\"legacy\"}]" });
    try std.testing.expectError(error.MissingEventId, import_history.importRecordingFile(&db, path, "default", allocator, io));
    try std.testing.expectEqual(@as(usize, 1), (try import_history.importFromFile(&db, path, "default", allocator, io)).imported);
    try std.testing.expectEqual(@as(usize, 1), (try import_history.importFromFile(&db, path, "default", allocator, io)).imported);
    try std.testing.expectEqual(@as(i64, 3), try scalar(&db, "SELECT COUNT(*) FROM history"));
    try tmp.dir.writeFile(io, .{ .sub_path = "event.json", .data = "[{\"cmd\":\"would insert\",\"event_id\":\"new-event\"},{\"cmd\":\"missing event\"}]" });
    try std.testing.expectError(error.MissingEventId, import_history.importRecordingFile(&db, path, "default", allocator, io));
    try std.testing.expectEqual(@as(i64, 3), try scalar(&db, "SELECT COUNT(*) FROM history"));
    try tmp.dir.writeFile(io, .{ .sub_path = "event.json", .data = "[{\"cmd\":\"bad\",\"timestamp\":-1}]" });
    try std.testing.expectError(error.InvalidTimestamp, import_history.importFromFile(&db, path, "default", allocator, io));
    try tmp.dir.writeFile(io, .{ .sub_path = "event.json", .data = "[{\"cmd\":\"bad\",\"duration_ms\":-1}]" });
    try std.testing.expectError(error.InvalidDuration, import_history.importFromFile(&db, path, "default", allocator, io));
}

test "add updates history and statistics atomically and captures the correct row ID" {
    var db = try zigstory.db.initDb(":memory:");
    defer db.deinit();
    for ([_][]const u8{ "git status", "echo other", "git status" }) |cmd| {
        try add.addCommand(&db, .{ .cmd = cmd, .cwd = "C:\\repo", .exit_code = 0, .duration_ms = 10 }, allocator, io);
    }
    try std.testing.expectEqual(@as(i64, 3), try scalar(&db, "SELECT COUNT(*) AS value FROM history WHERE rank > 0"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT frequency AS value FROM command_stats WHERE cmd = 'git status'"));
    try db.exec("CREATE TRIGGER reject_stats BEFORE INSERT ON command_stats BEGIN SELECT RAISE(ABORT, 'reject stats'); END", .{}, .{});
    try std.testing.expectError(error.SQLiteConstraint, add.addCommand(&db, .{
        .cmd = "must roll back",
        .cwd = "C:\\repo",
        .exit_code = 0,
        .duration_ms = 0,
    }, allocator, io));
    try std.testing.expectEqual(@as(i64, 3), try scalar(&db, "SELECT COUNT(*) AS value FROM history"));
}

test "JSON imports share ranking updates and roll back invalid batches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "batch.json",
        .data =
        \\[{"cmd":"echo \"hello\"\nnext","cwd":"C:\\repo","exit_code":0,"duration_ms":100},
        \\ {"cmd":"git status"},{"cmd":"git status"}]
        ,
    });
    const path = try tmp.dir.realPathFileAlloc(io, "batch.json", allocator);
    defer allocator.free(path);
    var db = try zigstory.db.initDb(":memory:");
    defer db.deinit();
    const result = try import_history.importFromFile(&db, path, "C:\\default", allocator, io);
    try std.testing.expectEqual(@as(usize, 3), result.imported);
    try std.testing.expectEqual(@as(i64, 3), try scalar(&db, "SELECT COUNT(*) AS value FROM history WHERE rank > 0"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT frequency AS value FROM command_stats WHERE cmd = 'git status'"));
    try tmp.dir.writeFile(io, .{
        .sub_path = "batch.json",
        .data = "[{\"cmd\":\"valid\"},{\"cmd\":\"\"}]",
    });
    try std.testing.expectError(error.EmptyCommand, import_history.importFromFile(&db, path, "C:\\default", allocator, io));
    try std.testing.expectEqual(@as(i64, 3), try scalar(&db, "SELECT COUNT(*) AS value FROM history"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT COUNT(*) AS value FROM command_stats"));
    try tmp.dir.writeFile(io, .{ .sub_path = "batch.json", .data = "[{\"cmd\":\"bad\",\"exit_code\":2147483648}]" });
    try std.testing.expectError(error.Overflow, import_history.importFromFile(&db, path, "C:\\default", allocator, io));
}

test "older imported timestamps do not move command recency backwards" {
    var db = try zigstory.db.initDb(":memory:");
    defer db.deinit();
    var writer = try zigstory.record.Writer.init(&db);
    defer writer.deinit();
    try db.exec("BEGIN", .{}, .{});
    errdefer zigstory.record.rollback(&db);
    for ([_]i64{ 200000, 100000 }) |timestamp| {
        _ = try writer.record(.{
            .cmd = "git status",
            .cwd = "C:\\repo",
            .exit_code = 0,
            .duration_ms = 0,
            .session_id = "session",
            .hostname = "host",
            .timestamp = timestamp,
        }, allocator, 200000);
    }
    try db.exec("COMMIT", .{}, .{});
    try std.testing.expectEqual(@as(i64, 200000), try scalar(&db, "SELECT last_used AS value FROM command_stats"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT frequency AS value FROM command_stats"));
}

test "recalculation rebuilds partially populated statistics and handles sparse IDs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "history.db", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "history.db", allocator);
    defer allocator.free(path);
    {
        var db = try zigstory.db.initDb(path);
        defer db.deinit();
        try add.addCommand(&db, .{ .cmd = "git status", .cwd = "C:\\repo", .exit_code = 0, .duration_ms = 0 }, allocator, io);
        try db.exec("INSERT INTO history (id,cmd,cwd,exit_code,duration_ms,timestamp) VALUES (1000,'legacy','C:\\repo',0,0,100000)", .{}, .{});
        try db.exec("INSERT INTO history (id,cmd,cwd,exit_code,duration_ms,timestamp) VALUES (2000,'git status','C:\\repo',0,0,100001)", .{}, .{});
    }
    try recalc.recalcRanks(.{ .db_path = path, .batch_size = 1 }, allocator, io);
    try recalc.recalcRanks(.{ .db_path = path, .batch_size = 2 }, allocator, io);
    var db = try zigstory.db.initDb(path);
    defer db.deinit();
    try std.testing.expectEqual(@as(i64, 3), try scalar(&db, "SELECT COUNT(*) AS value FROM history WHERE rank > 0"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT frequency AS value FROM command_stats WHERE cmd = 'git status'"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT frequency AS value FROM command_stats WHERE cmd = 'legacy'"));
    try std.testing.expectError(error.InvalidBatchSize, zigstory.ranking.recalculateAllRanks(&db, .{}, 0, null, io));
}
