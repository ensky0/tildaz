const std = @import("std");

// 빌드:
//   zig build                       -- 기본 빌드 (Debug, SIMD 비활성, #200)
//   zig build -Doptimize=ReleaseFast -- 릴리즈 최적화 빌드
//   zig build -Dsimd=true           -- SIMD 활성 (현재 Windows / Zig 0.15 에서 동작하지 않음)
//   zig build package               -- Windows 릴리즈 zip + .sha256 생성 (자동 ReleaseFast)
//   zig build check                 -- 6-target compile-only verify (#201)
//
// 릴리즈 버전. 태그 / dist/windows/README.txt / GitHub Release / dist/release-notes/
// 와 동기화 필요. src/tildaz.rc 의 FILEVERSION / PRODUCTVERSION / 문자열 블록도
// 같이 갱신.
const tildaz_version = "0.5.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const target_os = target.result.os.tag;
    const is_windows_target = target_os == .windows;
    const is_linux_target = target_os == .linux;
    // #200 — default 가 ReleaseFast 면 runtime safety check 모두 비활성
    // (overflow / null deref / array bounds 등 silently 통과) → 개발 사이클의
    // 버그가 production 까지 새어 나감. Debug 가 default — 안전성 + 진단 가능성
    // 우선. 빌드 시간 손해는 dev 경험에서 회복. 릴리즈 / packaging 은 명시
    // `-Doptimize=ReleaseFast` (CI / `package` step / `dist/release.sh`).
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "성능, 안전성, 바이너리 크기 중 무엇을 우선할지 선택 (default: Debug)",
    ) orelse .Debug;

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

    // ghostty 의 build.zig 는 macOS 타겟이면 기본적으로 xcframework / macOS app
    // 까지 빌드하려고 들어서 (`Config.zig` 의 `emit_xcframework` / `emit_macos_app`
    // 기본값 참고) tildaz 처럼 ghostty-vt 모듈만 필요한 의존자를 panic 시킨다.
    // `emit-lib-vt = true` 가 정확히 그 케이스를 위한 ghostty 옵션 — xcframework /
    // macOS app / docs 빌드를 모두 끄고 vt 모듈만 빌드한다. Windows 에서는 어차피
    // 기본값이 false 라 동작에 변화가 없다.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .simd = simd,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    if (is_windows_target) {
        // PE VERSIONINFO 리소스 (Explorer 속성 / Task Manager 에서 버전 표시).
        exe_mod.addWin32ResourceFile(.{ .file = b.path("src/tildaz.rc") });
    }

    if (is_linux_target) {
        // Linux Wayland 키보드 입력은 런타임에 dlopen/dlsym 으로 libxkbcommon 을
        // 로드한다. xkbcommon 자체는 링크 타임 필수 의존성으로 만들지 않되,
        // 부분 ELF mapper 가 아니라 시스템 dynamic loader 를 사용하기 위한 libc.
        exe_mod.link_libc = true;
    }

    const is_macos_target = target_os == .macos;
    if (is_macos_target) {
        // macos_host 가 사용하는 프레임워크 (M2 = AppKit + Metal + QuartzCore +
        // CoreGraphics + CoreFoundation, libobjc 는 `extern "objc"` 의 링크 대상).
        // 이후 milestone (CoreText, IOSurface 등) 에서 추가될 예정.
        exe_mod.linkSystemLibrary("objc", .{});
        exe_mod.linkFramework("AppKit", .{});
        exe_mod.linkFramework("Metal", .{});
        exe_mod.linkFramework("QuartzCore", .{});
        exe_mod.linkFramework("CoreGraphics", .{});
        exe_mod.linkFramework("CoreFoundation", .{});
        // ApplicationServices — `AXIsProcessTrusted` (Accessibility 권한 체크).
        // active CGEventTap 은 Input Monitoring 외에 Accessibility 권한도
        // 필요하므로 사용자 안내용으로 사전 체크.
        exe_mod.linkFramework("ApplicationServices", .{});
        // 참고: 이전엔 Carbon HIToolbox 의 RegisterEventHotKey 를 썼으나 macOS
        // Tahoe + ad-hoc sign 환경에서 silently fail 해서 CGEventTap (Apple DTS
        // 권장 modern API, CoreGraphics) 으로 전환. Carbon 프레임워크 링크 불필요.

        // Cross-compile (host arch ≠ target arch — 예: Apple Silicon dev /
        // CI runner 에서 x86_64-macos 빌드 / #133 universal binary) 시 zig 가
        // SDK 의 library / framework path 를 자동 검색 안 해서 `-lobjc` 같이
        // searched paths: none 으로 실패. `-Dmacos-sdk=` 로 받음 (CI 는
        // `xcrun --show-sdk-path` 결과 주입). native 빌드는 미지정 → zig 자동
        // 검색에 위임 (현재 동작 유지).
        const sdk_root = b.option(
            []const u8,
            "macos-sdk",
            "macOS SDK root (cross-compile 시 필수, native 는 비워둠). 예: $(xcrun --show-sdk-path)",
        ) orelse "";
        if (sdk_root.len > 0) {
            exe_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk_root}) });
            exe_mod.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk_root}) });
        }
    }

    const exe = b.addExecutable(.{
        .name = "tildaz",
        .root_module = exe_mod,
    });
    if (is_windows_target) {
        exe.subsystem = .Windows;
    }

    if (is_macos_target) {
        // macOS 는 일반 zig-out/bin/tildaz CLI 가 아니라 .app 번들 형태로 install.
        // unsigned CLI binary 가 macOS Tahoe (26+) 의 정식 앱 라이프사이클에 안
        // 들어가서 Carbon `RegisterEventHotKey` 가 silently fail 하는 막힘을 푸는
        // 핵심 — Info.plist + .app 폴더 구조 + ad-hoc 서명 셋이 갖춰져야 macOS
        // 가 우리를 \"정식 앱\" 으로 인식해 글로벌 핫키 dispatch 가 동작.
        //
        // 결과 경로:
        //   zig-out/TildaZ.app/Contents/MacOS/tildaz
        //   zig-out/TildaZ.app/Contents/Info.plist
        //
        // 실행: `./zig-out/TildaZ.app/Contents/MacOS/tildaz` (터미널 attach,
        // Ctrl+C 로 종료) 또는 `open ./zig-out/TildaZ.app` (LaunchServices).
        const install_macos_exe = b.addInstallFile(exe.getEmittedBin(), "TildaZ.app/Contents/MacOS/tildaz");
        b.getInstallStep().dependOn(&install_macos_exe.step);
        const install_macos_plist = b.addInstallFile(b.path("dist/macos/Info.plist"), "TildaZ.app/Contents/Info.plist");
        b.getInstallStep().dependOn(&install_macos_plist.step);
        // App icon — Info.plist 의 CFBundleIconFile=AppIcon 이 Resources/AppIcon.icns
        // 를 찾음 (#145). docs/favicon.svg 에서 sips + iconutil 로 만든 .icns commit.
        const install_macos_icon = b.addInstallFile(b.path("dist/macos/AppIcon.icns"), "TildaZ.app/Contents/Resources/AppIcon.icns");
        b.getInstallStep().dependOn(&install_macos_icon.step);
        // 코드 서명 identity. default `-` = ad-hoc (인증서 없이). macOS TCC
        // (Privacy & Security 권한 데이터베이스) 는 "signing identity + bundle
        // identifier" 로 앱 식별 — ad-hoc 은 매 빌드마다 hash 가 변경되어 동일
        // 앱으로 인식 안 되어서, 사용자가 매번 Input Monitoring + Accessibility
        // 권한 재부여해야 함.
        //
        // 로컬 개발 시 `-Dmacos-sign-identity="tildaz Local"` 로 self-signed
        // code-signing 인증서 사용 → identity stable → 권한 한 번만 부여하면
        // 다음 빌드에도 유지. self-signed 인증서 만드는 법: dist/macos/README.md.
        const sign_identity = b.option(
            []const u8,
            "macos-sign-identity",
            "macOS codesign identity. default `-` (ad-hoc). 로컬에서 권한 유지 용 self-signed cert 사용 시 그 이름 (예: \"tildaz Local\").",
        ) orelse "-";
        // codesign 대상은 install prefix 기준 (`zig build -p <dir>` 으로 prefix
        // 바꿔도 그 dir 의 .app 을 서명). 하드코딩된 `zig-out/TildaZ.app` 은 #133
        // universal 작업 중 두 prefix 로 install 할 때 mismatch 원인.
        const app_path = b.fmt("{s}/TildaZ.app", .{b.install_path});
        const sign = b.addSystemCommand(&.{
            "codesign",
            "--force",
            "--sign",
            sign_identity,
            app_path,
        });
        sign.step.dependOn(&install_macos_exe.step);
        sign.step.dependOn(&install_macos_plist.step);
        sign.step.dependOn(&install_macos_icon.step);
        b.getInstallStep().dependOn(&sign.step);
    } else {
        b.installArtifact(exe);
    }

    if (is_windows_target) {
        // 번들 ConPTY 런타임(Microsoft.Windows.Console.ConPTY).
        // tildaz.exe 와 같은 폴더로 복사되어 conpty.dll 의 ConptyCreatePseudoConsole
        // 이 sibling OpenConsole.exe 를 찾아 스폰합니다. 누락 시 src/conpty.zig 가
        // kernel32 CreatePseudoConsole 로 fallback 합니다.
        //
        // target arch 별 native binary 선택 — PE32+ x86_64 / ARM64 별도 (PE loader
        // 가 arch mismatch 시 STATUS_INVALID_IMAGE_FORMAT 로 거부).
        const conpty_arch_dir: []const u8 = switch (target.result.cpu.arch) {
            .x86_64 => "vendor/conpty/x64",
            .aarch64 => "vendor/conpty/arm64",
            else => @panic("unsupported Windows arch — only x86_64 / aarch64 ConPTY bundle 제공"),
        };
        const conpty_dll_path = b.fmt("{s}/conpty.dll", .{conpty_arch_dir});
        const open_console_path = b.fmt("{s}/OpenConsole.exe", .{conpty_arch_dir});
        b.getInstallStep().dependOn(&b.addInstallBinFile(b.path(conpty_dll_path), "conpty.dll").step);
        b.getInstallStep().dependOn(&b.addInstallBinFile(b.path(open_console_path), "OpenConsole.exe").step);
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

    // 6-target compile-only check 단계 (#201).
    //
    //   zig build check
    //
    // win/mac/linux × x86_64/aarch64 = 6 가지 target 의 *컴파일 단계* 만 돌려
    // type / 빌드 에러를 조기 발견. link 단계는 skip — macOS 의 framework /
    // -lobjc 같은 SDK 의존 link 가 없는 dev 머신에서도 모든 host 의 compile
    // error 가 surface. `b.addObject` 가 link 없이 .o 만 생성하는 핵심.
    //
    // 한계: link 단계의 미참조 symbol / framework 의 ABI mismatch 는 잡지 못함.
    // 그건 release.yml 의 실 host runner (windows-2022 / macos-15 / ubuntu-22.04)
    // 가 잡음. 이 step 은 *dev cycle 에서 mac/win 머신 없이도 compile error
    // 만큼은 잡자* 가 목표 (#201 옵션 A).
    const check_step = b.step("check", "6-target compile-only verify (#201)");
    const check_targets = [_]struct { name: []const u8, query: std.Target.Query }{
        .{ .name = "linux-x86_64", .query = .{ .os_tag = .linux, .cpu_arch = .x86_64, .abi = .gnu } },
        .{ .name = "linux-aarch64", .query = .{ .os_tag = .linux, .cpu_arch = .aarch64, .abi = .gnu } },
        .{ .name = "windows-x86_64", .query = .{ .os_tag = .windows, .cpu_arch = .x86_64 } },
        .{ .name = "windows-aarch64", .query = .{ .os_tag = .windows, .cpu_arch = .aarch64 } },
        .{ .name = "macos-x86_64", .query = .{ .os_tag = .macos, .cpu_arch = .x86_64 } },
        .{ .name = "macos-aarch64", .query = .{ .os_tag = .macos, .cpu_arch = .aarch64 } },
    };
    for (check_targets) |c| {
        const check_target = b.resolveTargetQuery(c.query);
        const check_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = check_target,
            // Debug — safety check 활성. ReleaseFast 와의 codegen 차이로 일부
            // type error 가 안 surface 되는 케이스 회피.
            .optimize = .Debug,
        });
        check_mod.addOptions("build_options", build_opts);
        if (b.lazyDependency("ghostty", .{
            .target = check_target,
            .simd = simd,
            .optimize = .Debug,
            .@"emit-lib-vt" = true,
        })) |dep| {
            check_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
        }
        // OS-specific link spec 도 declare. *compile-only* 라 link 안 함이지만
        // host 코드의 일부 `extern` decl 이 module 의 link_libc / framework 마커를
        // 검사하는 케이스 일관성. mac framework / windows resource 는 compile
        // 자체엔 영향 없어 skip.
        if (c.query.os_tag == .linux) check_mod.link_libc = true;
        const check_obj = b.addObject(.{
            .name = b.fmt("tildaz-check-{s}", .{c.name}),
            .root_module = check_mod,
        });
        check_step.dependOn(&check_obj.step);
    }

    // 패키지 단계: 릴리즈용 번들 zip + SHA256 sidecar 생성.
    //
    //   zig build package                              → x64 (기본)
    //   zig build package -Dtarget=aarch64-windows     → arm64
    //     → 먼저 install 단계로 zig-out/bin/ 에 tildaz.exe + conpty.dll + OpenConsole.exe
    //     → bash dist/windows/package.sh --version <tildaz_version> --arch <x64|arm64>
    //        → zig-out/release/tildaz-v<ver>-win-<arch>.zip
    //        → zig-out/release/tildaz-v<ver>-win-<arch>.zip.sha256
    //
    // bash 는 PATH 에서 해석돼요:
    //   Windows - Git for Windows 의 C:\Program Files\Git\usr\bin\bash.exe
    //   macOS / Linux - 시스템 기본 bash
    const package_step = b.step("package", "릴리즈 artifact + SHA256 sidecar 생성 (Windows zip / macOS dmg / Linux tar.gz·deb·rpm·AppImage)");
    if (is_windows_target) {
        const arch_arg: []const u8 = switch (target.result.cpu.arch) {
            .x86_64 => "x64",
            .aarch64 => "arm64",
            else => @panic("unsupported Windows arch for package step"),
        };
        const package_cmd = b.addSystemCommand(&.{
            "bash",
            "dist/windows/package.sh",
            "--version",
            tildaz_version,
            "--arch",
            arch_arg,
        });
        package_cmd.step.dependOn(b.getInstallStep());
        package_step.dependOn(&package_cmd.step);
    } else if (is_macos_target) {
        // macOS (#133) — package.sh 가 두 target (arm64 + x86_64) 자체 빌드 +
        // lipo 로 universal binary + .app 조립 + codesign + hdiutil 로 DMG 까지
        // 처리. install step 에 dependOn 안 함 — package.sh 가 단일 target 빌드
        // 산출물 (zig-out/TildaZ.app) 을 사용 안 하고 자기 prefix 로 새로 빌드.
        const package_cmd = b.addSystemCommand(&.{
            "bash",
            "dist/macos/package.sh",
            "--version",
            tildaz_version,
        });
        package_step.dependOn(&package_cmd.step);
    } else if (is_linux_target) {
        // Linux (#202) — 4 format (tar.gz / deb / rpm / AppImage) × 2 arch
        // (x86_64 / aarch64) = 8 artifact 매트릭스. 한 호출당 한 format —
        // `-Dformat=<tar.gz|deb|rpm|AppImage>` 로 선택. CI 가 matrix 안에서
        // 각 (arch, format) 한 번씩 호출.
        const format = b.option(
            []const u8,
            "format",
            "Linux release artifact 형식 (tar.gz / deb / rpm / AppImage)",
        ) orelse "tar.gz";
        const linux_arch_arg: []const u8 = switch (target.result.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            else => @panic("unsupported Linux arch for package step — only x86_64 / aarch64"),
        };
        const package_cmd = b.addSystemCommand(&.{
            "bash",
            "dist/linux/package.sh",
            "--version",
            tildaz_version,
            "--arch",
            linux_arch_arg,
            "--format",
            format,
        });
        package_cmd.step.dependOn(b.getInstallStep());
        package_step.dependOn(&package_cmd.step);
    } else {
        const package_fail = b.addFail("package step은 Windows / macOS / Linux 대상에서만 동작합니다.");
        package_step.dependOn(&package_fail.step);
    }
}
