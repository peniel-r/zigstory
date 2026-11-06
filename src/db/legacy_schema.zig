//! Only for upgrading/constructing the old unversioned schema, never recording.
const sqlite = @import("sqlite");

pub fn addColumnIfMissing(db: *sqlite.Db, comptime name: []const u8, comptime definition: []const u8) !void {
    const exists = blk: {
        var statement = try db.prepare("SELECT COUNT(*) FROM pragma_table_info('history') WHERE name='" ++ name ++ "'");
        defer statement.deinit();
        var rows = try statement.iterator(i64, .{});
        break :blk (try rows.next(.{})).? != 0;
    };
    if (!exists) try db.exec("ALTER TABLE history ADD COLUMN " ++ name ++ " " ++ definition, .{}, .{});
}

pub fn initialize(db: *sqlite.Db) !void {
    try addColumnIfMissing(db, "cmd_hash", "TEXT");
    try addColumnIfMissing(db, "rank", "REAL DEFAULT 0");
    if (sqlite.c.sqlite3_exec(db.db,
        \\CREATE TABLE IF NOT EXISTS command_stats(cmd_hash TEXT PRIMARY KEY,cmd TEXT NOT NULL,frequency INTEGER DEFAULT 1,last_used INTEGER NOT NULL);
        \\CREATE INDEX IF NOT EXISTS idx_rank ON history(rank DESC,timestamp DESC);
        \\CREATE INDEX IF NOT EXISTS idx_cmd_hash ON history(cmd_hash);
    , null, null, null) != sqlite.c.SQLITE_OK) return error.SQLiteError;
}
