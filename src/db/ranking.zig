const std = @import("std");
const sqlite = @import("sqlite");

/// Constants for frecency calculation
pub const FrecencyConfig = struct {
    /// Weight for frequency component
    frequency_weight: f64 = 2.0,
    /// Weight for recency component
    recency_weight: f64 = 100.0,
    /// Maximum days to consider (prevents division by very small numbers)
    max_days: i64 = 365,
};

/// Calculate frecency rank for a command
/// Formula: rank = (frequency * weight) + (recency_weight / days_since_last_use)
pub fn calculateFrecency(
    frequency: i64,
    last_used: i64,
    config: FrecencyConfig,
    current_time: i64,
) f64 {
    const seconds_since_last_use = current_time - last_used;
    const days_since_last_use = @max(1, seconds_since_last_use / 86400);
    const capped_days = @min(days_since_last_use, config.max_days);

    const freq_score = @as(f64, @floatFromInt(frequency)) * config.frequency_weight;
    const recency_score = config.recency_weight / @as(f64, @floatFromInt(capped_days));

    return freq_score + recency_score;
}

/// Get SHA256 hash of a normalized command
pub fn getCommandHash(cmd: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(cmd);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    // Convert to hex string
    var hex: [64]u8 = undefined;
    var i: usize = 0;
    for (hash) |byte| {
        _ = std.fmt.bufPrint(hex[i .. i + 2], "{x:0>2}", .{byte}) catch unreachable;
        i += 2;
    }

    return try allocator.dupe(u8, &hex);
}

/// Create command_stats table for tracking frequency
pub fn createCommandStatsTable(db: *sqlite.Db) !void {
    try db.execDynamic(
        \\CREATE TABLE IF NOT EXISTS command_stats (
        \\    cmd_hash TEXT PRIMARY KEY,
        \\    cmd TEXT NOT NULL,
        \\    frequency INTEGER DEFAULT 1,
        \\    last_used INTEGER NOT NULL
        \\)
    , .{}, .{});
}

/// Add cmd_hash column to history table
pub fn addCmdHashColumn(db: *sqlite.Db) !void {
    try addColumnIfMissing(db, "cmd_hash", "TEXT");
}

/// Add rank column to history table
pub fn addRankColumn(db: *sqlite.Db) !void {
    try addColumnIfMissing(db, "rank", "REAL DEFAULT 0");
}

fn addColumnIfMissing(db: *sqlite.Db, comptime name: []const u8, comptime definition: []const u8) !void {
    const exists = blk: {
        var stmt = try db.prepare("SELECT COUNT(*) FROM pragma_table_info('history') WHERE name = '" ++ name ++ "'");
        defer stmt.deinit();
        var rows = try stmt.iterator(i64, .{});
        break :blk (try rows.next(.{})).? != 0;
    };
    if (!exists) {
        try db.exec("ALTER TABLE history ADD COLUMN " ++ name ++ " " ++ definition, .{}, .{});
    }
}

/// Create index on rank column
pub fn createRankIndex(db: *sqlite.Db) !void {
    try db.execDynamic("CREATE INDEX IF NOT EXISTS idx_rank ON history(rank DESC, timestamp DESC)", .{}, .{});
}

/// Create index on cmd_hash column
pub fn createCmdHashIndex(db: *sqlite.Db) !void {
    try db.execDynamic("CREATE INDEX IF NOT EXISTS idx_cmd_hash ON history(cmd_hash)", .{}, .{});
}

/// Backfill cmd_hash for existing history entries that don't have it
pub fn backfillCmdHashes(db: *sqlite.Db, allocator: std.mem.Allocator) !void {
    // Check if backfill is needed
    var count_stmt = try db.prepare("SELECT COUNT(*) as count FROM history WHERE cmd_hash IS NULL");
    defer count_stmt.deinit();

    const CountResult = struct { count: i64 };
    var iter = try count_stmt.iterator(CountResult, .{});
    const null_count = (try iter.next(.{})).?.count;

    std.debug.print("Found {} entries without cmd_hash\n", .{null_count});

    if (null_count == 0) {
        // No backfill needed
        std.debug.print("No backfill needed - all entries have cmd_hash\n", .{});
        return;
    }

    std.debug.print("Backfilling cmd_hash for {} existing entries...\n", .{null_count});

    // Get all entries without cmd_hash
    const query = "SELECT id, cmd FROM history WHERE cmd_hash IS NULL";
    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const EntryResult = struct { id: i64, cmd: []const u8 };
    var result_iter = try stmt.iterator(EntryResult, .{});

    // Begin transaction
    var begin_stmt = try db.prepare("BEGIN TRANSACTION");
    defer begin_stmt.deinit();
    try begin_stmt.exec(.{}, .{});

    errdefer {
        var rollback_stmt = db.prepare("ROLLBACK") catch unreachable;
        defer rollback_stmt.deinit();
        rollback_stmt.exec(.{}, .{}) catch {};
    }

    // Update each entry with cmd_hash
    const update_query =
        \\UPDATE history
        \\SET cmd_hash = ?
        \\WHERE id = ?
    ;
    var update_stmt = try db.prepare(update_query);
    defer update_stmt.deinit();

    var processed: usize = 0;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const row = (try result_iter.nextAlloc(arena.allocator(), .{})) orelse break;

        const cmd_hash = try getCommandHash(row.cmd, arena.allocator());

        try update_stmt.exec(.{}, .{
            .cmd_hash = cmd_hash,
            .id = row.id,
        });
        update_stmt.reset();

        processed += 1;

        if (processed % 1000 == 0) {
            std.debug.print("\rBackfilled {} entries...", .{processed});
        }
    }

    std.debug.print("\rBackfilled {} entries.\n", .{processed});

    // Commit transaction
    {
        var commit_stmt = try db.prepare("COMMIT");
        defer commit_stmt.deinit();
        try commit_stmt.exec(.{}, .{});
    }

    std.debug.print("Backfill completed successfully!\n", .{});
}

/// Initialize ranking tables and columns
pub fn initRanking(db: *sqlite.Db) !void {
    try createCommandStatsTable(db);
    try addCmdHashColumn(db);
    try addRankColumn(db);
    try createRankIndex(db);
    try createCmdHashIndex(db);
}

/// Update command frequency and recency stats when a command is executed
pub fn updateCommandStats(
    db: *sqlite.Db,
    cmd: []const u8,
    cmd_hash: []const u8,
    current_time: i64,
) !void {
    const query =
        \\INSERT INTO command_stats (cmd_hash, cmd, frequency, last_used)
        \\VALUES (?, ?, 1, ?)
        \\ON CONFLICT(cmd_hash) DO UPDATE SET
        \\    frequency = frequency + 1,
        \\    last_used = MAX(last_used, ?);
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    try stmt.exec(.{}, .{
        cmd_hash,
        cmd,
        current_time,
        current_time,
    });
}

/// Calculate and update rank for a single history entry
pub fn updateHistoryRank(
    db: *sqlite.Db,
    history_id: i64,
    cmd_hash: []const u8,
    config: FrecencyConfig,
    io: std.Io,
) !void {
    // std.time.timestamp() removed in Zig 0.16 – use Io.Timestamp.
    const current_time = std.Io.Timestamp.now(io, .real).toSeconds();
    const query =
        \\UPDATE history
        \\SET rank = (
        \\    SELECT (s.frequency * ?) + (? / MAX(1, (? - s.last_used) / 86400.0))
        \\    FROM command_stats s
        \\    WHERE s.cmd_hash = ?
        \\)
        \\WHERE id = ?
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    try stmt.exec(.{}, .{
        config.frequency_weight,
        config.recency_weight,
        current_time,
        cmd_hash,
        history_id,
    });
}

/// Progress callback type
pub const ProgressCallback = *const fn (usize, usize) void;

/// Recalculate all ranks in batch
pub fn recalculateAllRanks(
    db: *sqlite.Db,
    config: FrecencyConfig,
    batch_size: usize,
    progress_callback: ?ProgressCallback,
    io: std.Io,
) !void {
    if (batch_size == 0) return error.InvalidBatchSize;
    // std.time.timestamp() removed in Zig 0.16 – use Io.Timestamp.
    const current_time = std.Io.Timestamp.now(io, .real).toSeconds();

    // Get total count
    var count_stmt = try db.prepare("SELECT COUNT(*) as total FROM history");
    defer count_stmt.deinit();

    const CountResult = struct { total: i64 };
    var iter = try count_stmt.iterator(CountResult, .{});
    const total = (try iter.next(.{})).?.total;

    // Update in batches
    const update_query =
        \\UPDATE history
        \\SET rank = COALESCE((
        \\    SELECT
        \\        (s.frequency * ?) + (? / MAX(1, (? - s.last_used) / 86400.0))
        \\    FROM command_stats s
        \\    WHERE s.cmd_hash = history.cmd_hash
        \\), 0)
        \\WHERE id IN (SELECT id FROM history WHERE id > ? ORDER BY id LIMIT ?);
    ;

    var processed: i64 = 0;
    var last_id: i64 = 0;
    var stmt = try db.prepare(update_query);
    defer stmt.deinit();
    var end_stmt = try db.prepare("SELECT MAX(id) AS id FROM (SELECT id FROM history WHERE id > ? ORDER BY id LIMIT ?)");
    defer end_stmt.deinit();
    while (processed < total) {
        const batch_i64 = @as(i64, @intCast(batch_size));
        var end_iter = try end_stmt.iterator(struct { id: ?i64 }, .{ last_id, batch_i64 });
        const end = (try end_iter.next(.{})).?.id orelse break;
        end_stmt.reset();

        try stmt.exec(.{}, .{
            config.frequency_weight,
            config.recency_weight,
            current_time,
            last_id,
            batch_i64,
        });
        stmt.reset();

        last_id = end;
        processed = @min(processed + batch_i64, total);

        if (progress_callback) |cb| {
            cb(@intCast(processed), @intCast(total));
        }
    }
}

/// Get command statistics for a specific command
pub const CommandStats = struct {
    cmd_hash: []const u8,
    cmd: []const u8,
    frequency: i64,
    last_used: i64,
    rank: f64,
};

pub fn getCommandStats(
    db: *sqlite.Db,
    cmd: []const u8,
    allocator: std.mem.Allocator,
) !?CommandStats {
    const query =
        \\SELECT s.cmd_hash, s.cmd, s.frequency, s.last_used, h.rank
        \\FROM command_stats s
        \\LEFT JOIN (
        \\    SELECT h.cmd, h.rank
        \\    FROM history h
        \\    ORDER BY h.timestamp DESC
        \\    LIMIT 1
        \\) h ON h.cmd = s.cmd
        \\WHERE s.cmd = ?;
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    var iter = try stmt.iterator(struct {
        cmd_hash: []const u8,
        cmd: []const u8,
        frequency: i64,
        last_used: i64,
        rank: ?f64,
    }, .{cmd});

    if (try iter.next(.{})) |row| {
        return CommandStats{
            .cmd_hash = try allocator.dupe(u8, row.cmd_hash),
            .cmd = try allocator.dupe(u8, row.cmd),
            .frequency = row.frequency,
            .last_used = row.last_used,
            .rank = row.rank orelse 0.0,
        };
    }

    return null;
}

/// Get top commands by rank
pub fn getTopRankedCommands(
    db: *sqlite.Db,
    limit: usize,
    allocator: std.mem.Allocator,
) !std.ArrayList(struct {
    cmd: []const u8,
    frequency: i64,
    last_used: i64,
    rank: f64,
}) {
    const query =
        \\SELECT h.cmd, s.frequency, s.last_used, h.rank
        \\FROM history h
        \\JOIN command_stats s ON (
        \\    SELECT sub.cmd_hash FROM history sub WHERE sub.id = h.id
        \\) = s.cmd_hash
        \\GROUP BY h.cmd
        \\ORDER BY h.rank DESC, h.timestamp DESC
        \\LIMIT ?;
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    var iter = try stmt.iterator(struct {
        cmd: []const u8,
        frequency: i64,
        last_used: i64,
        rank: f64,
    }, .{@intCast(limit)});

    var results = std.ArrayList(struct {
        cmd: []const u8,
        frequency: i64,
        last_used: i64,
        rank: f64,
    }).init(allocator);

    while (try iter.next(.{})) |row| {
        try results.append(.{
            .cmd = try allocator.dupe(u8, row.cmd),
            .frequency = row.frequency,
            .last_used = row.last_used,
            .rank = row.rank,
        });
    }

    return results;
}
