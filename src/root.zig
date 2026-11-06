const std = @import("std");

pub const db = @import("db/database.zig");
pub const cli = @import("cli/args.zig");
pub const record = @import("db/record.zig");
// Normalized storage, search and exponentially decayed score keys.
pub const catalog = @import("db/catalog.zig");

test "database initialization" {
    // Basic sanity check; full coverage runs from src/regression_tests.zig.
    _ = @import("db/database.zig");
}
