const std = @import("std");
const sqlite = @import("sqlite");
const ranking = @import("../src/db/ranking.zig");

test "recalculation performance benchmark" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a test database
    const test_db_path = "test_perf_ranking.db";
    defer {
        std.fs.cwd().deleteFile(test_db_path) catch {};
    }

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = test_db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    defer db.deinit();

    // Create tables
    try ranking.initRanking(&db);

    const num_entries = 10000;
    const num_unique_commands = 500;

    std.debug.print("Creating {d} history entries...\n", .{num_entries});

    const start_time = std.time.timestamp();
    const insert_stmt = try db.prepare("INSERT INTO history (cmd, cwd, exit_code, duration_ms, timestamp) VALUES (?, ?, ?, ?, ?)");
    defer insert_stmt.deinit();

    for (0..num_entries) |i| {
        const cmd_num = i % num_unique_commands;
        const cmd = try std.fmt.allocPrint(allocator, "test_command_{d}", .{cmd_num});
        defer allocator.free(cmd);
        const cwd = try std.fmt.allocPrint(allocator, "/home/user/test{d}", .{cmd_num});
        defer allocator.free(cwd);
        const timestamp = start_time + @as(i64, @intCast(i));
        try insert_stmt.exec(.{}, .{
            cmd,
            cwd,
            0,
            @as(i64, @intCast(100 + i)),
            timestamp,
        });
    }

    std.debug.print("Inserted {d} entries\n", .{num_entries});

    // Benchmark recalculation
    const recalc_iterations = 5;
    var total_recalc_time_ms: i64 = 0;

    for (0..recalc_iterations) |i| {
        std.debug.print("\nRecalculation iteration {d}/{d}...\n", .{i + 1, recalc_iterations});
        const timer = try std.time.Timer.start();
        try ranking.recalculateAllRanks(
            &db,
            ranking.FrecencyConfig{},
            100,
            null,
        );
        const elapsed_ms = timer.read() / 1_000_000;
        total_recalc_time_ms += elapsed_ms;
        std.debug.print("Recalculation time: {d}ms\n", .{elapsed_ms});
    }

    const avg_time_ms = total_recalc_time_ms / @as(i64, @intCast(recalc_iterations));
    std.debug.print("\nAverage recalculation time ({d} iterations): {d}ms\n", .{recalc_iterations, avg_time_ms});

    if (avg_time_ms < 1000) {
        std.debug.print("✅ Performance target met: Average < 1000ms\n", .{});
    } else {
        std.debug.print("❌ Performance target NOT met: Average {d}ms >= 1000ms\n", .{avg_time_ms});
    }
}
