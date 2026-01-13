const std = @import("std");
const vaxis = @import("vaxis");
const sqlite = @import("sqlite");

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
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(Event),
    should_quit: bool = false,
    selected_command: ?[]const u8 = null,

    /// Initialize the TUI application
    pub fn init(allocator: std.mem.Allocator) !TuiApp {
        var tty = try vaxis.Tty.init();
        errdefer tty.deinit();

        var vx = try vaxis.init(allocator, .{
            .kitty_keyboard_flags = .{ .report_events = true },
        });
        errdefer vx.deinit(allocator, tty.anyWriter());

        var loop: vaxis.Loop(Event) = .{
            .tty = &tty,
            .vaxis = &vx,
        };
        try loop.init();
        errdefer loop.stop();

        return TuiApp{
            .allocator = allocator,
            .tty = tty,
            .vx = vx,
            .loop = loop,
        };
    }

    /// Run the TUI main loop
    pub fn run(self: *TuiApp) !void {
        try self.loop.start();
        defer self.loop.stop();

        try self.vx.enterAltScreen(self.tty.anyWriter());
        try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);

        // Main event loop
        while (!self.should_quit) {
            self.loop.pollEvent();

            while (self.loop.tryEvent()) |event| {
                try self.handleEvent(event);
            }

            self.draw();

            var buffered = self.tty.bufferedWriter();
            try self.vx.render(buffered.writer().any());
            try buffered.flush();
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
                    // Enter: Exit with selection (to be implemented)
                    // For now, just exit
                    self.should_quit = true;
                }
            },
            .winsize => |ws| {
                // Handle terminal resize
                try self.vx.resize(self.allocator, self.tty.anyWriter(), ws);
            },
            else => {
                // Ignore other events for now
            },
        }
    }

    /// Draw the TUI interface
    fn draw(self: *TuiApp) void {
        const win = self.vx.window();
        win.clear();

        // Draw title bar
        const title = "zigstory - Command History Search";
        const title_len = @as(usize, @intCast(title.len));

        const child = win.child(.{
            .x_off = @as(usize, @intCast((win.width -| title_len) / 2)),
            .y_off = 0,
            .width = .{ .limit = title_len },
            .height = .{ .limit = 1 },
        });

        _ = child.printSegment(.{
            .text = title,
            .style = .{ .fg = .{ .index = 5 } }, // Magenta color
        }, .{});

        // Draw help text
        const help_text = "Press Ctrl+C or Escape to exit";
        const help_len = @as(usize, @intCast(help_text.len));

        const help_child = win.child(.{
            .x_off = @as(usize, @intCast((win.width -| help_len) / 2)),
            .y_off = win.height -| 1,
            .width = .{ .limit = help_len },
            .height = .{ .limit = 1 },
        });

        _ = help_child.printSegment(.{
            .text = help_text,
            .style = .{ .dim = true },
        }, .{});

        // Draw placeholder for search results
        const placeholder = "Search results will appear here (Task 4.2-4.5)";
        const placeholder_len = @as(usize, @intCast(placeholder.len));

        const placeholder_child = win.child(.{
            .x_off = @as(usize, @intCast((win.width -| placeholder_len) / 2)),
            .y_off = win.height / 2,
            .width = .{ .limit = placeholder_len },
            .height = .{ .limit = 1 },
        });

        _ = placeholder_child.printSegment(.{
            .text = placeholder,
            .style = .{ .dim = true },
        }, .{});
    }

    /// Clean up resources
    pub fn deinit(self: *TuiApp) void {
        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();
        self.* = undefined;
    }
};

/// Entry point for TUI search interface
pub fn search(allocator: std.mem.Allocator) !?[]const u8 {
    var app = try TuiApp.init(allocator);
    defer app.deinit();
    try app.run();

    return app.selected_command;
}
