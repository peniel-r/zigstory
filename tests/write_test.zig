const std = @import("std");
const write = @import("write");
const db_mod = @import("db");
const sqlite = @import("sqlite");

// Helper to create a temp DB for testing
fn createTempDb() !struct { db: sqlite.Db, path: []const u8, tmp_dir: std.testing.TmpDir } {
    var tmp_dir = std.testing.tmpDir(.{});
    const db_path_buf = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ db_path_buf, "test_write.db" });
    errdefer std.testing.allocator.free(db_path);
    std.testing.allocator.free(db_path_buf);

    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path);
    defer std.testing.allocator.free(db_path_z);

    const database = try db_mod.initDb(db_path_z);
    return .{ .db = database, .path = db_path, .tmp_dir = tmp_dir };
}

test "insertCommand: single insert with retry" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    const entry = write.CommandEntry{
        .cmd = "test command",
        .cwd = "/tmp",
        .exit_code = 0,
        .duration_ms = 100,
        .session_id = "test-session",
        .hostname = "test-host",
    };

    try write.insertCommand(&data.db, entry, .{});

    // Verify insertion
    var stmt = try data.db.prepare("SELECT COUNT(*) as count FROM history");
    defer stmt.deinit();
    var iter = try stmt.iterator(struct { count: i32 }, .{});
    if (try iter.next(.{})) |row| {
        try std.testing.expectEqual(@as(i32, 1), row.count);
    }
}

test "insertCommandsBatch: batch insert performance" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    // Create 100 test entries
    var entries: [100]write.CommandEntry = undefined;
    for (&entries, 0..) |*entry, i| {
        var cmd_buf: [64]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cmd_buf, "command {d}", .{i});

        entry.* = .{
            .cmd = try std.testing.allocator.dupe(u8, cmd),
            .cwd = "/tmp",
            .exit_code = 0,
            .duration_ms = 50,
            .session_id = "batch-session",
            .hostname = "test-host",
        };
    }
    defer for (entries) |entry| {
        std.testing.allocator.free(entry.cmd);
    };

    const start = std.time.milliTimestamp();
    try write.insertCommandsBatch(&data.db, &entries, .{});
    const elapsed = std.time.milliTimestamp() - start;

    std.debug.print("Batch insert (100 commands) took: {}ms\n", .{elapsed});

    // Verify all were inserted
    var stmt = try data.db.prepare("SELECT COUNT(*) as count FROM history");
    defer stmt.deinit();
    var iter = try stmt.iterator(struct { count: i32 }, .{});
    if (try iter.next(.{})) |row| {
        try std.testing.expectEqual(@as(i32, 100), row.count);
    }

    // Performance target: < 1000ms for 100 commands
    try std.testing.expect(elapsed < 1000);
}

test "insertCommand: single insert performance" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    const entry = write.CommandEntry{
        .cmd = "performance test",
        .cwd = "/tmp",
        .exit_code = 0,
        .duration_ms = 25,
        .session_id = "perf-session",
        .hostname = "test-host",
    };

    // Measure average over 10 inserts
    var total_time: i64 = 0;
    const iterations = 10;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.milliTimestamp();
        try write.insertCommand(&data.db, entry, .{});
        const elapsed = std.time.milliTimestamp() - start;
        total_time += elapsed;
    }

    const avg_time = @divTrunc(total_time, iterations);
    std.debug.print("Average single insert time: {}ms\n", .{avg_time});

    // Performance target: < 50ms average
    try std.testing.expect(avg_time < 50);
}

test "ConnectionPool: reuse connection" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const db_path_buf = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(db_path_buf);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ db_path_buf, "pool_test.db" });
    defer std.testing.allocator.free(db_path);

    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path);
    defer std.testing.allocator.free(db_path_z);

    var pool = write.ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();

    // First acquire
    const db1 = try pool.acquire(db_path_z);
    pool.release(db1);

    // Second acquire should return same connection
    const db2 = try pool.acquire(db_path_z);
    pool.release(db2);

    try std.testing.expectEqual(db1, db2);
}

test "insertCommandsBatch: empty batch" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    const entries: []const write.CommandEntry = &.{};
    try write.insertCommandsBatch(&data.db, entries, .{});

    // Verify no rows inserted
    var stmt = try data.db.prepare("SELECT COUNT(*) as count FROM history");
    defer stmt.deinit();
    var iter = try stmt.iterator(struct { count: i32 }, .{});
    if (try iter.next(.{})) |row| {
        try std.testing.expectEqual(@as(i32, 0), row.count);
    }
}
