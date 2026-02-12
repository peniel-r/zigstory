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
pub fn recalcRanks(params: RecalcParams, allocator: std.mem.Allocator) !void {
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

    // Populate command_stats table from existing history
    try populateCommandStats(&db, allocator, params.verbose);

    // Backfill cmd_hash for existing entries if needed
    std.debug.print("\nAbout to call backfillCmdHashes...\n", .{});
    if (params.verbose) {
        std.debug.print("Checking for missing cmd_hash values...\n", .{});
    }
    try ranking.backfillCmdHashes(&db, allocator);
    std.debug.print("BackfillCmdHashes completed.\n", .{});

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
    );

    if (params.verbose) {
        std.debug.print("\nRecalculation complete!\n", .{});
    }
}

/// Populate command_stats table from existing history entries
/// This ensures backward compatibility with existing databases
fn populateCommandStats(
    db: *sqlite.Db,
    allocator: std.mem.Allocator,
    verbose: bool,
) !void {
    if (verbose) {
        std.debug.print("Populating command_stats table from history...\n", .{});
    }

    // First, check if command_stats is empty
    var count_stmt = try db.prepare("SELECT COUNT(*) as count FROM command_stats");
    defer count_stmt.deinit();

    const CountResult = struct { count: i64 };
    var iter = try count_stmt.iterator(CountResult, .{});
    const stats_count = (try iter.next(.{})).?.count;

    if (stats_count > 0) {
        if (verbose) {
            std.debug.print("command_stats already has {} entries. Skipping population.\n", .{stats_count});
        }
        return;
    }

    // Get all unique commands from history with their frequency and last used time
    const query =
        \\SELECT cmd, COUNT(*) as frequency, MAX(timestamp) as last_used
        \\FROM history
        \\GROUP BY cmd;
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const Result = struct {
        cmd: []const u8,
        frequency: i64,
        last_used: i64,
    };

    var result_iter = try stmt.iterator(Result, .{});
    var count: usize = 0;

    // Begin transaction
    {
        var begin_stmt = try db.prepare("BEGIN TRANSACTION");
        defer begin_stmt.deinit();
        try begin_stmt.exec(.{}, .{});
    }

    errdefer {
        var rollback_stmt = db.prepare("ROLLBACK") catch unreachable;
        defer rollback_stmt.deinit();
        rollback_stmt.exec(.{}, .{}) catch {};
    }

    // Insert into command_stats
    const insert_query =
        \\INSERT INTO command_stats (cmd_hash, cmd, frequency, last_used)
        \\VALUES (?, ?, ?, ?);
    ;

    var insert_stmt = try db.prepare(insert_query);
    defer insert_stmt.deinit();

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const row = (try result_iter.nextAlloc(arena.allocator(), .{})) orelse break;

        const cmd_hash = try ranking.getCommandHash(row.cmd, allocator);
        defer allocator.free(cmd_hash);

        try insert_stmt.exec(.{}, .{
            cmd_hash,
            row.cmd,
            row.frequency,
            row.last_used,
        });
        insert_stmt.reset();

        count += 1;

        if (verbose and count % 100 == 0) {
            std.debug.print("Processed {} unique commands...\r", .{count});
        }
    }

    // Commit transaction
    {
        var commit_stmt = try db.prepare("COMMIT");
        defer commit_stmt.deinit();
        try commit_stmt.exec(.{}, .{});
    }

    if (verbose) {
        std.debug.print("\nPopulated {} unique commands into command_stats.\n", .{count});
    }
}
