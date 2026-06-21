//! Cross-platform 사용자 다이얼로그 추상화. 모든 alert / info / error 표시의
//! 단일 진입점.
//!
//! 호출처가 platform-specific API (`MessageBoxW`, `osascript`, `NSAlert`) 를
//! 직접 부르지 않게 — 메시지 텍스트는 `messages.zig` 에서 한 곳에서 관리하고
//! 표시는 platform 모듈 (`dialog/windows.zig`, `dialog/macos.zig`) 이 처리.
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
    .windows => @import("dialog/windows.zig"),
    .macos => @import("dialog/macos.zig"),
    .linux => @import("dialog/linux.zig"),
    else => @compileError("unsupported platform"),
};

pub fn showInfo(title: []const u8, message: []const u8) void {
    impl.show(.info, title, message);
}

/// About 다이얼로그 — `showInfo` 의 특수 케이스. macOS 는 NSTextView
/// accessoryView 로 path 가독성 + cmd+c 정상 동작 (NSAlert 의 informativeText
/// 는 NSTextField 라 modal 안에서 firstResponder 라우팅이 깨짐). Windows 는
/// MessageBoxW 자체 ctrl+c 가 동작하므로 `showInfo` 와 동일.
pub fn showAboutAlert(title: []const u8, message: []const u8) void {
    impl.showAboutAlert(title, message);
}

pub fn showError(title: []const u8, message: []const u8) void {
    impl.show(.err, title, message);
}

/// 에러 다이얼로그 표시 후 즉시 종료. config 검증 실패 같은 fatal 상황.
pub fn showFatal(title: []const u8, message: []const u8) noreturn {
    impl.show(.err, title, message);
    std.process.exit(1);
}

/// OK / Cancel 두 버튼의 확인 다이얼로그. "되돌릴 수 없는 작업"(종료 등) 직전에
/// 호출. #250 — 표준 매핑으로 전 플랫폼 통일: Enter=OK, Esc=Cancel. 다이얼로그
/// 출현 자체가 speed bump 라 실수 방지엔 충분 (#116 의 'Cancel 기본' 폐기).
///
/// 반환: OK (Quit) → true, Cancel / 닫기 → false.
pub fn showConfirm(title: []const u8, message: []const u8) bool {
    return impl.showConfirm(title, message);
}
