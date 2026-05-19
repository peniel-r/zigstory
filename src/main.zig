const std = @import("std");
const zigstory = @import("zigstory");
const sqlite = @import("sqlite");
const vaxis = @import("vaxis");
const add = @import("cli/add.zig");
const import_history = @import("cli/import.zig");
const list_history = @import("cli/list.zig");
const fzf_search = @import("cli/fzf.zig");
const tui = @import("tui/main.zig");
const clipboard = @import("clipboard.zig");
const help = @import("cli/help.zig");
const stats = @import("cli/stats.zig");
const ranking = zigstory.ranking;
const recalc = @import("cli/recalc.zig");
const perf = @import("cli/perf.zig");

// Use libvaxis panic handler for proper terminal cleanup
pub const panic = vaxis.panic_handler;

/// Helper: get home directory from environ_map (USERPROFILE on Windows, HOME on Unix).
/// Returns a borrowed slice – do NOT free it.
fn getHomeDir(environ_map: *std.process.Environ.Map) ?[]const u8 {
    return environ_map.get("USERPROFILE") orelse environ_map.get("HOME");
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const action = zigstory.cli.parse(allocator, init.minimal.args) catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        std.process.exit(1);
    };

    switch (action) {
        .add => |args| {
            defer {
                allocator.free(args.cmd);
                allocator.free(args.cwd);
            }

            const home_dir = getHomeDir(init.environ_map) orelse {
                std.debug.print("Error: Could not determine home directory\n", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.debug.print("Error creating database directory: {}\n", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.debug.print("Error initializing database: {}\n", .{err});
                std.process.exit(1);
            };
            defer db.deinit();

            // Add command to history
            add.addCommand(&db, .{
                .cmd = args.cmd,
                .cwd = args.cwd,
                .exit_code = args.exit_code,
                .duration_ms = args.duration,
            }, allocator, init.io) catch |err| {
                std.debug.print("Error adding command: {}\n", .{err});
                std.process.exit(1);
            };

            std.debug.print("Command added successfully\n", .{});
        },
        .search => {
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.debug.print("Error: Could not determine home directory\n", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.debug.print("Error creating database directory: {}\n", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.debug.print("Error initializing database: {}\n", .{err});
                std.process.exit(1);
            };
            defer db.deinit();

            // Get current working directory for filter
            const cwd = std.process.currentPathAlloc(init.io, allocator) catch |err| {
                std.debug.print("Error getting current directory: {}\n", .{err});
                std.process.exit(1);
            };
            defer allocator.free(cwd);

            // Launch TUI search interface
            const result = tui.search(allocator, &db, cwd, init.io, init.environ_map) catch |err| {
                std.debug.print("Error launching TUI: {}\n", .{err});
                std.process.exit(1);
            };

            if (result) |cmd| {
                std.debug.print("{s}\n", .{cmd});
                // Copy to clipboard for easy pasting
                clipboard.copyToClipboard(allocator, cmd) catch |err| {
                    std.debug.print("Warning: Failed to copy to clipboard: {}\n", .{err});
                };
                allocator.free(cmd);
            }
        },
        .import => |args| {
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.debug.print("Error: Could not determine home directory\n", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.debug.print("Error creating database directory: {}\n", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.debug.print("Error initializing database: {}\n", .{err});
                std.process.exit(1);
            };
            defer db.deinit();

            // Get current working directory
            const cwd_buffer = try std.process.currentPathAlloc(init.io, allocator);
            defer allocator.free(cwd_buffer);

            // Import from file if specified, otherwise import from PowerShell history
            if (args.file) |file_path| {
                defer allocator.free(file_path);
                const result = import_history.importFromFile(&db, file_path, cwd_buffer, allocator, init.io) catch |err| {
                    std.debug.print("Error importing from file: {}\n", .{err});
                    std.process.exit(1);
                };
                std.debug.print("\nImport complete!\n", .{});
                std.debug.print("Total commands in file: {}\n", .{result.total});
                std.debug.print("Imported: {}\n", .{result.imported});
            } else {
                const result = import_history.importHistory(&db, cwd_buffer, allocator, init.io) catch |err| {
                    std.debug.print("Error importing history: {}\n", .{err});
                    std.process.exit(1);
                };
                std.debug.print("\nImport complete!\n", .{});
                std.debug.print("Total commands in file: {}\n", .{result.total});
                std.debug.print("Imported: {}\n", .{result.imported});
                std.debug.print("Skipped (duplicates): {}\n", .{result.skipped});
            }
        },
        .stats => {
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.debug.print("Error: Could not determine home directory\n", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.debug.print("Error initializing database: {}\n", .{err});
                std.process.exit(1);
            };
            defer db.deinit();

            stats.run(&db, allocator, init.io) catch |err| {
                std.debug.print("Error running stats: {}\n", .{err});
                std.process.exit(1);
            };
        },
        .list => |args| {
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.debug.print("Error: Could not determine home directory\n", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.debug.print("Error creating database directory: {}\n", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.debug.print("Error initializing database: {}\n", .{err});
                std.process.exit(1);
            };
            defer db.deinit();

            // List entries
            list_history.listEntries(&db, args.count, allocator) catch |err| {
                std.debug.print("Error listing entries: {}\n", .{err});
                std.process.exit(1);
            };
        },
        .fzf => {
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.debug.print("Error: Could not determine home directory\n", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.debug.print("Error creating database directory: {}\n", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.debug.print("Error initializing database: {}\n", .{err});
                std.process.exit(1);
            };
            defer db.deinit();

            // Run fzf integration
            const result = fzf_search.runFzf(&db, allocator, init.io) catch |err| {
                std.debug.print("Error running fzf: {}\n", .{err});
                std.process.exit(1);
            };

            if (result) |cmd| {
                const stdout = std.Io.File.stdout();
                stdout.writeStreamingAll(init.io, cmd) catch {};
                stdout.writeStreamingAll(init.io, "\n") catch {};
                // Copy to clipboard for easy PS integration
                clipboard.copyToClipboard(allocator, cmd) catch |err| {
                    std.debug.print("Warning: Failed to copy to clipboard: {}\n", .{err});
                };
                allocator.free(cmd);
            }
        },
        .recalc_rank => {
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.debug.print("Error: Could not determine home directory\n", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.debug.print("Error creating database directory: {}\n", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Recalculate ranks using CLI module
            recalc.recalcRanks(.{
                .db_path = db_path_z,
                .verbose = true,
            }, allocator, init.io) catch |err| {
                std.debug.print("Error recalculating ranks: {}\n", .{err});
                std.process.exit(1);
            };
        },
        .perf => |params| {
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.debug.print("Error: Could not determine home directory\n", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.debug.print("Error creating database directory: {}\n", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.debug.print("Error initializing database: {}\n", .{err});
                std.process.exit(1);
            };
            defer db.deinit();

            // Run perf command with individual parameters (pass io for cwd resolution)
            perf.run(&db, params.cwd, params.format, params.threshold, allocator, init.io) catch |err| {
                std.debug.print("Error running perf: {}\n", .{err});
                std.process.exit(1);
            };
        },
        .help => {
            help.printHelp();
        },
    }
}
