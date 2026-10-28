const std = @import("std");
const vaxis = @import("vaxis");
const scrolling = @import("scrolling.zig");

// ─────────────────────────────────────────────────────────────────────────────
// Color Palette (Dracula-inspired theme)
// ─────────────────────────────────────────────────────────────────────────────
pub const colors = struct {
    // Background colors
    pub const bg_primary: vaxis.Color = .{ .rgb = .{ 40, 42, 54 } }; // Dark bg
    pub const bg_selected: vaxis.Color = .{ .rgb = .{ 68, 71, 90 } }; // Selected row
    pub const bg_title: vaxis.Color = .{ .rgb = .{ 98, 114, 164 } }; // Title bar

    // Foreground colors
    pub const fg_primary: vaxis.Color = .{ .rgb = .{ 248, 248, 242 } }; // Default text
    pub const fg_dimmed: vaxis.Color = .{ .rgb = .{ 98, 114, 164 } }; // Dimmed (timestamps)
    pub const fg_highlight: vaxis.Color = .{ .rgb = .{ 255, 184, 108 } }; // Orange (matches)
    pub const fg_success: vaxis.Color = .{ .rgb = .{ 80, 250, 123 } }; // Green (success)
    pub const fg_error: vaxis.Color = .{ .rgb = .{ 255, 85, 85 } }; // Red (failed commands)
    pub const fg_duration: vaxis.Color = .{ .rgb = .{ 189, 147, 249 } }; // Purple (duration)
    pub const fg_directory: vaxis.Color = .{ .rgb = .{ 139, 233, 253 } }; // Cyan (directory)
    pub const fg_title: vaxis.Color = .{ .rgb = .{ 0, 0, 0 } }; // Black for title
};

// ─────────────────────────────────────────────────────────────────────────────
// Column Widths
// ─────────────────────────────────────────────────────────────────────────────
pub const ColumnConfig = struct {
    timestamp_width: u16 = 10,
    duration_width: u16 = 9,
    directory_width: u16 = 18,
    indicator_width: u16 = 6,
    padding: u16 = 2,

    pub fn commandWidth(self: ColumnConfig, term_width: u16) u16 {
        const fixed_width = self.indicator_width + self.timestamp_width + self.duration_width + self.directory_width + self.padding;
        if (term_width <= fixed_width) return 10;
        return term_width - fixed_width;
    }
};

pub const default_config = ColumnConfig{};

// ─────────────────────────────────────────────────────────────────────────────
// Time Formatting
// ─────────────────────────────────────────────────────────────────────────────

pub fn formatRelativeTime(timestamp: i64, buf: []u8, now: i64) []const u8 {
    const diff = now - timestamp;

    if (diff < 0) return std.fmt.bufPrint(buf, "future", .{}) catch "?";
    if (diff < 60) return std.fmt.bufPrint(buf, "{d}s ago", .{diff}) catch "now";
    if (diff < 3600) {
        const mins = @divFloor(diff, 60);
        return std.fmt.bufPrint(buf, "{d}m ago", .{mins}) catch "?m";
    }
    if (diff < 86400) {
        const hours = @divFloor(diff, 3600);
        return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "?h";
    }
    if (diff < 604800) {
        const days = @divFloor(diff, 86400);
        return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "?d";
    }
    if (diff < 2592000) {
        const weeks = @divFloor(diff, 604800);
        return std.fmt.bufPrint(buf, "{d}w ago", .{weeks}) catch "?w";
    }
    const months = @divFloor(diff, 2592000);
    if (months < 12) return std.fmt.bufPrint(buf, "{d}mo ago", .{months}) catch "?mo";
    const years = @divFloor(diff, 31536000);
    return std.fmt.bufPrint(buf, "{d}y ago", .{years}) catch "?y";
}

pub fn formatDuration(duration_ms: i64, buf: []u8) ?[]const u8 {
    if (duration_ms <= 1000) return null;

    const seconds = @divFloor(duration_ms, 1000);
    const ms_remainder = @mod(duration_ms, 1000);

    if (seconds < 60) {
        if (ms_remainder >= 100) {
            return std.fmt.bufPrint(buf, "[{d}.{d}s]", .{ seconds, @divFloor(ms_remainder, 100) }) catch "[?s]";
        }
        return std.fmt.bufPrint(buf, "[{d}s]", .{seconds}) catch "[?s]";
    }
    if (seconds < 3600) {
        const mins = @divFloor(seconds, 60);
        const secs = @mod(seconds, 60);
        if (secs > 0) return std.fmt.bufPrint(buf, "[{d}m{d}s]", .{ mins, secs }) catch "[?m]";
        return std.fmt.bufPrint(buf, "[{d}m]", .{mins}) catch "[?m]";
    }
    const hours = @divFloor(seconds, 3600);
    const mins = @mod(@divFloor(seconds, 60), 60);
    if (mins > 0) return std.fmt.bufPrint(buf, "[{d}h{d}m]", .{ hours, mins }) catch "[?h]";
    return std.fmt.bufPrint(buf, "[{d}h]", .{hours}) catch "[?h]";
}

pub fn prefixByCells(win: vaxis.Window, text: []const u8, max_cells: usize) []const u8 {
    var iter = vaxis.unicode.graphemeIterator(text);
    var cells: usize = 0;
    var end: usize = 0;
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        if (std.mem.indexOfAny(u8, bytes, "\r\n") != null) break;
        const width = win.gwidth(bytes);
        if (cells + width > max_cells) break;
        cells += width;
        end = grapheme.start + bytes.len;
    }
    return text[0..end];
}

pub fn truncateDirectory(win: vaxis.Window, path: []const u8, max_cells: usize, buf: []u8) []const u8 {
    if (win.gwidth(path) <= max_cells and path.len <= buf.len) {
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }
    if (max_cells <= 2 or buf.len <= 2) return ".."[0..@min(max_cells, @min(buf.len, 2))];
    var iter = vaxis.unicode.graphemeIterator(path);
    var remaining_cells: usize = win.gwidth(path);
    var start: usize = path.len;
    while (iter.next()) |grapheme| {
        const suffix = path[grapheme.start..];
        if (remaining_cells <= max_cells - 2 and suffix.len <= buf.len - 2) {
            start = grapheme.start;
            break;
        }
        remaining_cells -|= win.gwidth(grapheme.bytes(path));
    }
    buf[0] = '.';
    buf[1] = '.';
    @memcpy(buf[2 .. 2 + path.len - start], path[start..]);
    return buf[0 .. 2 + path.len - start];
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry Rendering
// ─────────────────────────────────────────────────────────────────────────────

fn fillRowBackground(win: vaxis.Window, row: u16, style: vaxis.Style) void {
    if (row >= win.height) return;
    win.child(.{ .y_off = row, .height = 1 }).fill(.{ .style = style });
}

pub fn fillScreen(win: vaxis.Window) void {
    win.fill(.{ .style = .{ .bg = colors.bg_primary } });
}

pub fn renderEntry(
    win: vaxis.Window,
    allocator: std.mem.Allocator,
    entry: scrolling.HistoryEntry,
    row: u16,
    is_cursor_on_row: bool,
    is_in_selection_set: bool,
    search_query: ?[]const u8,
    _: ColumnConfig,
    now: i64,
) !void {
    const term_width = win.width;
    const is_failed = entry.exit_code != 0;

    const base_fg: vaxis.Color = if (is_failed) colors.fg_error else colors.fg_primary;
    const base_bg: vaxis.Color = if (is_cursor_on_row) colors.bg_selected else colors.bg_primary;

    const base_style = vaxis.Style{
        .fg = base_fg,
        .bg = base_bg,
        .bold = is_cursor_on_row,
    };

    const dimmed_style = vaxis.Style{
        .fg = colors.fg_dimmed,
        .bg = base_bg,
    };

    const duration_style = vaxis.Style{
        .fg = colors.fg_duration,
        .bg = base_bg,
    };

    // Fill row with background
    if (is_cursor_on_row) fillRowBackground(win, row, base_style);

    // Column 0-1: Selection indicator
    const indicator_style = vaxis.Style{
        .fg = colors.fg_highlight,
        .bg = base_bg,
        .bold = true,
    };
    const cursor_ind = if (is_cursor_on_row) ">" else " ";
    const select_ind = if (is_in_selection_set) "[x]" else "   ";

    var ind_buf: [32]u8 = undefined;
    const ind_raw = std.fmt.bufPrint(&ind_buf, "{s}{s} ", .{ cursor_ind, select_ind }) catch "> [x] ";
    const indicator = try allocator.dupe(u8, ind_raw);

    _ = win.printSegment(.{ .text = indicator, .style = indicator_style }, .{ .row_offset = row, .col_offset = 0, .wrap = .none });

    var time_buf: [32]u8 = undefined;
    const time_raw = formatRelativeTime(entry.timestamp, &time_buf, now);
    const time_text = try allocator.dupe(u8, time_raw);
    _ = win.printSegment(.{ .text = time_text, .style = dimmed_style }, .{ .row_offset = row, .col_offset = 6, .wrap = .none });

    // Column 16-25: Duration (9 chars, only if > 1s)
    var dur_buf: [32]u8 = undefined;
    if (formatDuration(entry.duration_ms, &dur_buf)) |dur_raw| {
        const dur_text = try allocator.dupe(u8, dur_raw);
        _ = win.printSegment(.{ .text = dur_text, .style = duration_style }, .{ .row_offset = row, .col_offset = 16, .wrap = .none });
    }

    // Column 25+: Command (rest of line)
    const cmd_start: u16 = 25;
    const max_cmd_len: usize = term_width -| (cmd_start + 2);
    const display_cmd = prefixByCells(win, entry.cmd, max_cmd_len);

    if (search_query) |query| {
        if (query.len > 0) {
            renderHighlightedText(win, display_cmd, query, row, cmd_start, base_style, is_cursor_on_row, base_bg);
        } else {
            _ = win.printSegment(.{ .text = display_cmd, .style = base_style }, .{ .row_offset = row, .col_offset = cmd_start });
        }
    } else {
        _ = win.printSegment(.{ .text = display_cmd, .style = base_style }, .{ .row_offset = row, .col_offset = cmd_start });
    }
}

fn renderHighlightedText(
    win: vaxis.Window,
    text: []const u8,
    query: []const u8,
    row: u16,
    start_col: u16,
    base_style: vaxis.Style,
    is_selected: bool,
    base_bg: vaxis.Color,
) void {
    const match_idx = findCaseInsensitive(text, query);

    if (match_idx) |byte_idx| {
        // A substring can start inside a combining/ZWJ cluster. Highlight the
        // complete cluster so rendering never receives a partial grapheme.
        var idx = byte_idx;
        var match_end = byte_idx + query.len;
        var iter = vaxis.unicode.graphemeIterator(text);
        while (iter.next()) |grapheme| {
            const end = grapheme.start + grapheme.bytes(text).len;
            if (grapheme.start <= byte_idx and end > byte_idx) idx = grapheme.start;
            if (grapheme.start < match_end and end >= match_end) {
                match_end = end;
                break;
            }
        }
        var col = start_col;

        // Pre-match
        if (idx > 0) {
            _ = win.printSegment(.{ .text = text[0..idx], .style = base_style }, .{ .row_offset = row, .col_offset = col });
            col += win.gwidth(text[0..idx]);
        }

        // Match
        const highlight_style = vaxis.Style{
            .fg = if (is_selected) colors.fg_title else colors.fg_highlight,
            .bg = if (is_selected) colors.fg_highlight else base_bg,
            .bold = true,
        };
        _ = win.printSegment(.{ .text = text[idx..match_end], .style = highlight_style }, .{ .row_offset = row, .col_offset = col });
        col += win.gwidth(text[idx..match_end]);

        // Post-match
        if (match_end < text.len) {
            _ = win.printSegment(.{ .text = text[match_end..], .style = base_style }, .{ .row_offset = row, .col_offset = col });
        }
    } else {
        _ = win.printSegment(.{ .text = text, .style = base_style }, .{ .row_offset = row, .col_offset = start_col });
    }
}

fn findCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

pub fn renderTitleBar(win: vaxis.Window) void {
    const title = " zigstory - Command History Search ";
    const title_style = vaxis.Style{
        .fg = colors.fg_title,
        .bg = colors.bg_title,
        .bold = true,
    };
    fillRowBackground(win, 0, title_style);
    const title_len: u16 = @intCast(title.len);
    const title_start: u16 = if (win.width > title_len) (win.width - title_len) / 2 else 0;
    _ = win.printSegment(.{ .text = title, .style = title_style }, .{ .col_offset = title_start, .row_offset = 0, .wrap = .none });
}

pub fn renderStatusBar(
    win: vaxis.Window,
    allocator: std.mem.Allocator,
    is_searching: bool,
    query: []const u8,
    total_count: usize,
    selected_index: usize,
    result_count: usize,
    selections_count: usize,
    filter_mode: ?[]const u8,
    command_mode: bool,
    command_buffer: []const u8,
) !void {
    const bar_style = vaxis.Style{
        .fg = colors.fg_dimmed,
        .bg = colors.bg_primary,
    };
    fillRowBackground(win, 1, bar_style);

    var status_buf: [512]u8 = undefined;
    var status_text: []const u8 = "";

    const search_style = vaxis.Style{
        .fg = colors.fg_success,
        .bg = colors.bg_primary,
        .bold = true,
    };

    const command_style = vaxis.Style{
        .fg = colors.fg_highlight,
        .bg = colors.bg_primary,
        .bold = true,
    };

    if (command_mode) {
        status_text = std.fmt.bufPrint(&status_buf, " :{s}", .{
            command_buffer,
        }) catch " : ";
    } else if (is_searching) {
        status_text = std.fmt.bufPrint(&status_buf, " Search: {s}| ({d} results) {s} | [FILTER: {s}]", .{
            query,
            result_count,
            if (selections_count > 0) std.fmt.bufPrint(status_buf[256..], "| {d} selected", .{selections_count}) catch "" else "",
            filter_mode orelse "Global",
        }) catch " Error ";
    } else {
        status_text = std.fmt.bufPrint(&status_buf, " {d} commands | {d}/{d} | Type to search {s} | [FILTER: {s}]", .{
            total_count,
            if (total_count > 0) selected_index + 1 else 0,
            total_count,
            if (selections_count > 0) std.fmt.bufPrint(status_buf[256..], "| {d} selected", .{selections_count}) catch "" else "",
            filter_mode orelse "Global",
        }) catch " Error ";
    }

    // Duplicate status_text to ensure it survives the frame
    const status_safe = try allocator.dupe(u8, status_text);
    const style = if (command_mode) command_style else search_style;
    _ = win.printSegment(.{ .text = prefixByCells(win, status_safe, win.width), .style = style }, .{ .row_offset = 1, .col_offset = 0, .wrap = .none });
}

pub fn renderHelpBar(win: vaxis.Window) void {
    const help_row: u16 = @intCast(win.height -| 1);
    const help_style = vaxis.Style{
        .fg = colors.fg_dimmed,
        .bg = colors.bg_primary,
    };
    fillRowBackground(win, help_row, help_style);

    const keybind_style = vaxis.Style{
        .fg = colors.fg_highlight,
        .bg = colors.bg_primary,
        .bold = true,
    };
    const desc_style = vaxis.Style{
        .fg = colors.fg_dimmed,
        .bg = colors.bg_primary,
    };

    var col: u16 = 1;
    const keybinds = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "↑/↓", .desc = " Nav  " },
        .{ .key = "Enter", .desc = " Select&Copy  " },
        .{ .key = "S+Space", .desc = " Toggle Sel " },
        .{ .key = "Ctrl+C", .desc = " Exit  " },
        .{ .key = "PgUp/Dn", .desc = " Page  " },
        .{ .key = "Home/End", .desc = " Jump  " },
        .{ .key = "Ctrl+U", .desc = " Clear  " },
        .{ .key = "Ctrl+F", .desc = " Toggle Filter  " },
        .{ .key = "", .desc = "Type to search" },
    };

    for (keybinds) |kb| {
        if (col >= win.width -| 5) break;
        if (kb.key.len > 0) {
            _ = win.printSegment(.{ .text = kb.key, .style = keybind_style }, .{ .row_offset = help_row, .col_offset = col, .wrap = .none });
            col += win.gwidth(kb.key);
        }

        _ = win.printSegment(.{ .text = kb.desc, .style = desc_style }, .{ .row_offset = help_row, .col_offset = col, .wrap = .none });
        col += win.gwidth(kb.desc);
    }
}

test "rendering truncates whole graphemes and highlights by terminal columns" {
    const allocator = std.testing.allocator;
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    var discard_buffer: [1024]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&discard_buffer);
    var vx = try vaxis.init(std.testing.io, allocator, &env, .{});
    defer vx.deinit(allocator, &sink.writer);
    vx.caps.unicode = .unicode;
    try vx.resize(allocator, &sink.writer, .{ .cols = 40, .rows = 5, .x_pixel = 0, .y_pixel = 0 });
    const win = vx.window();
    const sample = "\u{4e2d}e\u{301}\u{1f469}\u{200d}\u{1f680}tail";
    try std.testing.expectEqualStrings("", prefixByCells(win, sample, 1));
    try std.testing.expectEqualStrings("\u{4e2d}", prefixByCells(win, sample, 2));
    try std.testing.expectEqualStrings("\u{4e2d}e\u{301}", prefixByCells(win, sample, 4));
    try std.testing.expectEqualStrings("\u{4e2d}e\u{301}\u{1f469}\u{200d}\u{1f680}", prefixByCells(win, sample, 5));
    try std.testing.expectEqualStrings("first", prefixByCells(win, "first\nsecond", 40));
    fillScreen(win);
    renderHighlightedText(win, "\u{4e2d}e\u{301}tail", "\u{301}", 2, 0, .{ .fg = colors.fg_primary }, false, colors.bg_primary);
    try std.testing.expectEqualStrings("\u{4e2d}", vx.screen.readCell(0, 2).?.char.grapheme);
    try std.testing.expectEqualStrings("e\u{301}", vx.screen.readCell(2, 2).?.char.grapheme);
    try std.testing.expectEqual(colors.fg_highlight, vx.screen.readCell(2, 2).?.style.fg);
    try std.testing.expectEqualStrings("t", vx.screen.readCell(3, 2).?.char.grapheme);
    var path_buf: [64]u8 = undefined;
    const truncated = truncateDirectory(win, "C:\\\u{4e2d}\u{1f469}\u{200d}\u{1f680}", 4, &path_buf);
    try std.testing.expectEqualStrings("..\u{1f469}\u{200d}\u{1f680}", truncated);
    try std.testing.expect(win.gwidth(truncated) <= 4);
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated));
    renderHelpBar(win);
    try std.testing.expectEqualStrings("N", vx.screen.readCell(5, 4).?.char.grapheme);
}
