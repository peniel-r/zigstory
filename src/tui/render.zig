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

pub fn formatRelativeTime(timestamp: i64, buf: []u8) []const u8 {
    const now: i64 = std.time.timestamp();
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

pub fn truncateDirectory(path: []const u8, max_len: usize, buf: []u8) []const u8 {
    if (path.len <= max_len) {
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }
    if (max_len <= 2) return "..";

    const chars_to_keep = max_len - 2;
    const start = path.len - chars_to_keep;
    buf[0] = '.';
    buf[1] = '.';
    @memcpy(buf[2 .. 2 + chars_to_keep], path[start..]);
    return buf[0 .. 2 + chars_to_keep];
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry Rendering
// ─────────────────────────────────────────────────────────────────────────────

fn fillRowBackground(win: vaxis.Window, row: u16, style: vaxis.Style) void {
    var x: u16 = 0;
    while (x < win.width) : (x += 1) {
        _ = win.printSegment(.{ .text = " ", .style = style }, .{ .row_offset = row, .col_offset = x });
    }
}

pub fn fillScreen(win: vaxis.Window) void {
    const style = vaxis.Style{ .bg = colors.bg_primary };
    var y: u16 = 0;
    while (y < win.height) : (y += 1) {
        fillRowBackground(win, y, style);
    }
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
    fillRowBackground(win, row, base_style);

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

    _ = win.printSegment(.{ .text = indicator, .style = indicator_style }, .{ .row_offset = row, .col_offset = 0 });

    var time_buf: [32]u8 = undefined;
    const time_raw = formatRelativeTime(entry.timestamp, &time_buf);
    const time_text = try allocator.dupe(u8, time_raw);
    _ = win.printSegment(.{ .text = time_text, .style = dimmed_style }, .{ .row_offset = row, .col_offset = 6 });

    // Column 16-25: Duration (9 chars, only if > 1s)
    var dur_buf: [32]u8 = undefined;
    if (formatDuration(entry.duration_ms, &dur_buf)) |dur_raw| {
        const dur_text = try allocator.dupe(u8, dur_raw);
        _ = win.printSegment(.{ .text = dur_text, .style = duration_style }, .{ .row_offset = row, .col_offset = 16 });
    }

    // Column 25+: Command (rest of line)
    const cmd_start: u16 = 25;
    const max_cmd_len: usize = if (term_width > cmd_start + 2) term_width - cmd_start - 2 else 20;

    var display_cmd = entry.cmd;
    if (display_cmd.len > max_cmd_len) {
        display_cmd = display_cmd[0..max_cmd_len];
    }

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

    if (match_idx) |idx| {
        var col = start_col;

        // Pre-match
        if (idx > 0) {
            _ = win.printSegment(.{ .text = text[0..idx], .style = base_style }, .{ .row_offset = row, .col_offset = col });
            col += @intCast(idx);
        }

        // Match
        const highlight_style = vaxis.Style{
            .fg = if (is_selected) colors.fg_title else colors.fg_highlight,
            .bg = if (is_selected) colors.fg_highlight else base_bg,
            .bold = true,
        };
        const match_end = @min(idx + query.len, text.len);
        _ = win.printSegment(.{ .text = text[idx..match_end], .style = highlight_style }, .{ .row_offset = row, .col_offset = col });
        col += @intCast(match_end - idx);

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
    _ = win.printSegment(.{ .text = title, .style = title_style }, .{ .col_offset = title_start, .row_offset = 0 });
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

    if (is_searching) {
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
    _ = win.printSegment(.{ .text = status_safe, .style = search_style }, .{ .row_offset = 1, .col_offset = 0 });
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
        .{ .key = "Esc", .desc = " Exit  " },
        .{ .key = "PgUp/Dn", .desc = " Page  " },
        .{ .key = "Home/End", .desc = " Jump  " },
        .{ .key = "Ctrl+U", .desc = " Clear  " },
        .{ .key = "Ctrl+F", .desc = " Toggle Filter  " },
        .{ .key = "", .desc = "Type to search" },
    };

    for (keybinds) |kb| {
        if (col >= win.width -| 5) break;
        if (kb.key.len > 0) {
            _ = win.printSegment(.{ .text = kb.key, .style = keybind_style }, .{ .row_offset = help_row, .col_offset = col });
            col += @intCast(kb.key.len);
        }
        _ = win.printSegment(.{ .text = kb.desc, .style = desc_style }, .{ .row_offset = help_row, .col_offset = col });
        col += @intCast(kb.desc.len);
    }
}
