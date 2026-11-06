//! Isolated Windows console regression: stop an idle reader without user input.
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

extern "kernel32" fn WriteConsoleInputW(hConsoleInput: std.os.windows.HANDLE, lpBuffer: *const vaxis.Tty.INPUT_RECORD, nLength: std.os.windows.DWORD, lpNumberOfEventsWritten: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;

pub const panic = vaxis.panic_handler;

const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) return error.WindowsOnly;
    const allocator = std.heap.smp_allocator;
    var arguments = try init.minimal.args.iterateAllocator(allocator);
    defer arguments.deinit();
    _ = arguments.next();
    const option = arguments.next();
    const full_queue = if (option) |value| std.mem.eql(u8, value, "--full-queue") else false;
    if ((option != null and !full_queue) or arguments.next() != null) return error.UnknownProbeOption;
    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(init.io, &buffer);
    defer tty.deinit();
    var vx = try vaxis.init(init.io, allocator, init.environ_map, .{});
    defer vx.deinit(allocator, tty.writer());
    var loop = vaxis.Loop(Event).init(init.io, &tty, &vx);
    if (full_queue) {
        for (0..loop.queue.buf.len) |_| {
            if (!try loop.tryPostEvent(.focus_in)) return error.ProbeQueueFillFailed;
        }
    }
    try loop.start();
    defer loop.stop();
    if (full_queue) {
        // A non-key event makes the producer try to post into the full queue.
        var record: vaxis.Tty.INPUT_RECORD = .{ .EventType = 0x0010, .Event = .{ .FocusEvent = .{ .bSetFocus = .TRUE } } };
        var written: std.os.windows.DWORD = 0;
        if (!WriteConsoleInputW(tty.stdin, &record, 1, &written).toBool() or written != 1) return error.ProbeInputFailed;
    }
    // Allow the reader to block on the empty console input buffer. This test
    // never sends keys or negotiates terminal capabilities.
    try std.Io.sleep(init.io, .fromMilliseconds(50), .awake);
    try tty.writer().writeAll("ZS_IDLE_STOP_BEGIN\n");
    try tty.writer().flush();
    loop.stop();
    try tty.writer().writeAll("ZS_IDLE_STOP_END\n");
    try tty.writer().flush();
}
