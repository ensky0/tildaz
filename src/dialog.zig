//! Cross-platform 사용자 다이얼로그 추상화. 모든 alert / info / error 표시의
//! 단일 진입점.
//!
//! 호출처가 platform-specific API (`MessageBoxW`, `osascript`, `NSAlert`) 를
//! 직접 부르지 않게 — 메시지 텍스트는 `messages.zig` 에서 한 곳에서 관리하고
//! 표시는 platform 모듈 (`dialog_windows.zig`, `dialog_macos.zig`) 이 처리.
//!
//! 사용 예:
//!     const dialog = @import("dialog.zig");
//!     dialog.showInfo("About tildaz", message);
//!     dialog.showError("TildaZ Config Error", err_msg);
//!     dialog.showFatal("TildaZ Config Error", err_msg);  // 종료까지

const std = @import("std");
const builtin = @import("builtin");

pub const Severity = enum { info, err };

const impl = switch (builtin.os.tag) {
    .windows => @import("dialog_windows.zig"),
    .macos => @import("dialog_macos.zig"),
    else => @compileError("unsupported platform"),
};

pub fn showInfo(title: []const u8, message: []const u8) void {
    impl.show(.info, title, message);
}

pub fn showError(title: []const u8, message: []const u8) void {
    impl.show(.err, title, message);
}

/// 에러 다이얼로그 표시 후 즉시 종료. config 검증 실패 같은 fatal 상황.
pub fn showFatal(title: []const u8, message: []const u8) noreturn {
    impl.show(.err, title, message);
    std.process.exit(1);
}
