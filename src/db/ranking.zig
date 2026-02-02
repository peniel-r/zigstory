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
) f64 {
    const current_time = std.time.timestamp();
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
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS command_stats (
        \\    cmd_hash TEXT PRIMARY KEY,
        \\    cmd TEXT NOT NULL,
        \\    frequency INTEGER DEFAULT 1,
        \\    last_used INTEGER NOT NULL
        \\);
    , .{}, .{});
}

/// Add rank column to history table
pub fn addRankColumn(db: *sqlite.Db) !void {
    try db.exec(
        \\ALTER TABLE history ADD COLUMN rank REAL DEFAULT 0;
    , .{}, .{});
}

/// Create index on rank column
pub fn createRankIndex(db: *sqlite.Db) !void {
    try db.exec(
        \\CREATE INDEX IF NOT EXISTS idx_rank ON history(rank DESC, timestamp DESC);
    , .{}, .{});
}

/// Initialize ranking tables and columns
pub fn initRanking(db: *sqlite.Db) !void {
    // Create command_stats table
    createCommandStatsTable(db) catch |err| {
        // Ignore error if table already exists
        if (err != error.SQLiteError) return err;
    };

    // Add rank column to history table
    addRankColumn(db) catch |err| {
        // Ignore error if column already exists
        if (err != error.SQLiteError) return err;
    };

    // Create index on rank
    createRankIndex(db) catch |err| {
        // Ignore error if index already exists
        if (err != error.SQLiteError) return err;
    };
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
        \\    last_used = ?;
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
) !void {
    const current_time = std.time.timestamp();
    const query =
        \\UPDATE history h
        \\SET rank = (
        \\    SELECT (s.frequency * ?) + (? / MAX(1, (? - s.last_used) / 86400.0))
        \\    FROM command_stats s
        \\    WHERE s.cmd_hash = ?
        \\)
        \\WHERE h.id = ?;
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
) !void {
    const current_time = std.time.timestamp();

    // Get total count
    var count_stmt = try db.prepare("SELECT COUNT(*) as total FROM history");
    defer count_stmt.deinit();

    const CountResult = struct { total: i64 };
    var iter = try count_stmt.iterator(CountResult, .{});
    const total = (try iter.next(.{})).?.total;

    // Update in batches
    const update_query =
        \\UPDATE history h
        \\SET rank = (
        \\    SELECT COALESCE(
        \\        (s.frequency * ?) + (? / MAX(1, (? - s.last_used) / 86400.0)),
        \\        0
        \\    )
        \\    FROM command_stats s
        \\    WHERE s.cmd_hash = (
        \\        SELECT sub.cmd_hash FROM history sub WHERE sub.id = h.id
        \\    )
        \\)
        \\WHERE id BETWEEN ? AND ?;
    ;

    var processed: i64 = 0;
    while (processed < total) {
        const batch_i64 = @as(i64, @intCast(batch_size));
        const end = @min(processed + batch_i64 - 1, total - 1);

        var stmt = try db.prepare(update_query);
        defer stmt.deinit();

        try stmt.exec(.{}, .{
            config.frequency_weight,
            config.recency_weight,
            current_time,
            processed + 1,
            end + 1,
        });

        processed = end + 1;

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
