//! Windows 의 dialog 구현 — `MessageBoxW`. UTF-8 → UTF-16 변환 후 호출.
//! `dialog.zig` 에서 comptime 으로 select.

const std = @import("std");
const dialog = @import("dialog.zig");

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

pub fn show(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    var title_buf: [256]WCHAR = undefined;
    var msg_buf: [4096]WCHAR = undefined;
    const tlen = std.unicode.utf8ToUtf16Le(&title_buf, title) catch return;
    const mlen = std.unicode.utf8ToUtf16Le(&msg_buf, message) catch return;
    if (tlen >= title_buf.len or mlen >= msg_buf.len) return;
    title_buf[tlen] = 0;
    msg_buf[mlen] = 0;

    const flags = MB_OK | MB_TOPMOST | switch (severity) {
        .info => MB_ICONINFORMATION,
        .err => MB_ICONERROR,
    };
    _ = MessageBoxW(
        null,
        @ptrCast(msg_buf[0..mlen :0]),
        @ptrCast(title_buf[0..tlen :0]),
        flags,
    );
}

/// OK / Cancel 두 버튼 확인 다이얼로그 (#116). default 는 Cancel
/// (`MB_DEFBUTTON2`) — 사용자가 무심코 Enter 만 눌러도 종료가 진행되지 않게.
/// 반환: OK → true, Cancel / 닫기 → false.
pub fn showConfirm(title: []const u8, message: []const u8) bool {
    var title_buf: [256]WCHAR = undefined;
    var msg_buf: [4096]WCHAR = undefined;
    const tlen = std.unicode.utf8ToUtf16Le(&title_buf, title) catch return false;
    const mlen = std.unicode.utf8ToUtf16Le(&msg_buf, message) catch return false;
    if (tlen >= title_buf.len or mlen >= msg_buf.len) return false;
    title_buf[tlen] = 0;
    msg_buf[mlen] = 0;

    const result = MessageBoxW(
        null,
        @ptrCast(msg_buf[0..mlen :0]),
        @ptrCast(title_buf[0..tlen :0]),
        MB_OKCANCEL | MB_ICONQUESTION | MB_DEFBUTTON2 | MB_TOPMOST,
    );
    return result == IDOK;
}
