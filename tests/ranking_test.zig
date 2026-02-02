const std = @import("std");
const sqlite = @import("sqlite");
const ranking = @import("../src/db/ranking.zig");

test "calculateFrecency" {
    const config = ranking.FrecencyConfig{
        .frequency_weight = 2.0,
        .recency_weight = 100.0,
        .max_days = 365,
    };

    // Test with recent command (1 day ago)
    const current_time = std.time.timestamp();
    const rank_recent = ranking.calculateFrecency(10, current_time - 86400, config);
    try std.testing.expect(rank_recent > 0);

    // Test with old command (100 days ago)
    const rank_old = ranking.calculateFrecency(10, current_time - (86400 * 100), config);
    try std.testing.expect(rank_old < rank_recent);

    // Test with high frequency
    const rank_high_freq = ranking.calculateFrecency(100, current_time - 86400, config);
    const rank_low_freq = ranking.calculateFrecency(1, current_time - 86400, config);
    try std.testing.expect(rank_high_freq > rank_low_freq);
}

test "getCommandHash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test that same command produces same hash
    const cmd1 = "git commit -m 'test'";
    const hash1 = try ranking.getCommandHash(cmd1, allocator);
    const hash2 = try ranking.getCommandHash(cmd1, allocator);
    try std.testing.expectEqualStrings(hash1, hash2);

    // Test that different commands produce different hashes
    const cmd2 = "git status";
    const hash3 = try ranking.getCommandHash(cmd2, allocator);
    try std.testing.expect(!std.mem.eql(u8, hash1, hash3));

    // Test hash format (should be 64 hex characters)
    try std.testing.expectEqual(@as(usize, 64), hash1.len);
}

test "initRanking" {
    // Create temporary database
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrintZ(std.testing.allocator, "{s}/test.db", .{tmp.dir.path});
    defer std.testing.allocator.free(db_path);

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    defer db.deinit();

    // Initialize ranking system
    try ranking.initRanking(&db);

    // Verify command_stats table exists
    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='command_stats'");
    defer stmt.deinit();

    var iter = try stmt.iterator(struct { name: []const u8 }, .{});
    const result = try iter.next(.{});
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("command_stats", result.?.name);

    // Verify rank column exists in history table
    stmt = try db.prepare("PRAGMA table_info(history)");
    defer stmt.deinit();

    const ColumnInfo = struct {
        cid: i64,
        name: []const u8,
        type: []const u8,
        notnull: i64,
        dflt_value: ?[]const u8,
        pk: i64,
    };

    var rank_found = false;
    iter = try stmt.iterator(ColumnInfo, .{});
    while (try iter.next(.{})) |row| {
        if (std.mem.eql(u8, row.name, "rank")) {
            rank_found = true;
            try std.testing.expectEqualStrings("REAL", row.type);
        }
    }
    try std.testing.expect(rank_found);

    // Verify idx_rank index exists
    stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_rank'");
    defer stmt.deinit();

    iter = try stmt.iterator(struct { name: []const u8 }, .{});
    const index_result = try iter.next(.{});
    try std.testing.expect(index_result != null);
    try std.testing.expectEqualStrings("idx_rank", index_result.?.name);
}

test "updateCommandStats" {
    // Create temporary database
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrintZ(std.testing.allocator, "{s}/test.db", .{tmp.dir.path});
    defer std.testing.allocator.free(db_path);

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    defer db.deinit();

    try ranking.initRanking(&db);

    const cmd = "git status";
    const cmd_hash = try ranking.getCommandHash(cmd, std.testing.allocator);
    defer std.testing.allocator.free(cmd_hash);

    const current_time = std.time.timestamp();

    // Insert first time
    try ranking.updateCommandStats(&db, cmd, cmd_hash, current_time);

    var stmt = try db.prepare("SELECT frequency, last_used FROM command_stats WHERE cmd_hash = ?");
    defer stmt.deinit();

    const Result = struct {
        frequency: i64,
        last_used: i64,
    };

    var iter = try stmt.iterator(Result, .{cmd_hash});
    const result = try iter.next(.{});
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 1), result.?.frequency);

    // Update again (should increment frequency)
    try ranking.updateCommandStats(&db, cmd, cmd_hash, current_time + 10);

    iter = try stmt.iterator(Result, .{cmd_hash});
    const result2 = try iter.next(.{});
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(i64, 2), result2.?.frequency);
}

test "updateHistoryRank" {
    // Create temporary database
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrintZ(std.testing.allocator, "{s}/test.db", .{tmp.dir.path});
    defer std.testing.allocator.free(db_path);

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    defer db.deinit();

    try ranking.initRanking(&db);

    // Insert a history entry
    const cmd = "git commit";
    const cmd_hash = try ranking.getCommandHash(cmd, std.testing.allocator);
    defer std.testing.allocator.free(cmd_hash);

    const current_time = std.time.timestamp();

    var stmt = try db.prepare(
        \\INSERT INTO history (cmd, cwd, exit_code, duration_ms, session_id, hostname, timestamp)
        \\VALUES (?, ?, 0, 0, 'test-session', 'localhost', ?)
    );
    defer stmt.deinit();
    try stmt.exec(.{}, .{ cmd, current_time });

    // Update command stats
    try ranking.updateCommandStats(&db, cmd, cmd_hash, current_time);

    // Get history ID
    var rowid_stmt = try db.prepare("SELECT last_insert_rowid() as rowid");
    defer rowid_stmt.deinit();

    const RowIdResult = struct { rowid: i64 };
    var iter = try rowid_stmt.iterator(RowIdResult, .{});
    const rowid = (try iter.next(.{})).?.rowid;

    // Update history rank
    try ranking.updateHistoryRank(&db, rowid, cmd_hash, ranking.FrecencyConfig{});

    // Verify rank was updated
    var rank_stmt = try db.prepare("SELECT rank FROM history WHERE id = ?");
    defer rank_stmt.deinit();

    const RankResult = struct { rank: f64 };
    iter = try rank_stmt.iterator(RankResult, .{rowid});
    const rank_result = try iter.next(.{});
    try std.testing.expect(rank_result != null);
    try std.testing.expect(rank_result.?.rank > 0);
}

test "recalculateAllRanks" {
    // Create temporary database
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrintZ(std.testing.allocator, "{s}/test.db", .{tmp.dir.path});
    defer std.testing.allocator.free(db_path);

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    defer db.deinit();

    try ranking.initRanking(&db);

    // Insert multiple history entries with different commands
    const commands = [_][]const u8{ "git status", "npm install", "git commit" };
    const current_time = std.time.timestamp();

    for (commands, 0..) |cmd, i| {
        const cmd_hash = try ranking.getCommandHash(cmd, std.testing.allocator);
        defer std.testing.allocator.free(cmd_hash);

        // Insert history entry
        var stmt = try db.prepare(
            \\INSERT INTO history (cmd, cwd, exit_code, duration_ms, session_id, hostname, timestamp)
            \\VALUES (?, ?, 0, 0, 'test-session', 'localhost', ?)
        );
        defer stmt.deinit();
        try stmt.exec(.{}, .{ cmd, current_time - (@as(i64, @intCast(i)) * 86400) });

        // Update command stats
        try ranking.updateCommandStats(&db, cmd, cmd_hash, current_time - (@as(i64, @intCast(i)) * 86400));
    }

    // Recalculate all ranks
    try ranking.recalculateAllRanks(&db, ranking.FrecencyConfig{}, 10, null);

    // Verify all ranks are set
    var stmt = try db.prepare("SELECT COUNT(*) as count FROM history WHERE rank > 0");
    defer stmt.deinit();

    const CountResult = struct { count: i64 };
    var iter = try stmt.iterator(CountResult, .{});
    const result = (try iter.next(.{})).?.count;
    try std.testing.expectEqual(@as(i64, 3), result);
}

test "getCommandStats" {
    // Create temporary database
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrintZ(std.testing.allocator, "{s}/test.db", .{tmp.dir.path});
    defer std.testing.allocator.free(db_path);

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    defer db.deinit();

    try ranking.initRanking(&db);

    const cmd = "git status";
    const cmd_hash = try ranking.getCommandHash(cmd, std.testing.allocator);
    defer std.testing.allocator.free(cmd_hash);

    const current_time = std.time.timestamp();

    // Insert history entry
    var stmt = try db.prepare(
        \\INSERT INTO history (cmd, cwd, exit_code, duration_ms, session_id, hostname, timestamp)
        \\VALUES (?, ?, 0, 0, 'test-session', 'localhost', ?)
    );
    defer stmt.deinit();
    try stmt.exec(.{}, .{ cmd, current_time });

    // Update command stats
    try ranking.updateCommandStats(&db, cmd, cmd_hash, current_time);

    // Get command stats
    const stats = try ranking.getCommandStats(&db, cmd, std.testing.allocator);
    defer {
        std.testing.allocator.free(stats.?.cmd_hash);
        std.testing.allocator.free(stats.?.cmd);
    }

    try std.testing.expect(stats != null);
    try std.testing.expectEqual(@as(i64, 1), stats.?.frequency);
    try std.testing.expectEqualStrings(cmd, stats.?.cmd);

    // Test non-existent command
    const no_stats = try ranking.getCommandStats(&db, "nonexistent", std.testing.allocator);
    try std.testing.expect(no_stats == null);
}

test "getTopRankedCommands" {
    // Create temporary database
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrintZ(std.testing.allocator, "{s}/test.db", .{tmp.dir.path});
    defer std.testing.allocator.free(db_path);

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    defer db.deinit();

    try ranking.initRanking(&db);

    const current_time = std.time.timestamp();

    // Insert multiple commands with different frequencies
    const commands_with_freq = [_]struct { cmd: []const u8, freq: i64 }{
        .{ .cmd = "git status", .freq = 5 },
        .{ .cmd = "npm install", .freq = 10 },
        .{ .cmd = "git commit", .freq = 3 },
    };

    for (commands_with_freq) |item| {
        const cmd_hash = try ranking.getCommandHash(item.cmd, std.testing.allocator);
        defer std.testing.allocator.free(cmd_hash);

        // Insert history entries
        var i: i64 = 0;
        while (i < item.freq) : (i += 1) {
            var stmt = try db.prepare(
                \\INSERT INTO history (cmd, cwd, exit_code, duration_ms, session_id, hostname, timestamp)
                \\VALUES (?, ?, 0, 0, 'test-session', 'localhost', ?)
            );
            defer stmt.deinit();
            try stmt.exec(.{}, .{ item.cmd, current_time - (i * 86400) });
        }

        // Update command stats
        try ranking.updateCommandStats(&db, item.cmd, cmd_hash, current_time);
    }

    // Recalculate ranks
    try ranking.recalculateAllRanks(&db, ranking.FrecencyConfig{}, 10, null);

    // Get top ranked commands
    const top_commands = try ranking.getTopRankedCommands(&db, 3, std.testing.allocator);
    defer {
        for (top_commands.items) |cmd_info| {
            std.testing.allocator.free(cmd_info.cmd);
        }
        top_commands.deinit();
    }

    try std.testing.expectEqual(@as(usize, 3), top_commands.items.len);

    // Verify commands are sorted by rank (npm install should be first with highest frequency)
    try std.testing.expectEqualStrings("npm install", top_commands.items[0].cmd);
    try std.testing.expectEqual(@as(i64, 10), top_commands.items[0].frequency);
}
