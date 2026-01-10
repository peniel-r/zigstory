const std = @import("std");
const sqlite = @import("sqlite");

/// Configuration for write operations
pub const WriteConfig = struct {
    max_retries: u32 = 3,
    retry_delay_ms: u64 = 100,
};

/// Retry a database operation on SQLITE_BUSY errors
fn retryOnBusy(
    comptime func: anytype,
    args: anytype,
    config: WriteConfig,
) !void {
    var retries: u32 = 0;
    while (retries < config.max_retries) : (retries += 1) {
        @call(.auto, func, args) catch |err| {
            // Check if it's a busy error
            if (err == error.SQLiteBusy or err == error.SQLiteLocked) {
                if (retries < config.max_retries - 1) {
                    std.Thread.sleep(config.retry_delay_ms * std.time.ns_per_ms);
                    continue;
                }
            }
            return err;
        };
        return;
    }
    return error.MaxRetriesExceeded;
}

/// Parameters for a single command entry
pub const CommandEntry = struct {
    cmd: []const u8,
    cwd: []const u8,
    exit_code: i32,
    duration_ms: i64,
    session_id: []const u8,
    hostname: []const u8,
};

/// Insert a single command with retry logic
pub fn insertCommand(
    db: *sqlite.Db,
    entry: CommandEntry,
    config: WriteConfig,
) !void {
    const query =
        \\INSERT INTO history (cmd, cwd, exit_code, duration_ms, session_id, hostname)
        \\VALUES (?, ?, ?, ?, ?, ?)
    ;

    const InsertFn = struct {
        fn insert(database: *sqlite.Db, cmd_entry: CommandEntry) !void {
            var stmt = try database.prepare(query);
            defer stmt.deinit();

            try stmt.exec(.{}, .{
                .cmd = cmd_entry.cmd,
                .cwd = cmd_entry.cwd,
                .exit_code = cmd_entry.exit_code,
                .duration_ms = cmd_entry.duration_ms,
                .session_id = cmd_entry.session_id,
                .hostname = cmd_entry.hostname,
            });
        }
    };

    try retryOnBusy(InsertFn.insert, .{ db, entry }, config);
}

/// Insert multiple commands in a single transaction for better performance
pub fn insertCommandsBatch(
    db: *sqlite.Db,
    entries: []const CommandEntry,
    config: WriteConfig,
) !void {
    if (entries.len == 0) return;

    const BatchInsertFn = struct {
        fn batchInsert(database: *sqlite.Db, cmd_entries: []const CommandEntry) !void {
            // Begin transaction
            {
                var stmt = try database.prepare("BEGIN TRANSACTION");
                defer stmt.deinit();
                try stmt.exec(.{}, .{});
            }

            errdefer {
                var rollback_stmt = database.prepare("ROLLBACK") catch unreachable;
                defer rollback_stmt.deinit();
                rollback_stmt.exec(.{}, .{}) catch {};
            }

            // Prepare statement once, reuse for all inserts
            const query =
                \\INSERT INTO history (cmd, cwd, exit_code, duration_ms, session_id, hostname)
                \\VALUES (?, ?, ?, ?, ?, ?)
            ;

            var stmt = try database.prepare(query);
            defer stmt.deinit();

            // Insert all entries
            for (cmd_entries) |entry| {
                try stmt.exec(.{}, .{
                    .cmd = entry.cmd,
                    .cwd = entry.cwd,
                    .exit_code = entry.exit_code,
                    .duration_ms = entry.duration_ms,
                    .session_id = entry.session_id,
                    .hostname = entry.hostname,
                });
                stmt.reset();
            }

            // Commit transaction
            {
                var commit_stmt = try database.prepare("COMMIT");
                defer commit_stmt.deinit();
                try commit_stmt.exec(.{}, .{});
            }
        }
    };

    try retryOnBusy(BatchInsertFn.batchInsert, .{ db, entries }, config);
}

/// Connection pool for reusing database connections
pub const ConnectionPool = struct {
    db: ?*sqlite.Db,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConnectionPool {
        return .{
            .db = null,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.db) |db| {
            db.deinit();
            self.allocator.destroy(db);
            self.db = null;
        }
    }

    /// Get or create a database connection
    pub fn acquire(self: *ConnectionPool, db_path: [:0]const u8) !*sqlite.Db {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.db) |db| {
            return db;
        }

        // Create new connection
        const db_mod = @import("database");
        const new_db = try self.allocator.create(sqlite.Db);
        errdefer self.allocator.destroy(new_db);

        new_db.* = try db_mod.initDb(db_path);
        self.db = new_db;

        return new_db;
    }

    /// Release connection back to pool (no-op, connection is reused)
    pub fn release(self: *ConnectionPool, db: *sqlite.Db) void {
        _ = self;
        _ = db;
        // Connection stays in pool for reuse
    }
};
