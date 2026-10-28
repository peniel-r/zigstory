const std = @import("std");
const zigstory = @import("zigstory");
const sqlite = @import("sqlite");
const vaxis = @import("vaxis");
const add = @import("cli/add.zig");
const import_history = @import("cli/import.zig");
const consume = @import("cli/consume.zig");
const list_history = @import("cli/list.zig");
const fzf_search = @import("cli/fzf.zig");
const tui = @import("tui/main.zig");
const clipboard = @import("clipboard.zig");
const help = @import("cli/help.zig");
const stats = @import("cli/stats.zig");
const ranking = zigstory.ranking;
const recalc = @import("cli/recalc.zig");
const perf = @import("cli/perf.zig");
const logging = @import("logging.zig");
const timing = @import("tui/timing.zig");

pub const std_options: std.Options = .{ .logFn = logging.logFn, .log_level = .debug };

// Use libvaxis panic handler for proper terminal cleanup
pub const panic = vaxis.panic_handler;

/// Helper: get home directory from environ_map (USERPROFILE on Windows, HOME on Unix).
/// Returns a borrowed slice – do NOT free it.
fn getHomeDir(environ_map: *std.process.Environ.Map) ?[]const u8 {
    return environ_map.get("USERPROFILE") orelse environ_map.get("HOME");
}

pub fn main(init: std.process.Init) !void {
    var metrics = try timing.Metrics.init(init.io, init.environ_map);
    defer if (metrics) |*value| {
        value.save() catch |err| std.debug.print("TUI profiling failed: {}\n", .{err});
    };
    var logger = logging.Logger.init(init.io, std.heap.page_allocator, init.environ_map) catch |err| {
        std.debug.print("zigstory logging initialization failed: {}\n", .{err});
        return run(init, if (metrics) |*value| value else null);
    };
    defer logger.deinit();
    logging.active = &logger;
    defer logging.active = null;
    run(init, if (metrics) |*value| value else null) catch |err| {
        std.log.err("Command failed: {}", .{err});
        return err;
    };
}

fn run(init: std.process.Init, metrics: ?*timing.Metrics) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const action = zigstory.cli.parse(allocator, init.minimal.args) catch |err| {
        std.log.err("Error parsing arguments: {}", .{err});
        std.process.exit(1);
    };

    switch (action) {
        .add => |args| {
            defer {
                allocator.free(args.cmd);
                allocator.free(args.cwd);
            }

            const home_dir = getHomeDir(init.environ_map) orelse {
                std.log.err("Could not determine home directory", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.log.err("Error creating database directory: {}", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.log.err("Error initializing database: {}", .{err});
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
                std.log.err("Error adding command: {}", .{err});
                std.process.exit(1);
            };

            std.debug.print("Command added successfully\n", .{});
        },
        .search => {
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.log.err("Could not determine home directory", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.log.err("Error creating database directory: {}", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.log.err("Error initializing database: {}", .{err});
                std.process.exit(1);
            };
            defer db.deinit();

            // Get current working directory for filter
            const cwd = std.process.currentPathAlloc(init.io, allocator) catch |err| {
                std.log.err("Error getting current directory: {}", .{err});
                std.process.exit(1);
            };
            defer allocator.free(cwd);

            // Launch TUI search interface
            const result = tui.search(allocator, &db, cwd, init.io, init.environ_map, metrics) catch |err| {
                std.log.err("Error launching TUI: {}", .{err});
                std.process.exit(1);
            };

            if (result) |cmd| {
                std.debug.print("{s}\n", .{cmd});
                // Copy to clipboard for easy pasting
                clipboard.copyToClipboard(allocator, cmd) catch |err| {
                    std.log.warn("Failed to copy to clipboard: {}", .{err});
                };
                allocator.free(cmd);
            }
        },
        .import => |args| {
            if (args.consume) {
                const home = getHomeDir(init.environ_map) orelse return error.HomeDirectoryNotFound;
                consume.run(home, args.file.?, allocator, init.io) catch |err| {
                    std.debug.print("Recording import failed: {}; payload retained at {s}\n", .{ err, args.file.? });
                    return err;
                };
                return;
            }
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.log.err("Could not determine home directory", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.log.err("Error creating database directory: {}", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.log.err("Error initializing database: {}", .{err});
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
                    std.log.err("Error importing from file: {}", .{err});
                    std.process.exit(1);
                };
                std.debug.print("\nImport complete!\n", .{});
                std.debug.print("Total commands in file: {}\n", .{result.total});
                std.debug.print("Imported: {}\n", .{result.imported});
            } else {
                const result = import_history.importHistory(&db, cwd_buffer, allocator, init.io) catch |err| {
                    std.log.err("Error importing history: {}", .{err});
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
                std.log.err("Could not determine home directory", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.log.err("Error initializing database: {}", .{err});
                std.process.exit(1);
            };
            defer db.deinit();

            stats.run(&db, allocator, init.io) catch |err| {
                std.log.err("Error running stats: {}", .{err});
                std.process.exit(1);
            };
        },
        .list => |args| {
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.log.err("Could not determine home directory", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.log.err("Error creating database directory: {}", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.log.err("Error initializing database: {}", .{err});
                std.process.exit(1);
            };
            defer db.deinit();

            // List entries
            list_history.listEntries(&db, args.count, allocator) catch |err| {
                std.log.err("Error listing entries: {}", .{err});
                std.process.exit(1);
            };
        },
        .fzf => {
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.log.err("Could not determine home directory", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.log.err("Error creating database directory: {}", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.log.err("Error initializing database: {}", .{err});
                std.process.exit(1);
            };
            defer db.deinit();

            // Run fzf integration
            const result = fzf_search.runFzf(&db, allocator, init.io) catch |err| {
                std.log.err("Error running fzf: {}", .{err});
                std.process.exit(1);
            };

            if (result) |cmd| {
                const stdout = std.Io.File.stdout();
                stdout.writeStreamingAll(init.io, cmd) catch {};
                stdout.writeStreamingAll(init.io, "\n") catch {};
                // Copy to clipboard for easy PS integration
                clipboard.copyToClipboard(allocator, cmd) catch |err| {
                    std.log.warn("Failed to copy to clipboard: {}", .{err});
                };
                allocator.free(cmd);
            }
        },
        .recalc_rank => {
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.log.err("Could not determine home directory", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.log.err("Error creating database directory: {}", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Recalculate ranks using CLI module
            recalc.recalcRanks(.{
                .db_path = db_path_z,
                .verbose = true,
            }, allocator, init.io) catch |err| {
                std.log.err("Error recalculating ranks: {}", .{err});
                std.process.exit(1);
            };
        },
        .perf => |params| {
            const home_dir = getHomeDir(init.environ_map) orelse {
                std.log.err("Could not determine home directory", .{});
                std.process.exit(1);
            };

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.Io.Dir.cwd().createDirPath(init.io, db_dir) catch |err| {
                std.log.err("Error creating database directory: {}", .{err});
                std.process.exit(1);
            };

            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            // Initialize database
            var db = zigstory.db.initDb(db_path_z) catch |err| {
                std.log.err("Error initializing database: {}", .{err});
                std.process.exit(1);
            };
            defer db.deinit();

            // Run perf command with individual parameters (pass io for cwd resolution)
            perf.run(&db, params.cwd, params.format, params.threshold, allocator, init.io) catch |err| {
                std.log.err("Error running perf: {}", .{err});
                std.process.exit(1);
            };
        },
        .maintenance => {
            const home_dir = getHomeDir(init.environ_map) orelse return error.HomeDirectoryNotFound;
            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            try std.Io.Dir.cwd().createDirPath(init.io, db_dir);
            const db_path_z = try allocator.dupeZ(u8, db_path);
            var db = try zigstory.db.initDb(db_path_z);
            defer db.deinit();
            zigstory.db.maintain(&db) catch |err| {
                std.log.err("Error maintaining search index: {}", .{err});
                return err;
            };
            std.debug.print("Search index rebuilt and validated; database optimization complete.\n", .{});
        },
        .help => {
            help.printHelp();
        },
    }
}
