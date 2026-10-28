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
const record = @import("record.zig");

pub const schema_version = 1;

/// Execute one or more SQL statements that produce no result rows.
/// Wraps sqlite3_exec with a null callback.
fn rawExec(db: *sqlite.Db, sql: [:0]const u8) !void {
    const rc = sqlite.c.sqlite3_exec(db.db, sql.ptr, null, null, null);
    if (rc != sqlite.c.SQLITE_OK) return error.SQLiteError;
}

fn queryInt(db: *sqlite.Db, comptime sql: []const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    var rows = try stmt.iterator(i64, .{});
    return (try rows.next(.{})) orelse error.MissingDatabaseMetadata;
}

// ─── initDb ───────────────────────────────────────────────────────────────────

pub fn initDb(path: [:0]const u8) !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    errdefer db.deinit();

    // ── PRAGMAs ───────────────────────────────────────────────────────────────
    try rawExec(&db, "PRAGMA busy_timeout=1000");
    try rawExec(&db, "PRAGMA journal_mode=WAL");
    try rawExec(&db, "PRAGMA synchronous=NORMAL");

    try ensureSchema(&db);
    return db;
}

pub fn ensureSchema(db: *sqlite.Db) !void {
    const version = try queryInt(db, "PRAGMA user_version");
    if (version > schema_version) return error.UnsupportedSchemaVersion;
    if (version < schema_version) try migrate(db);
}

fn migrate(db: *sqlite.Db) !void {
    try rawExec(db, "BEGIN IMMEDIATE");
    errdefer record.rollback(db);
    // Another process may have migrated while this connection waited for the lock.
    const version = try queryInt(db, "PRAGMA user_version");
    if (version > schema_version) return error.UnsupportedSchemaVersion;
    if (version == schema_version) {
        try rawExec(db, "COMMIT");
        return;
    }
    const had_fts = try queryInt(db, "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'history_fts'") != 0;
    const ddl = [_][:0]const u8{
        \\CREATE TABLE IF NOT EXISTS history (
        \\    id          INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    cmd         TEXT    NOT NULL,
        \\    cwd         TEXT    NOT NULL,
        \\    exit_code   INTEGER,
        \\    duration_ms INTEGER,
        \\    session_id  TEXT,
        \\    hostname    TEXT,
        \\    timestamp   INTEGER DEFAULT (strftime('%s', 'now'))
        \\)
        ,
        "CREATE INDEX IF NOT EXISTS idx_cmd_prefix ON history(cmd COLLATE NOCASE)",
        "CREATE INDEX IF NOT EXISTS idx_history_time ON history(timestamp DESC, id DESC)",
        "CREATE INDEX IF NOT EXISTS idx_history_cwd_time ON history(cwd, timestamp DESC, id DESC)",
        "CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(cmd, content='history', content_rowid='id')",
        \\CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
        \\  INSERT INTO history_fts(rowid, cmd) VALUES (new.id, new.cmd);
        \\END
        ,
        \\CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
        \\  INSERT INTO history_fts(history_fts, rowid, cmd)
        \\      VALUES('delete', old.id, old.cmd);
        \\END
        ,
        "DROP TRIGGER IF EXISTS history_au",
        \\CREATE TRIGGER history_au AFTER UPDATE OF cmd, id ON history
        \\WHEN old.cmd IS NOT new.cmd OR old.id IS NOT new.id BEGIN
        \\  INSERT INTO history_fts(history_fts, rowid, cmd)
        \\      VALUES('delete', old.id, old.cmd);
        \\  INSERT INTO history_fts(rowid, cmd) VALUES (new.id, new.cmd);
        \\END
        ,
    };
    for (ddl) |stmt| {
        try rawExec(db, stmt);
    }
    if (!had_fts) {
        try rawExec(db, "INSERT INTO history_fts(history_fts) VALUES('rebuild')");
    }
    try ranking.initRanking(db);
    try rawExec(db, "PRAGMA user_version=1");
    try rawExec(db, "COMMIT");
}

/// Explicitly rebuild and validate the external-content FTS index.
pub fn maintain(db: *sqlite.Db) !void {
    {
        try rawExec(db, "BEGIN IMMEDIATE");
        errdefer record.rollback(db);
        try rawExec(db, "INSERT INTO history_fts(history_fts) VALUES('rebuild')");
        try rawExec(db, "INSERT INTO history_fts(history_fts, rank) VALUES('integrity-check', 1)");
        try rawExec(db, "COMMIT");
    }
    try rawExec(db, "PRAGMA optimize");
}
