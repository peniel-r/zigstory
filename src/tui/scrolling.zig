const std = @import("std");
const vaxis = @import("vaxis");
const sqlite = @import("sqlite");

/// History entry from database
pub const HistoryEntry = struct {
    id: i64,
    cmd: []const u8,
    cwd: []const u8,
    exit_code: i64,
    duration_ms: i64,
    timestamp: i64,
};

/// Page of history entries
pub const Page = struct {
    entries: []HistoryEntry,
    page_number: usize,

    /// Calculate total pages for a given total count
    pub fn totalPages(count: usize, page_size: usize) usize {
        if (count == 0) return 0;
        return (count + page_size - 1) / page_size;
    }
};

/// Fetch a page of history entries from database
pub fn fetchHistoryPage(
    db: *sqlite.Db,
    allocator: std.mem.Allocator,
    page_size: usize,
    offset: usize,
) ![]HistoryEntry {
    const query = "SELECT id, cmd, cwd, exit_code, duration_ms, timestamp FROM history ORDER BY timestamp DESC LIMIT ? OFFSET ?";
    const stmt = try db.prepare(query);
    defer stmt.deinit();

    try stmt.bind(1, @intCast(page_size));
    try stmt.bind(2, @intCast(offset));

    var entries = std.ArrayList(HistoryEntry).init(allocator);
    defer entries.deinit();

    while (stmt.step()) |_| {
        const id = stmt.row.i64(0);
        const cmd = try allocator.dupe(u8, stmt.row.text(1));
        const cwd = try allocator.dupe(u8, stmt.row.text(2));
        const exit_code = stmt.row.i64(3);
        const duration_ms = stmt.row.i64(4);
        const timestamp = stmt.row.i64(5);

        try entries.append(.{
            .id = id,
            .cmd = cmd,
            .cwd = cwd,
            .exit_code = exit_code,
            .duration_ms = duration_ms,
            .timestamp = timestamp,
        });
    }

    return entries.toOwnedSlice();
}

/// Get total count of history entries
pub fn getHistoryCount(db: *sqlite.Db) !usize {
    const query = "SELECT COUNT(*) FROM history";
    const stmt = try db.prepare(query);
    defer stmt.deinit();

    const result = stmt.one(usize, .{});
    return result orelse 0;
}

/// Scrolling state management
pub const ScrollingState = struct {
    /// Total number of entries in database
    total_count: usize = 0,

    /// Current scroll position (0-indexed)
    scroll_position: usize = 0,

    /// Number of visible rows in viewport
    visible_rows: usize = 0,

    /// Page size for caching (default: 100 rows)
    page_size: usize = 100,

    /// Calculate viewport height
    pub fn calculateViewport(height: usize) usize {
        // Leave space for title (1 row) + help text (1 row)
        // Also leave 1 row padding at top
        return @max(1, height -| 3);
    }

    /// Clamp scroll position to valid range
    pub fn clampScrollPosition(self: *ScrollingState, position: usize) usize {
        if (self.total_count == 0) return 0;
        const max_pos = self.total_count - 1;
        return @min(position, max_pos);
    }

    /// Calculate page number from scroll position
    pub fn currentPage(self: *ScrollingState) Page {
        return Page{
            .entries = &[_]HistoryEntry{},
            .page_number = self.scroll_position / self.page_size,
        };
    }

    /// Get offset for SQL query
    pub fn getSqlOffset(self: *ScrollingState) usize {
        return self.scroll_position;
    }

    /// Get limit for SQL query
    pub fn getSqlLimit(self: *ScrollingState) usize {
        const remaining = self.total_count - self.scroll_position;
        return @min(remaining, self.page_size);
    }
};
