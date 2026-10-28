const std = @import("std");
const zigstory = @import("zigstory");
const perf = @import("cli/perf.zig");

fn elapsed(io: std.Io, start: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds())) / 1e6;
}

pub fn main(minimal: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;
    var clock: std.Io.Threaded = .init_single_threaded;
    const clock_io = clock.io();
    var start = std.Io.Timestamp.now(clock_io, .awake);
    var threaded: std.Io.Threaded = .init(allocator, .{ .environ = minimal.environ, .argv0 = .init(minimal.args) });
    var runtime_open = true;
    defer if (runtime_open) threaded.deinit();
    const runtime_setup_ms = elapsed(clock_io, start);
    start = std.Io.Timestamp.now(clock_io, .awake);
    var env = try minimal.environ.createMap(allocator);
    defer env.deinit();
    const environment_ms = elapsed(clock_io, start);
    var args = try minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse return error.MissingDatabasePath;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    start = std.Io.Timestamp.now(clock_io, .awake);
    var db = try zigstory.db.initDb(path_z);
    var db_open = true;
    defer if (db_open) db.deinit();
    const database_open_ms = elapsed(clock_io, start);
    start = std.Io.Timestamp.now(clock_io, .awake);
    const metrics = try perf.getPerfMetrics(&db, "__zigstory_startup_profile__", allocator);
    allocator.free(metrics.last_cmd);
    const empty_perf_query_ms = elapsed(clock_io, start);
    start = std.Io.Timestamp.now(clock_io, .awake);
    db.deinit();
    db_open = false;
    threaded.deinit();
    runtime_open = false;
    const shutdown_ms = elapsed(clock_io, start);
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .runtime_setup_ms = runtime_setup_ms,
        .environment_ms = environment_ms,
        .database_open_ms = database_open_ms,
        .empty_perf_query_ms = empty_perf_query_ms,
        .shutdown_ms = shutdown_ms,
        .note = "In-process phases on a disposable snapshot; excludes OS executable loading and process launch",
    }, .{});
    defer allocator.free(json);
    try std.Io.File.stdout().writeStreamingAll(clock_io, json);
}
