// macOS auto-start: `~/Library/LaunchAgents/com.tildaz.app.plist`
//
// 사용자 로그인 시 launchd 가 plist 따라 `open -a TildaZ.app --args --autostart`
// 을 실행 — LaunchServices 가 우리 앱을 띄운다. Windows 의
// `autostart/windows.zig` (HKCU\...\Run) 와 동등.
//
// plist 가 우리 바이너리를 **직접** 지목하면 안 된다. launchd 는 plist 에 적힌
// 프로세스를 그 LaunchAgent job 의 본체로 보는데, `--autostart` launcher 는
// worker 를 spawn 한 뒤 곧바로 `exit(0)` 하는 설계다 (`main.zig` 의
// `runLauncher`). launcher 가 끝나면 launchd 가 job 을 닫으면서
// (`service inactive` → `shutting down` → `cleaning up` → `removing child`)
// 같은 job 의 worker 도 함께 사라진다. 실측 (재부팅 1회 + `launchctl kickstart`
// 재현 1회, 증상 동일): worker 가 AppKit 초기화를 마치고 Input Monitoring 권한을
// 요청하던 중 launcher 의 `exit(0)` 과 **같은 밀리초**에 끊겼고, 로그에는
// `[boot]` 만 남고 `config loaded` 도 `[exit]` 도 없었다. 종료 시그널의 종류는
// macOS 가 로그로 남기지 않아 확인하지 못했다.
//
// `open` 을 거치면 앱이 LaunchServices 의 별개 job
// (`application.me.ensky0.tildaz.…`) 으로 떠서 launcher 종료와 무관하게
// 살아남는다 — 같은 로그의 사용자 수동 실행 경로에서 대조 확인했다.

const std = @import("std");
const paths = @import("../paths.zig");
const Runtime = @import("../runtime.zig").Runtime;

const LABEL = "com.tildaz.app";

/// `.app` 번들 안에서 실행 중일 때 쓰는 `ProgramArguments` 항목 — 정상 경로.
/// `open` 이 LaunchServices 에 요청을 넘겨 앱을 별개 job 으로 띄운다.
const PROGRAM_ARGS_VIA_OPEN =
    \\        <string>/usr/bin/open</string>
    \\        <string>-a</string>
    \\        <string>{s}</string>
    \\        <string>--args</string>
    \\        <string>--autostart</string>
;

/// 번들 밖에서 실행 중일 때의 fallback (`zig-out/bin` 의 bare 바이너리 등).
/// `open` 으로 지목할 번들이 없어 바이너리를 직접 적는다 — 이 경로에는 위
/// 주석의 worker 동반 종료 문제가 그대로 남는다.
const PROGRAM_ARGS_DIRECT =
    \\        <string>{s}</string>
    \\        <string>--autostart</string>
;

/// `~/Library/LaunchAgents/com.tildaz.app.plist` 경로 (allocator-based).
fn plistPath(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    const home = try rt.envAlloc(allocator, "HOME");
    defer allocator.free(home);
    const dir = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents", .{home});
    defer allocator.free(dir);
    // #451 — `fs.makeDirAbsolute` ➡️ `Io.Dir.createDirAbsolute`. 공용 helper 를 쓴다
    // (`paths.ensureDir` = `createDirPath`) — 이미 있으면 성공이라 분기가 사라진다.
    try paths.ensureDir(rt, dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.plist", .{ dir, LABEL });
}

/// 현재 .app 번들의 main 바이너리 절대경로 (`.../TildaZ.app/Contents/MacOS/tildaz`).
/// `selfExePath` 가 ad-hoc sign 환경에서도 .app 안 경로를 그대로 돌려준다.
fn currentExePath(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // #451 — `fs.selfExePath` ➡️ `std.process.executablePath` (길이를 돌려준다).
    const n = try std.process.executablePath(rt.io, &buf);
    return allocator.dupe(u8, buf[0..n]);
}

/// exe 경로에서 `.app` 번들 root 를 뽑는다 — `open -a` 가 지목할 대상.
/// `.../TildaZ.app/Contents/MacOS/tildaz` → `.../TildaZ.app`.
/// 번들 구조가 아니면 null (호출자가 직접 실행 fallback 을 쓴다).
fn appBundlePath(exe: []const u8) ?[]const u8 {
    const macos_dir = std.Io.Dir.path.dirname(exe) orelse return null;
    if (!std.mem.endsWith(u8, macos_dir, "/Contents/MacOS")) return null;
    const contents_dir = std.Io.Dir.path.dirname(macos_dir) orelse return null;
    const bundle = std.Io.Dir.path.dirname(contents_dir) orelse return null;
    if (!std.mem.endsWith(u8, bundle, ".app")) return null;
    return bundle;
}

/// plist 본문 생성. 파일 쓰기와 분리해 두어 단위 테스트가 결과 XML 을 그대로
/// 고정한다 — plist 는 손으로 확인하기 어렵고 한 글자만 틀려도 launchd 가
/// 조용히 무시한다.
fn renderPlist(allocator: std.mem.Allocator, exe: []const u8) ![]u8 {
    const program_args = if (appBundlePath(exe)) |bundle|
        try std.fmt.allocPrint(allocator, PROGRAM_ARGS_VIA_OPEN, .{bundle})
    else
        try std.fmt.allocPrint(allocator, PROGRAM_ARGS_DIRECT, .{exe});
    defer allocator.free(program_args);

    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\{s}
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    , .{ LABEL, program_args });
}

/// auto-start 활성화 — LaunchAgent plist 작성. 이미 같은 내용이면 건드리지
/// 않는다. macOS 가 LaunchAgent 변경을 "background activity" 알림으로 보여줄
/// 수 있어서, 실제 변경이 있을 때만 파일 timestamp 를 바꾼다.
pub fn enable(rt: Runtime, allocator: std.mem.Allocator) !void {
    const exe = try currentExePath(rt, allocator);
    defer allocator.free(exe);

    const path = try plistPath(rt, allocator);
    defer allocator.free(path);

    const plist = try renderPlist(allocator, exe);
    defer allocator.free(plist);

    _ = try paths.writeFileIfChanged(rt, allocator, path, plist);
}

/// auto-start 비활성화 — plist 파일 삭제. 다음 로그인부터 효과 발생 (launchd 가
/// plist 없으면 등록 안 함). 즉시 현재 세션 bootout 이 필요하면 수동:
///   `launchctl bootout gui/$(id -u)/com.tildaz.app`
pub fn disable(rt: Runtime, allocator: std.mem.Allocator) void {
    const path = plistPath(rt, allocator) catch return;
    defer allocator.free(path);
    std.Io.Dir.deleteFileAbsolute(rt.io, path) catch {};
}

test "appBundlePath 는 .app 번들 root 만 인정한다" {
    try std.testing.expectEqualStrings(
        "/Applications/TildaZ.app",
        appBundlePath("/Applications/TildaZ.app/Contents/MacOS/tildaz").?,
    );
    // 번들 밖 bare 바이너리 — 직접 실행 fallback 이 필요한 경우.
    try std.testing.expect(appBundlePath("/usr/local/bin/tildaz") == null);
    // `Contents/MacOS` 아래가 아니면 번들 main 바이너리가 아니다.
    try std.testing.expect(appBundlePath("/tmp/TildaZ.app/Contents/tildaz") == null);
    // 두 단계 위가 `.app` 으로 끝나지 않으면 번들이 아니다.
    try std.testing.expect(appBundlePath("/tmp/Foo/Contents/MacOS/tildaz") == null);
}

test "renderPlist 는 번들 실행을 open 경유로 적는다" {
    const allocator = std.testing.allocator;
    const plist = try renderPlist(allocator, "/Applications/TildaZ.app/Contents/MacOS/tildaz");
    defer allocator.free(plist);
    try std.testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>com.tildaz.app</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>/usr/bin/open</string>
        \\        <string>-a</string>
        \\        <string>/Applications/TildaZ.app</string>
        \\        <string>--args</string>
        \\        <string>--autostart</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    , plist);
}

test "renderPlist 는 번들 밖 실행이면 바이너리를 직접 적는다" {
    const allocator = std.testing.allocator;
    const plist = try renderPlist(allocator, "/usr/local/bin/tildaz");
    defer allocator.free(plist);
    try std.testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>com.tildaz.app</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>/usr/local/bin/tildaz</string>
        \\        <string>--autostart</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    , plist);
}
