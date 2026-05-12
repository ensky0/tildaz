// macOS auto-start: `~/Library/LaunchAgents/com.tildaz.app.plist`
//
// 사용자 로그인 시 launchd 가 plist 따라 우리 .app 의 main 바이너리를 실행.
// Windows 의 `autostart/windows.zig` (HKCU\...\Run) 와 동등.
//
// LaunchAgent 위치는 Apple 표준 — `man launchd.plist` 참고. plist 자체는
// 로그인 시 자동 load 라 file drop 만으로 충분 (`launchctl load` 호출 불필요).
// disable 시 file 삭제 + 현재 세션의 launched 인스턴스도 bootout.
//
// 라벨 (`com.tildaz.app`) 은 reverse-DNS — 다른 사용자 LaunchAgent 와 충돌 방지.

const std = @import("std");

const LABEL = "com.tildaz.app";

/// `~/Library/LaunchAgents/com.tildaz.app.plist` 경로 (allocator-based).
fn plistPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const dir = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents", .{home});
    defer allocator.free(dir);
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return std.fmt.allocPrint(allocator, "{s}/{s}.plist", .{ dir, LABEL });
}

/// 현재 .app 번들의 main 바이너리 절대경로 (`.../TildaZ.app/Contents/MacOS/tildaz`).
/// `selfExePath` 가 ad-hoc sign 환경에서도 .app 안 경로를 그대로 돌려준다.
fn currentExePath(allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const slice = try std.fs.selfExePath(&buf);
    return allocator.dupe(u8, slice);
}

/// auto-start 활성화 — LaunchAgent plist 작성. 이미 같은 내용이면 건드리지
/// 않는다. macOS 가 LaunchAgent 변경을 "background activity" 알림으로 보여줄
/// 수 있어서, 실제 변경이 있을 때만 파일 timestamp 를 바꾼다.
pub fn enable(allocator: std.mem.Allocator) !void {
    const exe = try currentExePath(allocator);
    defer allocator.free(exe);

    const path = try plistPath(allocator);
    defer allocator.free(path);

    const plist = try std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{s}</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    , .{ LABEL, exe });
    defer allocator.free(plist);

    if (std.fs.openFileAbsolute(path, .{})) |existing_file| {
        defer existing_file.close();
        if (existing_file.readToEndAlloc(allocator, 64 * 1024)) |existing| {
            defer allocator.free(existing);
            if (std.mem.eql(u8, existing, plist)) return;
        } else |_| {}
    } else |_| {}

    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(plist);
}

/// auto-start 비활성화 — plist 파일 삭제. 다음 로그인부터 효과 발생 (launchd 가
/// plist 없으면 등록 안 함). 즉시 현재 세션 bootout 이 필요하면 수동:
///   `launchctl bootout gui/$(id -u)/com.tildaz.app`
pub fn disable(allocator: std.mem.Allocator) void {
    const path = plistPath(allocator) catch return;
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch {};
}
