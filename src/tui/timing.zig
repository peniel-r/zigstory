const std = @import("std");

pub const Metrics = struct {
    io: std.Io,
    path: []const u8,
    start: std.Io.Timestamp,
    launch: ?std.Io.Timestamp = null,
    terminal_init_ms: f64 = 0,
    negotiation_ms: f64 = 0,
    first_frame_ms: ?f64 = null,
    launch_to_first_frame_ms: ?f64 = null,
    first_frame_write_ms: f64 = 0,
    frame_count: usize = 0,
    frame_write_total_ms: f64 = 0,
    frame_write_max_ms: f64 = 0,
    input_to_frame_max_ms: f64 = 0,
    cols: u16 = 0,
    rows: u16 = 0,

    pub fn init(io: std.Io, env: *std.process.Environ.Map) !?Metrics {
        const path = env.get("ZIGSTORY_TUI_PROFILE") orelse return null;
        if (path.len == 0) return error.EmptyTuiProfilePath;
        var result: Metrics = .{ .io = io, .path = path, .start = std.Io.Timestamp.now(io, .awake) };
        if (env.get("ZIGSTORY_TUI_LAUNCH_NS")) |value| {
            const ns = try std.fmt.parseInt(i96, value, 10);
            if (ns < 0 or ns > result.start.nanoseconds) return error.InvalidTuiLaunchTimestamp;
            result.launch = .{ .nanoseconds = ns };
        }
        return result;
    }

    pub fn elapsed(self: *const Metrics, start: std.Io.Timestamp) f64 {
        return @as(f64, @floatFromInt(start.durationTo(std.Io.Timestamp.now(self.io, .awake)).toNanoseconds())) / 1e6;
    }

    pub fn frame(self: *Metrics, write_start: std.Io.Timestamp, input: ?std.Io.Timestamp) void {
        const write_ms = self.elapsed(write_start);
        if (self.first_frame_ms == null) {
            self.first_frame_ms = self.elapsed(self.start);
            self.launch_to_first_frame_ms = if (self.launch) |launch| self.elapsed(launch) else null;
            self.first_frame_write_ms = write_ms;
        }
        self.frame_count += 1;
        self.frame_write_total_ms += write_ms;
        self.frame_write_max_ms = @max(self.frame_write_max_ms, write_ms);
        if (input) |start| self.input_to_frame_max_ms = @max(self.input_to_frame_max_ms, self.elapsed(start));
    }

    pub fn save(self: *const Metrics) !void {
        var buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try std.json.Stringify.value(.{
            .main_to_first_frame_ms = self.first_frame_ms,
            .launch_to_first_frame_ms = self.launch_to_first_frame_ms,
            .terminal_init_ms = self.terminal_init_ms,
            .negotiation_ms = self.negotiation_ms,
            .first_frame_write_ms = self.first_frame_write_ms,
            .frame_count = self.frame_count,
            .frame_write_mean_ms = self.frame_write_total_ms / @as(f64, @floatFromInt(@max(self.frame_count, 1))),
            .frame_write_max_ms = self.frame_write_max_ms,
            .input_to_frame_max_ms = self.input_to_frame_max_ms,
            .cols = self.cols,
            .rows = self.rows,
            .note = "Actual tty render and flush; input timing begins when the event loop wakes. Excludes display composition and physical key latency. No command text.",
        }, .{}, &writer);
        const file = try std.Io.Dir.cwd().createFile(self.io, self.path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, writer.buffered());
    }
};

test "terminal metrics are opt-in and contain no history data" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(try Metrics.init(std.testing.io, &env) == null);
    try env.put("ZIGSTORY_TUI_PROFILE", "");
    try std.testing.expectError(error.EmptyTuiProfilePath, Metrics.init(std.testing.io, &env));
    try env.put("ZIGSTORY_TUI_PROFILE", "unused.json");
    try env.put("ZIGSTORY_TUI_LAUNCH_NS", "-1");
    try std.testing.expectError(error.InvalidTuiLaunchTimestamp, Metrics.init(std.testing.io, &env));
}
