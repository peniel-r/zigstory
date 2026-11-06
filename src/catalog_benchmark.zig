//! Disposable in-memory comparison; never reads or migrates installed history.
const std = @import("std");
const sqlite = @import("sqlite");
const zigstory = @import("zigstory");
const catalog = zigstory.catalog;
const old_search = @import("tui/search.zig");

const samples = 21;
const Case = struct { query: []const u8, cwd: ?[]const u8 = null };
const cases = [_]Case{
    .{ .query = "cmd " }, .{ .query = "cmd 000001" },           .{ .query = "no match" },
    .{ .query = "xy" },   .{ .query = "cmd ", .cwd = "local" },
};
const Timing = struct { median_ms: f64, p95_ms: f64 };
const Result = struct {
    query: []const u8,
    directory_filtered: bool,
    matches: usize,
    baseline_first_page: Timing,
    prototype_first_page: Timing,
    baseline_deep_page: Timing,
    prototype_deep_page: Timing,
    prototype_result_arena_bytes: usize,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    var arguments = try init.minimal.args.iterateAllocator(allocator);
    defer arguments.deinit();
    _ = arguments.next();
    var disk_fixture: ?[:0]u8 = null;
    defer if (disk_fixture) |path| allocator.free(path);
    var unique_count: i64 = 25000;
    var long_directories = false;
    while (arguments.next()) |option| {
        if (std.mem.eql(u8, option, "--disk-fixture")) {
            if (disk_fixture != null) return error.UnknownBenchmarkOption;
            disk_fixture = try allocator.dupeZ(u8, arguments.next() orelse return error.MissingFixturePath);
        } else if (std.mem.eql(u8, option, "--mostly-unique")) {
            unique_count = 100000;
        } else if (std.mem.eql(u8, option, "--long-directories")) {
            long_directories = true;
        } else return error.UnknownBenchmarkOption;
    }
    const local_directory = if (long_directories) "C:\\synthetic\\" ++ "nested\\" ** 20 ++ "local" else "local";
    const other_directory = if (long_directories) "C:\\synthetic\\" ++ "nested\\" ** 20 ++ "other" else "other";
    var query_cases = cases;
    query_cases[4].cwd = local_directory;
    if (disk_fixture) |path| {
        // Exclusive creation refuses all existing files, including real history.
        // This option seeds synthetic rows; it never migrates an input database.
        const file = try std.Io.Dir.cwd().createFile(init.io, path, .{ .exclusive = true });
        file.close(init.io);
    }
    defer if (disk_fixture) |path| {
        std.Io.Dir.cwd().deleteFile(init.io, path) catch {};
        for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
            const extra = std.fmt.allocPrint(allocator, "{s}{s}", .{ path, suffix }) catch continue;
            defer allocator.free(extra);
            std.Io.Dir.cwd().deleteFile(init.io, extra) catch {};
        }
    };
    var db = try zigstory.db.initDb(disk_fixture orelse ":memory:");
    defer db.deinit();
    try db.exec(
        \\WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<100000)
        \\INSERT INTO history(cmd,cwd,exit_code,duration_ms,session_id,hostname,timestamp,cmd_hash,event_id,rank)
        \\ SELECT printf('cmd %06d',i % ?),CASE WHEN i%3=0 THEN ? ELSE ? END,
        \\ i%13=0,i%5000,'benchmark-session','benchmark-host',i%70000,
        \\ printf('%064d',i % ?),printf('%036d',i),i%1000 FROM n
    , .{}, .{ unique_count, @as([]const u8, local_directory), @as([]const u8, other_directory), unique_count });
    const baseline_bytes = try usedBytes(&db);
    var results: [cases.len]Result = undefined;
    var first_ids = [_][]i64{&.{}} ** cases.len;
    var deep_ids = [_][]i64{&.{}} ** cases.len;
    defer for (first_ids, deep_ids) |first, deep| {
        allocator.free(first);
        allocator.free(deep);
    };
    {
        var state = old_search.SearchState.init(allocator);
        defer state.deinit(allocator);
        for (query_cases, 0..) |item, index| {
            state.query.clearRetainingCapacity();
            try state.query.appendSlice(allocator, item.query);
            state.filter_state = .{ .mode = if (item.cwd != null) .current_dir else .global, .current_dir = item.cwd };
            var first: [samples]f64 = undefined;
            var deep: [samples]f64 = undefined;
            for (0..samples) |i| {
                var start = std.Io.Timestamp.now(init.io, .awake);
                try state.loadPage(&db, 100, 0, true);
                first[i] = elapsed(init.io, start);
                start = std.Io.Timestamp.now(init.io, .awake);
                try state.loadPage(&db, 100, state.total_count -| 100, false);
                deep[i] = elapsed(init.io, start);
            }
            deep_ids[index] = try copyIds(allocator, state.results);
            try state.loadPage(&db, 100, 0, false);
            first_ids[index] = try copyIds(allocator, state.results);
            results[index] = .{
                .query = item.query,
                .directory_filtered = item.cwd != null,
                .matches = state.total_count,
                .baseline_first_page = summarize(&first),
                .baseline_deep_page = summarize(&deep),
                .prototype_first_page = undefined,
                .prototype_deep_page = undefined,
                .prototype_result_arena_bytes = 0,
            };
        }
    }
    const migration_start = std.Io.Timestamp.now(init.io, .awake);
    try catalog.migratePrototype(&db);
    const migration_ms = elapsed(init.io, migration_start);
    const prototype_bytes = try usedBytes(&db);
    // Explicit compaction is only for this disposable fixture, not migration.
    const vacuum_start = std.Io.Timestamp.now(init.io, .awake);
    try db.exec("VACUUM", .{}, .{});
    const compaction_ms = elapsed(init.io, vacuum_start);
    var page_arena: std.heap.ArenaAllocator = .init(allocator);
    defer page_arena.deinit();
    for (query_cases, 0..) |item, index| {
        var first: [samples]f64 = undefined;
        var deep: [samples]f64 = undefined;
        for (0..samples) |i| {
            _ = page_arena.reset(.retain_capacity);
            var start = std.Io.Timestamp.now(init.io, .awake);
            const count = try catalog.materializeMatches(&db, item.query, item.cwd, allocator);
            const page = try catalog.fetchPage(&db, 0, 100, page_arena.allocator());
            first[i] = elapsed(init.io, start);
            if (count != results[index].matches or !idsEqual(page, first_ids[index])) return error.PrototypeResultMismatch;
            _ = page_arena.reset(.retain_capacity);
            start = std.Io.Timestamp.now(init.io, .awake);
            const last = try catalog.fetchPage(&db, count -| 100, 100, page_arena.allocator());
            deep[i] = elapsed(init.io, start);
            if (!idsEqual(last, deep_ids[index])) return error.PrototypeResultMismatch;
        }
        results[index].prototype_first_page = summarize(&first);
        results[index].prototype_deep_page = summarize(&deep);
        results[index].prototype_result_arena_bytes = page_arena.queryCapacity();
    }
    const summary_query = "SELECT COUNT(*),SUM(frequency),SUM(success_count) FROM commands";
    var summary_times: [samples]f64 = undefined;
    for (0..samples) |i| {
        const start = std.Io.Timestamp.now(init.io, .awake);
        var stmt = try db.prepare(summary_query);
        defer stmt.deinit();
        var rows = try stmt.iterator(struct { commands: i64, events: i64, success: i64 }, .{});
        const row = (try rows.next(.{})).?;
        if (row.commands != unique_count or row.events != 100000) return error.PrototypeSummaryMismatch;
        summary_times[i] = elapsed(init.io, start);
    }
    var record_times: [samples]f64 = undefined;
    for (0..samples) |i| {
        const event_id = try std.fmt.allocPrint(allocator, "prototype-record-{d}", .{i});
        defer allocator.free(event_id);
        const start = std.Io.Timestamp.now(init.io, .awake);
        if (!try catalog.record(&db, .{
            .cmd = "cmd 000001",
            .cwd = local_directory,
            .exit_code = 0,
            .duration_ms = 1,
            .session_id = "benchmark",
            .hostname = "benchmark",
            .timestamp = 70001,
            .event_id = event_id,
        })) return error.PrototypeRecordingMismatch;
        record_times[i] = elapsed(init.io, start);
    }
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .fixture_mode = if (disk_fixture != null) "new temporary file" else "memory",
        .history_events = 100000,
        .distinct_commands = unique_count,
        .long_directories = long_directories,
        .half_life_days = 30,
        .migration_ms = migration_ms,
        .explicit_compaction_ms = compaction_ms,
        .baseline_used_bytes = baseline_bytes,
        .prototype_used_bytes = prototype_bytes,
        .cases = results,
        .catalog_summary = summarize(&summary_times),
        .prototype_record = summarize(&record_times),
        .sqlite_peak_bytes = sqlite.c.sqlite3_memory_highwater(0),
        .note = "Experimental schema 3, disposable synthetic fixture only. Disk mode refuses existing files and deletes its own fixture afterwards. First-page timings include ID materialization and 100 command rows; deep pages are indexed seeks. Production remains schema 2. Used bytes exclude freelist; physical file shrink requires explicit compaction. Recording is in-process SQL only, not shell/process launch latency.",
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
}

fn copyIds(allocator: std.mem.Allocator, entries: anytype) ![]i64 {
    const ids = try allocator.alloc(i64, entries.len);
    for (entries, ids) |entry, *id| id.* = entry.id;
    return ids;
}

fn idsEqual(entries: anytype, ids: []const i64) bool {
    if (entries.len != ids.len) return false;
    for (entries, ids) |entry, id| if (entry.id != id) return false;
    return true;
}

fn usedBytes(db: *sqlite.Db) !i64 {
    var stmt = try db.prepare("SELECT (page_count-freelist_count)*page_size FROM pragma_page_count,pragma_freelist_count,pragma_page_size");
    defer stmt.deinit();
    var rows = try stmt.iterator(i64, .{});
    return (try rows.next(.{})).?;
}

fn summarize(values: *[samples]f64) Timing {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return .{ .median_ms = values[10], .p95_ms = values[19] };
}

fn elapsed(io: std.Io, start: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds())) / 1e6;
}
