const std = @import("std");
const sqlite = @import("sqlite");
const scrolling = @import("scrolling.zig");
const directory_filter = @import("directory_filter.zig");

pub const SearchState = struct {
    query: std.ArrayListUnmanaged(u8) = .empty,
    results: []scrolling.HistoryEntry = &.{},
    results_arena: std.heap.ArenaAllocator,
    results_offset: usize = 0,
    total_count: usize = 0,
    filter_state: directory_filter.DirectoryFilterState = .{},
    cache_db: ?*sqlite.Db = null,
    cache_table: ?[:0]u8 = null,
    cache_valid: bool = false,
    cache_version: i64 = 0,
    cache_changes: c_int = 0,
    cache_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) SearchState {
        return .{ .results_arena = .init(allocator) };
    }

    pub fn deinit(self: *SearchState, allocator: std.mem.Allocator) void {
        self.dropCache(allocator);
        self.query.deinit(allocator);
        self.results_arena.deinit();
    }

    fn dropCache(self: *SearchState, allocator: std.mem.Allocator) void {
        if (self.cache_table) |table| {
            var buffer: [128]u8 = undefined;
            const sql = std.fmt.bufPrintZ(&buffer, "DROP TABLE IF EXISTS temp.{s}", .{table}) catch unreachable;
            self.cache_db.?.execDynamic(sql, .{}, .{}) catch |err| {
                std.log.err("Failed to release search cache: {}", .{err});
            };
            allocator.free(table);
        }
        self.cache_table = null;
        self.cache_db = null;
        self.cache_valid = false;
    }

    pub fn loadPage(self: *SearchState, db: *sqlite.Db, limit: usize, offset: usize, recount: bool) !void {
        self.results = &.{};
        _ = self.results_arena.reset(.retain_capacity);
        const allocator = self.results_arena.allocator();

        if (self.query.items.len == 0) {
            self.dropCache(self.results_arena.child_allocator);
            if (self.filter_state.isActive()) {
                try self.fetch(db, " WHERE cwd = ?", .{self.filter_state.current_dir.?}, limit, offset, recount);
            } else {
                try self.fetch(db, "", .{}, limit, offset, recount);
            }
            return;
        }

        var pattern: std.ArrayListUnmanaged(u8) = .empty;
        try pattern.append(allocator, '%');
        for (self.query.items) |c| {
            if (c == '%' or c == '_' or c == '\\') try pattern.append(allocator, '\\');
            try pattern.append(allocator, c);
        }
        try pattern.append(allocator, '%');

        if (self.filter_state.isActive()) {
            try self.fetch(db, " WHERE cmd LIKE ? ESCAPE '\\' AND cwd = ?", .{ pattern.items, self.filter_state.current_dir.? }, limit, offset, recount);
        } else {
            try self.fetch(db, " WHERE cmd LIKE ? ESCAPE '\\'", .{pattern.items}, limit, offset, recount);
        }
    }

    fn fetch(self: *SearchState, db: *sqlite.Db, comptime where: []const u8, values: anytype, limit: usize, offset: usize, recount: bool) !void {
        const searching = self.query.items.len > 0;
        if (searching) return self.fetchSearch(db, where, values, limit, offset, recount);
        if (recount) {
            const count_sql = "SELECT COUNT(*) AS count FROM history" ++ where;
            var count_stmt = try db.prepareDynamic(count_sql);
            defer count_stmt.deinit();
            var counts = try count_stmt.iterator(struct { count: i64 }, values);
            self.total_count = @intCast((try counts.next(.{})).?.count);
        }

        const page_sql = "SELECT id, cmd, cwd, exit_code, duration_ms, timestamp FROM history" ++ where ++
            " ORDER BY timestamp DESC, id DESC LIMIT ? OFFSET ?";
        var stmt = try db.prepareDynamic(page_sql);
        defer stmt.deinit();
        var rows = try stmt.iterator(scrolling.HistoryEntry, values ++ .{ @as(i64, @intCast(limit)), @as(i64, @intCast(offset)) });
        const allocator = self.results_arena.allocator();
        var results: std.ArrayListUnmanaged(scrolling.HistoryEntry) = .empty;
        while (try rows.nextAlloc(allocator, .{})) |row| {
            try results.append(allocator, row);
        }
        self.results = try results.toOwnedSlice(allocator);
        self.results_offset = offset;
    }

    fn fetchSearch(self: *SearchState, db: *sqlite.Db, comptime where: []const u8, values: anytype, limit: usize, offset: usize, recount: bool) !void {
        const allocator = self.results_arena.child_allocator;
        if (self.cache_db != db) self.dropCache(allocator);
        if (self.cache_table == null) {
            const table = try std.fmt.allocPrintSentinel(allocator, "zigstory_search_{x}", .{@intFromPtr(self)}, 0);
            errdefer allocator.free(table);
            const ddl = try std.fmt.allocPrintSentinel(allocator, "CREATE TEMP TABLE {s}(position INTEGER PRIMARY KEY, history_id INTEGER NOT NULL)", .{table}, 0);
            defer allocator.free(ddl);
            try db.execDynamic(ddl, .{}, .{});
            self.cache_table = table;
            self.cache_db = db;
        }
        var version_stmt = try db.prepare("PRAGMA data_version");
        defer version_stmt.deinit();
        var versions = try version_stmt.iterator(i64, .{});
        const version = (try versions.next(.{})).?;
        if (recount or !self.cache_valid or self.cache_version != version or
            self.cache_changes != sqlite.c.sqlite3_total_changes(db.db))
        {
            self.cache_valid = false;
            const delete_sql = try std.fmt.allocPrintSentinel(allocator, "DELETE FROM temp.{s}", .{self.cache_table.?}, 0);
            defer allocator.free(delete_sql);
            try db.execDynamic(delete_sql, .{}, .{});
            // Materialize only IDs once, not command strings on every page. The
            // integer primary key supports indexed absolute paging without OFFSET.
            const sql = try std.fmt.allocPrintSentinel(allocator, "INSERT INTO temp.{s}(history_id) " ++
                "SELECT id FROM (SELECT id,timestamp,ROW_NUMBER() OVER " ++
                "(PARTITION BY cmd ORDER BY timestamp DESC,id DESC) AS newest FROM history" ++ where ++
                ") WHERE newest=1 ORDER BY timestamp DESC,id DESC", .{self.cache_table.?}, 0);
            defer allocator.free(sql);
            var insert = try db.prepareDynamic(sql);
            defer insert.deinit();
            try insert.exec(.{}, values);
            self.cache_count = @intCast(sqlite.c.sqlite3_changes(db.db));
            self.cache_changes = sqlite.c.sqlite3_total_changes(db.db);
            self.cache_version = version;
            self.cache_valid = true;
        }
        self.total_count = self.cache_count;
        const page_sql = try std.fmt.allocPrintSentinel(allocator, "SELECT h.id,h.cmd,h.cwd,h.exit_code,h.duration_ms,h.timestamp FROM temp.{s} AS p " ++
            "CROSS JOIN history AS h ON h.id=p.history_id " ++
            "WHERE p.position > ? AND p.position <= ? ORDER BY p.position", .{self.cache_table.?}, 0);
        defer allocator.free(page_sql);
        var stmt = try db.prepareDynamic(page_sql);
        defer stmt.deinit();
        var rows = try stmt.iterator(scrolling.HistoryEntry, .{ @as(i64, @intCast(offset)), @as(i64, @intCast(offset +| limit)) });
        const result_allocator = self.results_arena.allocator();
        var results: std.ArrayListUnmanaged(scrolling.HistoryEntry) = .empty;
        while (try rows.nextAlloc(result_allocator, .{})) |row| try results.append(result_allocator, row);
        self.results = try results.toOwnedSlice(result_allocator);
        self.results_offset = offset;
    }
};
