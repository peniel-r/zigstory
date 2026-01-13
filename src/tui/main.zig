const std = @import("std");
const vaxis = @import("vaxis");
const sqlite = @import("sqlite");
const scrolling = @import("scrolling.zig");

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
    buffer: [1024]u8,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(Event),
    should_quit: bool = false,
    selected_command: ?[]const u8 = null,

    // Database and scrolling state
    db: *sqlite.Db,
    scroll_state: scrolling.ScrollingState,
    current_entries: []const scrolling.HistoryEntry,
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

        // Fetch initial page of entries
        const entries: []const scrolling.HistoryEntry = scrolling.fetchHistoryPage(
            db,
            allocator,
            scroll_state.page_size,
            0,
        ) catch &[_]scrolling.HistoryEntry{};

        return TuiApp{
            .allocator = allocator,
            .buffer = buffer,
            .tty = tty,
            .vx = vx,
            .loop = loop,
            .db = db,
            .scroll_state = scroll_state,
            .current_entries = entries,
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
            self.loop.pollEvent();

            while (self.loop.tryEvent()) |event| {
                try self.handleEvent(event);
            }

            self.draw();

            try self.vx.render(self.tty.writer());
            try self.tty.writer().flush();
        }
    }

    /// Handle keyboard and terminal events
    fn handleEvent(self: *TuiApp, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    // Ctrl+C: Exit without selection
                    self.should_quit = true;
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    // Escape: Exit without selection
                    self.should_quit = true;
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    // Enter: Exit with selection
                    if (self.selected_index < self.current_entries.len) {
                        const selected = self.current_entries[self.selected_index];
                        self.selected_command = try self.allocator.dupe(u8, selected.cmd);
                    }
                    self.should_quit = true;
                } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                    // Up arrow or k: Move selection up
                    if (self.selected_index > 0) {
                        self.selected_index -= 1;
                    }
                    // Check if we need to scroll up
                    if (self.selected_index < self.scroll_state.scroll_position) {
                        self.scroll_state.scroll_position = self.selected_index;
                        try self.refreshEntries();
                    }
                } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                    // Down arrow or j: Move selection down
                    if (self.selected_index + 1 < self.scroll_state.total_count) {
                        self.selected_index += 1;
                    }
                    // Check if we need to scroll down
                    const max_visible = self.scroll_state.scroll_position + self.scroll_state.visible_rows;
                    if (self.selected_index >= max_visible) {
                        self.scroll_state.scroll_position = self.selected_index - self.scroll_state.visible_rows + 1;
                        try self.refreshEntries();
                    }
                } else if (key.matches(vaxis.Key.page_up, .{}) or key.matches('k', .{ .ctrl = true })) {
                    // Page Up or Ctrl+K: Scroll up by page
                    if (self.selected_index > self.scroll_state.visible_rows) {
                        self.selected_index -= self.scroll_state.visible_rows;
                        self.scroll_state.scroll_position -|= self.scroll_state.visible_rows;
                    } else {
                        self.selected_index = 0;
                        self.scroll_state.scroll_position = 0;
                    }
                    try self.refreshEntries();
                } else if (key.matches(vaxis.Key.page_down, .{}) or key.matches('j', .{ .ctrl = true })) {
                    // Page Down or Ctrl+J: Scroll down by page
                    const max_pos = self.scroll_state.total_count -| 1;
                    self.selected_index = @min(self.selected_index + self.scroll_state.visible_rows, max_pos);
                    if (self.selected_index >= self.scroll_state.scroll_position + self.scroll_state.visible_rows) {
                        self.scroll_state.scroll_position = self.selected_index -| (self.scroll_state.visible_rows - 1);
                    }
                    try self.refreshEntries();
                } else if (key.matches('g', .{})) {
                    // g: Jump to top
                    self.selected_index = 0;
                    self.scroll_state.scroll_position = 0;
                    try self.refreshEntries();
                } else if (key.matches('G', .{ .shift = true })) {
                    // G: Jump to bottom
                    if (self.scroll_state.total_count > 0) {
                        self.selected_index = self.scroll_state.total_count - 1;
                        if (self.selected_index >= self.scroll_state.visible_rows) {
                            self.scroll_state.scroll_position = self.selected_index - self.scroll_state.visible_rows + 1;
                        }
                        try self.refreshEntries();
                    }
                }
            },
            .winsize => |ws| {
                // Handle terminal resize
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
                // Recalculate visible rows
                self.scroll_state.visible_rows = scrolling.ScrollingState.calculateViewport(ws.rows);
            },
            else => {
                // Ignore other events for now
            },
        }
    }

    /// Refresh entries from database based on current scroll position
    fn refreshEntries(self: *TuiApp) !void {
        // Free old entries
        for (self.current_entries) |entry| {
            self.allocator.free(entry.cmd);
            self.allocator.free(entry.cwd);
        }
        self.allocator.free(self.current_entries);

        // Fetch new entries
        self.current_entries = try scrolling.fetchHistoryPage(
            self.db,
            self.allocator,
            self.scroll_state.page_size,
            self.scroll_state.scroll_position,
        );
    }

    /// Draw the TUI interface
    fn draw(self: *TuiApp) void {
        const win = self.vx.window();
        win.clear();

        // Update visible rows based on terminal size
        self.scroll_state.visible_rows = scrolling.ScrollingState.calculateViewport(win.height);

        // Title bar at top
        const title = " zigstory - Command History Search ";
        const title_style = vaxis.Style{
            .fg = .{ .rgb = .{ 0, 0, 0 } }, // Black text
            .bg = .{ .rgb = .{ 138, 180, 248 } }, // Light blue background
            .bold = true,
        };

        // Draw title centered
        const title_start: u16 = if (win.width > title.len) @intCast((win.width - title.len) / 2) else 0;
        for (0..win.width) |x| {
            _ = win.printSegment(.{
                .text = " ",
                .style = title_style,
            }, .{ .col_offset = @intCast(x), .row_offset = 0 });
        }
        _ = win.printSegment(.{
            .text = title,
            .style = title_style,
        }, .{ .col_offset = title_start, .row_offset = 0 });

        // Status line (row 1)
        const status_text = std.fmt.allocPrint(self.allocator, " {d} commands | Position: {d}/{d} ", .{
            self.scroll_state.total_count,
            self.selected_index + 1,
            self.scroll_state.total_count,
        }) catch " Error ";
        defer if (!std.mem.eql(u8, status_text, " Error ")) self.allocator.free(status_text);

        _ = win.printSegment(.{
            .text = status_text,
            .style = .{ .dim = true },
        }, .{ .row_offset = 1 });

        // Draw entries starting at row 2
        const start_row: u16 = 2;
        const visible_count = @min(self.current_entries.len, self.scroll_state.visible_rows);

        for (0..visible_count) |i| {
            const entry = self.current_entries[i];
            const global_index = self.scroll_state.scroll_position + i;
            const is_selected = global_index == self.selected_index;
            const row: u16 = start_row + @as(u16, @intCast(i));

            // Truncate command to fit width
            const max_cmd_len = @max(1, win.width -| 4);
            const display_cmd = if (entry.cmd.len > max_cmd_len)
                entry.cmd[0..max_cmd_len]
            else
                entry.cmd;

            // Style for selected vs normal
            const style = if (is_selected)
                vaxis.Style{
                    .fg = .{ .rgb = .{ 0, 0, 0 } },
                    .bg = .{ .rgb = .{ 98, 114, 164 } }, // Highlight background
                    .bold = true,
                }
            else
                vaxis.Style{
                    .fg = .{ .rgb = .{ 248, 248, 242 } }, // Light text
                };

            // Draw selection indicator
            const indicator = if (is_selected) "▶ " else "  ";
            _ = win.printSegment(.{
                .text = indicator,
                .style = style,
            }, .{ .row_offset = row, .col_offset = 0 });

            // Draw command text
            _ = win.printSegment(.{
                .text = display_cmd,
                .style = style,
            }, .{ .row_offset = row, .col_offset = 2 });

            // Fill rest of row if selected (for full highlight)
            if (is_selected) {
                const remaining = win.width -| (display_cmd.len + 2);
                for (0..remaining) |x| {
                    _ = win.printSegment(.{
                        .text = " ",
                        .style = style,
                    }, .{ .row_offset = row, .col_offset = @as(u16, @intCast(display_cmd.len + 2 + x)) });
                }
            }
        }

        // Help text at bottom
        const help_row: u16 = @intCast(win.height -| 1);
        const help_text = " ↑/↓:Navigate  Enter:Select  Esc/Ctrl+C:Exit  g/G:Top/Bottom  PgUp/PgDn:Page ";
        _ = win.printSegment(.{
            .text = help_text,
            .style = .{
                .dim = true,
                .bg = .{ .rgb = .{ 40, 42, 54 } }, // Dark background
            },
        }, .{ .row_offset = help_row });
    }

    /// Clean up resources
    pub fn deinit(self: *TuiApp) void {
        // Free entries
        for (self.current_entries) |entry| {
            self.allocator.free(entry.cmd);
            self.allocator.free(entry.cwd);
        }
        self.allocator.free(self.current_entries);

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
