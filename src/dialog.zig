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
const messages = @import("messages.zig");

pub const Severity = enum { info, err };

pub const HotkeyValidation = union(enum) {
    available,
    duplicate: u32,
    invalid,
    check_failed,
};

pub const HotkeyValidator = struct {
    ctx: *anyopaque,
    validate_fn: *const fn (ctx: *anyopaque, hotkey: []const u8) HotkeyValidation,

    pub fn validate(self: HotkeyValidator, hotkey: []const u8) HotkeyValidation {
        return self.validate_fn(self.ctx, hotkey);
    }
};

pub fn hotkeyValidationMessage(buf: []u8, result: HotkeyValidation) []const u8 {
    return switch (result) {
        .available => "",
        .duplicate => |index| std.fmt.bufPrint(buf, messages.new_instance_hotkey_duplicate_format, .{index}) catch messages.new_instance_hotkey_duplicate_fallback,
        .invalid => messages.new_instance_hotkey_invalid_msg,
        .check_failed => messages.new_instance_hotkey_check_failed_msg,
    };
}

test "hotkey validation messages identify the conflicting TildaZ instance" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", hotkeyValidationMessage(&buf, .available));
    try std.testing.expectEqualStrings("Already used by TildaZ 3.", hotkeyValidationMessage(&buf, .{ .duplicate = 3 }));
    try std.testing.expectEqualStrings(messages.new_instance_hotkey_check_failed_msg, hotkeyValidationMessage(&buf, .check_failed));
}

const impl = switch (builtin.os.tag) {
    .windows => @import("dialog/windows.zig"),
    .macos => @import("dialog/macos.zig"),
    .linux => @import("dialog/linux.zig"),
    else => @compileError("unsupported platform"),
};

/// #282 G8 — 종료 확인 메시지 조립. 탭 수 복수형 계산 + `quit_confirm_format`
/// 조립을 host 별 복제 대신 한 곳에 (n==0 skip 은 호출처 정책이라 여기 안 둠).
/// 반환 null = bufPrint 실패 → 호출처가 안전 종료로 판단.
pub fn quitConfirmMessage(buf: []u8, tab_count: usize) ?[]const u8 {
    const plural: []const u8 = if (tab_count == 1) "" else "s";
    return std.fmt.bufPrint(buf, messages.quit_confirm_format, .{ tab_count, plural }) catch null;
}

test "quit confirm message handles singular plural and small buffers" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("This will close 1 open tab.", quitConfirmMessage(&buf, 1).?);
    try std.testing.expectEqualStrings("This will close 2 open tabs.", quitConfirmMessage(&buf, 2).?);

    var too_small: [1]u8 = undefined;
    try std.testing.expect(quitConfirmMessage(&too_small, 2) == null);
}

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

/// 실제 key 조합을 캡처하는 modal dialog. Cancel / 닫기면 null, Create면
/// allocator-owned canonical hotkey 문자열을 반환한다.
pub fn promptHotkey(allocator: std.mem.Allocator, title: []const u8, message: []const u8, validator: HotkeyValidator) ?[]u8 {
    return impl.promptHotkey(allocator, title, message, validator);
}
