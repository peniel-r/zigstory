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
    limit: usize,
    offset: usize,
) ![]HistoryEntry {
    // Use multiline string for query
    const query =
        \\SELECT id, cmd, cwd, exit_code, duration_ms, timestamp 
        \\FROM history 
        \\ORDER BY timestamp DESC 
        \\LIMIT ? OFFSET ?
    ;
    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const QueryRow = struct {
        id: i64,
        cmd: []const u8,
        cwd: []const u8,
        exit_code: i64,
        duration_ms: i64,
        timestamp: i64,
    };

    var iter = try stmt.iterator(QueryRow, .{
        @as(i64, @intCast(limit)),
        @as(i64, @intCast(offset)),
    });

    // Use a fixed buffer for collecting entries then copy to final slice
    var temp_entries: [200]HistoryEntry = undefined;
    var count: usize = 0;

    while (count < 200) {
        const row = (try iter.nextAlloc(allocator, .{})) orelse break;

        temp_entries[count] = .{
            .id = row.id,
            .cmd = row.cmd,
            .cwd = row.cwd,
            .exit_code = row.exit_code,
            .duration_ms = row.duration_ms,
            .timestamp = row.timestamp,
        };
        count += 1;
    }

    // Allocate exact size and copy
    const entries = try allocator.alloc(HistoryEntry, count);
    @memcpy(entries, temp_entries[0..count]);

    return entries;
}

/// Get total count of history entries
pub fn getHistoryCount(db: *sqlite.Db) !usize {
    const query = "SELECT COUNT(*) as count FROM history";
    var stmt = try db.prepare(query);
    defer stmt.deinit();

    var iter = try stmt.iterator(struct { count: i64 }, .{});
    const row = (try iter.next(.{})) orelse return 0;
    return @intCast(row.count);
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
