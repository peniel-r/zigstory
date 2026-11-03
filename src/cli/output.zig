const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const utf8_code_page: windows.UINT = 65001;

// Declared exactly as libvaxis declares them, so both declarations stay compatible.
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) windows.UINT;
extern "kernel32" fn GetConsoleMode(kConsoleHandle: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleOutputCP(wCodePageId: windows.UINT) callconv(.winapi) windows.BOOL;

/// Buffered stdout for human-readable reports. Report text is UTF-8; when stdout is
/// a Windows console, the console uses UTF-8 while the report is written, so
/// non-ASCII command text and bar characters render on any console code page.
pub const Report = struct {
    file_writer: std.Io.File.Writer,
    previous_code_page: ?windows.UINT = null,

    /// Do not move the report after calling `writer`.
    pub fn init(io: std.Io, buffer: []u8) Report {
        const stdout = std.Io.File.stdout();
        var report: Report = .{ .file_writer = stdout.writerStreaming(io, buffer) };
        if (builtin.os.tag == .windows) report.previous_code_page = useUtf8Console(stdout.handle);
        return report;
    }

    pub fn writer(self: *Report) *std.Io.Writer {
        return &self.file_writer.interface;
    }

    /// Flushes buffered output and restores the console code page.
    pub fn finish(self: *Report) !void {
        defer self.restoreCodePage();
        try self.file_writer.interface.flush();
    }

    /// Restores the console code page without flushing; use on error paths.
    pub fn restoreCodePage(self: *Report) void {
        if (builtin.os.tag != .windows) return;
        if (self.previous_code_page) |code_page| _ = SetConsoleOutputCP(code_page);
        self.previous_code_page = null;
    }
};

/// Returns the previous code page when the console was switched to UTF-8.
fn useUtf8Console(handle: windows.HANDLE) ?windows.UINT {
    var mode: windows.DWORD = undefined;
    // Redirected output is not a console; its bytes are already UTF-8.
    if (!GetConsoleMode(handle, &mode).toBool()) return null;
    const previous = GetConsoleOutputCP();
    if (previous == utf8_code_page or !SetConsoleOutputCP(utf8_code_page).toBool()) return null;
    return previous;
}

pub const DisplayPrefix = struct {
    text: []const u8,
    truncated: bool,
};

/// Returns the first line of `text`, cut to at most `max_bytes` without splitting
/// a UTF-8 sequence. `truncated` reports whether anything was left out.
pub fn displayPrefix(text: []const u8, max_bytes: usize) DisplayPrefix {
    const line_end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    var end = @min(line_end, max_bytes);
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    return .{ .text = text[0..end], .truncated = end < text.len };
}

/// Returns `text` limited to `max_bytes`, using "..." to mark omitted text.
pub fn ellipsize(buffer: []u8, text: []const u8, max_bytes: usize) []const u8 {
    std.debug.assert(max_bytes >= 3 and buffer.len >= max_bytes);
    const whole = displayPrefix(text, max_bytes);
    if (!whole.truncated) return whole.text;
    const shown = displayPrefix(text, max_bytes - 3);
    @memcpy(buffer[0..shown.text.len], shown.text);
    @memcpy(buffer[shown.text.len..][0..3], "...");
    return buffer[0 .. shown.text.len + 3];
}
