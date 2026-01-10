const std = @import("std");
const sqlite = @import("sqlite");

pub const History = struct {
    id: ?i64 = null,
    cmd: []const u8,
    cwd: []const u8,
    exit_code: i32,
    duration_ms: i64,
    session_id: []const u8,
    hostname: []const u8,
    timestamp: i64,
};

pub fn initDb(path: [:0]const u8) !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });

    // Validating basic connection
    // Ensure WAL Mode
    // PRAGMA journal_mode returns a row, so we use prepare/step
    {
        var stmt = try db.prepare("PRAGMA journal_mode=WAL");
        defer stmt.deinit();
        var iter = try stmt.iterator(void, .{});
        _ = try iter.next(.{});
    }

    // These behave like updates usually, but prepare is safer
    {
        var stmt = try db.prepare("PRAGMA synchronous=NORMAL");
        defer stmt.deinit();
        var iter = try stmt.iterator(void, .{});
        _ = try iter.next(.{});
    }
    {
        var stmt = try db.prepare("PRAGMA busy_timeout=1000");
        defer stmt.deinit();
        var iter = try stmt.iterator(void, .{});
        _ = try iter.next(.{});
    }

    // Create Tables
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS history (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    cmd TEXT NOT NULL,
        \\    cwd TEXT NOT NULL,
        \\    exit_code INTEGER,
        \\    duration_ms INTEGER,
        \\    session_id TEXT,
        \\    hostname TEXT,
        \\    timestamp INTEGER DEFAULT (strftime('%s', 'now'))
        \\);
    , .{}, .{});

    // Create Index for prefix search (used by predictor)
    try db.exec(
        \\CREATE INDEX IF NOT EXISTS idx_cmd_prefix ON history(cmd COLLATE NOCASE);
    , .{}, .{});

    // Create FTS5 virtual table for TUI search
    // Note: FTS5 might not be enabled by default in some builds, but zig-sqlite usually enables it.
    // If this fails, we might need check build flags.
    try db.exec(
        \\CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(cmd, content='history', content_rowid='id');
    , .{}, .{});

    return db;
}
