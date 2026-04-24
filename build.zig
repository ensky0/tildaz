const std = @import("std");

// 빌드:
//   zig build                  -- 기본 빌드 (ReleaseFast, SIMD 비활성)
//   zig build -Dsimd=true      -- SIMD 활성 (현재 Windows / Zig 0.15 에서 동작하지 않음)
//   zig build -Doptimize=Debug -- 디버그 빌드
//   zig build package          -- Windows 릴리즈 zip + .sha256 생성
//
// 릴리즈 버전. 태그 / dist/windows/README.txt / GitHub Release / dist/release-notes/
// 와 동기화 필요. src/tildaz.rc 의 FILEVERSION / PRODUCTVERSION / 문자열 블록도
// 같이 갱신.
const tildaz_version = "0.2.11";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const target_os = target.result.os.tag;
    const is_windows_target = target_os == .windows;
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "성능, 안전성, 바이너리 크기 중 무엇을 우선할지 선택",
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

    // SIMD: 현재 Windows 에서 동작하지 않습니다. Zig 0.15 빌드 시스템이 ghostty 의
    // SIMD C++ 소스(highway, simdutf)에 C++ 표준 라이브러리 include path 를
    // 전달하지 못하는 문제가 있어, upstream 수정 전까지 기본값을 false 로 둡니다.
    const simd = b.option(bool, "simd", "SIMD 가속 활성화 (Windows / Zig 0.15 에서는 동작하지 않음)") orelse false;

    if (b.lazyDependency("ghostty", .{ .simd = simd, .optimize = optimize })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    if (is_windows_target) {
        // PE VERSIONINFO 리소스 (Explorer 속성 / Task Manager 에서 버전 표시).
        exe_mod.addWin32ResourceFile(.{ .file = b.path("src/tildaz.rc") });
    }

    const exe = b.addExecutable(.{
        .name = "tildaz",
        .root_module = exe_mod,
    });
    if (is_windows_target) {
        exe.subsystem = .Windows;
    }
    b.installArtifact(exe);

    if (is_windows_target) {
        // 번들 ConPTY 런타임(Microsoft.Windows.Console.ConPTY).
        // tildaz.exe 와 같은 폴더로 복사되어 conpty.dll 의 ConptyCreatePseudoConsole
        // 이 sibling OpenConsole.exe 를 찾아 스폰합니다. 누락 시 src/conpty.zig 가
        // kernel32 CreatePseudoConsole 로 fallback 합니다.
        b.getInstallStep().dependOn(&b.addInstallBinFile(b.path("vendor/conpty/conpty.dll"), "conpty.dll").step);
        b.getInstallStep().dependOn(&b.addInstallBinFile(b.path("vendor/conpty/OpenConsole.exe"), "OpenConsole.exe").step);
    }

    // 실행 단계
    const run_step = b.step("run", "TildaZ 실행");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // 테스트 단계
    const test_step = b.step("test", "테스트 실행");
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // 패키지 단계: 릴리즈용 번들 zip + SHA256 sidecar 생성.
    //
    //   zig build package
    //     → 먼저 install 단계로 zig-out/bin/ 에 tildaz.exe + conpty.dll + OpenConsole.exe
    //     → bash dist/windows/package.sh --version <tildaz_version>
    //        → zig-out/release/tildaz-v<ver>-win-x64.zip
    //        → zig-out/release/tildaz-v<ver>-win-x64.zip.sha256
    //
    // bash 는 PATH 에서 해석돼요:
    //   Windows - Git for Windows 의 C:\Program Files\Git\usr\bin\bash.exe
    //   macOS / Linux - 시스템 기본 bash
    const package_step = b.step("package", "Windows 릴리즈 zip 번들과 SHA256 sidecar 생성");
    if (is_windows_target) {
        const package_cmd = b.addSystemCommand(&.{
            "bash",
            "dist/windows/package.sh",
            "--version",
            tildaz_version,
        });
        package_cmd.step.dependOn(b.getInstallStep());
        package_step.dependOn(&package_cmd.step);
    } else {
        const package_fail = b.addFail("package step은 현재 Windows 릴리즈 번들 전용입니다. Windows 대상에서 실행해 주세요.");
        package_step.dependOn(&package_fail.step);
    }
}
