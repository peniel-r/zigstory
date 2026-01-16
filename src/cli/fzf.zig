const std = @import("std");
const sqlite = @import("sqlite");

/// Runs fzf as a subprocess, piping deduplicated command history to its stdin
/// and returning the selected command if any.
pub fn runFzf(db: *sqlite.Db, allocator: std.mem.Allocator) !?[]const u8 {
    // 1. Check if fzf is installed
    const fzf_check_cmd = [_][]const u8{ "fzf", "--version" };
    var child_check = std.process.Child.init(&fzf_check_cmd, allocator);
    child_check.stdout_behavior = .Ignore;
    child_check.stderr_behavior = .Ignore;
    _ = child_check.spawnAndWait() catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("fzf not found. Install from <https://github.com/junegunn/fzf>\n", .{});
            std.process.exit(2);
        }
        return err;
    };

    // 2. Query all commands from database, deduplicated, most recent first.
    // We use GROUP BY and MAX(timestamp) to ensure we get the most recent instance of each command.
    const query = "SELECT cmd FROM history GROUP BY cmd ORDER BY MAX(timestamp) DESC";
    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const QueryRow = struct {
        cmd: []const u8,
    };

    var iter = try stmt.iterator(QueryRow, .{});

    // 3. Spawn fzf
    // stdin: Pipe (to send history)
    // stdout: Pipe (to capture selection)
    // stderr: Inherit (for the fzf UI to show on terminal)
    var child = std.process.Child.init(&[_][]const u8{"fzf"}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    // 4. Pipe commands to fzf's stdin
    // Use an arena for row allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    if (child.stdin) |stdin| {
        while (try iter.nextAlloc(arena_allocator, .{})) |row| {
            stdin.writeAll(row.cmd) catch |err| {
                if (err == error.BrokenPipe) break;
                return err;
            };
            stdin.writeAll("\n") catch |err| {
                if (err == error.BrokenPipe) break;
                return err;
            };
        }
        stdin.close();
        child.stdin = null;
    }

    // 5. Capture selected command from fzf's stdout
    var fzf_stdout = std.ArrayList(u8).empty;
    defer fzf_stdout.deinit(allocator);

    var buf: [1024]u8 = undefined;
    while (true) {
        const bytes_read = try child.stdout.?.read(&buf);
        if (bytes_read == 0) break;
        try fzf_stdout.appendSlice(allocator, buf[0..bytes_read]);
    }
    const stdout_content = try fzf_stdout.toOwnedSlice(allocator);
    errdefer allocator.free(stdout_content);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
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
