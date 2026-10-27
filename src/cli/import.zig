const std = @import("std");
const sqlite = @import("sqlite");
const zigstory = @import("zigstory");
const record = zigstory.record;

/// Represents a parsed history entry
const HistoryEntry = struct {
    cmd: []const u8,
    timestamp: i64,
};

/// Gets the PowerShell history file path
fn getHistoryPath(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    // Use std.c.getenv – std.process.getEnvVarOwned was removed in Zig 0.16.
    // Try APPDATA path first
    if (std.c.getenv("APPDATA")) |appdata_c| {
        const appdata = std.mem.sliceTo(appdata_c, 0);
        const path = try std.fs.path.join(allocator, &.{ appdata, "Microsoft", "Windows", "PowerShell", "PSReadline", "ConsoleHost_history.txt" });

        // Check if file exists
        if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
            file.close(io);
            return path;
        } else |_| {
            allocator.free(path);
        }
    }

    // Try USERPROFILE path
    if (std.c.getenv("USERPROFILE")) |userprofile_c| {
        const userprofile = std.mem.sliceTo(userprofile_c, 0);
        const path = try std.fs.path.join(allocator, &.{ userprofile, ".local", "share", "powershell", "PSReadline", "ConsoleHost_history.txt" });

        // Check if file exists
        if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
            file.close(io);
            return path;
        } else |_| {
            allocator.free(path);
        }
    }

    return error.HistoryFileNotFound;
}

/// Parse PowerShell history file
/// Returns a slice of HistoryEntry (caller must free each cmd and the slice itself)
pub fn parseHistoryFile(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !struct { entries: []HistoryEntry, count: usize } {
    // Read entire file into memory.
    // std.fs.File was removed in Zig 0.16; use std.Io.File.
    const file_size = try file.length(io);
    const buffer = try allocator.alloc(u8, file_size);
    errdefer allocator.free(buffer);

    const bytes_read = try file.readPositionalAll(io, buffer, 0);
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
    const base_timestamp = std.Io.Timestamp.now(io, .real).toSeconds();

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
    cwd: ?[]const u8 = null,
    exit_code: i32 = 0,
    duration_ms: i64 = 0,
};

/// Import from JSON file (for batch writes from PowerShell)
pub fn importFromFile(
    db: *sqlite.Db,
    file_path: []const u8,
    default_cwd: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
) !struct {
    total: usize,
    imported: usize,
} {
    // Read JSON file – std.fs.cwd() removed in Zig 0.16; use std.Io.Dir.cwd().
    var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    const file_size = try file.length(io);
    const json_data = try allocator.alloc(u8, file_size);
    defer allocator.free(json_data);

    const bytes_read = try file.readPositionalAll(io, json_data, 0);
    if (bytes_read != file_size) {
        return error.ReadError;
    }

    // Parse JSON
    const parsed = try std.json.parseFromSlice([]JsonEntry, allocator, json_data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const entries = parsed.value;

    // Prepare session ID and hostname for all entries
    const add_mod = @import("add.zig");
    const session_id = try add_mod.generateSessionId(allocator, io);
    defer allocator.free(session_id);

    const hostname = try add_mod.getHostname(allocator);
    defer allocator.free(hostname);

    // Batch insert
    var imported: usize = 0;

    var writer = try record.Writer.init(db);
    defer writer.deinit();
    try db.exec("BEGIN IMMEDIATE", .{}, .{});
    errdefer record.rollback(db);

    const timestamp = std.Io.Timestamp.now(io, .real).toSeconds();

    for (entries) |entry| {
        try writer.record(.{
            .cmd = entry.cmd,
            .cwd = entry.cwd orelse default_cwd,
            .exit_code = entry.exit_code,
            .duration_ms = entry.duration_ms,
            .session_id = session_id,
            .hostname = hostname,
            .timestamp = timestamp,
        }, allocator, timestamp);
        imported += 1;
    }

    // Commit transaction
    try db.exec("COMMIT", .{}, .{});

    return .{
        .total = entries.len,
        .imported = imported,
    };
}

/// Import history entries into the database
/// Returns the number of entries imported
pub fn importHistory(
    db: *sqlite.Db,
    cwd: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
) !struct {
    total: usize,
    imported: usize,
    skipped: usize,
} {
    // Get history file path
    const history_path = getHistoryPath(allocator, io) catch |err| {
        std.debug.print("Error finding PowerShell history file: {}\n", .{err});
        std.debug.print("Looking for history at:\n", .{});
        std.debug.print("  %%APPDATA%%\\Microsoft\\Windows\\PowerShell\\PSReadline\\ConsoleHost_history.txt\n", .{});
        std.debug.print("  %%USERPROFILE%%\\.local\\share\\powershell\\PSReadline\\ConsoleHost_history.txt\n", .{});
        return err;
    };
    defer allocator.free(history_path);

    std.debug.print("Reading history from: {s}\n", .{history_path});

    // Open and parse history file – std.fs.cwd() removed in Zig 0.16.
    const file = try std.Io.Dir.cwd().openFile(io, history_path, .{});
    defer file.close(io);

    const parsed = try parseHistoryFile(allocator, io, file);
    const entries = parsed.entries;
    const count = parsed.count;
    defer {
        for (entries) |entry| allocator.free(entry.cmd);
        allocator.free(entries);
    }

    std.debug.print("Found {} commands in history file\n", .{count});

    // Import entries, skipping duplicates
    var imported: usize = 0;
    var skipped: usize = 0;

    // Use batch insertion for better performance
    var writer = try record.Writer.init(db);
    defer writer.deinit();

    // Generate a single session ID for all imported commands
    const session_id = "imported-session";

    // Get hostname – std.process.getEnvVarOwned removed in Zig 0.16, use std.c.getenv.
    const hostname = if (std.c.getenv("COMPUTERNAME")) |name|
        try allocator.dupe(u8, std.mem.sliceTo(name, 0))
    else
        try allocator.dupe(u8, "unknown");
    defer allocator.free(hostname);

    // Display progress
    const progress_interval = if (count / 20 > 1) count / 20 else 1; // Update progress ~20 times
    try db.exec("BEGIN IMMEDIATE", .{}, .{});
    errdefer record.rollback(db);
    const now = std.Io.Timestamp.now(io, .real).toSeconds();

    for (entries[0..count], 0..) |entry, index| {
        // Check for duplicates
        if (try isDuplicate(db, entry.cmd, cwd, entry.timestamp)) {
            skipped += 1;
        } else {
            // Insert entry
            try writer.record(.{
                .cmd = entry.cmd,
                .cwd = cwd,
                .exit_code = 0, // Unknown for imported history
                .duration_ms = 0, // Unknown for imported history
                .session_id = session_id,
                .hostname = hostname,
                .timestamp = entry.timestamp,
            }, allocator, now);
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

    try db.exec("COMMIT", .{}, .{});

    return .{
        .total = count,
        .imported = imported,
        .skipped = skipped,
    };
}
