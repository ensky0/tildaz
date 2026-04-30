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
const MB_ICONINFORMATION: c_uint = 0x40;
const MB_ICONERROR: c_uint = 0x10;

pub fn show(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    var title_buf: [256]WCHAR = undefined;
    var msg_buf: [4096]WCHAR = undefined;
    const tlen = std.unicode.utf8ToUtf16Le(&title_buf, title) catch return;
    const mlen = std.unicode.utf8ToUtf16Le(&msg_buf, message) catch return;
    if (tlen >= title_buf.len or mlen >= msg_buf.len) return;
    title_buf[tlen] = 0;
    msg_buf[mlen] = 0;

    const flags = MB_OK | switch (severity) {
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
