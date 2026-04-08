const std = @import("std");

// Build:
//   zig build                  -- default build (ReleaseFast, SIMD disabled)
//   zig build -Dsimd=true      -- SIMD enabled (currently broken on Windows, Zig 0.15 issue)
//   zig build -Doptimize=Debug -- debug build
//
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseFast;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // SIMD: currently broken on Windows — Zig 0.15 build system doesn't pass C++ stdlib
    // include paths to ghostty's SIMD C++ sources (highway, simdutf).
    // Keep default false until Zig upstream fixes this.
    const simd = b.option(bool, "simd", "SIMD acceleration (broken on Windows/Zig 0.15)") orelse false;

    if (b.lazyDependency("ghostty", .{ .simd = simd, .optimize = optimize, .@"emit-lib-vt" = true })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "tildaz",
        .root_module = exe_mod,
    });

    const os_tag = target.query.os_tag orelse @import("builtin").os.tag;

    // Platform-specific configuration
    switch (os_tag) {
        .windows => {
            exe.subsystem = .Windows;
        },
        .macos => {
            exe_mod.linkFramework("AppKit", .{});
            exe_mod.linkFramework("Metal", .{});
            exe_mod.linkFramework("CoreText", .{});
            exe_mod.linkFramework("CoreGraphics", .{});
            exe_mod.linkFramework("QuartzCore", .{});
            exe_mod.linkSystemLibrary("c", .{});
        },
        else => {},
    }

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run TildaZ");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // Test step
    const test_step = b.step("test", "Run tests");
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
