const std = @import("std");

pub const Action = union(enum) {
    add: AddParams,
    search: void,
    import: ImportParams,
    stats: void,
    list: ListParams,
    help: void,
};

pub const AddParams = struct {
    cmd: []const u8,
    cwd: []const u8,
    exit_code: i32,
    duration: i64,
};

pub const ListParams = struct {
    count: usize = 5,
};

pub const ImportParams = struct {
    file: ?[]const u8 = null,
};

pub fn parse(allocator: std.mem.Allocator) !Action {
    var iter = try std.process.argsWithAllocator(allocator);
    defer iter.deinit();

    _ = iter.skip(); // skip binary name

    const command = iter.next() orelse return .help;

    if (std.mem.eql(u8, command, "add")) {
        return parseAdd(allocator, &iter);
    } else if (std.mem.eql(u8, command, "search")) {
        return .search;
    } else if (std.mem.eql(u8, command, "import")) {
        return parseImport(allocator, &iter);
    } else if (std.mem.eql(u8, command, "stats")) {
        return .stats;
    } else if (std.mem.eql(u8, command, "list")) {
        return parseList(allocator, &iter);
    } else if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        return .help;
    }

    return .help;
}

fn parseAdd(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !Action {
    var cmd: ?[]const u8 = null;
    var cwd: ?[]const u8 = null;
    var exit_code: i32 = 0;
    var duration: i64 = 0;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--cmd") or std.mem.eql(u8, arg, "-c")) {
            cmd = try allocator.dupe(u8, iter.next() orelse return error.MissingArgValue);
        } else if (std.mem.eql(u8, arg, "--cwd") or std.mem.eql(u8, arg, "-w")) {
            cwd = try allocator.dupe(u8, iter.next() orelse return error.MissingArgValue);
        } else if (std.mem.eql(u8, arg, "--exit") or std.mem.eql(u8, arg, "-e")) {
            const val = iter.next() orelse return error.MissingArgValue;
            exit_code = try std.fmt.parseInt(i32, val, 10);
        } else if (std.mem.eql(u8, arg, "--duration") or std.mem.eql(u8, arg, "-d")) {
            const val = iter.next() orelse return error.MissingArgValue;
            duration = try std.fmt.parseInt(i64, val, 10);
        }
    }

    if (cmd == null or cwd == null) {
        return error.MissingRequiredArgs;
    }

    return Action{
        .add = .{
            .cmd = cmd.?,
            .cwd = cwd.?,
            .exit_code = exit_code,
            .duration = duration,
        },
    };
}

fn parseList(_: std.mem.Allocator, iter: *std.process.ArgIterator) !Action {
    // Default count is 5
    var count: usize = 5;

    // Check if count is provided
    const count_arg = iter.next();
    if (count_arg) |arg| {
        count = try std.fmt.parseInt(usize, arg, 10);
    }

    return Action{
        .list = .{
            .count = count,
        },
    };
}

fn parseImport(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !Action {
    var file: ?[]const u8 = null;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            file = try allocator.dupe(u8, iter.next() orelse return error.MissingArgValue);
        }
    }

    return Action{
        .import = .{
            .file = file,
        },
    };
}
