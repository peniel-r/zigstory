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

    pub fn init(allocator: std.mem.Allocator) SearchState {
        return .{ .results_arena = .init(allocator) };
    }

    pub fn deinit(self: *SearchState, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        self.results_arena.deinit();
    }

    pub fn loadPage(self: *SearchState, db: *sqlite.Db, limit: usize, offset: usize, recount: bool) !void {
        self.results = &.{};
        _ = self.results_arena.reset(.retain_capacity);
        const allocator = self.results_arena.allocator();

        if (self.query.items.len == 0) {
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
        if (recount) {
            const count_sql = if (searching)
                "SELECT COUNT(DISTINCT cmd) AS count FROM history" ++ where
            else
                "SELECT COUNT(*) AS count FROM history" ++ where;
            var count_stmt = try db.prepareDynamic(count_sql);
            defer count_stmt.deinit();
            var counts = try count_stmt.iterator(struct { count: i64 }, values);
            self.total_count = @intCast((try counts.next(.{})).?.count);
        }

        const page_sql = if (searching)
            "SELECT id, cmd, cwd, exit_code, duration_ms, MAX(timestamp) AS timestamp FROM history" ++ where ++
                " GROUP BY cmd ORDER BY timestamp DESC, id DESC LIMIT ? OFFSET ?"
        else
            "SELECT id, cmd, cwd, exit_code, duration_ms, timestamp FROM history" ++ where ++
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
};
