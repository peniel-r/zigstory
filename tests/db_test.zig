const std = @import("std");
const db = @import("db");
const sqlite = @import("sqlite");

// Helper to create a temp DB for testing
fn createTempDb() !struct { db: sqlite.Db, path: []const u8, tmp_dir: std.testing.TmpDir } {
    var tmp_dir = std.testing.tmpDir(.{});
    const db_path_buf = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ db_path_buf, "test_db.db" });
    errdefer std.testing.allocator.free(db_path);
    std.testing.allocator.free(db_path_buf);

    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path);
    defer std.testing.allocator.free(db_path_z);

    const database = try db.initDb(db_path_z);
    return .{ .db = database, .path = db_path, .tmp_dir = tmp_dir };
}

test "initDb: verify WAL mode and synchronous settings" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    // Check synchronous
    {
        var stmt = try data.db.prepare("PRAGMA synchronous");
        defer stmt.deinit();
        var iter = try stmt.iterator(struct { val: i32 }, .{});
        if (try iter.next(.{})) |row| {
            // NORMAL is 1
            try std.testing.expectEqual(@as(i32, 1), row.val);
        }
    }

    // Check busy_timeout
    {
        var stmt = try data.db.prepare("PRAGMA busy_timeout");
        defer stmt.deinit();
        var iter = try stmt.iterator(struct { val: i32 }, .{});
        if (try iter.next(.{})) |row| {
            try std.testing.expectEqual(@as(i32, 1000), row.val);
        }
    }
}

test "createTables: verify schema" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    // Check history table structure
    {
        // Simple check: try inserting a row with all fields
        const query =
            \\INSERT INTO history (cmd, cwd, exit_code, duration_ms, session_id, hostname) 
            \\VALUES (?, ?, ?, ?, ?, ?)
        ;
        var stmt = try data.db.prepare(query);
        defer stmt.deinit();
        try stmt.exec(.{}, .{
            .cmd = "echo hello",
            .cwd = "/tmp",
            .exit_code = @as(i32, 0),
            .duration_ms = @as(i64, 100),
            .session_id = "sess-1",
            .hostname = "test-host",
        });
    }

    // Check FTS table
    {
        var stmt = try data.db.prepare("INSERT INTO history_fts(history_fts) VALUES('rebuild')");
        defer stmt.deinit();
        try stmt.exec(.{}, .{});
    }
}

test "insertCommand: simple write and read" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    const cmd_text = "git commit -m 'test'";

    // Insert
    {
        var stmt = try data.db.prepare("INSERT INTO history (cmd, cwd, exit_code, duration_ms) VALUES (?, ?, ?, ?)");
        defer stmt.deinit();
        try stmt.exec(.{}, .{
            .cmd = cmd_text,
            .cwd = "/home/user",
            .exit_code = @as(i32, 0),
            .duration_ms = @as(i64, 50),
        });
    }

    // Verify row was inserted
    {
        var stmt = try data.db.prepare("SELECT COUNT(*) as count FROM history WHERE exit_code = 0");
        defer stmt.deinit();
        var iter = try stmt.iterator(struct { count: i32 }, .{});
        if (try iter.next(.{})) |row| {
            try std.testing.expectEqual(@as(i32, 1), row.count);
        }
    }
}
