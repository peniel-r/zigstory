const std = @import("std");
const sqlite = @import("sqlite");
const zigstory = @import("zigstory");
const search = @import("tui/search.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    var db = try zigstory.db.initSchema2Fixture(":memory:");
    defer db.deinit();
    try db.exec(
        \\WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i < 100000)
        \\INSERT INTO history(id,cmd,cwd,exit_code,duration_ms,timestamp) SELECT i, printf('cmd %06d',i % 25000),
        \\ CASE WHEN i % 2 = 0 THEN 'local' ELSE 'other' END, 0, 0, i % 70000 FROM n
    , .{}, .{});
    try zigstory.db.ensureSchema(&db);
    var state = search.SearchState.init(allocator);
    defer state.deinit(allocator);
    try state.query.appendSlice(allocator, "cmd ");
    var initial: [21]f64 = undefined;
    var deep: [21]f64 = undefined;
    var page: [21]f64 = undefined;
    for (0..initial.len) |i| {
        var start = std.Io.Timestamp.now(init.io, .awake);
        try state.loadPage(&db, 100, 0, true);
        initial[i] = elapsed(init.io, start);
        if (state.total_count != 25000 or state.results.len != 100) return error.IncorrectBenchmarkResults;
        start = std.Io.Timestamp.now(init.io, .awake);
        try state.loadPage(&db, 100, 24900, false);
        deep[i] = elapsed(init.io, start);
        if (state.results.len != 100 or state.results_offset != 24900) return error.IncorrectBenchmarkResults;
        start = std.Io.Timestamp.now(init.io, .awake);
        try state.loadPage(&db, 100, 100, false);
        page[i] = elapsed(init.io, start);
        if (state.results.len != 100 or state.results_offset != 100) return error.IncorrectBenchmarkResults;
    }
    std.mem.sort(f64, &initial, {}, std.sort.asc(f64));
    std.mem.sort(f64, &deep, {}, std.sort.asc(f64));
    std.mem.sort(f64, &page, {}, std.sort.asc(f64));
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .rows = 100000,
        .unique_matches = state.total_count,
        .initial_median_ms = initial[10],
        .initial_p95_ms = initial[19],
        .deep_page_median_ms = deep[10],
        .deep_page_p95_ms = deep[19],
        .next_page_median_ms = page[10],
        .peak_result_arena_bytes = state.results_arena.queryCapacity(),
        .sqlite_peak_bytes = sqlite.c.sqlite3_memory_highwater(0),
    }, .{});
    defer allocator.free(json);
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
}

fn elapsed(io: std.Io, start: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds())) / 1e6;
}
