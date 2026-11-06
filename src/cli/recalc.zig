const std = @import("std");
const sqlite = @import("sqlite");
const zigstory = @import("zigstory");

/// Parameters for recalc-rank command
pub const RecalcParams = struct {
    db_path: [:0]const u8,
    batch_size: usize = 100,
    verbose: bool = false,
};

/// Compatibility command: scores decay without rewrites; explicitly repair
/// catalog counts, latest links, locations and FTS when requested.
pub fn recalcRanks(params: RecalcParams, allocator: std.mem.Allocator, io: std.Io) !void {
    _ = allocator;
    _ = io;
    if (params.batch_size == 0) return error.InvalidBatchSize;
    // Open database
    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = params.db_path },
        .open_flags = .{
            .write = true,
            .create = false,
        },
        .threading_mode = .MultiThread,
    });
    defer db.deinit();

    if (sqlite.c.sqlite3_busy_timeout(db.db, 1000) != sqlite.c.SQLITE_OK) return error.SQLiteError;
    try zigstory.db.ensureSchema(&db);

    if (params.verbose) std.debug.print("Backfill compatibility: rebuilding catalog statistics and search index...\n", .{});
    try zigstory.db.maintain(&db);
    if (params.verbose) std.debug.print("Catalog statistics and search index rebuilt and validated.\n", .{});
}
