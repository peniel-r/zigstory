const std = @import("std");
const sqlite = @import("sqlite");

pub fn run(db: *sqlite.Db, allocator: std.mem.Allocator) !void {
    // 1. Overview
    std.debug.print("\nOVERVIEW\n", .{});
    std.debug.print("--------\n", .{});

    const total_count = try getTotalCommands(db);
    std.debug.print("Total Commands:  {}\n", .{total_count});

    const unique_count = try getUniqueCommands(db);
    std.debug.print("Unique Commands: {}\n", .{unique_count});

    const session_stats = try getSessionStats(db);
    std.debug.print("Total Sessions:  {}\n", .{session_stats.count});
    if (session_stats.first_cmd > 0 and session_stats.last_cmd > 0) {
        const span_sec = session_stats.last_cmd - session_stats.first_cmd;
        const days = @divFloor(span_sec, 86400);
        std.debug.print("History Span:    {} days\n", .{days});
    }

    const success_rate = try getSuccessRate(db);
    std.debug.print("Success Rate:    {d:.1}%\n", .{success_rate});

    // 2. Most Used Commands
    std.debug.print("\nTOP COMMANDS\n", .{});
    std.debug.print("--------------------------------------------------\n", .{});
    std.debug.print("{s:<4} {s:<45} {s:<8} {s:<15}\n", .{ "#", "Command", "Count", "Last Used" });

    try printTopCommands(db, allocator);

    // 3. Execution Distribution (Hourly)
    std.debug.print("\nACTIVITY BY HOUR\n", .{});
    std.debug.print("----------------\n", .{});

    try printHourlyDistribution(db, allocator);

    // 4. Directory Breakdown
    std.debug.print("\nTOP DIRECTORIES\n", .{});
    std.debug.print("---------------\n", .{});

    try printTopDirectories(db, allocator);

    std.debug.print("\n", .{});
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

fn printTopCommands(db: *sqlite.Db, allocator: std.mem.Allocator) !void {
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

        const time_str = try formatRelativeTime(row.last_used, arena.allocator());

        // Truncate command if too long
        var display_cmd = try arena.allocator().dupe(u8, row.cmd);
        if (display_cmd.len > 45) {
            display_cmd[42] = '.';
            display_cmd[43] = '.';
            display_cmd[44] = '.';
            display_cmd = display_cmd[0..45];
        }

        std.debug.print("{d:<2}   {s:<45} {d:<8} {s:<15}\n", .{ index, display_cmd, row.count, time_str });
        index += 1;
    }
}

fn printHourlyDistribution(db: *sqlite.Db, allocator: std.mem.Allocator) !void {
    // Initialize array for 24 hours
    var hours = [_]i64{0} ** 24;
    var max_count: i64 = 0;

    const query =
        \\SELECT strftime('%H', datetime(timestamp, 'unixepoch')) as hour, COUNT(*) as count
        \\FROM history
        \\GROUP BY hour
        \\ORDER BY hour
    ;

    var stmt = try db.prepare(query);
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
        std.debug.print("No data available.\n", .{});
        return;
    }

    // Print chart
    const time_labels = [_][]const u8{ "00", "01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23" };

    for (0..24) |i| {
        const count = hours[i];

        // Calculate bar length (max 40 chars)
        const bar_len = if (max_count > 0) @divFloor(count * 40, max_count) else 0;

        std.debug.print("{s} | ", .{time_labels[i]});

        var j: i64 = 0;
        while (j < bar_len) : (j += 1) {
            // Use Extended ASCII Full Block (0xDB)
            std.debug.print("\xDB", .{});
        }

        if (count > 0) {
            std.debug.print(" {}\n", .{count});
        } else {
            std.debug.print("\n", .{});
        }
    }
}

fn printTopDirectories(db: *sqlite.Db, allocator: std.mem.Allocator) !void {
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

    std.debug.print("{s:<8} {s}\n", .{ "Count", "Directory" });

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const row = (try iter.nextAlloc(arena.allocator(), .{})) orelse break;

        std.debug.print("{d:<8} {s}\n", .{ row.count, row.cwd });
    }
}

fn formatRelativeTime(timestamp: i64, allocator: std.mem.Allocator) ![]u8 {
    const now = std.time.timestamp();
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
