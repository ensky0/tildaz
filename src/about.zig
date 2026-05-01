//! About / 버전 확인 다이얼로그.
//!   - Windows: F1 으로 띄운 후 Ctrl+Shift+I.
//!   - macOS: Shift+Cmd+I (mainMenu "About TildaZ" 의 keyEquivalent — 메뉴바
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
const paths = @import("paths.zig");

/// About 다이얼로그 표시. 호출 환경: F1 토글 후 Ctrl+Shift+I (Windows) /
/// Shift+Cmd+I (macOS) 등 일반 사용자 trigger.
///
/// 표시 경로는 모두 절대 경로 (`~` / `%APPDATA%` 같은 단축 안 씀) — SPEC.md
/// §11.3. 사용자가 그대로 vim / explorer 명령에 paste 가능 + 환경 ambiguity 제거.
pub fn showAboutDialog() void {
    var path_buf: [1024]u8 = undefined;
    const exe_path = currentExePath(&path_buf) catch "(unknown)";

    const pid: u64 = @intCast(switch (builtin.os.tag) {
        .windows => getCurrentProcessIdWindows(),
        else => std.c.getpid(),
    });

    var heap_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    const alloc = fba.allocator();
    const config_path = paths.configPath(alloc) catch "(unknown)";
    const log_path = paths.logPath(alloc) catch "(unknown)";

    var msg_buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, messages.about_format, .{
        build_options.version,
        exe_path,
        pid,
        config_path,
        log_path,
    }) catch return;

    // macOS 는 NSAlert.accessoryView 의 NSTextView 로 표시 — informativeText
    // (NSTextField) 는 setSelectable:YES 만으로 cmd+c 가 동작 안 함. NSTextView
    // 는 firstResponder + copy: 액션 정상 + monospace + 자연스러운 word
    // 더블클릭 선택. Windows 의 MessageBoxW 는 ctrl+c 자체 동작 OK.
    if (builtin.os.tag == .macos) {
        @import("dialog_macos.zig").showAboutAlert(messages.about_title, msg);
    } else {
        dialog.showInfo(messages.about_title, msg);
    }
}

fn currentExePath(buf: []u8) ![]const u8 {
    return std.fs.selfExePath(buf);
}

extern "kernel32" fn GetCurrentProcessId() callconv(.c) u32;

fn getCurrentProcessIdWindows() u32 {
    if (builtin.os.tag != .windows) return 0;
    return GetCurrentProcessId();
}
