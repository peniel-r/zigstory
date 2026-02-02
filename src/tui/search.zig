const std = @import("std");
const sqlite = @import("sqlite");
const scrolling = @import("scrolling.zig");
const directory_filter = @import("directory_filter.zig");

pub const SearchState = struct {
    query: std.ArrayListUnmanaged(u8),
    results: []scrolling.HistoryEntry,
    selected_index: usize = 0,
    visible_rows: usize = 20,
    filter_state: directory_filter.DirectoryFilterState,

    pub fn init(allocator: std.mem.Allocator) SearchState {
        _ = allocator;
        return .{
            .query = .{},
            .results = &[_]scrolling.HistoryEntry{},
            .selected_index = 0,
            .filter_state = directory_filter.DirectoryFilterState.init(null),
        };
    }

    pub fn deinit(self: *SearchState, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        self.clearResults(allocator);
    }

    pub fn clearResults(self: *SearchState, allocator: std.mem.Allocator) void {
        for (self.results) |entry| {
            allocator.free(entry.cmd);
            allocator.free(entry.cwd);
        }
        if (self.results.len > 0) {
            allocator.free(self.results);
        }
        self.results = &[_]scrolling.HistoryEntry{};
    }

    pub fn performSearch(
        self: *SearchState,
        db: *sqlite.Db,
        allocator: std.mem.Allocator,
        limit: usize,
    ) !void {
        // Clear previous results
        self.clearResults(allocator);
        self.selected_index = 0; // Reset selection

        if (self.query.items.len == 0) {
            self.results = try scrolling.fetchHistoryPage(db, allocator, limit, 0);
            return;
        }

        // Build LIKE pattern: %query%
        var like_pattern = std.ArrayListUnmanaged(u8){};
        defer like_pattern.deinit(allocator);

        try like_pattern.append(allocator, '%');
        for (self.query.items) |c| {
            // Escape LIKE special chars
            if (c == '%' or c == '_' or c == '\\') {
                try like_pattern.append(allocator, '\\');
            }
            try like_pattern.append(allocator, c);
        }
        try like_pattern.append(allocator, '%');

        const QueryRow = struct {
            id: i64,
            cmd: []const u8,
            cwd: []const u8,
            exit_code: i64,
            duration_ms: i64,
            timestamp: i64,
        };

        var new_results = std.ArrayListUnmanaged(scrolling.HistoryEntry){};
        errdefer {
            for (new_results.items) |e| {
                allocator.free(e.cmd);
                allocator.free(e.cwd);
            }
            new_results.deinit(allocator);
        }

        // Use appropriate query based on filter mode
        if (self.filter_state.isActive()) {
            // Filtered query with cwd constraint
            const query_sql =
                \\SELECT id, cmd, cwd, exit_code, duration_ms, MAX(timestamp) as timestamp
                \\FROM history
                \\WHERE cmd LIKE ? ESCAPE '\' AND cwd = ?
                \\GROUP BY cmd
                \\ORDER BY timestamp DESC
                \\LIMIT ?
            ;

            var stmt = try db.prepare(query_sql);
            defer stmt.deinit();

            var iter = try stmt.iterator(QueryRow, .{
                like_pattern.items,
                self.filter_state.current_dir.?,
                @as(i64, @intCast(limit)),
            });

            while (try iter.nextAlloc(allocator, .{})) |row| {
                try new_results.append(allocator, .{
                    .id = row.id,
                    .cmd = row.cmd,
                    .cwd = row.cwd,
                    .exit_code = row.exit_code,
                    .duration_ms = row.duration_ms,
                    .timestamp = row.timestamp,
                });
            }
        } else {
            // Global query without cwd constraint
            const query_sql =
                \\SELECT id, cmd, cwd, exit_code, duration_ms, MAX(timestamp) as timestamp
                \\FROM history
                \\WHERE cmd LIKE ? ESCAPE '\'
                \\GROUP BY cmd
                \\ORDER BY timestamp DESC
                \\LIMIT ?
            ;

            var stmt = try db.prepare(query_sql);
            defer stmt.deinit();

            var iter = try stmt.iterator(QueryRow, .{
                like_pattern.items,
                @as(i64, @intCast(limit)),
            });

            while (try iter.nextAlloc(allocator, .{})) |row| {
                try new_results.append(allocator, .{
                    .id = row.id,
                    .cmd = row.cmd,
                    .cwd = row.cwd,
                    .exit_code = row.exit_code,
                    .duration_ms = row.duration_ms,
                    .timestamp = row.timestamp,
                });
            }
        }

        self.results = try new_results.toOwnedSlice(allocator);
    }
};
