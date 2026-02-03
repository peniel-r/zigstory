const std = @import("std");
const sqlite = @import("sqlite");

// Note: PerfParams is defined in args.zig (CLI parsing)
// We use individual parameters here to avoid circular imports

pub const PerfMetrics = struct {
    avg_duration_ms: f64,
    last_duration_ms: i64,
    last_cmd: []const u8,
    success_rate: f64,
    total_commands: i64,
    last_exit_code: i32,
};

pub const PerfMetricsJson = struct {
    avg_duration_ms: f64,
    last_duration_ms: i64,
    last_cmd: []const u8,
    success_rate: f64,
    total_commands: i64,
    last_exit_code: i32,
};

/// Run performance metrics command
pub fn run(db: *sqlite.Db, cwd_param: ?[]const u8, format_param: []const u8, threshold_param: i64, allocator: std.mem.Allocator) !void {
    const cwd = if (cwd_param) |c| c else try std.process.getCwdAlloc(allocator);
    defer if (cwd_param == null) allocator.free(cwd);

    const metrics = try getPerfMetrics(db, cwd, allocator);

    // Print metrics before freeing to use the data
    if (std.mem.eql(u8, format_param, "json")) {
        try printJson(metrics, allocator);
    } else {
        try printText(metrics, threshold_param, allocator);
    }

    // Free the duplicated command string after using metrics
    allocator.free(metrics.last_cmd);
}

/// Get performance metrics for a directory
fn getPerfMetrics(db: *sqlite.Db, cwd: []const u8, allocator: std.mem.Allocator) !PerfMetrics {
    const query =
        \\SELECT
        \\  AVG(duration_ms) as avg_duration,
        \\  SUM(CASE WHEN exit_code = 0 THEN 1 ELSE 0 END) as success,
        \\  COUNT(*) as total,
        \\  (SELECT duration_ms FROM history WHERE cwd = ? ORDER BY timestamp DESC LIMIT 1) as last_duration,
        \\  (SELECT exit_code FROM history WHERE cwd = ? ORDER BY timestamp DESC LIMIT 1) as last_exit_code,
        \\  (SELECT cmd FROM history WHERE cwd = ? ORDER BY timestamp DESC LIMIT 1) as last_cmd
        \\FROM history
        \\WHERE cwd = ?
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const Row = struct {
        avg_duration: ?f64,
        success: i64,
        total: i64,
        last_duration: ?i64,
        last_exit_code: ?i32,
        last_cmd: ?[]const u8,
    };

    // Use arena allocator for row data
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var iter = try stmt.iterator(Row, .{ cwd, cwd, cwd, cwd });
    const row = (try iter.nextAlloc(arena_alloc, .{})) orelse {
        return PerfMetrics{
            .avg_duration_ms = 0.0,
            .last_duration_ms = 0,
            .last_cmd = try allocator.dupe(u8, ""),
            .success_rate = 100.0,
            .total_commands = 0,
            .last_exit_code = 0,
        };
    };

    const avg_duration = row.avg_duration orelse 0.0;
    const success_rate = if (row.total > 0)
        @as(f64, @floatFromInt(row.success)) / @as(f64, @floatFromInt(row.total)) * 100.0
    else
        100.0;
    const last_duration = row.last_duration orelse 0;
    const last_exit_code = row.last_exit_code orelse 0;
    const last_cmd = if (row.last_cmd) |c| try allocator.dupe(u8, c) else try allocator.dupe(u8, "");

    return PerfMetrics{
        .avg_duration_ms = avg_duration,
        .last_duration_ms = last_duration,
        .last_cmd = last_cmd,
        .success_rate = success_rate,
        .total_commands = row.total,
        .last_exit_code = last_exit_code,
    };
}

/// Print metrics in text format
fn printText(metrics: PerfMetrics, threshold: i64, allocator: std.mem.Allocator) !void {
    const avg_str = try formatDuration(metrics.avg_duration_ms, allocator);
    defer allocator.free(avg_str);

    // Truncate command if too long
    var display_cmd = metrics.last_cmd;
    if (display_cmd.len > 30) {
        const truncated = try allocator.dupe(u8, metrics.last_cmd[0..30]);
        defer allocator.free(truncated);
        display_cmd = try std.fmt.allocPrint(allocator, "{s}...", .{truncated});
        defer allocator.free(display_cmd);
    }

    std.debug.print("{s} avg", .{avg_str});

    // Show warning if last command was slow
    if (metrics.last_duration_ms > threshold and metrics.last_duration_ms > 0) {
        std.debug.print(" [⚠️ last: {d}ms]", .{metrics.last_duration_ms});
    }

    // Show success rate if not 100%
    if (metrics.success_rate < 100.0 and metrics.total_commands > 0) {
        std.debug.print(" [✅ {d:.1}%]", .{metrics.success_rate});
    }

    std.debug.print("\n", .{});
}

/// Print metrics in JSON format
fn printJson(metrics: PerfMetrics, _: std.mem.Allocator) !void {
    var buffer: [512]u8 = undefined;
    const json = std.fmt.bufPrintZ(&buffer,
        \\{{"avg_duration_ms":{d:.1},"last_duration_ms":{d},"last_cmd":"{s}","success_rate":{d:.1},"total_commands":{d},"last_exit_code":{d}}}
    , .{
        metrics.avg_duration_ms,
        metrics.last_duration_ms,
        metrics.last_cmd,
        metrics.success_rate,
        metrics.total_commands,
        metrics.last_exit_code,
    }) catch return error.BufferTooSmall;
    std.debug.print("{s}\n", .{json});
}

/// Format duration in human-readable format
fn formatDuration(duration_ms: f64, allocator: std.mem.Allocator) ![]u8 {
    if (duration_ms < 1000) {
        return std.fmt.allocPrint(allocator, "{d:.0}ms", .{duration_ms});
    } else if (duration_ms < 60000) {
        return std.fmt.allocPrint(allocator, "{d:.1}s", .{duration_ms / 1000});
    } else {
        return std.fmt.allocPrint(allocator, "{d:.1}m", .{duration_ms / 60000});
    }
}
