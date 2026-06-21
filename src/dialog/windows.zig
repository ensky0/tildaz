//! Windows 의 dialog 구현 — `MessageBoxW`. UTF-8 → UTF-16 변환 후 호출.
//! `dialog.zig` 에서 comptime 으로 select.

const std = @import("std");
const dialog = @import("../dialog.zig");

const WCHAR = u16;

extern "user32" fn MessageBoxW(
    hWnd: ?*anyopaque,
    lpText: [*:0]const WCHAR,
    lpCaption: [*:0]const WCHAR,
    uType: c_uint,
) callconv(.c) c_int;

const MB_OK: c_uint = 0x0;
const MB_OKCANCEL: c_uint = 0x1;
const MB_ICONINFORMATION: c_uint = 0x40;
const MB_ICONERROR: c_uint = 0x10;
const MB_ICONQUESTION: c_uint = 0x20;
const MB_DEFBUTTON2: c_uint = 0x100;
/// 다이얼로그 자체에 `WS_EX_TOPMOST` 부여 — 우리 메인 창이 topmost 라
/// 일반 z-order 의 MessageBox 가 그 뒤에 가려져 버튼을 누를 수 없는 사고
/// 방지. 메인 창과 같은 topmost 그룹 안에서 modal 다이얼로그가 더 늦게
/// 만들어진 쪽이 위로 올라옴.
const MB_TOPMOST: c_uint = 0x40000;

const IDOK: c_int = 1;

/// UTF-8 title / message 를 NUL-terminated WCHAR 버퍼에 인코딩 후 MessageBoxW
/// 호출. 변환 실패 / overflow 시 `default` 반환 (caller 가 적절한 fallback 결정).
fn messageBox(title: []const u8, message: []const u8, flags: c_uint, default: c_int) c_int {
    var title_buf: [256]WCHAR = undefined;
    var msg_buf: [4096]WCHAR = undefined;
    const tlen = std.unicode.utf8ToUtf16Le(&title_buf, title) catch return default;
    const mlen = std.unicode.utf8ToUtf16Le(&msg_buf, message) catch return default;
    if (tlen >= title_buf.len or mlen >= msg_buf.len) return default;
    title_buf[tlen] = 0;
    msg_buf[mlen] = 0;

    return MessageBoxW(
        null,
        @ptrCast(msg_buf[0..mlen :0]),
        @ptrCast(title_buf[0..tlen :0]),
        flags,
    );
}

pub fn show(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    const flags = MB_OK | MB_TOPMOST | switch (severity) {
        .info => MB_ICONINFORMATION,
        .err => MB_ICONERROR,
    };
    _ = messageBox(title, message, flags, 0);
}

/// About 다이얼로그 — Windows 의 MessageBoxW 는 자체 ctrl+c 동작 OK 라
/// `show(.info, ...)` 로 forward. macOS 측은 NSTextView accessoryView 로
/// path 가독성 + cmd+c 라우팅을 따로 처리. wrapper 시그니처 통일을 위해
/// 양쪽 platform 모두 같은 이름으로 노출.
pub fn showAboutAlert(title: []const u8, message: []const u8) void {
    show(.info, title, message);
}

/// OK / Cancel 두 버튼 확인 다이얼로그. #250 — 표준 매핑(Enter=OK, Esc=Cancel)
/// 으로 통일. 기본 버튼 = 첫 번째(OK) 이므로 `MB_DEFBUTTON2`(Cancel 기본) 제거 →
/// Enter=OK. Esc 는 MB_OKCANCEL 에서 항상 Cancel. (#116 의 'Cancel 기본 — Enter
/// 종료 방지' 폐기 — 다이얼로그 출현 자체가 speed bump.)
/// 반환: OK → true, Cancel / 닫기 → false.
pub fn showConfirm(title: []const u8, message: []const u8) bool {
    const result = messageBox(
        title,
        message,
        MB_OKCANCEL | MB_ICONQUESTION | MB_TOPMOST,
        0, // 변환 실패 → false (안전한 default).
    );
    return result == IDOK;
}
