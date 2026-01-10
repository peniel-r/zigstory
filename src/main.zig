const std = @import("std");
const zigstory = @import("zigstory");
const sqlite = @import("sqlite");

pub fn main() !void {
    var stdout = std.io.getStdOut().writer();
    try stdout.print("Zigstory CLI - Database Initialized.\n", .{});
}
