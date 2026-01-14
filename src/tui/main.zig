const std = @import("std");
const vaxis = @import("vaxis");
const sqlite = @import("sqlite");
const scrolling = @import("scrolling.zig");
const search_logic = @import("search.zig");
const render = @import("render.zig");

/// Custom panic handler for proper terminal cleanup
pub const panic = vaxis.panic_handler;

/// Event types for the TUI
const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    mouse: vaxis.Mouse,
    focus_in,
    focus_out,
    paste_start,
    paste_end,
    paste: []const u8,
    color_report: vaxis.Color.Report,
    color_scheme: vaxis.Color.Scheme,
    winsize: vaxis.Winsize,
};

/// TUI application state
const TuiApp = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    buffer: [1024]u8,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(Event),
    should_quit: bool = false,
    selected_command: ?[]const u8 = null,

    // Database and scrolling state
    db: *sqlite.Db,
    scroll_state: scrolling.ScrollingState,

    // Search state (replaces current_entries)
    search_state: search_logic.SearchState,

    selected_index: usize = 0,

    /// Initialize the TUI application
    pub fn init(allocator: std.mem.Allocator, db: *sqlite.Db) !TuiApp {
        var buffer: [1024]u8 = undefined;
        var tty = try vaxis.Tty.init(&buffer);
        errdefer tty.deinit();

        var vx = try vaxis.init(allocator, .{
            .kitty_keyboard_flags = .{ .report_events = true },
        });
        errdefer vx.deinit(allocator, tty.writer());

        var loop: vaxis.Loop(Event) = .{
            .tty = &tty,
            .vaxis = &vx,
        };
        try loop.init();
        errdefer loop.stop();

        // Get total count from database
        const total_count = scrolling.getHistoryCount(db) catch 0;

        // Initialize scroll state
        const scroll_state = scrolling.ScrollingState{
            .total_count = total_count,
            .scroll_position = 0,
            .visible_rows = 20, // Will be updated on first draw
            .page_size = 100,
        };

        var search_state = search_logic.SearchState.init(allocator);

        // Fetch initial page of entries (Browsing mode)
        search_state.results = try scrolling.fetchHistoryPage(
            db,
            allocator,
            scroll_state.page_size,
            0,
        );

        return TuiApp{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .buffer = buffer,
            .tty = tty,
            .vx = vx,
            .loop = loop,
            .db = db,
            .scroll_state = scroll_state,
            .search_state = search_state,
        };
    }

    /// Run the TUI main loop
    pub fn run(self: *TuiApp) !void {
        try self.loop.start();
        defer self.loop.stop();

        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);

        // Main event loop
        while (!self.should_quit) {
            _ = self.arena.reset(.retain_capacity);
            const frame_allocator = self.arena.allocator();

            self.loop.pollEvent();

            while (self.loop.tryEvent()) |event| {
                try self.handleEvent(event);
            }

            try self.draw(frame_allocator);

            try self.vx.render(self.tty.writer());
            try self.tty.writer().flush();
        }
    }

    fn isSearching(self: *TuiApp) bool {
        return self.search_state.query.items.len > 0;
    }

    /// Perform fuzzy search and reset scroll
    fn performFuzzySearch(self: *TuiApp) !void {
        try self.search_state.performSearch(self.db, self.allocator, 50000);
        // In search mode, total count is the number of results
        self.scroll_state.total_count = self.search_state.results.len;
        self.scroll_state.scroll_position = 0;
        self.selected_index = 0;
    }

    /// Handle keyboard and terminal events
    fn handleEvent(self: *TuiApp, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    // Ctrl+C: Exit without selection
                    self.should_quit = true;
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    // Escape: Exit search mode or app
                    if (self.isSearching()) {
                        self.search_state.query.clearRetainingCapacity();
                        // Reset to browser mode
                        self.scroll_state.total_count = try scrolling.getHistoryCount(self.db);
                        self.scroll_state.scroll_position = 0;
                        self.selected_index = 0;
                        try self.refreshEntries();
                    } else {
                        self.should_quit = true;
                    }
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    // Enter: Exit with selection
                    // Check bounds
                    const results = self.search_state.results;
                    // Determine actual index
                    const idx = self.selected_index;
                    // In Browser mode, selected_index is global, but results start at scroll_pos
                    if (!self.isSearching()) {
                        // results[0] corresponds to scroll_pos
                        // selected_index is global.
                        // local_index = selected_index - scroll_pos
                        if (idx >= self.scroll_state.scroll_position) {
                            const local_idx = idx - self.scroll_state.scroll_position;
                            if (local_idx < results.len) {
                                const selected = results[local_idx];
                                self.selected_command = try self.allocator.dupe(u8, selected.cmd);
                            }
                        }
                    } else {
                        // Search mode: results[0] is index 0.
                        // selected_index is local.
                        if (idx < results.len) {
                            const selected = results[idx];
                            self.selected_command = try self.allocator.dupe(u8, selected.cmd);
                        }
                    }
                    self.should_quit = true;
                } else if (key.matches(vaxis.Key.up, .{}) or (!self.isSearching() and key.matches('k', .{}))) {
                    // Up arrow: Move selection up
                    if (self.selected_index > 0) {
                        self.selected_index -= 1;
                    }
                    // Sync scroll
                    if (self.selected_index < self.scroll_state.scroll_position) {
                        self.scroll_state.scroll_position = self.selected_index;
                        try self.refreshEntries();
                    }
                } else if (key.matches(vaxis.Key.down, .{}) or (!self.isSearching() and key.matches('j', .{}))) {
                    // Down arrow: Move selection down
                    if (self.selected_index + 1 < self.scroll_state.total_count) {
                        self.selected_index += 1;
                    }
                    // Sync scroll
                    const max_visible = self.scroll_state.scroll_position + self.scroll_state.visible_rows;
                    if (self.selected_index >= max_visible) {
                        self.scroll_state.scroll_position = self.selected_index - self.scroll_state.visible_rows + 1;
                        try self.refreshEntries();
                    }
                } else if (key.matches(vaxis.Key.page_up, .{}) or key.matches('k', .{ .ctrl = true })) {
                    // Page Up
                    if (self.selected_index > self.scroll_state.visible_rows) {
                        self.selected_index -= self.scroll_state.visible_rows;
                        self.scroll_state.scroll_position -|= self.scroll_state.visible_rows;
                    } else {
                        self.selected_index = 0;
                        self.scroll_state.scroll_position = 0;
                    }
                    try self.refreshEntries();
                } else if (key.matches(vaxis.Key.page_down, .{}) or key.matches('j', .{ .ctrl = true })) {
                    // Page Down
                    const max_pos = self.scroll_state.total_count -| 1;
                    self.selected_index = @min(self.selected_index + self.scroll_state.visible_rows, max_pos);
                    if (self.selected_index >= self.scroll_state.scroll_position + self.scroll_state.visible_rows) {
                        self.scroll_state.scroll_position = self.selected_index -| (self.scroll_state.visible_rows - 1);
                    }
                    try self.refreshEntries();
                } else if (key.matches(vaxis.Key.backspace, .{})) {
                    // Backspace for search
                    if (self.search_state.query.items.len > 0) {
                        _ = self.search_state.query.pop();
                        try self.performFuzzySearch();
                    }
                } else if (key.text) |text| {
                    // Text input for search
                    // Ignore control chars?
                    try self.search_state.query.appendSlice(self.allocator, text);
                    try self.performFuzzySearch();
                }
            },
            .winsize => |ws| {
                // Handle terminal resize
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
                self.scroll_state.visible_rows = scrolling.ScrollingState.calculateViewport(ws.rows);
            },
            else => {},
        }
    }

    /// Refresh entries (mostly for browser mode)
    fn refreshEntries(self: *TuiApp) !void {
        if (self.isSearching()) {
            return; // Search results are static until query changes
        }

        // Browser Mode: Fetch from DB using OFFSET
        self.search_state.clearResults(self.allocator);
        self.search_state.results = try scrolling.fetchHistoryPage(
            self.db,
            self.allocator,
            self.scroll_state.page_size,
            self.scroll_state.scroll_position,
        );
    }

    /// Draw the TUI interface
    /// Draw the TUI interface
    fn draw(self: *TuiApp, allocator: std.mem.Allocator) !void {
        const win = self.vx.window();

        // IMPORTANT: Fill entire screen with background color FIRST
        // This ensures no transparency shows through
        render.fillScreen(win);

        // Update visible rows
        self.scroll_state.visible_rows = scrolling.ScrollingState.calculateViewport(win.height);

        // Render title bar (row 0)
        render.renderTitleBar(win);

        // Render status/search bar (row 1)
        const search_query = self.search_state.query.items;
        try render.renderStatusBar(
            win,
            allocator,
            self.isSearching(),
            search_query,
            self.scroll_state.total_count,
            self.selected_index,
            self.search_state.results.len,
        );

        // Draw entries starting at row 2
        const start_row: u16 = 2;

        // Determine entries to display
        var display_slice: []scrolling.HistoryEntry = undefined;
        var start_index: usize = 0;

        if (self.isSearching()) {
            // In search mode, results contains ALL matches.
            // We need to slice based on scroll_position.
            const total = self.search_state.results.len;
            if (self.scroll_state.scroll_position >= total) {
                start_index = 0; // Should not happen if clamped
            } else {
                start_index = self.scroll_state.scroll_position;
            }
            display_slice = self.search_state.results[start_index..];
        } else {
            // In browser mode, fetchHistoryPage returns entries starting at scroll_position.
            // So results[0] IS scroll_position.
            display_slice = self.search_state.results;
            start_index = self.scroll_state.scroll_position;
        }

        const visible_count = @min(display_slice.len, self.scroll_state.visible_rows);

        // Render each entry row
        for (0..visible_count) |i| {
            const entry = display_slice[i];
            const global_index = start_index + i;
            const is_selected = global_index == self.selected_index;
            const row: u16 = start_row + @as(u16, @intCast(i));

            // Get search query for highlighting (only if searching)
            const query_for_highlight: ?[]const u8 = if (self.isSearching()) self.search_state.query.items else null;

            // Render the entry using the render module
            try render.renderEntry(
                win,
                allocator,
                entry,
                row,
                is_selected,
                query_for_highlight,
                render.default_config,
            );
        }

        // Render help bar at bottom
        render.renderHelpBar(win);
    }

    /// Clean up resources
    pub fn deinit(self: *TuiApp) void {
        self.arena.deinit();
        self.search_state.deinit(self.allocator);
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.* = undefined;
    }
};

/// Entry point for TUI search interface
pub fn search(allocator: std.mem.Allocator, db: *sqlite.Db) !?[]const u8 {
    var app = try TuiApp.init(allocator, db);
    defer app.deinit();
    try app.run();

    return app.selected_command;
}
