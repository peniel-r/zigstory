const std = @import("std");

/// Filter mode for directory-based filtering
pub const FilterMode = enum {
    /// Show all commands from all directories
    global,
    /// Show only commands from current directory
    current_dir,

    pub fn toString(self: FilterMode) []const u8 {
        return switch (self) {
            .global => "Global",
            .current_dir => "Current Dir",
        };
    }
};

/// Directory filter state
pub const DirectoryFilterState = struct {
    /// Current filter mode
    mode: FilterMode = .global,
    /// Current directory (for current_dir mode)
    current_dir: ?[]const u8 = null,

    /// Initialize directory filter state
    pub fn init(current_dir: ?[]const u8) DirectoryFilterState {
        return .{
            .mode = .global,
            .current_dir = current_dir,
        };
    }

    /// Toggle between filter modes
    pub fn toggleMode(self: *DirectoryFilterState) void {
        self.mode = switch (self.mode) {
            .global => .current_dir,
            .current_dir => .global,
        };
    }

    /// Get WHERE clause for SQL query based on current mode
    pub fn getWhereClause(self: *const DirectoryFilterState, allocator: std.mem.Allocator) !?[]const u8 {
        return switch (self.mode) {
            .global => null,
            .current_dir => {
                if (self.current_dir) |_| {
                    return try std.fmt.allocPrint(allocator, "cwd = ?", .{});
                }
                return null;
            },
        };
    }

    /// Get bind parameters for WHERE clause
    pub fn getBindParams(self: *const DirectoryFilterState) ![]const anyerror {
        return switch (self.mode) {
            .global => &[_]anyerror{},
            .current_dir => {
                if (self.current_dir) |dir| {
                    return &[_]anyerror{dir};
                }
                return &[_]anyerror{};
            },
        };
    }

    /// Check if filter is active
    pub fn isActive(self: *const DirectoryFilterState) bool {
        return self.mode == .current_dir and self.current_dir != null;
    }

    /// Deallocate resources (no-op - current_dir owned by caller)
    pub fn deinit(_: *DirectoryFilterState, _: std.mem.Allocator) void {}
};
