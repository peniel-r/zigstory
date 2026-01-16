const std = @import("std");
const vaxis = @import("vaxis");
const sqlite = @import("sqlite");
const scrolling = @import("scrolling.zig");
const search_logic = @import("search.zig");
const render = @import("render.zig");
const navigation = @import("navigation.zig");

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
    selections: std.ArrayListUnmanaged(scrolling.HistoryEntry) = .{},

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
            .selections = .{},
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

    /// Toggle selection of an entry
    fn toggleSelection(self: *TuiApp, entry: scrolling.HistoryEntry) !void {
        // Check if already selected (by ID)
        for (self.selections.items, 0..) |s, i| {
            if (s.id == entry.id) {
                // Remove selection
                self.allocator.free(s.cmd);
                self.allocator.free(s.cwd);
                _ = self.selections.orderedRemove(i);
                return;
            }
        }

        // Add selection if not full
        if (self.selections.items.len < 5) {
            const new_entry = scrolling.HistoryEntry{
                .id = entry.id,
                .cmd = try self.allocator.dupe(u8, entry.cmd),
                .cwd = try self.allocator.dupe(u8, entry.cwd),
                .exit_code = entry.exit_code,
                .duration_ms = entry.duration_ms,
                .timestamp = entry.timestamp,
            };
            try self.selections.append(self.allocator, new_entry);
        } else {
            // TODO: Show flash message or visual feedback that limit is reached
            // For now, simpler implementation: just do nothing
        }
    }

    /// Handle keyboard and terminal events
    fn handleEvent(self: *TuiApp, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                // Toggles selection with Space
                if (key.matches(' ', .{})) {
                    const entry = try navigation.getSelectedCommandEntry(
                        self.search_state.results,
                        self.selected_index,
                        self.scroll_state.scroll_position,
                        self.isSearching(),
                    );

                    if (entry) |e| {
                        try self.toggleSelection(e);
                    }
                    return;
                }

                // Handle backspace for search first (before navigation)
                if (key.matches(vaxis.Key.backspace, .{})) {
                    if (self.search_state.query.items.len > 0) {
                        _ = self.search_state.query.pop();
                        try self.performFuzzySearch();
                    }
                    return;
                }

                // Handle text input for search
                if (key.text) |text| {
                    try self.search_state.query.appendSlice(self.allocator, text);
                    try self.performFuzzySearch();
                    return;
                }

                // Create navigation state
                const old_scroll_pos = self.scroll_state.scroll_position;
                var nav_state = navigation.NavigationState{
                    .selected_index = self.selected_index,
                    .scroll_position = self.scroll_state.scroll_position,
                    .total_count = self.scroll_state.total_count,
                    .visible_rows = self.scroll_state.visible_rows,
                    .is_searching = self.isSearching(),
                };

                // Handle navigation keys
                const action = nav_state.handleKey(key);

                // Update state from navigation
                self.selected_index = nav_state.selected_index;
                self.scroll_state.scroll_position = nav_state.scroll_position;

                // Handle navigation actions
                switch (action) {
                    .quit => {
                        self.should_quit = true;
                    },
                    .select => {
                        if (self.selections.items.len > 0) {
                            // Construct piped command from selections
                            var piped_cmd = std.ArrayListUnmanaged(u8){};
                            defer piped_cmd.deinit(self.allocator);

                            for (self.selections.items, 0..) |sel, i| {
                                if (i > 0) try piped_cmd.appendSlice(self.allocator, " | ");
                                try piped_cmd.appendSlice(self.allocator, sel.cmd);
                            }
                            self.selected_command = try piped_cmd.toOwnedSlice(self.allocator);
                        } else {
                            // Single selection fallback
                            self.selected_command = try navigation.getSelectedCommand(
                                self.allocator,
                                self.search_state.results,
                                self.selected_index,
                                self.scroll_state.scroll_position,
                                self.isSearching(),
                            );
                        }
                        self.should_quit = true;
                    },
                    .refresh => {
                        // Refresh search results
                        if (self.isSearching()) {
                            try self.performFuzzySearch();
                        } else {
                            try self.refreshEntries();
                        }
                    },
                    .clear_search => {
                        // Clear search query (Ctrl+U)
                        self.search_state.query.clearRetainingCapacity();
                        try self.performFuzzySearch();
                    },
                    .exit_search_mode => {
                        // Exit search mode and return to browser
                        self.search_state.query.clearRetainingCapacity();
                        self.scroll_state.total_count = try scrolling.getHistoryCount(self.db);
                        self.scroll_state.scroll_position = 0;
                        self.selected_index = 0;
                        try self.refreshEntries();
                    },
                    .none => {
                        // Check if we need to refresh due to scroll position change
                        if (!self.isSearching() and nav_state.needsRefresh(old_scroll_pos)) {
                            try self.refreshEntries();
                        }
                    },
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
            self.selections.items.len,
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

            // Check if selected
            var is_in_selection_set = false;
            for (self.selections.items) |s| {
                if (s.id == entry.id) {
                    is_in_selection_set = true;
                    break;
                }
            }

            // Render the entry using the render module
            try render.renderEntry(
                win,
                allocator,
                entry,
                row,
                is_selected,
                is_in_selection_set,
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
        for (self.selections.items) |item| {
            self.allocator.free(item.cmd);
            self.allocator.free(item.cwd);
        }
        self.selections.deinit(self.allocator);
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
