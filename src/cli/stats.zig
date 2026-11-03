const std = @import("std");
const sqlite = @import("sqlite");
const output = @import("output.zig");

/// Buckets history by local hour of day; SQLite's 'localtime' applies the system time zone.
pub const hourly_sql =
    \\SELECT strftime('%H', timestamp, 'unixepoch', 'localtime') as hour, COUNT(*) as count
    \\FROM history
    \\GROUP BY hour
    \\ORDER BY hour
;

pub fn run(db: *sqlite.Db, allocator: std.mem.Allocator, io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var report = output.Report.init(io, &buffer);
    errdefer report.restoreCodePage();
    try write(report.writer(), db, allocator, io);
    try report.finish();
}

fn write(w: *std.Io.Writer, db: *sqlite.Db, allocator: std.mem.Allocator, io: std.Io) !void {
    // 1. Overview
    try w.writeAll("\nOVERVIEW\n");
    try w.writeAll("--------\n");

    const total_count = try getTotalCommands(db);
    try w.print("Total Commands:  {}\n", .{total_count});

    const unique_count = try getUniqueCommands(db);
    try w.print("Unique Commands: {}\n", .{unique_count});

    const session_stats = try getSessionStats(db);
    try w.print("Total Sessions:  {}\n", .{session_stats.count});
    if (session_stats.first_cmd > 0 and session_stats.last_cmd > 0) {
        const span_sec = session_stats.last_cmd - session_stats.first_cmd;
        const days = @divFloor(span_sec, 86400);
        try w.print("History Span:    {} days\n", .{days});
    }

    const success_rate = try getSuccessRate(db);
    try w.print("Success Rate:    {d:.1}%\n", .{success_rate});

    // 2. Most Used Commands
    try w.writeAll("\nTOP COMMANDS\n");
    try w.writeAll("--------------------------------------------------\n");
    try w.print("{s:<4} {s:<45} {s:<8} {s:<15}\n", .{ "#", "Command", "Count", "Last Used" });

    try printTopCommands(w, db, allocator, io);

    // 3. Execution Distribution (Hourly)
    try w.writeAll("\nACTIVITY BY HOUR\n");
    try w.writeAll("----------------\n");

    try printHourlyDistribution(w, db, allocator);

    // 4. Directory Breakdown
    try w.writeAll("\nTOP DIRECTORIES\n");
    try w.writeAll("---------------\n");

    try printTopDirectories(w, db, allocator);

    try w.writeAll("\n");
}

fn getTotalCommands(db: *sqlite.Db) !i64 {
    var stmt = try db.prepare("SELECT COUNT(*) as count FROM history");
    defer stmt.deinit();

    var iter = try stmt.iterator(struct { count: i64 }, .{});
    if (try iter.next(.{})) |row| {
        return row.count;
    }
    return 0;
}

fn getUniqueCommands(db: *sqlite.Db) !i64 {
    var stmt = try db.prepare("SELECT COUNT(DISTINCT cmd) as count FROM history");
    defer stmt.deinit();

    var iter = try stmt.iterator(struct { count: i64 }, .{});
    if (try iter.next(.{})) |row| {
        return row.count;
    }
    return 0;
}

const SessionStats = struct {
    count: i64,
    first_cmd: i64,
    last_cmd: i64,
};

fn getSessionStats(db: *sqlite.Db) !SessionStats {
    // Count sessions
    var count: i64 = 0;
    {
        var stmt = try db.prepare("SELECT COUNT(DISTINCT session_id) as count FROM history");
        defer stmt.deinit();
        var iter = try stmt.iterator(struct { count: i64 }, .{});
        if (try iter.next(.{})) |row| {
            count = row.count;
        }
    }

    // Get time range
    var first: i64 = 0;
    var last: i64 = 0;
    {
        var stmt = try db.prepare("SELECT MIN(timestamp) as min, MAX(timestamp) as max FROM history");
        defer stmt.deinit();
        // Use optional i64 for nullable columns
        const Row = struct { min: ?i64, max: ?i64 };
        var iter = try stmt.iterator(Row, .{});
        if (try iter.next(.{})) |row| {
            if (row.min) |m| first = m;
            if (row.max) |m| last = m;
        }
    }

    return SessionStats{ .count = count, .first_cmd = first, .last_cmd = last };
}

fn getSuccessRate(db: *sqlite.Db) !f64 {
    var stmt = try db.prepare("SELECT COUNT(*) as total, SUM(CASE WHEN exit_code = 0 THEN 1 ELSE 0 END) as success FROM history");
    defer stmt.deinit();

    const Row = struct { total: i64, success: ?i64 };
    var iter = try stmt.iterator(Row, .{});

    if (try iter.next(.{})) |row| {
        if (row.total == 0) return 100.0;
        const success = row.success orelse 0;
        return @as(f64, @floatFromInt(success)) / @as(f64, @floatFromInt(row.total)) * 100.0;
    }
    return 0.0;
}

fn printTopCommands(w: *std.Io.Writer, db: *sqlite.Db, allocator: std.mem.Allocator, io: std.Io) !void {
    const query =
        \\SELECT cmd, COUNT(*) as count, MAX(timestamp) as last_used
        \\FROM history
        \\GROUP BY cmd
        \\ORDER BY count DESC
        \\LIMIT 10
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const Row = struct {
        cmd: []const u8,
        count: i64,
        last_used: i64,
    };

    var iter = try stmt.iterator(Row, .{});
    var index: usize = 1;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const row = (try iter.nextAlloc(arena.allocator(), .{})) orelse break;

        const time_str = try formatRelativeTime(row.last_used, arena.allocator(), io);

        // Show the first line, truncated without splitting UTF-8 sequences.
        var cmd_buf: [45]u8 = undefined;
        const display_cmd = output.ellipsize(&cmd_buf, row.cmd, cmd_buf.len);

        try w.print("{d:<2}   {s:<45} {d:<8} {s:<15}\n", .{ index, display_cmd, row.count, time_str });
        index += 1;
    }
}

fn printHourlyDistribution(w: *std.Io.Writer, db: *sqlite.Db, allocator: std.mem.Allocator) !void {
    // Initialize array for 24 hours
    var hours = [_]i64{0} ** 24;
    var max_count: i64 = 0;

    var stmt = try db.prepare(hourly_sql);
    defer stmt.deinit();

    const Row = struct {
        hour: []const u8,
        count: i64,
    };

    var iter = try stmt.iterator(Row, .{});

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const row = (try iter.nextAlloc(arena.allocator(), .{})) orelse break;

        // hour is returned as string "00", "01" etc.
        const hour = try std.fmt.parseInt(usize, row.hour, 10);
        if (hour < 24) {
            hours[hour] = row.count;
            if (row.count > max_count) max_count = row.count;
        }
    }

    if (max_count == 0) {
        try w.writeAll("No data available.\n");
        return;
    }

    // Print chart
    for (hours, 0..) |count, hour| {
        // Calculate bar length (max 40 chars)
        const bar_len: usize = @intCast(@divFloor(count * 40, max_count));

        try w.print("{d:0>2} | ", .{hour});
        try w.splatBytesAll("█", bar_len);

        if (count > 0) {
            try w.print(" {}\n", .{count});
        } else {
            try w.writeAll("\n");
        }
    }
}

fn printTopDirectories(w: *std.Io.Writer, db: *sqlite.Db, allocator: std.mem.Allocator) !void {
    const query =
        \\SELECT cwd, COUNT(*) as count
        \\FROM history
        \\GROUP BY cwd
        \\ORDER BY count DESC
        \\LIMIT 5
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const Row = struct {
        cwd: []const u8,
        count: i64,
    };

    var iter = try stmt.iterator(Row, .{});

    try w.print("{s:<8} {s}\n", .{ "Count", "Directory" });

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const row = (try iter.nextAlloc(arena.allocator(), .{})) orelse break;

        try w.print("{d:<8} {s}\n", .{ row.count, row.cwd });
    }
}

fn formatRelativeTime(timestamp: i64, allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const diff = now - timestamp;

    if (diff < 60) {
        return std.fmt.allocPrint(allocator, "{d}s ago", .{diff});
    } else if (diff < 3600) {
        return std.fmt.allocPrint(allocator, "{d}m ago", .{@divFloor(diff, 60)});
    } else if (diff < 86400) {
        return std.fmt.allocPrint(allocator, "{d}h ago", .{@divFloor(diff, 3600)});
    } else if (diff < 604800) {
        return std.fmt.allocPrint(allocator, "{d}d ago", .{@divFloor(diff, 86400)});
    } else {
        return std.fmt.allocPrint(allocator, "{d}w ago", .{@divFloor(diff, 604800)});
    }
}
