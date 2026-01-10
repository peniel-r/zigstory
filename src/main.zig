const std = @import("std");
const zigstory = @import("zigstory");
const sqlite = @import("sqlite");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const action = zigstory.cli.parse(allocator) catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        std.process.exit(1);
    };

    switch (action) {
        .add => |args| {
            std.debug.print("ADD command: cmd='{s}', cwd='{s}', exit={}, duration={}ms\n", .{ args.cmd, args.cwd, args.exit_code, args.duration });
            allocator.free(args.cmd);
            allocator.free(args.cwd);
        },
        .search => {
            std.debug.print("SEARCH command\n", .{});
        },
        .import => {
            std.debug.print("IMPORT command\n", .{});
        },
        .stats => {
            std.debug.print("STATS command\n", .{});
        },
        .help => {
            std.debug.print("Usage: zigstory [add|search|import] [options]\n", .{});
        },
    }
}
