const std = @import("std");
const builtin = @import("builtin");

pub fn copyToClipboard(allocator: std.mem.Allocator, text: []const u8) !void {
    if (builtin.os.tag == .windows) {
        return copyToClipboardWindows(allocator, text);
    } else {
        // Fallback or error for other OSes if needed
        return error.UnsupportedOperatingSystem;
    }
}

const windows = std.os.windows;

// Extern declarations for Clipboard API
extern "user32" fn OpenClipboard(hWndNewOwner: ?windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn SetClipboardData(uFormat: windows.UINT, hMem: windows.HANDLE) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn GlobalAlloc(uFlags: windows.UINT, dwBytes: usize) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GlobalLock(hMem: windows.HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GlobalFree(hMem: windows.HANDLE) callconv(.winapi) ?windows.HANDLE;

fn copyToClipboardWindows(allocator: std.mem.Allocator, text: []const u8) !void {
    // Windows API constants
    const CF_UNICODETEXT = 13;
    const GHND = 0x0042;

    if (OpenClipboard(null) == 0) return error.OpenClipboardFailed;
    defer _ = CloseClipboard();

    if (EmptyClipboard() == 0) return error.EmptyClipboardFailed;

    // Convert UTF-8 to UTF-16 for Windows clipboard
    const utf16_text = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
    defer allocator.free(utf16_text);

    const size = (utf16_text.len + 1) * 2;
    const hMem = GlobalAlloc(GHND, size) orelse return error.GlobalAllocFailed;
    errdefer _ = GlobalFree(hMem);

    const pMem = GlobalLock(hMem) orelse return error.GlobalLockFailed;
    const pMem_u16: [*]u16 = @ptrCast(@alignCast(pMem));
    @memcpy(pMem_u16[0..utf16_text.len], utf16_text[0..utf16_text.len]);
    pMem_u16[utf16_text.len] = 0; // Null terminator
    _ = GlobalUnlock(hMem);

    if (SetClipboardData(CF_UNICODETEXT, hMem) == null) return error.SetClipboardDataFailed;
    // SetClipboardData takes ownership of hMem on success
}
