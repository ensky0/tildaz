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
//!     if (dialog.showConfirm("Quit", "Quit?")) { ... }   // OK/Cancel

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

/// OK / Cancel 두 버튼의 확인 다이얼로그. 실수 종료 방지 (#116) 같이
/// "되돌릴 수 없는 작업" 직전에 호출. default 버튼은 Cancel — 사용자가
/// 무심코 Enter 만 눌러도 작업이 진행되지 않게.
///
/// 반환: OK (Quit) → true, Cancel / 닫기 → false.
pub fn showConfirm(title: []const u8, message: []const u8) bool {
    return impl.showConfirm(title, message);
}
