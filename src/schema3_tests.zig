const std = @import("std");
const sqlite = @import("sqlite");
const zigstory = @import("zigstory");
const search = @import("tui/search.zig");
const allocator = std.testing.allocator;
const io = std.testing.io;

fn add(db: *sqlite.Db, cmd: []const u8, cwd: []const u8, timestamp: i64, event: ?[]const u8) !void {
    _ = try zigstory.catalog.record(db, .{ .cmd = cmd, .cwd = cwd, .timestamp = timestamp, .event_id = event, .exit_code = 0, .duration_ms = 1, .session_id = "s", .hostname = "h" });
}

fn scalar(db: *sqlite.Db, comptime sql: []const u8) !i64 {
    var statement = try db.prepare(sql);
    defer statement.deinit();
    var rows = try statement.iterator(i64, .{});
    return (try rows.next(.{})).?;
}

test "schema 3 production search preserves browse counts, deduplication and cache invalidation" {
    var db = try zigstory.db.initDb(":memory:");
    defer db.deinit();
    try add(&db, "duplicate", "local", 10, "a");
    try add(&db, "duplicate", "other", 20, "b");
    try add(&db, "duplicate", "local", 20, "c");
    try add(&db, "literal %_\\", "local", 30, "d");
    var state = search.SearchState.init(allocator);
    defer state.deinit(allocator);
    try state.loadPage(&db, 100, 0, true);
    try std.testing.expect(state.catalog_mode);
    try std.testing.expectEqual(@as(usize, 4), state.total_count); // Browsing retains executions.
    try state.query.appendSlice(allocator, "duplicate");
    try state.loadPage(&db, 100, 0, true);
    try std.testing.expectEqual(@as(usize, 1), state.total_count);
    try std.testing.expectEqual(@as(i64, 3), state.results[0].id);
    state.filter_state = .{ .mode = .current_dir, .current_dir = "other" };
    try state.loadPage(&db, 100, 0, true);
    try std.testing.expectEqual(@as(i64, 2), state.results[0].id);
    try add(&db, "duplicate", "other", 40, "e");
    try state.loadPage(&db, 100, 0, false);
    try std.testing.expectEqual(@as(i64, 5), state.results[0].id);
    state.query.clearRetainingCapacity();
    try state.loadPage(&db, 100, 0, true);
    try std.testing.expectEqual(@as(usize, 2), state.total_count);
    try std.testing.expect(state.cache_table == null);
    state.filter_state = .{};
    try state.query.appendSlice(allocator, "%_\\");
    try state.loadPage(&db, 100, 0, true);
    try std.testing.expectEqual(@as(usize, 1), state.total_count);
    try std.testing.expectEqualStrings("literal %_\\", state.results[0].cmd);
}

test "schema 3 search states stay independent and readonly caches detect external commits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "history.db", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "history.db", allocator);
    defer allocator.free(path);
    var writer = try zigstory.db.initDb(path);
    defer writer.deinit();
    try add(&writer, "match first", "local", 1, "first");
    try add(&writer, "other command", "local", 2, "other");
    var reader = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{} });
    defer reader.deinit();
    var one = search.SearchState.init(allocator);
    defer one.deinit(allocator);
    var two = search.SearchState.init(allocator);
    defer two.deinit(allocator);
    try one.query.appendSlice(allocator, "match");
    try two.query.appendSlice(allocator, "other");
    try one.loadPage(&reader, 1, 0, true);
    try two.loadPage(&reader, 1, 0, true);
    try one.loadPage(&reader, 1, 0, false);
    try std.testing.expectEqualStrings("match first", one.results[0].cmd);
    try add(&writer, "match latest", "local", 3, "latest");
    try one.loadPage(&reader, 1, 0, false);
    try std.testing.expectEqual(@as(usize, 2), one.total_count);
    try std.testing.expectEqualStrings("match latest", one.results[0].cmd);
    try one.loadPage(&reader, 1, 1, false);
    try std.testing.expectEqualStrings("match first", one.results[0].cmd);
}

test "version zero migration rollback preserves all original columns when normalization fails" {
    var db = try sqlite.Db.init(.{ .mode = .Memory, .open_flags = .{ .write = true, .create = true } });
    defer db.deinit();
    try db.exec("CREATE TABLE history(id INTEGER PRIMARY KEY,cmd TEXT,cwd TEXT,exit_code INTEGER,duration_ms INTEGER,timestamp INTEGER)", .{}, .{});
    try db.exec("INSERT INTO history VALUES(1,'original','local',0,7,'invalid timestamp')", .{}, .{});
    try std.testing.expectError(error.InvalidLegacyTimestamp, zigstory.db.ensureSchema(&db));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 6), try scalar(&db, "SELECT COUNT(*) FROM pragma_table_info('history')"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT COUNT(*) FROM history WHERE timestamp='invalid timestamp'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT COUNT(*) FROM sqlite_schema WHERE name='commands'"));
}

test "production prepared writer requires a transaction and repairs preserve stable command IDs" {
    var db = try zigstory.db.initDb(":memory:");
    defer db.deinit();
    var writer = try zigstory.record.Writer.init(&db);
    defer writer.deinit();
    const entry = zigstory.record.Entry{ .cmd = "stable", .cwd = "local", .timestamp = 1, .exit_code = 0, .duration_ms = 0, .session_id = "s", .hostname = "h", .event_id = "stable" };
    try std.testing.expectError(error.RecordingTransactionRequired, writer.record(entry, allocator, 1));
    try add(&db, "stable", "local", 1, "stable");
    const id = try scalar(&db, "SELECT id FROM commands WHERE cmd='stable'");
    try zigstory.db.maintain(&db);
    try std.testing.expectEqual(id, try scalar(&db, "SELECT id FROM commands WHERE cmd='stable'"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "PRAGMA foreign_keys"));
}

test "schema 3 search keeps more than 50000 accessible matches with bounded rows" {
    var db = try zigstory.db.initSchema2Fixture(":memory:");
    defer db.deinit();
    try db.exec(
        \\WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<50100)
        \\INSERT INTO history(id,cmd,cwd,exit_code,duration_ms,timestamp)
        \\ SELECT i,printf('normalized %06d',i),'local',0,1,i FROM n
    , .{}, .{});
    try zigstory.db.ensureSchema(&db);
    var state = search.SearchState.init(allocator);
    defer state.deinit(allocator);
    try state.query.appendSlice(allocator, "normalized");
    try state.loadPage(&db, 100, 0, true);
    try std.testing.expectEqual(@as(usize, 50100), state.total_count);
    try std.testing.expectEqual(@as(usize, 100), state.results.len);
    try state.loadPage(&db, 100, 50099, false);
    try std.testing.expectEqual(@as(usize, 1), state.results.len);
    try std.testing.expectEqual(@as(i64, 1), state.results[0].id);
    const capacity = state.results_arena.queryCapacity();
    for (0..12) |i| {
        try state.loadPage(&db, 100, if (i % 2 == 0) 0 else 50000, false);
        try std.testing.expect(state.results.len <= 100);
        try std.testing.expect(state.results_arena.queryCapacity() <= @max(capacity, 1024 * 1024));
    }
}
