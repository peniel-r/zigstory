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

// ─── Low-level helpers ────────────────────────────────────────────────────────
//
// Under Zig 0.16 on Windows x64, sqlite3_prepare_v2 / sqlite3_prepare_v3
// called through zig-sqlite's wrapper returns SQLITE_OK but ppStmt = null
// for valid SQL.  The root cause appears to be a codegen / ABI issue in the
// @intCast(query.len) → c_int path inside prepareWithTail.
//
// Work-around: use sqlite3_exec (which calls sqlite3_prepare_v2 internally
// in C, bypassing Zig's argument-passing) for all statements that do not
// need to return rows.  For statements that DO return rows we use a tiny
// C-callback trampoline via sqlite3_exec.
//
// For SELECT queries that return a single scalar row (the FTS rebuild check)
// we store the result through a callback context struct.

/// Execute one or more SQL statements that produce no result rows.
/// Wraps sqlite3_exec with a null callback.
fn rawExec(db: *sqlite.Db, sql: [:0]const u8) !void {
    const rc = sqlite.c.sqlite3_exec(db.db, sql.ptr, null, null, null);
    if (rc != sqlite.c.SQLITE_OK) return error.SQLiteError;
}

/// Context for rawQuery64 below.
const ScalarPair = struct { c: i64, m: i64 };

/// sqlite3_exec callback: reads two integer columns into a *ScalarPair.
fn scalarPairCallback(
    ctx: ?*anyopaque,
    argc: c_int,
    argv: [*c][*c]u8,
    _: [*c][*c]u8,
) callconv(.c) c_int {
    if (argc < 2) return 0;
    const pair: *ScalarPair = @ptrCast(@alignCast(ctx.?));
    if (argv[0]) |s| pair.c = std.fmt.parseInt(i64, std.mem.sliceTo(s, 0), 10) catch 0;
    if (argv[1]) |s| pair.m = std.fmt.parseInt(i64, std.mem.sliceTo(s, 0), 10) catch 0;
    return 0;
}

/// Run a SELECT that returns one row with two i64 columns (c, m).
fn rawQueryPair(db: *sqlite.Db, sql: [:0]const u8) !ScalarPair {
    var result = ScalarPair{ .c = 0, .m = 0 };
    const rc = sqlite.c.sqlite3_exec(db.db, sql.ptr, scalarPairCallback, &result, null);
    if (rc != sqlite.c.SQLITE_OK) return error.SQLiteError;
    return result;
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

    // ── PRAGMAs ───────────────────────────────────────────────────────────────
    try rawExec(&db, "PRAGMA journal_mode=WAL");
    try rawExec(&db, "PRAGMA synchronous=NORMAL");
    try rawExec(&db, "PRAGMA busy_timeout=1000");

    // ── Schema (CREATE TABLE / INDEX / FTS / TRIGGERS) ────────────────────────
    // Each statement is executed separately so that pre-existing objects
    // (SQLiteError = "already exists") are silently ignored.
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
        \\CREATE TRIGGER IF NOT EXISTS history_au AFTER UPDATE ON history BEGIN
        \\  INSERT INTO history_fts(history_fts, rowid, cmd)
        \\      VALUES('delete', old.id, old.cmd);
        \\  INSERT INTO history_fts(rowid, cmd) VALUES (new.id, new.cmd);
        \\END
        ,
    };
    for (ddl) |stmt| {
        rawExec(&db, stmt) catch {}; // ignore "already exists"
    }

    // ── FTS5 rebuild check ────────────────────────────────────────────────────
    const fts = try rawQueryPair(&db,
        "SELECT count(*) AS c, COALESCE(MAX(rowid),0) AS m FROM history_fts");
    const hist = try rawQueryPair(&db,
        "SELECT count(*) AS c, COALESCE(MAX(id),0) AS m FROM history");

    if (hist.c != fts.c or hist.m != fts.m) {
        try rawExec(&db, "INSERT INTO history_fts(history_fts) VALUES('rebuild')");
    }

    // ── Ranking system ────────────────────────────────────────────────────────
    try ranking.initRanking(&db);

    return db;
}
