const std = @import("std");
const vaxis = @import("vaxis");
const sqlite = @import("sqlite");
const scrolling = @import("scrolling.zig");
const search_logic = @import("search.zig");
const render = @import("render.zig");
const navigation = @import("navigation.zig");
const directory_filter = @import("directory_filter.zig");

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
    io: std.Io,
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
    selections: std.ArrayListUnmanaged(scrolling.HistoryEntry) = .empty,

    selected_index: usize = 0,
    search_dirty: bool = false,

    // Vim-like command mode
    command_mode: bool = false,
    command_buffer: std.ArrayListUnmanaged(u8) = .empty,

    /// Initialize TUI application
    pub fn init(self: *TuiApp, allocator: std.mem.Allocator, db: *sqlite.Db, current_dir: ?[]const u8, io: std.Io, environ_map: *std.process.Environ.Map) !void {
        // The writer borrows buffer; the input loop borrows tty and vx.
        // Initialize in place and do not move the app after this point.
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .io = io,
            .buffer = undefined,
            .tty = undefined,
            .vx = undefined,
            .loop = undefined,
            .db = db,
            .scroll_state = .{},
            .search_state = search_logic.SearchState.init(allocator),
        };
        errdefer self.arena.deinit();
        errdefer self.search_state.deinit(allocator);

        self.tty = try vaxis.Tty.init(io, &self.buffer);
        errdefer self.tty.deinit();

        self.vx = try vaxis.init(io, allocator, environ_map, .{
            .kitty_keyboard_flags = .{ .report_events = true },
        });
        errdefer self.vx.deinit(allocator, self.tty.writer());

        self.loop = vaxis.Loop(Event).init(io, &self.tty, &self.vx);

        // Initialize scroll state
        self.scroll_state = scrolling.ScrollingState{
            .scroll_position = 0,
            .visible_rows = 20, // Will be updated on first draw
            .page_size = 100,
        };

        // Set current directory for filtering
        self.search_state.filter_state = directory_filter.DirectoryFilterState.init(current_dir);

        self.search_dirty = true;
        try self.flushSearch();
    }

    /// Run the TUI main loop
    pub fn run(self: *TuiApp) !void {
        try self.loop.start();
        defer self.loop.stop();

        try self.vx.enterAltScreen(self.tty.writer());
        // queryTerminal now takes std.Io.Duration instead of nanosecond integer
        try self.vx.queryTerminal(self.tty.writer(), .{ .nanoseconds = std.time.ns_per_s });

        try self.drawInitialFrame();

        // Main event loop
        while (!self.should_quit) {
            _ = self.arena.reset(.retain_capacity);
            const frame_allocator = self.arena.allocator();

            // pollEvent and tryEvent now return error unions in vaxis 0.6
            try self.loop.pollEvent();

            while (try self.loop.tryEvent()) |event| {
                try self.handleEvent(event);
                if (self.should_quit) break;
            }

            if (self.should_quit) break;
            try self.flushSearch();
            try self.draw(frame_allocator);

            try self.vx.render(self.tty.writer());
            try self.tty.writer().flush();
        }
    }

    fn drawInitialFrame(self: *TuiApp) !void {
        // Windows does not guarantee a resize event when entering the alt screen.
        try self.handleEvent(.{ .winsize = try self.tty.getWinsize() });
        try self.draw(self.arena.allocator());
        try self.vx.render(self.tty.writer());
        try self.tty.writer().flush();
    }

    fn isSearching(self: *TuiApp) bool {
        return self.search_state.query.items.len > 0;
    }

    fn flushSearch(self: *TuiApp) !void {
        if (!self.search_dirty) return;
        self.scroll_state.scroll_position = 0;
        self.selected_index = 0;
        try self.search_state.loadPage(self.db, self.pageSize(), 0, true);
        self.scroll_state.total_count = self.search_state.total_count;
        self.search_dirty = false;
    }

    fn pageSize(self: *TuiApp) usize {
        return @max(self.scroll_state.page_size, self.scroll_state.visible_rows);
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
            const cmd = try self.allocator.dupe(u8, entry.cmd);
            errdefer self.allocator.free(cmd);
            const cwd = try self.allocator.dupe(u8, entry.cwd);
            errdefer self.allocator.free(cwd);
            const new_entry = scrolling.HistoryEntry{
                .id = entry.id,
                .cmd = cmd,
                .cwd = cwd,
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
                // Handle command mode (vim-like ':q')
                if (key.matches(':', .{})) {
                    self.command_mode = true;
                    self.command_buffer.clearRetainingCapacity();
                    return;
                }

                // If in command mode, handle command input
                if (self.command_mode) {
                    // Escape: Exit command mode
                    if (key.matches(vaxis.Key.escape, .{})) {
                        self.command_mode = false;
                        self.command_buffer.clearRetainingCapacity();
                        return;
                    }

                    // Enter: Execute command
                    if (key.matches(vaxis.Key.enter, .{})) {
                        if (std.mem.eql(u8, self.command_buffer.items, "q")) {
                            self.should_quit = true;
                        }
                        self.command_mode = false;
                        self.command_buffer.clearRetainingCapacity();
                        return;
                    }

                    // Backspace: Remove last character
                    if (key.matches(vaxis.Key.backspace, .{})) {
                        if (self.command_buffer.items.len > 0) {
                            _ = self.command_buffer.pop();
                        }
                        return;
                    }

                    // Add character to command buffer
                    if (key.text) |text| {
                        try self.command_buffer.appendSlice(self.allocator, text);
                        return;
                    }

                    return; // Don't process other keys in command mode
                }

                // Toggles selection with Shift + Space
                if (key.matches(' ', .{}) and key.mods.shift) {
                    try self.flushSearch();
                    const entry = try navigation.getSelectedCommandEntry(
                        self.search_state.results,
                        self.selected_index,
                        self.search_state.results_offset,
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
                        self.search_dirty = true;
                    }
                    return;
                }

                // Handle Ctrl+F to toggle directory filter
                if (key.matches('f', .{ .ctrl = true })) {
                    self.search_state.filter_state.toggleMode();
                    self.search_dirty = true;
                    return;
                }

                // Handle text input for search
                if (key.text) |text| {
                    try self.search_state.query.appendSlice(self.allocator, text);
                    self.search_dirty = true;
                    return;
                }

                // Navigation and selection must see all preceding queued edits.
                try self.flushSearch();
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
                            var piped_cmd: std.ArrayListUnmanaged(u8) = .empty;
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
                                self.search_state.results_offset,
                            );
                        }
                        self.should_quit = true;
                    },
                    .refresh => {
                        self.search_dirty = true;
                    },
                    .clear_search => {
                        // Clear search query (Ctrl+U)
                        self.search_state.query.clearRetainingCapacity();
                        self.search_dirty = true;
                    },
                    .exit_search_mode => {
                        // Exit search mode and return to browser
                        self.search_state.query.clearRetainingCapacity();
                        self.search_dirty = true;
                    },
                    .none => {
                        // Check if we need to refresh due to scroll position change
                        if (nav_state.needsRefresh(old_scroll_pos)) {
                            try self.refreshEntries();
                        }
                    },
                }
            },
            .winsize => |ws| {
                // Handle terminal resize
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
                self.scroll_state.visible_rows = scrolling.ScrollingState.calculateViewport(ws.rows);
                try self.refreshEntries();
            },
            else => {},
        }
    }

    fn refreshEntries(self: *TuiApp) !void {
        const start = self.scroll_state.scroll_position;
        const end = @min(start + self.scroll_state.visible_rows, self.scroll_state.total_count);
        const cached_end = self.search_state.results_offset + self.search_state.results.len;
        if (start >= self.search_state.results_offset and end <= cached_end) {
            return;
        }
        try self.search_state.loadPage(
            self.db,
            self.pageSize(),
            start,
            false,
        );
    }

    /// Draw the TUI interface
    /// Draw the TUI interface
    fn draw(self: *TuiApp, allocator: std.mem.Allocator) !void {
        const win = self.vx.window();
        // Compute current time once per frame for relative timestamps.
        const now: i64 = std.Io.Timestamp.now(self.io, .real).toSeconds();

        // IMPORTANT: Fill entire screen with background color FIRST
        // This ensures no transparency shows through
        render.fillScreen(win);

        // Update visible rows
        self.scroll_state.visible_rows = scrolling.ScrollingState.calculateViewport(win.height);

        // Render title bar (row 0)
        render.renderTitleBar(win);

        // Render status/search bar (row 1)
        const search_query = self.search_state.query.items;
        const filter_mode_str = self.search_state.filter_state.mode.toString();
        const command_buf = self.command_buffer.items;
        try render.renderStatusBar(
            win,
            allocator,
            self.isSearching(),
            search_query,
            self.scroll_state.total_count,
            self.selected_index,
            self.search_state.total_count,
            self.selections.items.len,
            filter_mode_str,
            self.command_mode,
            command_buf,
        );

        // Draw entries starting at row 2
        const start_row: u16 = 2;

        // Determine entries to display
        const start_index = self.scroll_state.scroll_position;
        const local_start = @min(start_index -| self.search_state.results_offset, self.search_state.results.len);
        const display_slice = self.search_state.results[local_start..];

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
                now,
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
        self.command_buffer.deinit(self.allocator);
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.* = undefined;
    }
};

/// Entry point for TUI search interface
pub fn search(allocator: std.mem.Allocator, db: *sqlite.Db, current_dir: ?[]const u8, io: std.Io, environ_map: *std.process.Environ.Map) !?[]const u8 {
    // The CLI's command-scoped arena cannot reclaim repeated search allocations.
    const app_allocator = std.heap.smp_allocator;
    var app: TuiApp = undefined;
    try app.init(app_allocator, db, current_dir, io, environ_map);
    defer app.deinit();
    defer if (app.selected_command) |cmd| app_allocator.free(cmd);
    try app.run();

    return if (app.selected_command) |cmd| try allocator.dupe(u8, cmd) else null;
}

test "TUI initialization retains pointers to app-owned storage" {
    const allocator = std.testing.allocator;
    var environ_map: std.process.Environ.Map = .init(allocator);
    defer environ_map.deinit();
    var db = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer db.deinit();
    try db.exec(
        \\CREATE TABLE history (
        \\  id INTEGER PRIMARY KEY, cmd TEXT, cwd TEXT, exit_code INTEGER,
        \\  duration_ms INTEGER, timestamp INTEGER
        \\)
    , .{}, .{});

    var app: TuiApp = undefined;
    try app.init(allocator, &db, null, std.testing.io, &environ_map);
    defer app.deinit();

    try std.testing.expect(app.loop.tty == &app.tty);
    try std.testing.expect(app.loop.vaxis == &app.vx);
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expect(app.tty.writer().buffer.ptr == &app.buffer);
    }
}

test "TUI renders the initial frame without input or resize events" {
    const allocator = std.testing.allocator;
    var environ_map: std.process.Environ.Map = .init(allocator);
    defer environ_map.deinit();
    var db = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer db.deinit();
    try db.exec(
        \\CREATE TABLE history (
        \\  id INTEGER PRIMARY KEY, cmd TEXT, cwd TEXT, exit_code INTEGER,
        \\  duration_ms INTEGER, timestamp INTEGER
        \\)
    , .{}, .{});
    try db.exec("INSERT INTO history VALUES (1, 'echo startup', 'C:\\', 0, 0, 0)", .{}, .{});

    var app: TuiApp = undefined;
    try app.init(allocator, &db, null, std.testing.io, &environ_map);
    defer app.deinit();

    try std.testing.expectEqual(@as(u16, 0), app.vx.window().height);
    try std.testing.expect(try app.loop.tryEvent() == null);
    try app.drawInitialFrame();
    const size = try app.tty.getWinsize();
    try std.testing.expectEqual(size.cols, app.vx.window().width);
    try std.testing.expectEqual(size.rows, app.vx.window().height);
    try std.testing.expectEqual(
        scrolling.ScrollingState.calculateViewport(size.rows),
        app.scroll_state.visible_rows,
    );
    try std.testing.expect(try app.loop.tryEvent() == null);
    try std.testing.expectEqual(@as(usize, 1), app.search_state.results.len);
    try std.testing.expectEqualStrings("echo startup", app.search_state.results[0].cmd);
    try std.testing.expectEqualStrings("e", app.vx.screen.readCell(25, 2).?.char.grapheme);
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expectEqual(@as(usize, 0), app.tty.writer().end);
    }
}

fn createNavigationTestDb(count: usize) !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    errdefer db.deinit();
    try db.exec(
        \\CREATE TABLE history (
        \\  id INTEGER PRIMARY KEY, cmd TEXT, cwd TEXT, exit_code INTEGER,
        \\  duration_ms INTEGER, timestamp INTEGER
        \\)
    , .{}, .{});
    try db.exec(
        \\WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i < ?)
        \\INSERT INTO history SELECT i, printf('cmd %06d',i),
        \\  CASE WHEN i % 2 = 0 THEN 'local' ELSE 'other' END, 0, 0, i FROM n
    , .{}, .{@as(i64, @intCast(count))});
    return db;
}

test "search pages retain full counts beyond the former 50000 result limit" {
    const allocator = std.testing.allocator;
    var db = try createNavigationTestDb(50100);
    defer db.deinit();
    var state = search_logic.SearchState.init(allocator);
    defer state.deinit(allocator);
    try state.query.appendSlice(allocator, "cmd ");
    try state.loadPage(&db, 100, 0, true);
    try std.testing.expectEqual(@as(usize, 50100), state.total_count);
    try std.testing.expectEqual(@as(usize, 100), state.results.len);
    try state.loadPage(&db, 100, 50099, false);
    try std.testing.expectEqual(@as(usize, 50100), state.total_count);
    try std.testing.expectEqual(@as(usize, 1), state.results.len);
    try std.testing.expectEqualStrings("cmd 000001", state.results[0].cmd);
    try std.testing.expectEqual(@as(i64, 1), (try navigation.getSelectedCommandEntry(state.results, 50099, state.results_offset)).?.id);
    try std.testing.expect(try navigation.getSelectedCommandEntry(state.results, 50098, state.results_offset) == null);
}

test "directory filtering survives query clearing and updates the complete browsing count" {
    const allocator = std.testing.allocator;
    var environ_map: std.process.Environ.Map = .init(allocator);
    defer environ_map.deinit();
    var db = try createNavigationTestDb(600);
    defer db.deinit();
    var app: TuiApp = undefined;
    try app.init(allocator, &db, "local", std.testing.io, &environ_map);
    defer app.deinit();
    try app.handleEvent(.{ .key_press = .{ .codepoint = 'f', .mods = .{ .ctrl = true } } });
    try app.flushSearch();
    try std.testing.expectEqual(@as(usize, 300), app.scroll_state.total_count);
    for (app.search_state.results) |row| try std.testing.expectEqualStrings("local", row.cwd);
    try app.handleEvent(.{ .key_press = .{ .codepoint = 'c', .text = "cmd" } });
    try app.flushSearch();
    try app.handleEvent(.{ .key_press = .{ .codepoint = 'u', .mods = .{ .ctrl = true } } });
    try app.flushSearch();
    try std.testing.expect(!app.isSearching());
    try std.testing.expectEqual(@as(usize, 300), app.scroll_state.total_count);
    try app.handleEvent(.{ .key_press = .{ .codepoint = vaxis.Key.end } });
    try std.testing.expectEqual(@as(usize, 299), app.selected_index);
    try std.testing.expectEqual(@as(i64, 2), (try navigation.getSelectedCommandEntry(app.search_state.results, app.selected_index, app.search_state.results_offset)).?.id);
    try app.handleEvent(.{ .key_press = .{ .codepoint = 'f', .mods = .{ .ctrl = true } } });
    try app.flushSearch();
    try std.testing.expectEqual(@as(usize, 600), app.scroll_state.total_count);
}

test "search deduplicates commands using the newest matching directory entry" {
    const allocator = std.testing.allocator;
    var db = try createNavigationTestDb(1);
    defer db.deinit();
    try db.exec("INSERT INTO history VALUES(2,'duplicate','local',0,0,20)", .{}, .{});
    try db.exec("INSERT INTO history VALUES(3,'duplicate','other',1,0,30)", .{}, .{});
    var state = search_logic.SearchState.init(allocator);
    defer state.deinit(allocator);
    try state.query.appendSlice(allocator, "duplicate");
    try state.loadPage(&db, 100, 0, true);
    try std.testing.expectEqual(@as(usize, 1), state.total_count);
    try std.testing.expectEqual(@as(i64, 3), state.results[0].id);
    state.filter_state = directory_filter.DirectoryFilterState.init("local");
    state.filter_state.toggleMode();
    try state.loadPage(&db, 100, 0, true);
    try std.testing.expectEqual(@as(usize, 1), state.total_count);
    try std.testing.expectEqual(@as(i64, 2), state.results[0].id);
    try state.query.appendSlice(allocator, " no match");
    try state.loadPage(&db, 100, 0, true);
    try std.testing.expectEqual(@as(usize, 0), state.total_count);
    try std.testing.expectEqual(@as(usize, 0), state.results.len);
}

test "large viewports and page navigation load complete pages" {
    const allocator = std.testing.allocator;
    var environ_map: std.process.Environ.Map = .init(allocator);
    defer environ_map.deinit();
    var db = try createNavigationTestDb(1000);
    defer db.deinit();
    var app: TuiApp = undefined;
    try app.init(allocator, &db, null, std.testing.io, &environ_map);
    defer app.deinit();
    var size = try app.tty.getWinsize();
    size.cols = 80;
    size.rows = 240;
    try app.handleEvent(.{ .winsize = size });
    try std.testing.expectEqual(@as(usize, 237), app.search_state.results.len);
    try app.handleEvent(.{ .key_press = .{ .codepoint = vaxis.Key.page_down } });
    try std.testing.expectEqual(@as(i64, 763), (try navigation.getSelectedCommandEntry(app.search_state.results, app.selected_index, app.search_state.results_offset)).?.id);
    try app.handleEvent(.{ .key_press = .{ .codepoint = vaxis.Key.end } });
    try std.testing.expectEqual(@as(i64, 1), (try navigation.getSelectedCommandEntry(app.search_state.results, app.selected_index, app.search_state.results_offset)).?.id);
    try app.handleEvent(.{ .key_press = .{ .codepoint = vaxis.Key.page_up } });
    try std.testing.expectEqual(@as(i64, 238), (try navigation.getSelectedCommandEntry(app.search_state.results, app.selected_index, app.search_state.results_offset)).?.id);
    try app.handleEvent(.{ .key_press = .{ .codepoint = vaxis.Key.home } });
    try std.testing.expectEqual(@as(i64, 1000), (try navigation.getSelectedCommandEntry(app.search_state.results, app.selected_index, app.search_state.results_offset)).?.id);
}

test "queued edits coalesce but Enter selects from the updated query" {
    const allocator = std.testing.allocator;
    var environ_map: std.process.Environ.Map = .init(allocator);
    defer environ_map.deinit();
    var db = try createNavigationTestDb(300);
    defer db.deinit();
    var app: TuiApp = undefined;
    try app.init(allocator, &db, null, std.testing.io, &environ_map);
    defer app.deinit();
    defer if (app.selected_command) |cmd| allocator.free(cmd);
    try app.handleEvent(.{ .key_press = .{ .codepoint = '0', .text = "000" } });
    try app.handleEvent(.{ .key_press = .{ .codepoint = '0', .text = "001" } });
    try std.testing.expect(app.search_dirty);
    try std.testing.expectEqual(@as(usize, 300), app.scroll_state.total_count);
    try app.handleEvent(.{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expect(app.should_quit);
    try std.testing.expectEqualStrings("cmd 000001", app.selected_command.?);
}

test "repeated result pages reuse bounded memory and preserve literal LIKE characters" {
    const allocator = std.testing.allocator;
    var db = try createNavigationTestDb(300);
    defer db.deinit();
    try db.exec("INSERT INTO history VALUES(301,'literal %_\\','local',0,0,301)", .{}, .{});
    var state = search_logic.SearchState.init(allocator);
    defer state.deinit(allocator);
    try state.query.appendSlice(allocator, "%_\\");
    try state.loadPage(&db, 100, 0, true);
    try std.testing.expectEqual(@as(usize, 1), state.total_count);
    state.query.clearRetainingCapacity();
    try state.query.appendSlice(allocator, "cmd");
    try state.loadPage(&db, 100, 0, true);
    // Warm up the retained arena; repeated pages must not accumulate old results.
    try state.loadPage(&db, 100, 0, true);
    const capacity = state.results_arena.queryCapacity();
    for (0..20) |i| {
        try state.loadPage(&db, 100, (i % 3) * 100, true);
        try std.testing.expect(state.results_arena.queryCapacity() <= capacity);
        try std.testing.expectEqual(@as(usize, 300), state.total_count);
    }
}
