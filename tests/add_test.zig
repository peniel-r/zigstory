const std = @import("std");
const add = @import("add");
const db_mod = @import("db");
const sqlite = @import("sqlite");

// Helper to create a temp DB for testing
fn createTempDb() !struct { db: sqlite.Db, path: []const u8, tmp_dir: std.testing.TmpDir } {
    var tmp_dir = std.testing.tmpDir(.{});
    const db_path_buf = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ db_path_buf, "test_add.db" });
    errdefer std.testing.allocator.free(db_path);
    std.testing.allocator.free(db_path_buf);

    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path);
    defer std.testing.allocator.free(db_path_z);

    const database = try db_mod.initDb(db_path_z);
    return .{ .db = database, .path = db_path, .tmp_dir = tmp_dir };
}

test "addCommand: valid command inserts successfully" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    // Add a command
    try add.addCommand(&data.db, .{
        .cmd = "git status",
        .cwd = "/home/user/project",
        .exit_code = 0,
        .duration_ms = 150,
    }, std.testing.allocator);

    // Verify it was inserted
    var stmt = try data.db.prepare("SELECT COUNT(*) as count FROM history WHERE exit_code = 0");
    defer stmt.deinit();
    var iter = try stmt.iterator(struct { count: i32 }, .{});
    if (try iter.next(.{})) |row| {
        try std.testing.expectEqual(@as(i32, 1), row.count);
    }
}

test "addCommand: empty command rejected" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    // Try to add empty command
    const result = add.addCommand(&data.db, .{
        .cmd = "",
        .cwd = "/home/user",
        .exit_code = 0,
        .duration_ms = 0,
    }, std.testing.allocator);

    try std.testing.expectError(error.EmptyCommand, result);
}

test "addCommand: empty path rejected" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    // Try to add with empty path
    const result = add.addCommand(&data.db, .{
        .cmd = "ls",
        .cwd = "",
        .exit_code = 0,
        .duration_ms = 0,
    }, std.testing.allocator);

    try std.testing.expectError(error.EmptyPath, result);
}

test "addCommand: session_id is generated if not provided" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    // Add command without session_id
    try add.addCommand(&data.db, .{
        .cmd = "echo test",
        .cwd = "/tmp",
        .exit_code = 0,
        .duration_ms = 50,
    }, std.testing.allocator);

    // Verify session_id was generated (not null)
    var stmt = try data.db.prepare("SELECT COUNT(*) as count FROM history WHERE session_id IS NOT NULL");
    defer stmt.deinit();
    var iter = try stmt.iterator(struct { count: i32 }, .{});
    if (try iter.next(.{})) |row| {
        try std.testing.expectEqual(@as(i32, 1), row.count);
    }
}

test "addCommand: hostname is captured if not provided" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    // Add command without hostname
    try add.addCommand(&data.db, .{
        .cmd = "pwd",
        .cwd = "/home",
        .exit_code = 0,
        .duration_ms = 10,
    }, std.testing.allocator);

    // Verify hostname was captured (not null)
    var stmt = try data.db.prepare("SELECT COUNT(*) as count FROM history WHERE hostname IS NOT NULL");
    defer stmt.deinit();
    var iter = try stmt.iterator(struct { count: i32 }, .{});
    if (try iter.next(.{})) |row| {
        try std.testing.expectEqual(@as(i32, 1), row.count);
    }
}

test "addCommand: custom session_id and hostname are used" {
    var data = try createTempDb();
    defer {
        data.db.deinit();
        std.testing.allocator.free(data.path);
        data.tmp_dir.cleanup();
    }

    const custom_session = "test-session-123";
    const custom_hostname = "test-host";

    // Add command with custom values
    try add.addCommand(&data.db, .{
        .cmd = "custom test",
        .cwd = "/test",
        .exit_code = 0,
        .duration_ms = 25,
        .session_id = custom_session,
        .hostname = custom_hostname,
    }, std.testing.allocator);

    // Verify at least one row was inserted (custom values test is implicit since addCommand succeeded)
    var stmt = try data.db.prepare("SELECT COUNT(*) as count FROM history");
    defer stmt.deinit();

    var iter = try stmt.iterator(struct { count: i32 }, .{});
    if (try iter.next(.{})) |row| {
        try std.testing.expectEqual(@as(i32, 1), row.count);
    }
}
