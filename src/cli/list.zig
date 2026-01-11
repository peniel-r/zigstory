const std = @import("std");
const sqlite = @import("sqlite");

/// Formats a duration in milliseconds to a human-readable string
fn formatDuration(allocator: std.mem.Allocator, duration_ms: i64) ![]const u8 {
    if (duration_ms < 1000) {
        return try std.fmt.allocPrint(allocator, "{}ms", .{duration_ms});
    } else if (duration_ms < 60000) {
        const seconds = @as(f64, @floatFromInt(duration_ms)) / 1000.0;
        return try std.fmt.allocPrint(allocator, "{d:.1}s", .{seconds});
    } else if (duration_ms < 3600000) {
        const minutes = @as(f64, @floatFromInt(duration_ms)) / 60000.0;
        return try std.fmt.allocPrint(allocator, "{d:.1}m", .{minutes});
    } else {
        const hours = @as(f64, @floatFromInt(duration_ms)) / 3600000.0;
        return try std.fmt.allocPrint(allocator, "{d:.1}h", .{hours});
    }
}

/// Formats a Unix timestamp to a readable date/time string
fn formatTimestamp(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
    // For now, just return the raw timestamp as a string
    // A proper implementation would convert to local time, but this requires
    // more complex time handling or an external library
    return try std.fmt.allocPrint(allocator, "{d}", .{timestamp});
}

/// Truncates a string to fit within a maximum width, adding "..." if truncated
fn truncateString(allocator: std.mem.Allocator, str: []const u8, max_width: usize) ![]const u8 {
    if (str.len <= max_width) {
        return try allocator.dupe(u8, str);
    }

    const truncated = str[0..(max_width - 3)];
    return try std.fmt.allocPrint(allocator, "{s}...", .{truncated});
}

/// Lists the last N entries from command history
pub fn listEntries(db: *sqlite.Db, requested_count: usize, allocator: std.mem.Allocator) !void {
    // Query for total count
    const count_query = "SELECT COUNT(*) as count FROM history";
    var count_stmt = try db.prepare(count_query);
    defer count_stmt.deinit();

    var count_iter = try count_stmt.iterator(struct { count: i64 }, .{});
    const count_row = (try count_iter.next(.{})) orelse {
        std.debug.print("No commands in history\n", .{});
        return;
    };
    const total_count = count_row.count;

    // If no entries, show message and return
    if (total_count == 0) {
        std.debug.print("No commands in history\n", .{});
        return;
    }

    // Determine how many entries to show
    const show_count = @min(requested_count, @as(usize, @intCast(total_count)));

    // Query for last N entries ordered by timestamp
    const query = "SELECT cmd, cwd, exit_code, duration_ms, timestamp FROM history ORDER BY timestamp DESC";

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const QueryRow = struct {
        cmd: []const u8,
        cwd: []const u8,
        exit_code: i32,
        duration_ms: i64,
        timestamp: i64,
    };

    var iter = try stmt.iterator(QueryRow, .{});
    var index: usize = 0;

    // Print header
    std.debug.print("Showing {} of {} entries\n", .{ show_count, total_count });
    std.debug.print("========================\n", .{});

    while (true) {
        // Use arena allocator for each row iteration
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const row = (try iter.nextAlloc(arena.allocator(), .{})) orelse break;
        if (index >= show_count) break;

        const display_index = index + 1;

        // Format duration
        const duration_str = try formatDuration(arena.allocator(), row.duration_ms);

        // Format timestamp
        const timestamp_str = try formatTimestamp(arena.allocator(), row.timestamp);

        // Truncate command if too long (max 60 chars)
        const cmd_display = try truncateString(arena.allocator(), row.cmd, 60);

        // Print entry
        std.debug.print("\n{}. {s}\n", .{ display_index, cmd_display });
        std.debug.print("   Dir: {s}\n", .{row.cwd});
        std.debug.print("   Exit: {} | Duration: {s}\n", .{ row.exit_code, duration_str });
        std.debug.print("   Time: {s}\n", .{timestamp_str});

        index += 1;
    }

    std.debug.print("\n", .{});
}
