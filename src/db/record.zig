const std = @import("std");
const sqlite = @import("sqlite");
const ranking = @import("ranking.zig");

pub const Entry = struct {
    cmd: []const u8,
    cwd: []const u8,
    exit_code: i32,
    duration_ms: i64,
    session_id: []const u8,
    hostname: []const u8,
    timestamp: i64,
    event_id: ?[]const u8 = null,
};

/// Reuse within a caller-owned transaction so all three writes commit together.
pub const Writer = struct {
    db: *sqlite.Db,
    insert: sqlite.DynamicStatement,
    stats: sqlite.DynamicStatement,
    rank: sqlite.DynamicStatement,

    pub fn init(db: *sqlite.Db) !Writer {
        var insert = try db.prepareDynamic(
            \\INSERT INTO history (cmd, cwd, exit_code, duration_ms, session_id, hostname, timestamp, cmd_hash, event_id)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(event_id) DO NOTHING
        );
        errdefer insert.deinit();
        var stats = try db.prepareDynamic(
            \\INSERT INTO command_stats (cmd_hash, cmd, frequency, last_used)
            \\VALUES (?, ?, 1, ?)
            \\ON CONFLICT(cmd_hash) DO UPDATE SET
            \\  frequency = frequency + 1,
            \\  last_used = MAX(last_used, excluded.last_used)
        );
        errdefer stats.deinit();
        const rank = try db.prepareDynamic(
            \\UPDATE history SET rank = (
            \\  SELECT (frequency * ?) + (? / MAX(1, (? - last_used) / 86400.0))
            \\  FROM command_stats WHERE cmd_hash = ?
            \\) WHERE id = ?
        );
        return .{ .db = db, .insert = insert, .stats = stats, .rank = rank };
    }

    pub fn deinit(self: *Writer) void {
        self.rank.deinit();
        self.stats.deinit();
        self.insert.deinit();
    }

    pub fn record(self: *Writer, entry: Entry, allocator: std.mem.Allocator, now: i64) !bool {
        if (entry.cmd.len == 0) return error.EmptyCommand;
        if (entry.cwd.len == 0) return error.EmptyPath;
        if (entry.duration_ms < 0) return error.InvalidDuration;
        if (entry.timestamp < 0) return error.InvalidTimestamp;
        if (entry.event_id) |id| {
            if (id.len == 0) return error.EmptyEventId;
        }
        const hash = try ranking.getCommandHash(entry.cmd, allocator);
        defer allocator.free(hash);
        defer resetStatement(&self.insert);
        defer resetStatement(&self.stats);
        defer resetStatement(&self.rank);
        try self.insert.exec(.{}, .{
            entry.cmd,        entry.cwd,      entry.exit_code, entry.duration_ms,
            entry.session_id, entry.hostname, entry.timestamp, hash,
            entry.event_id,
        });
        if (sqlite.c.sqlite3_changes(self.db.db) == 0) return false;
        const id = sqlite.c.sqlite3_last_insert_rowid(self.db.db);
        try self.stats.exec(.{}, .{ hash, entry.cmd, entry.timestamp });
        const config = ranking.FrecencyConfig{};
        try self.rank.exec(.{}, .{ config.frequency_weight, config.recency_weight, now, hash, id });
        return true;
    }
};

fn resetStatement(stmt: *sqlite.DynamicStatement) void {
    // sqlite3_reset returns the preceding step's error, which record propagates.
    _ = sqlite.c.sqlite3_reset(stmt.stmt);
    const rc = sqlite.c.sqlite3_clear_bindings(stmt.stmt);
    if (rc != sqlite.c.SQLITE_OK) {
        std.log.err("Failed to clear recording statement bindings: {d}", .{rc});
    }
}

pub fn rollback(db: *sqlite.Db) void {
    db.exec("ROLLBACK", .{}, .{}) catch |err| {
        std.log.err("Failed to roll back history transaction: {}", .{err});
    };
}
