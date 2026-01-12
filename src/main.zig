const std = @import("std");
const zigstory = @import("zigstory");
const sqlite = @import("sqlite");
const add = @import("cli/add.zig");
const import_history = @import("cli/import.zig");
const list_history = @import("cli/list.zig");

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
            defer {
                allocator.free(args.cmd);
                allocator.free(args.cwd);
            }

            // Get or create default database path
            const home_dir = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| blk: {
                if (err == error.EnvironmentVariableNotFound) {
                    break :blk std.process.getEnvVarOwned(allocator, "HOME") catch {
                        std.debug.print("Error: Could not determine home directory\n", .{});
                        std.process.exit(1);
                    };
                }
                std.debug.print("Error getting home directory: {}\n", .{err});
                std.process.exit(1);
            };
            defer allocator.free(home_dir);

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.fs.cwd().makePath(db_dir) catch |err| {
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
            }, allocator) catch |err| {
                std.debug.print("Error adding command: {}\n", .{err});
                std.process.exit(1);
            };

            std.debug.print("Command added successfully\n", .{});
        },
        .search => {
            std.debug.print("SEARCH command\n", .{});
        },
        .import => |args| {
            // Get or create default database path
            const home_dir = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| blk: {
                if (err == error.EnvironmentVariableNotFound) {
                    break :blk std.process.getEnvVarOwned(allocator, "HOME") catch {
                        std.debug.print("Error: Could not determine home directory\n", .{});
                        std.process.exit(1);
                    };
                }
                std.debug.print("Error getting home directory: {}\n", .{err});
                std.process.exit(1);
            };
            defer allocator.free(home_dir);

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.fs.cwd().makePath(db_dir) catch |err| {
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
            const cwd_buffer = try std.process.getCwdAlloc(allocator);
            defer allocator.free(cwd_buffer);

            // Import from file if specified, otherwise import from PowerShell history
            if (args.file) |file_path| {
                defer allocator.free(file_path);
                const result = import_history.importFromFile(&db, file_path, cwd_buffer, allocator) catch |err| {
                    std.debug.print("Error importing from file: {}\n", .{err});
                    std.process.exit(1);
                };
                std.debug.print("\nImport complete!\n", .{});
                std.debug.print("Total commands in file: {}\n", .{result.total});
                std.debug.print("Imported: {}\n", .{result.imported});
            } else {
                const result = import_history.importHistory(&db, cwd_buffer, allocator) catch |err| {
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
            std.debug.print("STATS command\n", .{});
        },
        .list => |args| {
            // Get or create default database path
            const home_dir = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| blk: {
                if (err == error.EnvironmentVariableNotFound) {
                    break :blk std.process.getEnvVarOwned(allocator, "HOME") catch {
                        std.debug.print("Error: Could not determine home directory\n", .{});
                        std.process.exit(1);
                    };
                }
                std.debug.print("Error getting home directory: {}\n", .{err});
                std.process.exit(1);
            };
            defer allocator.free(home_dir);

            const db_path = try std.fs.path.join(allocator, &.{ home_dir, ".zigstory", "history.db" });
            defer allocator.free(db_path);

            // Ensure directory exists
            const db_dir = std.fs.path.dirname(db_path) orelse ".";
            std.fs.cwd().makePath(db_dir) catch |err| {
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
        .help => {
            std.debug.print("Usage: zigstory [add|search|import|list] [options]\n", .{});
        },
    }
}
