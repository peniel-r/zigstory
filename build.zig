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
    exe.linkLibC();

    b.installArtifact(exe);

    // Temporarily disable run step due to Windows build issue
    // const run_step = b.step("run", "Run the app");
    // const run_cmd = b.addRunArtifact(exe);
    // run_step.dependOn(&run_cmd.step);

    // run_cmd.step.dependOn(b.getInstallStep());

    // if (b.args) |args| {
    //     run_cmd.addArgs(args);
    // }
}
