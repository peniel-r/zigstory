const std = @import("std");

pub const db = @import("db/database.zig");
pub const cli = @import("cli/args.zig");
pub const ranking = @import("db/ranking.zig");

test "database initialization" {
    // Basic sanity check, more comprehensive tests in tests/db_test.zig
    _ = @import("db/database.zig");
}
