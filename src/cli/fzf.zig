const std = @import("std");
const sqlite = @import("sqlite");

/// Runs fzf as a subprocess, piping deduplicated command history to its stdin
/// and returning the selected command if any.
pub fn runFzf(db: *sqlite.Db, allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    // 1. Check if fzf is installed using process.spawn (std.process.Child.init removed in 0.16)
    {
        var child = std.process.spawn(io, .{
            .argv = &[_][]const u8{ "fzf", "--version" },
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("fzf not found. Install from <https://github.com/junegunn/fzf>\n", .{});
                std.process.exit(2);
            }
            return err;
        };
        _ = try child.wait(io);
    }

    // 2. Query all commands from database, deduplicated, most recent first.
    const query = "SELECT cmd FROM history GROUP BY cmd ORDER BY MAX(timestamp) DESC";
    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const QueryRow = struct {
        cmd: []const u8,
    };

    var iter = try stmt.iterator(QueryRow, .{});

    // 3. Spawn fzf with stdin/stdout piped, stderr inherited for the fzf UI
    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{"fzf"},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    // 4. Pipe commands to fzf's stdin
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        if (child.stdin) |stdin| {
            while (try iter.nextAlloc(arena_allocator, .{})) |row| {
                stdin.writeStreamingAll(io, row.cmd) catch |err| {
                    if (err == error.BrokenPipe) break;
                    return err;
                };
                stdin.writeStreamingAll(io, "\n") catch |err| {
                    if (err == error.BrokenPipe) break;
                    return err;
                };
            }
            stdin.close(io);
            child.stdin = null;
        }
    }

    // 5. Capture selected command from fzf's stdout using Io.Reader.allocRemaining
    var fzf_buf: [256]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &fzf_buf);
    const stdout_content = try reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(stdout_content);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code == 0) {
                const trimmed = std.mem.trim(u8, stdout_content, " \n\r\t");
                if (trimmed.len > 0) {
                    const result = try allocator.dupe(u8, trimmed);
                    allocator.free(stdout_content);
                    return result;
                }
            }
        },
        else => {},
    }

    allocator.free(stdout_content);
    return null;
}
