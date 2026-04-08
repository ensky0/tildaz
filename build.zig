const std = @import("std");

// Build:
//   zig build                  -- default build (ReleaseFast, SIMD disabled)
//   zig build -Dsimd=true      -- SIMD enabled (currently broken on Windows, Zig 0.15 issue)
//   zig build -Doptimize=Debug -- debug build
//
// Cross-platform targets:
//   zig build -Dtarget=x86_64-windows      -- Windows (default)
//   zig build -Dtarget=aarch64-macos       -- macOS ARM (M1/M2/M3)
//   zig build -Dtarget=x86_64-macos        -- macOS Intel
//   zig build -Dtarget=x86_64-linux-gnu    -- Linux x86_64
//
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const os = target.result.os.tag;
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

    if (b.lazyDependency("ghostty", .{ .simd = simd, .optimize = optimize })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "tildaz",
        .root_module = exe_mod,
    });

    switch (os) {
        .windows => {
            exe.subsystem = .Windows;
        },
        .macos => {
            exe.linkFramework("Cocoa");
            exe.linkFramework("Metal");
            exe.linkFramework("MetalKit");
            exe.linkFramework("CoreText");
            exe.linkFramework("CoreGraphics");
            exe.linkFramework("CoreFoundation");
            exe.linkFramework("ApplicationServices");
            exe.linkFramework("Carbon");
            exe.linkLibC();

            // Objective-C 브릿지 파일 컴파일 (.m)
            // Zig은 .m (Objective-C) 파일을 직접 컴파일할 수 있다.
            exe_mod.addCSourceFiles(.{
                .files = &.{
                    "src/macos/bridge.m",
                    "src/macos/metal_bridge.m",
                },
                .flags = &.{
                    "-fobjc-arc", // ARC (Automatic Reference Counting)
                    "-fmodules",
                    "-std=c11",
                },
            });
            exe_mod.addIncludePath(b.path("src"));
        },
        .linux => {
            exe.linkSystemLibrary("gtk-4");
            exe.linkSystemLibrary("gl");
            exe.linkSystemLibrary("fontconfig");
            exe.linkSystemLibrary("freetype2");
            exe.linkLibC();
        },
        else => @panic("Unsupported target OS"),
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
