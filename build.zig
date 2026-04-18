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

    if (b.lazyDependency("ghostty", .{ .simd = simd, .optimize = optimize })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "tildaz",
        .root_module = exe_mod,
    });
    exe.subsystem = .Windows;
    b.installArtifact(exe);

    // Bundled ConPTY runtime (Microsoft.Windows.Console.ConPTY).
    // tildaz.exe 와 같은 폴더로 복사되어 conpty.dll 의 ConptyCreatePseudoConsole
    // 이 sibling OpenConsole.exe 를 찾아 스폰합니다. 누락 시 src/conpty.zig 가
    // kernel32 CreatePseudoConsole 로 fallback 합니다.
    b.getInstallStep().dependOn(&b.addInstallBinFile(b.path("vendor/conpty/conpty.dll"), "conpty.dll").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(b.path("vendor/conpty/OpenConsole.exe"), "OpenConsole.exe").step);

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
