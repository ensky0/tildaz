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
const Runtime = @import("runtime.zig").Runtime;
const builtin = @import("builtin");
const log = @import("log.zig");
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
///
/// #483 — `pane_count` 가 `tab_count` 보다 크면 (= 어느 탭이 갈려 있으면) pane 수를 괄호로 덧붙인다.
/// 같으면 예전 문구 그대로다 — 분할을 안 쓰는 사용자에게 낯선 낱말을 보이지 않기 위해서다.
pub fn quitConfirmMessage(buf: []u8, tab_count: usize, pane_count: usize) ?[]const u8 {
    const plural: []const u8 = if (tab_count == 1) "" else "s";
    if (pane_count > tab_count) {
        return std.fmt.bufPrint(buf, messages.quit_confirm_panes_format, .{ tab_count, plural, pane_count }) catch null;
    }
    return std.fmt.bufPrint(buf, messages.quit_confirm_format, .{ tab_count, plural }) catch null;
}

test "quit confirm message handles singular plural and small buffers" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("This will close 1 open tab.", quitConfirmMessage(&buf, 1, 1).?);
    try std.testing.expectEqualStrings("This will close 2 open tabs.", quitConfirmMessage(&buf, 2, 2).?);

    var too_small: [1]u8 = undefined;
    try std.testing.expect(quitConfirmMessage(&too_small, 2, 2) == null);
}

test "#483 quit confirm names the panes only when a tab is actually split" {
    var buf: [64]u8 = undefined;
    // 갈린 탭이 있으면 사라지는 셸 수를 괄호로 — 탭 수만 적으면 1 탭 · 16 pane 도 "1 open tab" 이었다.
    try std.testing.expectEqualStrings("This will close 1 open tab (6 panes).", quitConfirmMessage(&buf, 1, 6).?);
    try std.testing.expectEqualStrings("This will close 2 open tabs (5 panes).", quitConfirmMessage(&buf, 2, 5).?);
    // 아무 탭도 안 갈렸으면 예전 문구 그대로.
    try std.testing.expectEqualStrings("This will close 3 open tabs.", quitConfirmMessage(&buf, 3, 3).?);
}

pub fn showInfo(rt: Runtime, title: []const u8, message: []const u8) void {
    impl.show(rt, .info, title, message);
}

/// 모든 dialog는 본문 자연 크기를 우선하고 화면을 넘을 때만 본문에 세로
/// scroll을 제공한다. 제목·button·prompt input/status는 고정한다. About은
/// 본문 selection/copy도 제공하므로 전용 진입점을 유지한다.
pub fn showAboutAlert(rt: Runtime, title: []const u8, message: []const u8) void {
    impl.showAboutAlert(rt, title, message);
}

pub fn showError(rt: Runtime, title: []const u8, message: []const u8) void {
    impl.show(rt, .err, title, message);
}

/// 에러 다이얼로그 표시 후 즉시 종료. config 검증 실패 같은 fatal 상황. platform
/// backend의 공통 overflow 정책을 따르며 Windows 저장 상한도 보존한다 (#316).
///
/// **나가기 전에 로그에 이유를 남긴다** ([#510](https://github.com/ensky0/tildaz/issues/510)).
/// 예전에는 다이얼로그를 *본 사람만* 이유를 알았다. Windows 실기 검증에서 전역 핫키
/// 등록이 막힌 회차의 로그가 `[startup] frame clock started` 에서 그냥 끊겼고 `hotkey` ·
/// `fatal` 어느 것도 한 줄이 없었다 (총 4 줄). 사용자가 그 로그를 이슈에 붙여 와도 왜
/// 죽었는지 알 수 없다는 뜻이라, 진단 자료라는 로그의 목적과 어긋난다.
///
/// **호출처마다 심지 않고 여기 한 곳에 둔다.** 이 함수가 세 platform 공통 진입점이고
/// `noreturn` 이라, 한 줄로 모든 fatal 경로가 덮인다 (오늘 호출처 9 곳). 새 fatal 을
/// 추가하는 사람이 로그를 잊을 자리가 아예 없어진다.
///
/// **다이얼로그보다 먼저 쓴다.** `impl.showFatal` 은 사용자가 창을 닫을 때까지 돌아오지
/// 않으므로, 뒤에 두면 창을 안 닫고 프로세스를 죽인 경우 아무것도 안 남는다.
pub fn showFatal(rt: Runtime, title: []const u8, message: []const u8) noreturn {
    var body_buf: [fatal_log_body_max]u8 = undefined;
    log.appendLine("fatal", "{s}: {s}", .{ title, collapseForLog(&body_buf, message) });
    impl.showFatal(rt, title, message);
    std.process.exit(1);
}

/// 로그 한 줄에 담을 fatal 본문의 상한. `log.appendLine` 의 2048 버퍼에서 timestamp ·
/// category · title 을 빼고도 남는 크기다.
const fatal_log_body_max = 1024;

const fatal_log_truncated_suffix = " ...";

/// 여러 줄 본문을 로그 **한 줄**로 접는다. 공백 · 줄바꿈이 이어지면 공백 하나로 줄이고,
/// `buf` 를 넘으면 자른 뒤 `" ..."` 를 붙인다.
///
/// **길이를 여기서 자르는 것이 핵심이다.** `log.appendLine` 은 버퍼를 넘기면 *아무것도
/// 쓰지 않고 돌아간다* (`bufPrint … catch return`). 그대로 넘기면 긴 config 오류에서
/// 로그가 지금과 똑같이 비어, 이 변경이 고치려는 증상이 그 경로에 그대로 남는다.
///
/// 자른 자리가 multi-byte 글자 가운데면 그 글자를 통째로 버린다 — 본문에 `•` 가 있다
/// (`messages.hotkey_registration_failed_format`).
fn collapseForLog(buf: []u8, message: []const u8) []const u8 {
    std.debug.assert(buf.len > fatal_log_truncated_suffix.len);
    const cap = buf.len - fatal_log_truncated_suffix.len;
    var len: usize = 0;
    var pending_space = false;
    var truncated = false;
    for (message) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n' => {
                // 앞이 비어 있으면 접을 것이 없다 — 선행 공백은 그냥 버린다.
                if (len != 0) pending_space = true;
            },
            else => {
                const need: usize = if (pending_space) 2 else 1;
                if (len + need > cap) {
                    truncated = true;
                    break;
                }
                if (pending_space) {
                    buf[len] = ' ';
                    len += 1;
                    pending_space = false;
                }
                buf[len] = c;
                len += 1;
            },
        }
    }
    if (!truncated) return buf[0..len];
    while (len > 0 and buf[len - 1] & 0xC0 == 0x80) len -= 1;
    if (len > 0 and buf[len - 1] & 0x80 != 0) len -= 1;
    @memcpy(buf[len..][0..fatal_log_truncated_suffix.len], fatal_log_truncated_suffix);
    return buf[0 .. len + fatal_log_truncated_suffix.len];
}

/// OK / Cancel 두 버튼의 확인 다이얼로그. "되돌릴 수 없는 작업"(종료 등) 직전에
/// 호출. #250 — 표준 매핑으로 전 플랫폼 통일: Enter=OK, Esc=Cancel. 다이얼로그
/// 출현 자체가 speed bump 라 실수 방지엔 충분 (#116 의 'Cancel 기본' 폐기).
///
/// 반환: OK (Quit) → true, Cancel / 닫기 → false.
pub fn showConfirm(rt: Runtime, title: []const u8, message: []const u8) bool {
    return impl.showConfirm(rt, title, message);
}

/// 실제 key 조합을 캡처하는 modal dialog. Cancel / 닫기면 null, Create면
/// allocator-owned canonical hotkey 문자열을 반환한다.
pub fn promptHotkey(rt: Runtime, allocator: std.mem.Allocator, title: []const u8, message: []const u8, validator: HotkeyValidator) ?[]u8 {
    return impl.promptHotkey(rt, allocator, title, message, validator);
}

test "#510 fatal 본문은 로그 한 줄로 접힌다" {
    var buf: [fatal_log_body_max]u8 = undefined;

    // 줄바꿈 연속 · 선행 공백 · 탭이 모두 공백 하나로 접힌다.
    try std.testing.expectEqualStrings(
        "a b c",
        collapseForLog(&buf, "  a\n\n b\t\tc  "),
    );
    try std.testing.expectEqualStrings("", collapseForLog(&buf, " \n\t "));
    try std.testing.expectEqualStrings("x", collapseForLog(&buf, "x"));
}

test "#510 실제 hotkey 실패 본문이 통째로 한 줄에 들어간다" {
    // 이 메시지가 접히다 잘리면 진단이 안 되므로, 상한이 실제 본문보다 넉넉한지를
    // 표본이 아니라 **그 본문 자체**로 확인한다.
    var msg_buf: [1024]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &msg_buf,
        messages.hotkey_registration_failed_format,
        .{ @as(u32, 0x7B), @as(u32, 0), "/home/me/.config/tildaz/config_9.toml" },
    );

    var buf: [fatal_log_body_max]u8 = undefined;
    const line = collapseForLog(&buf, message);
    try std.testing.expect(!std.mem.endsWith(u8, line, fatal_log_truncated_suffix));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, line, '\n'));
    // 잘리지 않았다면 F12 예약 안내가 그대로 살아 있어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, line, "kernel debugger") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "config_9.toml") != null);
}

test "#510 넘치면 잘리고 표시가 붙는다 — multi-byte 글자를 반토막 내지 않는다" {
    // `•` (U+2022, 3 byte) 가 상한에 정확히 걸치도록 채운다.
    var buf: [16]u8 = undefined;
    const line = collapseForLog(&buf, "aaaaaaaaaa\u{2022}bbbb");
    try std.testing.expect(std.mem.endsWith(u8, line, fatal_log_truncated_suffix));
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    try std.testing.expect(line.len <= buf.len);
}
