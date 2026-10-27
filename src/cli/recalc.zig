const std = @import("std");
const sqlite = @import("sqlite");
const zigstory = @import("zigstory");
const ranking = zigstory.ranking;

/// Parameters for recalc-rank command
pub const RecalcParams = struct {
    db_path: [:0]const u8,
    batch_size: usize = 100,
    verbose: bool = false,
};

/// Progress callback for displaying progress
fn progressCallback(processed: usize, total: usize, verbose: bool) void {
    if (!verbose) return;

    const percentage = @as(f32, @floatFromInt(processed)) * 100.0 / @as(f32, @floatFromInt(total));
    std.debug.print("Progress: {}/{} ({d:.1}%)\r", .{ processed, total, percentage });
}

/// Recalculate all ranks in the database
pub fn recalcRanks(params: RecalcParams, allocator: std.mem.Allocator, io: std.Io) !void {
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

    // Initialize ranking tables (safe to run even if already initialized)
    try ranking.initRanking(&db);

    if (params.verbose) {
        std.debug.print("Initializing ranking system...\n", .{});
        std.debug.print("Recalculating ranks with batch size: {}\n", .{params.batch_size});
    }

    // Backfill cmd_hash for existing entries if needed
    std.debug.print("\nAbout to call backfillCmdHashes...\n", .{});
    if (params.verbose) {
        std.debug.print("Checking for missing cmd_hash values...\n", .{});
    }
    try ranking.backfillCmdHashes(&db, allocator);
    std.debug.print("BackfillCmdHashes completed.\n", .{});

    try db.exec("BEGIN IMMEDIATE", .{}, .{});
    errdefer zigstory.record.rollback(&db);
    try populateCommandStats(&db, params.verbose);

    if (params.verbose) {
        std.debug.print("\nRecalculating ranks for all history entries...\n", .{});
    }

    // Recalculate all ranks
    const Wrapper = struct {
        fn cb(processed: usize, total: usize) void {
            progressCallback(processed, total, true);
        }
    };

    try ranking.recalculateAllRanks(
        &db,
        ranking.FrecencyConfig{},
        params.batch_size,
        if (params.verbose) &Wrapper.cb else null,
        io,
    );
    try db.exec("COMMIT", .{}, .{});

    if (params.verbose) {
        std.debug.print("\nRecalculation complete!\n", .{});
    }
}

/// Populate command_stats table from existing history entries
/// This ensures backward compatibility with existing databases
fn populateCommandStats(
    db: *sqlite.Db,
    verbose: bool,
) !void {
    if (verbose) {
        std.debug.print("Populating command_stats table from history...\n", .{});
    }

    try db.exec("DELETE FROM command_stats", .{}, .{});
    try db.exec(
        \\INSERT INTO command_stats (cmd_hash, cmd, frequency, last_used)
        \\SELECT cmd_hash, cmd, COUNT(*), MAX(timestamp)
        \\FROM history GROUP BY cmd_hash
    , .{}, .{});
}
