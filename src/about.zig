//! About / 버전 확인 다이얼로그. Windows: F1 으로 띄운 후 Ctrl+Shift+I.
//! macOS: mainMenu 의 "About TildaZ" 항목 (Cmd+, 같은 단축키는 macOS 에서
//! Settings 표준이라 별도 단축키 없이 menu item).
//!
//! 두 platform 모두 같은 텍스트 (`messages.about_format`) 를 같은 다이얼로그
//! 모듈 (`dialog.showInfo`) 로 표시. exe 경로 / pid 만 platform-specific.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");

/// About 다이얼로그 표시. 호출 환경: F1 토글 후 Ctrl+Shift+I (Windows) /
/// mainMenu About (macOS) 등 일반 사용자 trigger.
pub fn showAboutDialog() void {
    var path_buf: [1024]u8 = undefined;
    const exe_path = currentExePath(&path_buf) catch "(unknown)";

    const pid: u64 = @intCast(switch (builtin.os.tag) {
        .windows => getCurrentProcessIdWindows(),
        else => std.c.getpid(),
    });

    var msg_buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, messages.about_format, .{
        build_options.version,
        exe_path,
        pid,
    }) catch return;

    dialog.showInfo(messages.about_title, msg);
}

fn currentExePath(buf: []u8) ![]const u8 {
    return std.fs.selfExePath(buf);
}

extern "kernel32" fn GetCurrentProcessId() callconv(.c) u32;

fn getCurrentProcessIdWindows() u32 {
    if (builtin.os.tag != .windows) return 0;
    return GetCurrentProcessId();
}
