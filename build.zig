const std = @import("std");
const manifest = @import("build.zig.zon");
const versioning = @import("build/version.zig");
const git_version = @import("build/git_version.zig");

// Ghostty는 Windows target query의 ABI가 null이면 내부 target만 MSVC로
// 바꾼다. TildaZ root는 Zig가 이미 resolve한 GNU ABI를 계속 써서 두 module의
// ABI가 갈라지고, SIMD C++ source가 MSVC SDK header를 찾지 못한다 (#19).
// result는 건드리지 않고 그 resolved ABI를 query에도 명시해 dependency 경계에서
// 같은 target 의미를 보존한다. 명시적으로 요청한 ABI는 그대로 둔다.
fn preserveResolvedWindowsAbi(target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    var explicit_target = target;
    if (target.result.os.tag == .windows and target.query.abi == null) {
        explicit_target.query.abi = target.result.abi;
    }
    return explicit_target;
}

// 빌드:
//   zig build                       -- 기본 빌드 (Debug, SIMD 비활성, #200)
//   zig build -Doptimize=ReleaseFast -Dsimd=true -- 릴리즈 최적화 + SIMD (#19)
//   zig build package -Doptimize=ReleaseFast -Dsimd=true -- 릴리즈 package + SHA256
//   zig build check                 -- 6-target compile-only verify (#201)
//
pub fn build(b: *std.Build) void {
    const target = preserveResolvedWindowsAbi(b.standardTargetOptions(.{}));
    const target_os = target.result.os.tag;
    const is_windows_target = target_os == .windows;
    const is_linux_target = target_os == .linux;
    const is_macos_target = target_os == .macos;
    // 릴리즈 version의 단일 원본은 build.zig.zon. About/log, platform metadata,
    // package 이름은 검증된 파생 규칙(build/version.zig)으로만 만든다.
    const app_version = versioning.derive(b.allocator, manifest.version) catch |err|
        std.debug.panic("invalid build.zig.zon version '{s}': {s}", .{ manifest.version, @errorName(err) });
    // macOS code-signing identity. 일반 install build와 universal package build가
    // 반드시 같은 값을 사용해야 최종 `.app`의 identity가 중간 arch build와
    // 어긋나지 않는다 (#109). default `-`는 ad-hoc.
    const macos_sign_identity = b.option(
        []const u8,
        "macos-sign-identity",
        "macOS codesign identity. default `-` (ad-hoc). stable self-signed cert 사용 시 그 이름 (예: \"TildazLocal\").",
    ) orelse "-";
    // #200 — default 가 ReleaseFast 면 runtime safety check 모두 비활성
    // (overflow / null deref / array bounds 등 silently 통과) → 개발 사이클의
    // 버그가 production 까지 새어 나감. Debug 가 default — 안전성 + 진단 가능성
    // 우선. 빌드 시간 손해는 dev 경험에서 회복. 릴리즈는 GitHub Actions가
    // `-Doptimize=ReleaseFast`를 명시한다.
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

    // 컴파일 타임 상수 — About 다이얼로그 / `--version` / tildaz.log 의 boot 엔트리에서
    // 사용. 세 값을 사람이 읽는 한 줄로 합치는 규칙은 `src/version.zig` 한 곳에 있다.
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", app_version.full);
    // #383 — 어느 커밋에서 빌드했나. git 이 없거나 `.git` 이 없는 소스 tarball 이면
    // 빈 문자열이고 버전 문자열에서 통째로 빠진다 (`build/git_version.zig`).
    const git = git_version.detect(b);
    build_opts.addOption([]const u8, "commit", git.commit);
    build_opts.addOption(bool, "commit_dirty", git.dirty);
    exe_mod.addOptions("build_options", build_opts);

    // #19 — 현재 Ghostty pin + Zig 0.16.0에서 Linux · macOS · Windows native
    // compile/link와 representative corpus 이득을 검증했다. 공식 ReleaseFast
    // pipeline은 `-Dsimd=true`를 명시한다. 기본 false는 Debug 개발 빌드와
    // 6-target cross-host check가 C++ toolchain/SDK까지 요구하지 않게 보존한다.
    const simd = b.option(bool, "simd", "ghostty VT stream SIMD 가속 활성화 (default: false; official release callers pass true)") orelse false;
    const simd_arg = if (simd) "true" else "false";
    // stress 하네스가 리포트에 찍는다 (#371) — SIMD 는 정확히 ghostty-vt 의 VT stream
    // 파서를 켜는 옵션이라, 어느 조합으로 잰 숫자인지 적지 않으면 비교가 성립하지 않는다.
    build_opts.addOption(bool, "simd", simd);

    // ghostty 의 build.zig 는 macOS 타겟이면 기본적으로 xcframework / macOS app
    // 까지 빌드하려고 들어서 (`Config.zig` 의 `emit_xcframework` / `emit_macos_app`
    // 기본값 참고) tildaz 처럼 ghostty-vt 모듈만 필요한 의존자를 panic 시킨다.
    // `emit-lib-vt = true` 가 정확히 그 케이스를 위한 ghostty 옵션 — xcframework /
    // macOS app / docs 빌드를 모두 끄고 vt 모듈만 빌드한다. Windows 에서는 어차피
    // 기본값이 false 라 동작에 변화가 없다.
    //
    // `font-backend = .freetype` 명시 — ghostty 의 build.zig 는 `emit-lib-vt` 여부와
    // 무관하게 `SharedDeps.init` 을 항상 돌리고, 거기서 `font_backend.hasFontconfig()`
    // 이 true 면 `lazyDependency("fontconfig")` 를 호출한다 (`SharedDeps.zig`). fontconfig
    // 은 다시 libxml2 를 끌어오는데, libxml2 tarball 은 Unix 심볼릭 링크(test fixtures)
    // 를 담고 있어 심볼릭 링크 권한 없는 Windows (Developer Mode off) 에선 unpack 이
    // AccessDenied 로 실패한다. font_backend 의 기본값은 타겟별 `FontBackend.default`
    // 라 Linux 등에서 `fontconfig_freetype` (hasFontconfig=true) 가 된다. `.freetype` 은
    // hasFontconfig=false 라 그 경로를 스킵 → libxml2 를 아예 안 받는다. VT 파서 모듈은
    // 폰트 백엔드를 실제로 쓰지 않으므로 값은 무방하고, 빌드 그래프 평가만 통과하면 된다.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .simd = simd,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        .@"font-backend" = .freetype,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    // TOML config 파서 (#493). ghostty 와 달리 lazy 가 아니다 — config 파싱은
    // 조건 없이 항상 필요하다 (ghostty 의 `uucode` 와 같은 성격).
    exe_mod.addImport("toml", b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    }).module("toml"));

    if (is_windows_target) {
        // PE VERSIONINFO 리소스 (Explorer 속성 / Task Manager 에서 버전 표시).
        const windows_resource = b.addConfigHeader(.{
            .style = .{ .autoconf_at = b.path("src/tildaz.rc.in") },
            .include_path = "tildaz.rc",
        }, .{
            .VERSION_MAJOR = app_version.windows_major,
            .VERSION_MINOR = app_version.windows_minor,
            .VERSION_PATCH = app_version.windows_patch,
            .VERSION_REVISION = app_version.windows_revision,
            .WINDOWS_FILE_FLAGS = app_version.windows_file_flags,
            .VERSION_FULL = app_version.full,
        });
        exe_mod.addWin32ResourceFile(.{
            .file = windows_resource.getOutputFile(),
            // generated RC와 icon의 디렉터리가 다르므로 llvm-rc include path로
            // source icon을 찾는다. 물리 경로를 template에 하드코딩하지 않는다.
            .include_paths = &.{b.path("src")},
        });
    }

    if (is_linux_target) {
        // Linux Wayland 키보드 입력은 런타임에 dlopen/dlsym 으로 libxkbcommon 을
        // 로드한다. xkbcommon 자체는 링크 타임 필수 의존성으로 만들지 않되,
        // 부분 ELF mapper 가 아니라 시스템 dynamic loader 를 사용하기 위한 libc.
        exe_mod.link_libc = true;
    }

    const macos_sdk_root = if (is_macos_target)
        b.option(
            []const u8,
            "macos-sdk",
            "macOS SDK root (cross-compile 시 필수, native 는 비워둠). 예: $(xcrun --show-sdk-path)",
        ) orelse ""
    else
        "";
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
        if (macos_sdk_root.len > 0) {
            exe_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{macos_sdk_root}) });
            exe_mod.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{macos_sdk_root}) });
        }
    }

    const exe = b.addExecutable(.{
        .name = "tildaz",
        .root_module = exe_mod,
    });
    if (is_windows_target) {
        exe.subsystem = .Windows;
    }

    if (is_linux_target) {
        // Zig 0.15 는 x86_64-linux Debug 에서 self-hosted backend + self-hosted ELF
        // 링커를 기본 쓰는데, 이 링커가 최신 GNU toolchain(예: GCC 16)이 crt1.o 에
        // 넣는 `.sframe` 섹션의 R_X86_64_PC64 relocation 을 처리하지 못해 링크가
        // fatal 로 실패한다. ReleaseSafe/Fast 는 기본 LLVM backend + LLD 라 정상인데
        // (그 차이가 원인 단서였다), self-hosted backend + LLD 조합도 불안정해서
        // (link command terminated unexpectedly) backend·linker 를 모두 LLVM/LLD 로
        // 맞춘다 = ReleaseSafe 와 동일 toolchain. optimize 모드(Debug)는 그대로 둬
        // 디버그 정보/safety check 는 유지된다. (Debug codegen 이 self-hosted 보다
        // 느려지는 게 유일한 trade-off.)
        exe.use_llvm = true;
        exe.use_lld = true;
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
        // ConfigHeader는 모든 출력 첫 줄에 C 주석을 넣으므로 XML plist에는 쓸
        // 수 없다. build runner가 @embedFile로 template 변경을 추적하고,
        // WriteFile은 주석 없이 정확한 XML만 생성한다.
        const macos_metadata = b.addWriteFiles();
        const macos_plist = macos_metadata.add("Info.plist", renderMacosPlist(b, app_version));
        const install_macos_plist = b.addInstallFile(macos_plist, "TildaZ.app/Contents/Info.plist");
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
        // 로컬 개발 시 `-Dmacos-sign-identity=TildazLocal` 로 self-signed
        // code-signing 인증서 사용 → identity stable → 권한 한 번만 부여하면
        // 다음 빌드에도 유지. self-signed 인증서 만드는 법: dist/macos/SETUP.md.
        // codesign 대상은 install prefix 기준 (`zig build -p <dir>` 으로 prefix
        // 바꿔도 그 dir 의 .app 을 서명). 하드코딩된 `zig-out/TildaZ.app` 은 #133
        // universal 작업 중 두 prefix 로 install 할 때 mismatch 원인.
        const app_path = b.fmt("{s}/TildaZ.app", .{b.install_path});
        const sign = b.addSystemCommand(&.{
            "codesign",
            "--force",
            "--sign",
            macos_sign_identity,
            app_path,
        });
        sign.step.dependOn(&install_macos_exe.step);
        sign.step.dependOn(&install_macos_plist.step);
        sign.step.dependOn(&install_macos_icon.step);
        b.getInstallStep().dependOn(&sign.step);
    } else {
        b.installArtifact(exe);
    }

    // stress 하네스도 같은 런타임을 exe 옆에 두고 실행해야 하므로 (아래 stress 단계)
    // install step 을 붙잡아 둡니다. Windows 아닌 target 에선 null 입니다.
    var conpty_dll_install: ?*std.Build.Step.InstallFile = null;
    var conpty_open_console_install: ?*std.Build.Step.InstallFile = null;
    // 테스트 단계도 같은 런타임을 테스트 바이너리 옆에 두고 실행해야 하므로 (#459)
    // arch 별 vendor 디렉토리를 붙잡아 둡니다. Windows 아닌 target 에선 null 입니다.
    var conpty_arch_dir: ?[]const u8 = null;
    if (is_windows_target) {
        // 번들 ConPTY 런타임(Microsoft.Windows.Console.ConPTY).
        // tildaz.exe 옆 `_internal\` 하위로 복사되어 conpty.dll 의
        // ConptyCreatePseudoConsole 이 sibling OpenConsole.exe 를 찾아 스폰합니다.
        // 최상위엔 tildaz.exe 만 남겨 사용자가 실행할 파일 혼동을 막고,
        // pty.zig 가 <exe dir>\_internal\conpty.dll 을 절대경로로 로드합니다.
        // 두 파일은 필수 — 누락 시 시작 검사가 에러로 막습니다 (fallback 없음, #339).
        //
        // target arch 별 native binary 선택 — PE32+ x86_64 / ARM64 별도 (PE loader
        // 가 arch mismatch 시 STATUS_INVALID_IMAGE_FORMAT 로 거부).
        const arch_dir: []const u8 = switch (target.result.cpu.arch) {
            .x86_64 => "vendor/conpty/x64",
            .aarch64 => "vendor/conpty/arm64",
            else => @panic("unsupported Windows arch — only x86_64 / aarch64 ConPTY bundle 제공"),
        };
        conpty_arch_dir = arch_dir;
        const conpty_dll_path = b.fmt("{s}/conpty.dll", .{arch_dir});
        const open_console_path = b.fmt("{s}/OpenConsole.exe", .{arch_dir});
        const dll_install = b.addInstallBinFile(b.path(conpty_dll_path), "_internal/conpty.dll");
        const open_console_install = b.addInstallBinFile(b.path(open_console_path), "_internal/OpenConsole.exe");
        b.getInstallStep().dependOn(&dll_install.step);
        b.getInstallStep().dependOn(&open_console_install.step);
        conpty_dll_install = dll_install;
        conpty_open_console_install = open_console_install;
    }

    // 실행 단계
    const run_step = b.step("run", "TildaZ 실행");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // 테스트 단계 — `main.zig`를 test root로 재사용하면 runtime main의 lazy
    // import가 test build에서 도달되지 않아 0개가 수집된다 (#318). test block이
    // 있는 모듈을 명시한 aggregate root를 별도 module로 구성한다.
    const test_step = b.step("test", "테스트 실행");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", build_opts);
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .simd = simd,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        .@"font-backend" = .freetype,
    })) |dep| {
        test_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    test_mod.addImport("toml", b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    }).module("toml"));
    if (is_linux_target) test_mod.link_libc = true;
    if (is_macos_target) {
        test_mod.linkSystemLibrary("objc", .{});
        test_mod.linkFramework("AppKit", .{});
        test_mod.linkFramework("Metal", .{});
        test_mod.linkFramework("QuartzCore", .{});
        test_mod.linkFramework("CoreGraphics", .{});
        test_mod.linkFramework("CoreFoundation", .{});
        test_mod.linkFramework("ApplicationServices", .{});

        if (macos_sdk_root.len > 0) {
            test_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{macos_sdk_root}) });
            test_mod.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{macos_sdk_root}) });
        }
    }
    const exe_tests = b.addTest(.{ .root_module = test_mod });
    if (is_linux_target) {
        exe_tests.use_llvm = true;
        exe_tests.use_lld = true;
    }
    if (conpty_arch_dir) |arch_dir| {
        // Windows — 테스트도 **install 된 경로에서** 실행한다 (#459). `addRunArtifact`
        // 는 테스트 바이너리를 zig 캐시의 output 디렉토리에서 바로 띄우는데, ConPTY
        // 경로는 실행파일 옆 `_internal\conpty.dll` 이 필수라 (#339 에서 kernel32
        // fallback 제거) 그 자리에서는 만들 수 없다 — 캐시 디렉토리는 내용이 hash 로
        // 봉인돼 런타임을 끼워 넣을 자리가 아니다. 그래서 `bundledRuntimeFilesPresent`
        // (모듈 경로 옆을 본다 — CWD 가 아니다) 가 false 를 내고 conpty 테스트가
        // `error.SkipZigTest` 로 빠져, Windows 에서도 그 테스트가 한 번도 검증되지
        // 않았다. stress 단계가 같은 이유로 쓰는 패턴 (#371) 과 같은 형태다.
        //
        // 릴리즈 번들 디렉토리에 test.exe 가 섞이지 않도록 `zig-out/bin` 이 아니라
        // 전용 `zig-out/test/` 로 install 한다.
        const test_dir = "test";
        const test_install = b.addInstallArtifact(exe_tests, .{
            .dest_dir = .{ .override = .{ .custom = test_dir } },
        });
        const test_dll_install = b.addInstallFile(
            b.path(b.fmt("{s}/conpty.dll", .{arch_dir})),
            b.fmt("{s}/_internal/conpty.dll", .{test_dir}),
        );
        const test_open_console_install = b.addInstallFile(
            b.path(b.fmt("{s}/OpenConsole.exe", .{arch_dir})),
            b.fmt("{s}/_internal/OpenConsole.exe", .{test_dir}),
        );
        const test_run = b.addSystemCommand(&.{
            b.getInstallPath(.{ .custom = test_dir }, exe_tests.out_filename),
        });
        test_run.step.dependOn(&test_install.step);
        test_run.step.dependOn(&test_dll_install.step);
        test_run.step.dependOn(&test_open_console_install.step);
        // 인자에 output file 이 없어 `infer_from_args` 로는 캐시 대상이 될 수 있다.
        // 테스트는 매번 실제로 돌아야 하므로 side-effects 를 명시한다 (`inherit` 은
        // 그와 동시에 test runner 의 요약 / 실패 지점을 그대로 흘려보내고, non-zero
        // exit 을 빌드 실패로 만든다).
        test_run.stdio = .inherit;
        test_step.dependOn(&test_run.step);
    } else {
        test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    }

    // package-manager / bundle / PE version 파생은 runtime source와 독립된 build
    // helper라 별도 test root로 수집한다. `zig build test`에서 항상 함께 실행.
    const version_test_mod = b.createModule(.{
        .root_source_file = b.path("build/version.zig"),
        .target = target,
        .optimize = optimize,
    });
    const version_tests = b.addTest(.{ .root_module = version_test_mod });
    test_step.dependOn(&b.addRunArtifact(version_tests).step);

    // stress / 처리량 하네스 단계 (#371 · #278).
    //
    //   zig build stress -- throughput --layer parser --mb 64 --workload plain
    //   zig build stress -- throughput --layer pty    --mb 64 --workload ansi
    //
    // 창도 렌더러도 없이 PTY → VT 경로만 돌려서 대용량 출력 소화 속도를 잰다.
    // Linux · macOS · Windows 에서 같은 명령이다 — 셸 스크립트를 쓰지 않는 이유는
    // `src/stress.zig` 문서 주석과 #371 코멘트에 있다.
    //
    // 측정은 공식 릴리즈와 같은 조합으로 한다:
    //   zig build stress -Doptimize=ReleaseFast -Dsimd=true -- throughput --layer pty
    const stress_step = b.step("stress", "stress / 처리량 하네스 실행 (#371 · #278)");
    const stress_mod = b.createModule(.{
        .root_source_file = b.path("src/stress.zig"),
        .target = target,
        .optimize = optimize,
    });
    stress_mod.addOptions("build_options", build_opts);
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .simd = simd,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        .@"font-backend" = .freetype,
    })) |dep| {
        stress_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    stress_mod.addImport("toml", b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    }).module("toml"));
    // 하네스는 창을 띄우지 않지만 `config.zig` 를 거쳐 dialog 경로가 그래프에 들어온다
    // (기본 scrollback 값을 앱과 같게 쓰기 위해). 그래서 link spec 은 test_mod 와 같다.
    if (is_linux_target) stress_mod.link_libc = true;
    if (is_macos_target) {
        stress_mod.linkSystemLibrary("objc", .{});
        stress_mod.linkFramework("AppKit", .{});
        stress_mod.linkFramework("Metal", .{});
        stress_mod.linkFramework("QuartzCore", .{});
        stress_mod.linkFramework("CoreGraphics", .{});
        stress_mod.linkFramework("CoreFoundation", .{});
        stress_mod.linkFramework("ApplicationServices", .{});

        if (macos_sdk_root.len > 0) {
            stress_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{macos_sdk_root}) });
            stress_mod.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{macos_sdk_root}) });
        }
    }
    const stress_exe = b.addExecutable(.{
        .name = "tildaz-stress",
        .root_module = stress_mod,
    });
    if (is_linux_target) {
        // 메인 exe 와 같은 이유 (self-hosted ELF 링커의 `.sframe` relocation 미지원).
        stress_exe.use_llvm = true;
        stress_exe.use_lld = true;
    }
    // 실행은 `addRunArtifact` 가 아니라 **install 된 `zig-out/bin` 경로**에서 한다.
    // `addRunArtifact` 는 zig 캐시의 output 디렉토리에서 바로 띄우는데, Windows 의
    // ConPTY 는 실행파일 옆 `_internal\conpty.dll` 이 필수라 (#339 에서 kernel32
    // fallback 제거) 그 자리에서는 만들 수 없다 — 캐시 디렉토리는 내용이 hash 로
    // 봉인돼 런타임을 끼워 넣을 자리가 아니다. Windows 실기에서 `--layer pty` ·
    // `frame` · `scrollback` 이 전부 곧바로 `error.ConptyRuntimeUnavailable` 로
    // 실패했다 (#371). `parser` 층만 PTY 를 안 써서 통과했다.
    //
    // platform 별로 갈라 두지 않는다 — 세 platform 이 같은 경로로 실행돼야 숫자를
    // 나란히 둘 수 있고, exe 옆 레이아웃이 릴리즈 번들과 같아진다.
    //
    // producer 자식도 `std.process.executablePath` 로 자기 경로를 띄우므로 (`stress.zig` 의
    // `ProducerSession.start`) 자식 역시 같은 디렉토리에서 돈다.
    const stress_install = b.addInstallArtifact(stress_exe, .{});
    const stress_run = b.addSystemCommand(&.{b.getInstallPath(.bin, stress_exe.out_filename)});
    stress_run.step.dependOn(&stress_install.step);
    if (conpty_dll_install) |s| stress_run.step.dependOn(&s.step);
    if (conpty_open_console_install) |s| stress_run.step.dependOn(&s.step);
    // 인자에 output file 이 없어 `infer_from_args` 로는 캐시 대상이 될 수 있다.
    // 측정은 매번 실제로 돌아야 하므로 side-effects 를 명시한다 (`inherit` 은 그와
    // 동시에 stdout 을 그대로 흘려 리포트가 보이게 하고, non-zero exit 을 실패로
    // 만든다 — 잘못된 인자에 usage + exit 2 를 내는 동작이 그대로 유지된다).
    stress_run.stdio = .inherit;
    if (b.args) |args| stress_run.addArgs(args);
    stress_step.dependOn(&stress_run.step);

    // 렌더 검증 화면 (#401 · #415 · #416 · #417 · #418).
    //
    //   zig build render-test
    //   tildaz -e <zig-out/bin/render-test> -size 88x33
    //
    // **`-size` 를 이 값으로 쓴다.** 화면은 62 줄이지만 그만큼 창을 키우면 노트북에서 아래가
    // 화면 밖으로 나간다 — 33 줄로 띄우고 스크롤로 본다. 폭 88 은 가장 긴 줄 기준이고, 줄이면
    // 줄바꿈이 생겨 `|` 정렬 판정이 깨진다.
    //
    // **세 platform 이 같은 프로그램을 띄운다.** 셸 스크립트로 같은 화면을 내려면 `printf`
    // 구현차 · cmd 의 CP949 · PowerShell 인코딩을 전부 맞춰야 하는데, 바이트를 프로그램
    // 안에 두면 그 변수가 사라진다. 실행은 `zig build` 가 아니라 **tildaz 가** 한다 —
    // 검증 대상이 tildaz 의 렌더 경로라서다. 그래서 run 단계 없이 install 만 한다.
    const render_test_mod = b.createModule(.{
        .root_source_file = b.path("src/render_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const render_test_exe = b.addExecutable(.{
        .name = "render-test",
        .root_module = render_test_mod,
    });
    if (is_linux_target) {
        // 메인 exe 와 같은 이유 (self-hosted ELF 링커의 `.sframe` relocation 미지원).
        render_test_exe.use_llvm = true;
        render_test_exe.use_lld = true;
    }
    const render_test_step = b.step("render-test", "결합 기호 · cluster 렌더 검증 화면 빌드 (tildaz -e 로 띄운다)");
    render_test_step.dependOn(&b.addInstallArtifact(render_test_exe, .{}).step);

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
    // 검사 대상 root. 앱 본체와 stress 하네스는 진입점이 달라 서로의 컴파일 에러를
    // 잡아주지 않는다 — 하네스도 세 platform 코드를 지나므로 (session_core · terminal
    // · config) 같이 돌린다. 하네스 그래프는 renderer / host 를 안 물어서 앱보다 작다.
    const check_roots = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "app", .path = "src/main.zig" },
        .{ .name = "stress", .path = "src/stress.zig" },
    };
    for (check_targets) |c| {
        const check_target = preserveResolvedWindowsAbi(b.resolveTargetQuery(c.query));
        for (check_roots) |root| {
            const check_mod = b.createModule(.{
                .root_source_file = b.path(root.path),
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
                // libxml2 회피 — 위 메인 빌드의 `font-backend` 주석 참고. check 는 linux
                // 타겟도 도는데, linux 기본 font_backend 는 fontconfig_freetype 이라 더더욱 필요.
                .@"font-backend" = .freetype,
            })) |dep| {
                check_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
            }

            check_mod.addImport("toml", b.dependency("toml", .{
                .target = target,
                .optimize = optimize,
            }).module("toml"));
            // OS-specific link spec 도 declare. *compile-only* 라 link 안 함이지만
            // host 코드의 일부 `extern` decl 이 module 의 link_libc / framework 마커를
            // 검사하는 케이스 일관성. mac framework / windows resource 는 compile
            // 자체엔 영향 없어 skip.
            if (c.query.os_tag == .linux) check_mod.link_libc = true;
            const check_obj = b.addObject(.{
                .name = b.fmt("tildaz-check-{s}-{s}", .{ root.name, c.name }),
                .root_module = check_mod,
            });
            check_step.dependOn(&check_obj.step);
        }
    }

    // 본체 빌드에 들어가지 않는 독립 진단 도구도 저장소가 안내하는 빌드 대상이다.
    // #451의 0.16 이전에서 `src/`만 검사해 세 도구의 제거 API가 남았으므로, 기본
    // `check`와 성격을 섞지 않고 전용 compile-only 단계에서 두 아키텍처를 확인한다.
    const probe_check_step = b.step("probe-check", "독립 Linux/Windows 진단 도구 compile-only verify (#451)");
    const probe_check_targets = [_]struct { name: []const u8, query: std.Target.Query }{
        .{ .name = "linux-x86_64", .query = .{ .os_tag = .linux, .cpu_arch = .x86_64, .abi = .gnu } },
        .{ .name = "linux-aarch64", .query = .{ .os_tag = .linux, .cpu_arch = .aarch64, .abi = .gnu } },
        .{ .name = "windows-x86_64", .query = .{ .os_tag = .windows, .cpu_arch = .x86_64 } },
        .{ .name = "windows-aarch64", .query = .{ .os_tag = .windows, .cpu_arch = .aarch64 } },
    };
    const probe_roots = [_]struct { name: []const u8, path: []const u8, os: std.Target.Os.Tag }{
        .{ .name = "dmabuf", .path = "dist/linux/dmabuf-probe.zig", .os = .linux },
        .{ .name = "osc-title", .path = "dist/linux/osc-title-probe.zig", .os = .linux },
        .{ .name = "osc-title", .path = "dist/windows/osc-title-probe.zig", .os = .windows },
    };
    for (probe_check_targets) |c| {
        for (probe_roots) |root| {
            if (c.query.os_tag != root.os) continue;
            const probe_mod = b.createModule(.{
                .root_source_file = b.path(root.path),
                .target = preserveResolvedWindowsAbi(b.resolveTargetQuery(c.query)),
                .optimize = .ReleaseSafe,
            });
            // 세 도구 모두 libc ABI의 PTY/Win32/DynLib 경로를 직접 쓴다.
            probe_mod.link_libc = true;
            const probe_obj = b.addObject(.{
                .name = b.fmt("tildaz-probe-{s}-{s}", .{ root.name, c.name }),
                .root_module = probe_mod,
            });
            probe_check_step.dependOn(&probe_obj.step);
        }
    }

    // 패키지 단계: 릴리즈용 번들 zip + SHA256 sidecar 생성.
    //
    //   zig build package -Doptimize=ReleaseFast -Dsimd=true                          → native Windows arch
    //   zig build package -Dtarget=aarch64-windows -Doptimize=ReleaseFast -Dsimd=true → arm64
    //     → 먼저 install 단계로 zig-out/bin/ 에 tildaz.exe + _internal/{conpty.dll,OpenConsole.exe}
    //     → PowerShell dist/windows/package.ps1 -Version <full-version>
    //        (세 PE header에서 x64/arm64를 판정하고 서로 일치하는지 검증)
    //        → zig-out/release/tildaz-v<ver>-win-<arch>.zip
    //        → zig-out/release/tildaz-v<ver>-win-<arch>.zip.sha256
    //
    // Windows package는 Windows PowerShell만 사용한다. WSL/Git Bash가 없는
    // 기본 Windows 개발 환경에서도 같은 native 경로로 동작한다 (#332).
    // macOS / Linux package만 각 host의 시스템 Bash를 사용한다.
    const package_step = b.step("package", "릴리즈 artifact + SHA256 sidecar 생성 (Windows zip / macOS dmg / Linux tar.gz·deb·rpm·AppImage)");
    if (is_windows_target) {
        const package_cmd = b.addSystemCommand(&.{
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "dist/windows/package.ps1",
            "-Version",
            app_version.full,
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
            app_version.full,
            "--sign-identity",
            macos_sign_identity,
            "--simd",
            simd_arg,
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
        const linux_package_version = if (std.mem.eql(u8, format, "deb"))
            app_version.debian_package
        else if (std.mem.eql(u8, format, "rpm"))
            app_version.rpm_package
        else if (std.mem.eql(u8, format, "pkg"))
            app_version.arch_package
        else
            app_version.full;
        const package_cmd = b.addSystemCommand(&.{
            "bash",
            "dist/linux/package.sh",
            "--version",
            app_version.full,
            "--package-version",
            linux_package_version,
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

fn renderMacosPlist(b: *std.Build, version: versioning.Derived) []const u8 {
    const template = @embedFile("dist/macos/Info.plist.in");
    const short_token = "@MACOS_SHORT_VERSION@";
    const build_token = "@MACOS_BUILD_VERSION@";
    if (std.mem.count(u8, template, short_token) != 1 or
        std.mem.count(u8, template, build_token) != 1)
    {
        @panic("dist/macos/Info.plist.in must contain each version token exactly once");
    }

    const with_short = std.mem.replaceOwned(
        u8,
        b.allocator,
        template,
        short_token,
        version.macos_short,
    ) catch @panic("OOM rendering macOS Info.plist");
    return std.mem.replaceOwned(
        u8,
        b.allocator,
        with_short,
        build_token,
        version.macos_build,
    ) catch @panic("OOM rendering macOS Info.plist");
}
