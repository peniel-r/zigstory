/// History entry from database
pub const HistoryEntry = struct {
    id: i64,
    cmd: []const u8,
    cwd: []const u8,
    exit_code: i64,
    duration_ms: i64,
    timestamp: i64,
};

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
};
