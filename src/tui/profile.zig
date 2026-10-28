const std = @import("std");
const sqlite = @import("sqlite");
const search = @import("search.zig");
const render = @import("render.zig");
const vaxis = @import("vaxis");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse return error.MissingDatabasePath;
    if (args.next() != null) return error.UnexpectedArgument;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var db = try sqlite.Db.init(.{
        .mode = .{ .File = path_z },
        .open_flags = .{},
    });
    defer db.deinit();
    const query = blk: {
        var stmt = try db.prepare("SELECT substr(cmd,1,8) FROM history GROUP BY cmd ORDER BY COUNT(*) DESC LIMIT 1");
        defer stmt.deinit();
        var rows = try stmt.iterator([]const u8, .{});
        break :blk (try rows.nextAlloc(allocator, .{})) orelse try allocator.dupe(u8, "");
    };
    defer allocator.free(query);
    var state = search.SearchState.init(allocator);
    defer state.deinit(allocator);
    var discard_buffer: [4096]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&discard_buffer);
    var vx = try vaxis.init(init.io, allocator, init.environ_map, .{});
    defer vx.deinit(allocator, &sink.writer);
    try vx.resize(allocator, &sink.writer, .{ .cols = 160, .rows = 240, .x_pixel = 0, .y_pixel = 0 });
    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();
    var times: [80]f64 = undefined;
    var render_times: [80]f64 = undefined;
    var first_frame_ms: f64 = 0;
    var peak_frame_capacity: usize = 0;
    var peak_capacity: usize = 0;
    var warm_capacity: usize = 0;
    var final_capacity: usize = 0;
    var max_rows: usize = 0;
    for (0..times.len) |i| {
        state.query.clearRetainingCapacity();
        if (i % 2 == 1) try state.query.appendSlice(allocator, query);
        const start = std.Io.Timestamp.now(init.io, .awake);
        try state.loadPage(&db, 237, 0, true);
        if (i % 4 >= 2 and state.total_count > 237) {
            try state.loadPage(&db, 237, state.total_count - 237, false);
        }
        times[i] = @as(f64, @floatFromInt(start.durationTo(std.Io.Timestamp.now(init.io, .awake)).toNanoseconds())) / 1e6;
        const capacity = state.results_arena.queryCapacity();
        peak_capacity = @max(peak_capacity, capacity);
        if (i < 40) warm_capacity = @max(warm_capacity, capacity) else final_capacity = @max(final_capacity, capacity);
        max_rows = @max(max_rows, state.results.len);
        const render_start = std.Io.Timestamp.now(init.io, .awake);
        _ = frame_arena.reset(.retain_capacity);
        const frame_allocator = frame_arena.allocator();
        const win = vx.window();
        render.fillScreen(win);
        render.renderTitleBar(win);
        try render.renderStatusBar(win, frame_allocator, state.query.items.len > 0, state.query.items, state.total_count, state.results_offset, state.total_count, 0, "Global", false, "");
        const now = std.Io.Timestamp.now(init.io, .real).toSeconds();
        for (state.results, 0..) |entry, row| {
            try render.renderEntry(win, frame_allocator, entry, @intCast(row + 2), row == 0, false, if (state.query.items.len > 0) state.query.items else null, render.default_config, now);
        }
        render.renderHelpBar(win);
        try vx.render(&sink.writer);
        try sink.writer.flush();
        render_times[i] = @as(f64, @floatFromInt(render_start.durationTo(std.Io.Timestamp.now(init.io, .awake)).toNanoseconds())) / 1e6;
        if (i == 0) first_frame_ms = render_times[i];
        peak_frame_capacity = @max(peak_frame_capacity, frame_arena.queryCapacity());
    }
    std.mem.sort(f64, &times, {}, std.sort.asc(f64));
    std.mem.sort(f64, &render_times, {}, std.sort.asc(f64));
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .iterations = times.len,
        .page_limit = 237,
        .max_rows_loaded = max_rows,
        .median_ms = times[times.len / 2],
        .p95_ms = times[times.len * 95 / 100],
        .peak_result_arena_bytes = peak_capacity,
        .first_half_peak_bytes = warm_capacity,
        .second_half_peak_bytes = final_capacity,
        .frame_arena_peak_bytes = peak_frame_capacity,
        .headless_frame_first_ms = first_frame_ms,
        .headless_frame_median_ms = render_times[render_times.len / 2],
        .headless_frame_p95_ms = render_times[render_times.len * 95 / 100],
        .screen_cols = 160,
        .screen_rows = 240,
        .note = "TUI paging and headless 160x240 rendering to a discard sink; excludes terminal I/O and input thread",
    }, .{});
    defer allocator.free(json);
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
}
