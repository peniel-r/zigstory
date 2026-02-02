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

const ranking = @import("ranking.zig");

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
    try db.exec(
        \\CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(cmd, content='history', content_rowid='id');
    , .{}, .{});

    // Triggers to keep FTS5 index in sync
    try db.exec(
        \\CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
        \\  INSERT INTO history_fts(rowid, cmd) VALUES (new.id, new.cmd);
        \\END;
        \\CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
        \\  INSERT INTO history_fts(history_fts, rowid, cmd) VALUES('delete', old.id, old.cmd);
        \\END;
        \\CREATE TRIGGER IF NOT EXISTS history_au AFTER UPDATE ON history BEGIN
        \\  INSERT INTO history_fts(history_fts, rowid, cmd) VALUES('delete', old.id, old.cmd);
        \\  INSERT INTO history_fts(rowid, cmd) VALUES (new.id, new.cmd);
        \\END;
    , .{}, .{});

    // Check if rebuild is needed (if history exists but fts is empty)
    // This handles the case where the table existed before triggers were added
    // Check for sync issues (count mismatch OR max ID mismatch)
    var fts_count: i64 = 0;
    var fts_max: i64 = 0;
    var history_count: i64 = 0;
    var history_max: i64 = 0;

    // We can't use db.prepare directly easily for scalar with this library wrapper sometimes,
    // but let's try standard iterator approach
    {
        var stmt = try db.prepare("SELECT count(*) as c, COALESCE(MAX(rowid), 0) as m FROM history_fts");
        defer stmt.deinit();
        var iter = try stmt.iterator(struct { c: i64, m: i64 }, .{});
        if (try iter.next(.{})) |row| {
            fts_count = row.c;
            fts_max = row.m;
        }
    }
    {
        var stmt = try db.prepare("SELECT count(*) as c, COALESCE(MAX(id), 0) as m FROM history");
        defer stmt.deinit();
        var iter = try stmt.iterator(struct { c: i64, m: i64 }, .{});
        if (try iter.next(.{})) |row| {
            history_count = row.c;
            history_max = row.m;
        }
    }

    if (history_count != fts_count or history_max != fts_max) {
        try db.exec("INSERT INTO history_fts(history_fts) VALUES('rebuild')", .{}, .{});
    }

    // Initialize ranking system (tables and columns)
    try ranking.initRanking(&db);

    return db;
}
