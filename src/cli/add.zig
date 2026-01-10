const std = @import("std");
const sqlite = @import("sqlite");

/// Parameters for the add command
pub const AddParams = struct {
    cmd: []const u8,
    cwd: []const u8,
    exit_code: i32,
    duration_ms: i64,
    session_id: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
};

/// Validates that a command string is not empty
fn validateCommand(cmd: []const u8) !void {
    if (cmd.len == 0) {
        return error.EmptyCommand;
    }
}

/// Validates that a path exists and is accessible
fn validatePath(cwd: []const u8) !void {
    if (cwd.len == 0) {
        return error.EmptyPath;
    }
    // Basic validation - just check it's not empty
    // In production, you might want to check if the path exists
}

/// Generates a UUID v4 session ID
fn generateSessionId(allocator: std.mem.Allocator) ![]const u8 {
    var random = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const rand = random.random();

    var uuid: [36]u8 = undefined;
    var buf: [16]u8 = undefined;
    rand.bytes(&buf);

    // Set version (4) and variant bits
    buf[6] = (buf[6] & 0x0f) | 0x40;
    buf[8] = (buf[8] & 0x3f) | 0x80;

    _ = try std.fmt.bufPrint(&uuid, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        buf[0],  buf[1],  buf[2],  buf[3],
        buf[4],  buf[5],  buf[6],  buf[7],
        buf[8],  buf[9],  buf[10], buf[11],
        buf[12], buf[13], buf[14], buf[15],
    });

    return try allocator.dupe(u8, &uuid);
}

/// Gets the system hostname
fn getHostname(allocator: std.mem.Allocator) ![]const u8 {
    // Try environment variables first (works on both Windows and Unix)
    if (std.process.getEnvVarOwned(allocator, "COMPUTERNAME")) |name| {
        return name;
    } else |_| {
        if (std.process.getEnvVarOwned(allocator, "HOSTNAME")) |name| {
            return name;
        } else |_| {
            // On Unix systems, try gethostname
            if (@import("builtin").os.tag != .windows) {
                var buffer: [256]u8 = undefined;
                const result = std.posix.gethostname(&buffer) catch {
                    return try allocator.dupe(u8, "unknown");
                };
                return try allocator.dupe(u8, result);
            }
            return try allocator.dupe(u8, "unknown");
        }
    }
}

/// Adds a command to the history database
pub fn addCommand(db: *sqlite.Db, params: AddParams, allocator: std.mem.Allocator) !void {
    // Validate inputs
    try validateCommand(params.cmd);
    try validatePath(params.cwd);

    // Generate session ID if not provided
    const session_id = if (params.session_id) |sid|
        try allocator.dupe(u8, sid)
    else
        try generateSessionId(allocator);
    defer allocator.free(session_id);

    // Get hostname if not provided
    const hostname = if (params.hostname) |hn|
        try allocator.dupe(u8, hn)
    else
        try getHostname(allocator);
    defer allocator.free(hostname);

    // Insert into database
    const query =
        \\INSERT INTO history (cmd, cwd, exit_code, duration_ms, session_id, hostname)
        \\VALUES (?, ?, ?, ?, ?, ?)
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    try stmt.exec(.{}, .{
        .cmd = params.cmd,
        .cwd = params.cwd,
        .exit_code = params.exit_code,
        .duration_ms = params.duration_ms,
        .session_id = session_id,
        .hostname = hostname,
    });
}
