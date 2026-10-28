const std = @import("std");

pub const Level = enum(u8) { Error, Warning, Info, Debug, Off };
pub var active: ?*Logger = null;

pub const Logger = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: []const u8,
    level: Level = .Error,
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, env: *std.process.Environ.Map) !Logger {
        const home = env.get("USERPROFILE") orelse env.get("HOME") orelse return error.HomeDirectoryNotFound;
        const directory = if (env.get("ZIGSTORY_LOG_DIR")) |path|
            try allocator.dupe(u8, path)
        else
            try std.fs.path.join(allocator, &.{ home, ".zigstory", "logs" });
        var level: Level = .Error;
        if (env.get("ZIGSTORY_LOG_LEVEL")) |value| {
            level = parseLevel(value) catch {
                std.debug.print("Invalid ZIGSTORY_LOG_LEVEL; using Error.\n", .{});
                return .{ .io = io, .allocator = allocator, .directory = directory };
            };
        }
        return .{ .io = io, .allocator = allocator, .directory = directory, .level = level };
    }

    pub fn deinit(self: *Logger) void {
        self.allocator.free(self.directory);
    }

    pub fn write(self: *Logger, level: Level, event: []const u8, code: ?[]const u8) !void {
        if (@intFromEnum(level) > @intFromEnum(self.level) or self.level == .Off) return;
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const dir = std.Io.Dir.cwd();
        try dir.createDirPath(self.io, self.directory);
        const lock_path = try std.fs.path.join(self.allocator, &.{ self.directory, "cli.lock" });
        defer self.allocator.free(lock_path);
        const lock = try dir.createFile(self.io, lock_path, .{ .truncate = false });
        defer lock.close(self.io);
        var attempts: usize = 0;
        while (!try lock.tryLock(self.io, .exclusive)) {
            attempts += 1;
            if (attempts == 100) return error.LogLockTimeout;
            try std.Io.sleep(self.io, .fromMilliseconds(10), .awake);
        }
        defer lock.unlock(self.io);
        const path = try std.fs.path.join(self.allocator, &.{ self.directory, "cli.log" });
        defer self.allocator.free(path);
        const previous = try std.fmt.allocPrint(self.allocator, "{s}.1", .{path});
        defer self.allocator.free(previous);
        const line = try std.json.Stringify.valueAlloc(self.allocator, .{
            .timestamp = std.Io.Timestamp.now(self.io, .real).toSeconds(),
            .level = @tagName(level),
            .component = "cli",
            .event = event,
            .code = code,
        }, .{});
        defer self.allocator.free(line);
        var file = try dir.createFile(self.io, path, .{ .truncate = false, .read = true });
        var open = true;
        defer if (open) file.close(self.io);
        var length = try file.length(self.io);
        if (length + line.len + 1 > 1024 * 1024) {
            file.close(self.io);
            open = false;
            dir.deleteFile(self.io, previous) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            try dir.rename(path, dir, previous, self.io);
            file = try dir.createFile(self.io, path, .{ .read = true });
            open = true;
            length = 0;
        }
        try file.writePositionalAll(self.io, line, length);
        try file.writePositionalAll(self.io, "\n", length + line.len);
    }
};

pub fn parseLevel(value: []const u8) !Level {
    inline for (std.meta.tags(Level)) |level| {
        if (std.ascii.eqlIgnoreCase(value, @tagName(level))) return level;
    }
    return error.InvalidLogLevel;
}

pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const mapped: Level = switch (level) {
        .err => .Error,
        .warn => .Warning,
        .info => .Info,
        .debug => .Debug,
    };
    const logger = active orelse {
        std.log.defaultLog(level, scope, format, args);
        return;
    };
    const enabled = logger.level != .Off and @intFromEnum(mapped) <= @intFromEnum(logger.level);
    // Disabling file logging must not hide an operation's console diagnostic.
    if (level == .err or level == .warn or enabled) std.log.defaultLog(level, scope, format, args);
    if (!enabled) return;
    // Persist only the static event template and error identifiers, never string arguments.
    var code: ?[]const u8 = null;
    inline for (args) |argument| {
        if (@typeInfo(@TypeOf(argument)) == .error_set) code = @errorName(argument);
    }
    logger.write(mapped, @tagName(scope) ++ ": " ++ format, code) catch |err| {
        std.debug.print("zigstory logging failed: {}\n", .{err});
    };
}
