const std = @import("std");
const vaxis = @import("vaxis");
const scrolling = @import("scrolling.zig");
const search_logic = @import("search.zig");

/// Navigation action result
pub const NavigationAction = enum {
    none,
    quit,
    select,
    refresh,
    exit_search_mode,
    clear_search,
};

/// Navigation state for keyboard handling
pub const NavigationState = struct {
    selected_index: usize,
    scroll_position: usize,
    total_count: usize,
    visible_rows: usize,
    is_searching: bool,

    /// Handle keyboard navigation
    pub fn handleKey(
        self: *NavigationState,
        key: vaxis.Key,
    ) NavigationAction {
        // Ctrl+C: Exit without selection
        if (key.matches('c', .{ .ctrl = true })) {
            return .quit;
        }

        // Escape: Exit search mode or quit
        if (key.matches(vaxis.Key.escape, .{})) {
            if (self.is_searching) {
                return .exit_search_mode;
            } else {
                return .quit;
            }
        }

        // Enter: Select command and exit
        if (key.matches(vaxis.Key.enter, .{})) {
            return .select;
        }

        // Ctrl+R: Refresh search results
        if (key.matches('r', .{ .ctrl = true })) {
            return .refresh;
        }

        // Ctrl+U: Clear search query (readline/bash style)
        if (key.matches('u', .{ .ctrl = true })) {
            if (self.is_searching) {
                return .clear_search;
            }
        }

        // Up arrow or Ctrl+P: Move selection up
        if (key.matches(vaxis.Key.up, .{}) or
            key.matches('p', .{ .ctrl = true }) or
            (!self.is_searching and key.matches('k', .{})))
        {
            self.moveUp(1);
        }
        // Down arrow or Ctrl+N: Move selection down
        else if (key.matches(vaxis.Key.down, .{}) or
            key.matches('n', .{ .ctrl = true }) or
            (!self.is_searching and key.matches('j', .{})))
        {
            self.moveDown(1);
        }
        // Home: Jump to first result
        else if (key.matches(vaxis.Key.home, .{})) {
            self.jumpToFirst();
        }
        // End: Jump to last result
        else if (key.matches(vaxis.Key.end, .{})) {
            self.jumpToLast();
        }
        // Page Up or Ctrl+K: Scroll up one page
        else if (key.matches(vaxis.Key.page_up, .{}) or
            key.matches('k', .{ .ctrl = true }))
        {
            self.pageUp();
        }
        // Page Down or Ctrl+J: Scroll down one page
        else if (key.matches(vaxis.Key.page_down, .{}) or
            key.matches('j', .{ .ctrl = true }))
        {
            self.pageDown();
        }

        return .none;
    }

    /// Move selection up by n positions
    fn moveUp(self: *NavigationState, n: usize) void {
        if (self.selected_index >= n) {
            self.selected_index -= n;
        } else {
            self.selected_index = 0;
        }
        self.syncScrollPosition();
    }

    /// Move selection down by n positions
    fn moveDown(self: *NavigationState, n: usize) void {
        const max_index = if (self.total_count > 0) self.total_count - 1 else 0;
        self.selected_index = @min(self.selected_index + n, max_index);
        self.syncScrollPosition();
    }

    /// Jump to first result
    fn jumpToFirst(self: *NavigationState) void {
        self.selected_index = 0;
        self.scroll_position = 0;
    }

    /// Jump to last result
    fn jumpToLast(self: *NavigationState) void {
        if (self.total_count > 0) {
            self.selected_index = self.total_count - 1;
            // Position scroll so last item is visible
            if (self.total_count > self.visible_rows) {
                self.scroll_position = self.total_count - self.visible_rows;
            } else {
                self.scroll_position = 0;
            }
        }
    }

    /// Scroll up one page
    fn pageUp(self: *NavigationState) void {
        if (self.selected_index > self.visible_rows) {
            self.selected_index -= self.visible_rows;
            if (self.scroll_position >= self.visible_rows) {
                self.scroll_position -= self.visible_rows;
            } else {
                self.scroll_position = 0;
            }
        } else {
            self.selected_index = 0;
            self.scroll_position = 0;
        }
    }

    /// Scroll down one page
    fn pageDown(self: *NavigationState) void {
        const max_index = if (self.total_count > 0) self.total_count - 1 else 0;
        self.selected_index = @min(self.selected_index + self.visible_rows, max_index);
        self.syncScrollPosition();
    }

    /// Sync scroll position to keep selection visible
    fn syncScrollPosition(self: *NavigationState) void {
        // If selection is above viewport, scroll up
        if (self.selected_index < self.scroll_position) {
            self.scroll_position = self.selected_index;
        }
        // If selection is below viewport, scroll down
        else if (self.selected_index >= self.scroll_position + self.visible_rows) {
            self.scroll_position = self.selected_index - self.visible_rows + 1;
        }
    }

    /// Check if scroll position needs database refresh (for browser mode)
    pub fn needsRefresh(self: *NavigationState, old_scroll_pos: usize) bool {
        return self.scroll_position != old_scroll_pos;
    }
};

/// Get selected command from results
pub fn getSelectedCommand(
    allocator: std.mem.Allocator,
    results: []const scrolling.HistoryEntry,
    selected_index: usize,
    scroll_position: usize,
    is_searching: bool,
) !?[]const u8 {
    if (results.len == 0) return null;

    if (is_searching) {
        // In search mode, selected_index is direct index into results
        if (selected_index < results.len) {
            return try allocator.dupe(u8, results[selected_index].cmd);
        }
    } else {
        // In browser mode, results[0] corresponds to scroll_position
        // Calculate local index
        if (selected_index >= scroll_position) {
            const local_idx = selected_index - scroll_position;
            if (local_idx < results.len) {
                return try allocator.dupe(u8, results[local_idx].cmd);
            }
        }
    }

    return null;
}
