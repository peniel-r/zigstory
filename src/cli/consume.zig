const std = @import("std");
const zigstory = @import("zigstory");
const import_history = @import("import.zig");

/// Retain failed payloads and diagnostics even if the originating shell exits.
pub fn run(home: []const u8, path: []const u8, allocator: std.mem.Allocator, io: std.Io) !void {
    const error_path = try std.fmt.allocPrint(allocator, "{s}.error", .{path});
    defer allocator.free(error_path);
    consumePayload(home, path, error_path, allocator, io) catch |err| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = error_path, .data = @errorName(err) }) catch |log_err| {
            std.log.err("Failed to persist recording failure diagnostic: {}", .{log_err});
        };
        return err;
    };
}

fn consumePayload(home: []const u8, path: []const u8, error_path: []const u8, allocator: std.mem.Allocator, io: std.Io) !void {
    const db_path = try std.fs.path.join(allocator, &.{ home, ".zigstory", "history.db" });
    defer allocator.free(db_path);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(db_path).?);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    var db = try zigstory.db.initDb(db_path_z);
    defer db.deinit();
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    _ = try import_history.importRecordingFile(&db, path, cwd, allocator, io);
    std.Io.Dir.cwd().deleteFile(io, error_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.Io.Dir.cwd().deleteFile(io, path);
}
