//! About / 버전 확인 다이얼로그.
//!   - Windows: F1 으로 띄운 후 Ctrl+Shift+I.
//!   - macOS: Cmd+Shift+I (mainMenu "About TildaZ" 의 keyEquivalent — 메뉴바
//!     UI 는 Accessory mode 라 안 보이지만 키 dispatch 는 동작).
//!
//! Platform 별로 modifier 가 다른 이유: macOS 표준 modifier 가 Cmd, 다른 탭
//! 단축키 (Cmd+T/W/숫자/[/]) 와 일관성. 같은 *기능* 의 단축키지만 각 OS 표준
//! 에 맞게 다름 — Chrome / VS Code 같은 cross-platform 앱과 동일 패턴.
//!
//! 두 platform 모두 같은 텍스트 (`messages.about_format`) 를 같은 다이얼로그
//! 모듈 (`dialog.showInfo`) 로 표시. exe 경로 / pid 만 platform-specific.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");

/// About 다이얼로그 표시. 호출 환경: F1 토글 후 Ctrl+Shift+I (Windows) /
/// Cmd+Shift+I (macOS) 등 일반 사용자 trigger.
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
