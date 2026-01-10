const std = @import("std");

pub const db = @import("db/database.zig");
pub const cli = @import("cli/args.zig");

test "database initialization" {
    // Test database flow
    // Use a temporary file for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const db_path_buf = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(db_path_buf);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ db_path_buf, "test.db" });
    defer std.testing.allocator.free(db_path);

    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path);
    defer std.testing.allocator.free(db_path_z);

    // Initialize DB
    var test_db = try db.initDb(db_path_z);
    defer test_db.deinit();

    // Verify tables exist
    _ = try test_db.prepare("SELECT count(*) FROM history");
    _ = try test_db.prepare("SELECT count(*) FROM history_fts");
}
