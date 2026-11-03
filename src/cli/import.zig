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

/// Parse a PowerShell history file in file order (oldest first).
/// PSReadLine stores each newline inside a command as a backtick followed by a
/// line break, so continued lines are rejoined the same way PSReadLine reads them.
/// Returns a slice of HistoryEntry (caller must free each cmd and the slice itself)
pub fn parseHistoryFile(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !struct { entries: []HistoryEntry, count: usize } {
    // Read entire file into memory.
    // std.fs.File was removed in Zig 0.16; use std.Io.File.
    const file_size = try file.length(io);
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    const bytes_read = try file.readPositionalAll(io, buffer, 0);
    if (bytes_read != file_size) {
        return error.ReadError;
    }

    var commands: std.ArrayListUnmanaged([]u8) = .empty;
    defer commands.deinit(allocator);
    errdefer for (commands.items) |cmd| allocator.free(cmd);
    var continued: std.ArrayListUnmanaged(u8) = .empty;
    defer continued.deinit(allocator);

    var content: []const u8 = buffer;
    if (std.mem.startsWith(u8, content, "\xEF\xBB\xBF")) content = content[3..];
    // A final line break does not start another (empty) line.
    if (std.mem.endsWith(u8, content, "\n")) content = content[0 .. content.len - 1];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.endsWith(u8, line, "`")) {
            try continued.appendSlice(allocator, line[0 .. line.len - 1]);
            try continued.append(allocator, '\n');
            continue;
        }
        var text = line;
        if (continued.items.len > 0) {
            try continued.appendSlice(allocator, line);
            text = continued.items;
        }
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) {
            try commands.ensureUnusedCapacity(allocator, 1);
            commands.appendAssumeCapacity(try allocator.dupe(u8, trimmed));
        }
        continued.clearRetainingCapacity();
    }
    // An unterminated continuation is incomplete; PSReadLine drops it as well.

    const count = commands.items.len;
    if (count == 0) {
        return .{ .entries = &.{}, .count = 0 };
    }

    const entries = try allocator.alloc(HistoryEntry, count);
    errdefer allocator.free(entries);

    // PSReadLine appends new commands. Preserve file order; actual times are unknown.
    const base_timestamp = std.Io.Timestamp.now(io, .real).toSeconds();
    for (commands.items, entries, 0..) |cmd, *entry, index| {
        const age = std.math.mul(i64, @intCast(count - index - 1), 60) catch return error.HistoryTooLarge;
        entry.* = .{ .cmd = cmd, .timestamp = base_timestamp -| age };
    }
    // Every command is now owned by entries.
    commands.clearRetainingCapacity();

    return .{ .entries = entries, .count = count };
}

/// JSON entry structure for batch import
const JsonEntry = struct {
    cmd: []const u8,
    cwd: ?[]const u8 = null,
    exit_code: i32 = 0,
    duration_ms: i64 = 0,
    timestamp: ?i64 = null,
    session_id: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    event_id: ?[]const u8 = null,
};

pub const ImportResult = struct { total: usize, imported: usize };

/// Import from JSON file (for batch writes from PowerShell)
pub fn importFromFile(
    db: *sqlite.Db,
    file_path: []const u8,
    default_cwd: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
) !ImportResult {
    return importFile(db, file_path, default_cwd, allocator, io, false);
}

pub fn importRecordingFile(
    db: *sqlite.Db,
    file_path: []const u8,
    default_cwd: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
) !ImportResult {
    return importFile(db, file_path, default_cwd, allocator, io, true);
}

fn importFile(
    db: *sqlite.Db,
    file_path: []const u8,
    default_cwd: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    require_event_id: bool,
) !ImportResult {
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
        if (require_event_id and entry.event_id == null) return error.MissingEventId;
        const inserted = try writer.record(.{
            .cmd = entry.cmd,
            .cwd = entry.cwd orelse default_cwd,
            .exit_code = entry.exit_code,
            .duration_ms = entry.duration_ms,
            .session_id = entry.session_id orelse session_id,
            .hostname = entry.hostname orelse hostname,
            .timestamp = entry.timestamp orelse timestamp,
            .event_id = entry.event_id,
        }, allocator, timestamp);
        imported += @intFromBool(inserted);
    }

    // Commit transaction
    try db.exec("COMMIT", .{}, .{});

    return .{
        .total = entries.len,
        .imported = imported,
    };
}

pub const PSReadLineImportResult = struct {
    total: usize,
    imported: usize,
    skipped: usize,
};

/// Import the default PowerShell history file into the database.
pub fn importHistory(
    db: *sqlite.Db,
    cwd: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
) !PSReadLineImportResult {
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
    return importHistoryFile(db, history_path, cwd, allocator, io, true);
}

/// Counts stored rows for an exact command. The NOCASE comparison lets SQLite
/// narrow the search with idx_cmd_prefix before the exact (binary) comparison.
pub const existing_count_sql = "SELECT COUNT(*) FROM history WHERE cmd = ? COLLATE NOCASE AND cmd = ?";

/// Import a PSReadLine history file. The file has no timestamps, so occurrences
/// are reconciled per command: when history already holds N rows for a command,
/// whether from an earlier import or from live recording, the first N occurrences
/// in the file are treated as present. Re-importing is therefore idempotent.
pub fn importHistoryFile(
    db: *sqlite.Db,
    path: []const u8,
    cwd: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    report_progress: bool,
) !PSReadLineImportResult {
    // Open and parse history file – std.fs.cwd() removed in Zig 0.16.
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const parsed = try parseHistoryFile(allocator, io, file);
    const entries = parsed.entries;
    const count = parsed.count;
    defer {
        for (entries) |entry| allocator.free(entry.cmd);
        allocator.free(entries);
    }

    if (report_progress) std.debug.print("Found {} commands in history file\n", .{count});

    var imported: usize = 0;
    var skipped: usize = 0;

    var writer = try record.Writer.init(db);
    defer writer.deinit();
    var existing_stmt = try db.prepare(existing_count_sql);
    defer existing_stmt.deinit();
    // Remaining stored rows for each command that file occurrences still match.
    var already_stored: std.StringHashMapUnmanaged(usize) = .empty;
    defer already_stored.deinit(allocator);

    // Generate a single session ID for all imported commands
    const session_id = "imported-session";

    // Get hostname – std.process.getEnvVarOwned removed in Zig 0.16, use std.c.getenv.
    const hostname = if (std.c.getenv("COMPUTERNAME")) |name|
        try allocator.dupe(u8, std.mem.sliceTo(name, 0))
    else
        try allocator.dupe(u8, "unknown");
    defer allocator.free(hostname);

    // Display progress
    const progress_interval = @max(count / 20, 1); // Update progress ~20 times
    // Counts are read inside the write transaction, so concurrent recordings cannot race.
    try db.exec("BEGIN IMMEDIATE", .{}, .{});
    errdefer record.rollback(db);
    const now = std.Io.Timestamp.now(io, .real).toSeconds();

    for (entries, 0..) |entry, index| {
        const stored = try already_stored.getOrPut(allocator, entry.cmd);
        if (!stored.found_existing) stored.value_ptr.* = try countStored(&existing_stmt, entry.cmd);
        if (stored.value_ptr.* > 0) {
            stored.value_ptr.* -= 1;
            skipped += 1;
        } else {
            _ = try writer.record(.{
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
        if (report_progress and (index % progress_interval == 0 or index == count - 1)) {
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

    if (report_progress) std.debug.print("\n", .{}); // New line after progress

    try db.exec("COMMIT", .{}, .{});

    return .{
        .total = count,
        .imported = imported,
        .skipped = skipped,
    };
}

fn countStored(stmt: anytype, cmd: []const u8) !usize {
    defer stmt.reset();
    var rows = try stmt.iterator(i64, .{ cmd, cmd });
    return @intCast((try rows.next(.{})) orelse 0);
}
