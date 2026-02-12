const std = @import("std");
const sqlite = @import("sqlite");
const zigstory = @import("zigstory");
const ranking = zigstory.ranking;

/// Represents a parsed history entry
const HistoryEntry = struct {
    cmd: []const u8,
    timestamp: i64,
};

/// Gets the PowerShell history file path
fn getHistoryPath(allocator: std.mem.Allocator) ![]const u8 {
    // Try APPDATA path first
    const appdata_result = std.process.getEnvVarOwned(allocator, "APPDATA");
    if (appdata_result) |appdata| {
        defer allocator.free(appdata);
        const path = try std.fs.path.join(allocator, &.{ appdata, "Microsoft", "Windows", "PowerShell", "PSReadline", "ConsoleHost_history.txt" });

        // Check if file exists
        if (std.fs.cwd().openFile(path, .{})) |file| {
            file.close();
            return path;
        } else |_| {
            allocator.free(path);
        }
    } else |_| {}

    // Try USERPROFILE path
    const userprofile_result = std.process.getEnvVarOwned(allocator, "USERPROFILE");
    if (userprofile_result) |userprofile| {
        defer allocator.free(userprofile);
        const path = try std.fs.path.join(allocator, &.{ userprofile, ".local", "share", "powershell", "PSReadline", "ConsoleHost_history.txt" });

        // Check if file exists
        if (std.fs.cwd().openFile(path, .{})) |file| {
            file.close();
            return path;
        } else |_| {
            allocator.free(path);
        }
    } else |_| {}

    return error.HistoryFileNotFound;
}

/// Parse PowerShell history file
/// Returns a slice of HistoryEntry (caller must free each cmd and the slice itself)
pub fn parseHistoryFile(allocator: std.mem.Allocator, file: *std.fs.File) !struct { entries: []HistoryEntry, count: usize } {
    // Read entire file into memory
    const file_size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, file_size);
    errdefer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    if (bytes_read != file_size) {
        return error.ReadError;
    }

    // First pass: count non-empty lines
    var count: usize = 0;
    var start: usize = 0;
    const newline: u8 = '\n';

    for (buffer, 0..) |byte, i| {
        if (byte == newline or i == buffer.len - 1) {
            const end = if (byte == newline) i else i + 1;
            const line = buffer[start..end];

            // Skip empty lines
            if (line.len > 0 and !std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "")) {
                count += 1;
            }
            start = end + 1;
        }
    }

    if (count == 0) {
        allocator.free(buffer);
        return .{ .entries = &.{}, .count = 0 };
    }

    // Allocate array for entries
    const entries = try allocator.alloc(HistoryEntry, count);
    errdefer {
        // Free any allocated commands on error
        for (entries[0..count]) |entry| {
            allocator.free(entry.cmd);
        }
        allocator.free(entries);
    }

    // Second pass: parse entries
    start = 0;
    var index: usize = 0;
    var line_number: u32 = 0;

    // Use a base timestamp (current time minus estimated history age)
    // We'll decrement by 60 seconds for each command to simulate realistic timestamps
    const base_timestamp = std.time.timestamp();

    for (buffer, 0..) |byte, i| {
        if (byte == newline or i == buffer.len - 1) {
            const end = if (byte == newline) i else i + 1;
            const line = buffer[start..end];
            line_number += 1;
            start = end + 1;

            // Skip empty lines
            if (line.len == 0 or std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "")) {
                continue;
            }

            // Trim whitespace
            const trimmed_cmd = try allocator.dupe(u8, std.mem.trim(u8, line, " \t\r"));

            // Calculate timestamp (reverse order - older commands at end of file)
            // PowerShell history appends new commands, so earlier lines are older
            const timestamp = base_timestamp - (@as(i64, @intCast(line_number)) * 60);

            entries[index] = HistoryEntry{
                .cmd = trimmed_cmd,
                .timestamp = timestamp,
            };
            index += 1;
        }
    }

    allocator.free(buffer);

    return .{ .entries = entries, .count = count };
}

/// Check if a duplicate entry exists in the database
pub fn isDuplicate(db: *sqlite.Db, cmd: []const u8, cwd: []const u8, timestamp: i64) !bool {
    const query =
        \\SELECT COUNT(*) FROM history
        \\WHERE cmd = ? AND cwd = ? AND timestamp = ?
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    var iter = try stmt.iterator(i64, .{
        .cmd = cmd,
        .cwd = cwd,
        .timestamp = timestamp,
    });
    const count = (try iter.next(.{})) orelse return false;

    return count > 0;
}

/// JSON entry structure for batch import
const JsonEntry = struct {
    cmd: []const u8,
    cwd: []const u8,
    exit_code: i32,
    duration_ms: i64,
};

/// Import from JSON file (for batch writes from PowerShell)
pub fn importFromFile(
    db: *sqlite.Db,
    file_path: []const u8,
    default_cwd: []const u8,
    allocator: std.mem.Allocator,
) !struct {
    total: usize,
    imported: usize,
} {
    // Read JSON file
    var file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const json_data = try allocator.alloc(u8, file_size);
    defer allocator.free(json_data);

    const bytes_read = try file.readAll(json_data);
    if (bytes_read != file_size) {
        return error.ReadError;
    }

    // Parse JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value != std.json.Value.array) {
        return error.InvalidJsonFormat;
    }

    const array = parsed.value.array;

    // Prepare session ID and hostname for all entries
    const add_mod = @import("add.zig");
    const session_id = try add_mod.generateSessionId(allocator);
    defer allocator.free(session_id);

    const hostname = try add_mod.getHostname(allocator);
    defer allocator.free(hostname);

    // Batch insert
    var imported: usize = 0;

    // Use transaction for better performance
    {
        var begin_stmt = try db.prepare("BEGIN TRANSACTION");
        defer begin_stmt.deinit();
        try begin_stmt.exec(.{}, .{});
    }
    errdefer {
        var rollback_stmt = db.prepare("ROLLBACK") catch unreachable;
        defer rollback_stmt.deinit();
        rollback_stmt.exec(.{}, .{}) catch {};
    }

    const query =
        \\INSERT INTO history (cmd, cwd, exit_code, duration_ms, session_id, hostname, timestamp, cmd_hash)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const timestamp = std.time.timestamp();

    for (array.items) |item| {
        if (item != .object) {
            continue;
        }

        const obj = item.object;

        // Extract fields
        const cmd = obj.get("cmd") orelse continue;
        const cmd_str = if (cmd == .string) cmd.string else continue;

        const cwd_obj = obj.get("cwd");
        const cwd_str = if (cwd_obj) |c| (if (c == .string) c.string else null) else null;
        const cwd_final = if (cwd_str) |s| s else default_cwd;

        const exit_code_obj = obj.get("exit_code");
        const exit_code = if (exit_code_obj) |e| (if (e == .integer) @as(i32, @intCast(e.integer)) else 0) else 0;

        const duration_ms_obj = obj.get("duration_ms");
        const duration_ms = if (duration_ms_obj) |d| (if (d == .integer) @as(i64, @intCast(d.integer)) else 0) else 0;

        // Compute command hash
        const cmd_hash = try ranking.getCommandHash(cmd_str, allocator);
        defer allocator.free(cmd_hash);

        // Insert into database
        try stmt.exec(.{}, .{
            .cmd = cmd_str,
            .cwd = cwd_final,
            .exit_code = exit_code,
            .duration_ms = duration_ms,
            .session_id = session_id,
            .hostname = hostname,
            .timestamp = timestamp,
            .cmd_hash = cmd_hash,
        });
        stmt.reset();
        imported += 1;
    }

    // Commit transaction
    {
        var commit_stmt = try db.prepare("COMMIT");
        defer commit_stmt.deinit();
        try commit_stmt.exec(.{}, .{});
    }

    return .{
        .total = array.items.len,
        .imported = imported,
    };
}

/// Import history entries into the database
/// Returns the number of entries imported
pub fn importHistory(
    db: *sqlite.Db,
    cwd: []const u8,
    allocator: std.mem.Allocator,
) !struct {
    total: usize,
    imported: usize,
    skipped: usize,
} {
    // Get history file path
    const history_path = getHistoryPath(allocator) catch |err| {
        std.debug.print("Error finding PowerShell history file: {}\n", .{err});
        std.debug.print("Looking for history at:\n", .{});
        std.debug.print("  %%APPDATA%%\\Microsoft\\Windows\\PowerShell\\PSReadline\\ConsoleHost_history.txt\n", .{});
        std.debug.print("  %%USERPROFILE%%\\.local\\share\\powershell\\PSReadline\\ConsoleHost_history.txt\n", .{});
        return err;
    };
    defer allocator.free(history_path);

    std.debug.print("Reading history from: {s}\n", .{history_path});

    // Open and parse history file
    var file = try std.fs.cwd().openFile(history_path, .{});
    defer file.close();

    const parsed = try parseHistoryFile(allocator, &file);
    const entries = parsed.entries;
    const count = parsed.count;

    std.debug.print("Found {} commands in history file\n", .{count});

    // Import entries, skipping duplicates
    var imported: usize = 0;
    var skipped: usize = 0;

    // Use batch insertion for better performance
    const query =
        \\INSERT INTO history (cmd, cwd, exit_code, duration_ms, session_id, hostname, timestamp, cmd_hash)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    // Generate a single session ID for all imported commands
    const session_id = "imported-session";

    // Get hostname
    const hostname = std.process.getEnvVarOwned(allocator, "COMPUTERNAME") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
            break :blk try allocator.dupe(u8, "unknown");
        }
        return err;
    };
    defer allocator.free(hostname);

    // Display progress
    const progress_interval = if (count / 20 > 1) count / 20 else 1; // Update progress ~20 times

    for (entries[0..count], 0..) |entry, index| {
        // Check for duplicates
        if (try isDuplicate(db, entry.cmd, cwd, entry.timestamp)) {
            skipped += 1;
        } else {
            // Compute command hash
            const cmd_hash = try ranking.getCommandHash(entry.cmd, allocator);
            defer allocator.free(cmd_hash);

            // Insert entry
            try stmt.exec(.{}, .{
                .cmd = entry.cmd,
                .cwd = cwd,
                .exit_code = 0, // Unknown for imported history
                .duration_ms = 0, // Unknown for imported history
                .session_id = session_id,
                .hostname = hostname,
                .timestamp = entry.timestamp,
                .cmd_hash = cmd_hash,
            });
            stmt.reset(); // Reset statement for next use
            imported += 1;
        }

        // Display progress
        if (index % progress_interval == 0 or index == count - 1) {
            const progress_percent = @as(f64, @floatFromInt(index + 1)) / @as(f64, @floatFromInt(count)) * 100.0;
            std.debug.print("\rProgress: {d:.1}% ({}/{d}) - Imported: {}, Skipped: {}", .{
                progress_percent,
                index + 1,
                count,
                imported,
                skipped,
            });
        }
    }

    std.debug.print("\n", .{}); // New line after progress

    // Free all allocated commands and entries array
    for (entries[0..count]) |entry| {
        allocator.free(entry.cmd);
    }
    allocator.free(entries);

    return .{
        .total = count,
        .imported = imported,
        .skipped = skipped,
    };
}
