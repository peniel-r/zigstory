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
        try writer.record(.{
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
