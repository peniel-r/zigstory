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
    buffer: [1024]u8,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(Event),
    should_quit: bool = false,
    selected_command: ?[]const u8 = null,

    /// Initialize the TUI application
    pub fn init(allocator: std.mem.Allocator) !TuiApp {
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

        return TuiApp{
            .allocator = allocator,
            .buffer = buffer,
            .tty = tty,
            .vx = vx,
            .loop = loop,
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
                    // Enter: Exit with selection (to be implemented)
                    // For now, just exit
                    self.should_quit = true;
                }
            },
            .winsize => |ws| {
                // Handle terminal resize
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
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

        // Simple test drawing - title at top
        const title = "zigstory - Command History Search";
        _ = win.printSegment(.{
            .text = title,
            .style = .{ .fg = .{ .index = 5 } }, // Magenta color
        }, .{});

        // Help text at bottom
        const help_text = "Press Ctrl+C or Escape to exit";
        _ = win.printSegment(.{
            .text = help_text,
            .style = .{ .dim = true },
        }, .{});
    }

    /// Clean up resources
    pub fn deinit(self: *TuiApp) void {
        self.vx.deinit(self.allocator, self.tty.writer());
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
