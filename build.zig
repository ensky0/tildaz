const std = @import("std");

// Build:
//   zig build                  -- default build (ReleaseFast, SIMD disabled)
//   zig build -Dsimd=true      -- SIMD enabled (currently broken on Windows, Zig 0.15 issue)
//   zig build -Doptimize=Debug -- debug build
//   zig build package          -- build + create zig-out/release/tildaz-v<ver>-win-x64.zip + .sha256
//
// 릴리즈 버전. 태그 / dist/windows/README.txt / GitHub Release / dist/release-notes/
// 와 동기화 필요. src/tildaz.rc 의 FILEVERSION / PRODUCTVERSION / 문자열 블록도
// 같이 갱신.
const tildaz_version = "0.2.10";

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

    // 컴파일 타임 상수 — About 다이얼로그 / tildaz.log 의 boot 엔트리에서 사용.
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", tildaz_version);
    exe_mod.addOptions("build_options", build_opts);

    // SIMD: currently broken on Windows — Zig 0.15 build system doesn't pass C++ stdlib
    // include paths to ghostty's SIMD C++ sources (highway, simdutf).
    // Keep default false until Zig upstream fixes this.
    const simd = b.option(bool, "simd", "SIMD acceleration (broken on Windows/Zig 0.15)") orelse false;

    if (b.lazyDependency("ghostty", .{ .simd = simd, .optimize = optimize })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    // PE VERSIONINFO 리소스 (Explorer 속성 / Task Manager 에서 버전 표시).
    exe_mod.addWin32ResourceFile(.{ .file = b.path("src/tildaz.rc") });

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

    // Package step — 릴리즈용 번들 zip + SHA256 sidecar 생성.
    //
    //   zig build package
    //     → 먼저 install 단계로 zig-out/bin/ 에 tildaz.exe + conpty.dll + OpenConsole.exe
    //     → bash dist/windows/package.sh --version <tildaz_version>
    //        → zig-out/release/tildaz-v<ver>-win-x64.zip
    //        → zig-out/release/tildaz-v<ver>-win-x64.zip.sha256
    //
    // bash 는 PATH 에서 해석돼요:
    //   Windows — Git for Windows 의 C:\Program Files\Git\usr\bin\bash.exe
    //   macOS / Linux — 시스템 기본 bash
    const package_cmd = b.addSystemCommand(&.{
        "bash",
        "dist/windows/package.sh",
        "--version",
        tildaz_version,
    });
    package_cmd.step.dependOn(b.getInstallStep());

    const package_step = b.step("package", "Create release zip bundle + SHA256 sidecar in zig-out/release/");
    package_step.dependOn(&package_cmd.step);
}
