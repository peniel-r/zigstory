const std = @import("std");

/// Writes the selected command for a shell integration. The file is written even
/// when the selection is cancelled, leaving it empty, so a reused path can never
/// return a stale command.
pub fn writeOutput(io: std.Io, path: []const u8, selected: ?[]const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = selected orelse "" });
}
