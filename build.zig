const std = @import("std");

// Build:
//   zig build                  -- SIMD enabled (requires MSVC Build Tools)
//   zig build -Dsimd=false     -- SIMD disabled (no MSVC needed)
//   zig build -Doptimize=ReleaseFast  -- optimized release build
//
// MSVC Build Tools install (for SIMD):
//   winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive"
//
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // SIMD: disable with -Dsimd=false if MSVC/Windows SDK is not installed
    const simd = b.option(bool, "simd", "SIMD acceleration (disable with -Dsimd=false if no MSVC)") orelse true;

    if (b.lazyDependency("ghostty", .{ .simd = simd })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "tildaz",
        .root_module = exe_mod,
    });
    exe.subsystem = .Windows;
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
