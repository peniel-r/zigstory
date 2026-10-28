const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
        .fts5 = true,
    });
    const sqlite_mod = sqlite_dep.module("sqlite");

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const mod = b.addModule("zigstory", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("sqlite", sqlite_mod);

    const exe = b.addExecutable(.{
        .name = "zigstory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigstory", .module = mod },
                .{ .name = "sqlite", .module = sqlite_mod },
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    // Zig 0.16: Build.Step.Compile no longer exposes linkLibC().
    // Linking libc is handled via module/executable options or dependency modules.
    if (target.result.os.tag == .windows) {
        // Zig 0.16: link system libraries at the Module level.
        // The executable's root_module is a *std.Build.Module so call the
        // Module API to add a system library.
        exe.root_module.linkSystemLibrary("user32", .{});
    }

    b.installArtifact(exe);

    const tui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlite", .module = sqlite_mod },
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    const test_step = b.step("test-tui", "Run TUI startup, search, and navigation regressions");
    test_step.dependOn(&b.addRunArtifact(tui_tests).step);

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/regression_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlite", .module = sqlite_mod },
                .{ .name = "zigstory", .module = mod },
            },
        }),
    });
    const core_test_step = b.step("test-core", "Run database and import regressions");
    core_test_step.dependOn(&b.addRunArtifact(core_tests).step);
    const all_tests = b.step("test", "Run core and TUI regression tests");
    all_tests.dependOn(test_step);
    all_tests.dependOn(core_test_step);

    const tui_profile = b.addExecutable(.{
        .name = "zigstory-tui-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/profile.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlite", .module = sqlite_mod },
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    const profile_install = b.addInstallArtifact(tui_profile, .{});
    const profile_step = b.step("profile-tools", "Build the read-only TUI paging/rendering profiler");
    profile_step.dependOn(&profile_install.step);

    const startup_profile = b.addExecutable(.{
        .name = "zigstory-startup-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/startup_profile.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigstory", .module = mod },
                .{ .name = "sqlite", .module = sqlite_mod },
            },
        }),
    });
    profile_step.dependOn(&b.addInstallArtifact(startup_profile, .{}).step);

    const search_benchmark = b.addExecutable(.{
        .name = "zigstory-search-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/search_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqlite", .module = sqlite_mod }},
        }),
    });
    profile_step.dependOn(&b.addInstallArtifact(search_benchmark, .{}).step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
