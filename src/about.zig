// Ctrl+Shift+I — About / 버전 확인 MessageBox.
//
// tildaz 는 WS_POPUP + WS_EX_TOOLWINDOW 라 타이틀바도 없고 Alt+Tab 목록에도
// 안 잡혀서, "지금 실행 중인 tildaz 가 어디 있는 어느 버전의 exe 인지" 를
// 사용자가 확인할 방법이 본체에 없었음. F1 로 창을 띄우고 Ctrl+Shift+I 를
// 누르면 버전 + exe 풀 경로 + pid 를 MessageBox 로 보여준다.

const std = @import("std");
const build_options = @import("build_options");

const WCHAR = u16;
const HANDLE = std.os.windows.HANDLE;
const DWORD = std.os.windows.DWORD;

extern "user32" fn MessageBoxW(?*anyopaque, [*:0]const WCHAR, [*:0]const WCHAR, c_uint) callconv(.c) c_int;
extern "kernel32" fn GetModuleFileNameW(?HANDLE, [*]WCHAR, DWORD) callconv(.c) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.c) DWORD;

const MB_OK: c_uint = 0x0;
const MB_ICONINFORMATION: c_uint = 0x40;

pub fn showAboutDialog(owner: ?*anyopaque) void {
    // 1. 현재 exe 의 풀 경로 (UTF-16 → UTF-8)
    var path_w: [300]WCHAR = undefined;
    const path_wlen = GetModuleFileNameW(null, &path_w, path_w.len);
    var path_u8: [600]u8 = undefined;
    const path_u8_len: usize = if (path_wlen > 0)
        (std.unicode.utf16LeToUtf8(&path_u8, path_w[0..path_wlen]) catch 0)
    else
        0;

    // 2. pid
    const pid = GetCurrentProcessId();

    // 3. 메시지 텍스트 조립 (UTF-8)
    var msg_u8: [1536]u8 = undefined;
    const msg_slice = std.fmt.bufPrint(&msg_u8, "tildaz v{s}\n\n" ++
        "exe : {s}\n" ++
        "pid : {d}\n\n" ++
        "https://github.com/ensky0/tildaz", .{
        build_options.version,
        path_u8[0..path_u8_len],
        pid,
    }) catch return;

    // 4. UTF-8 → UTF-16 (MessageBoxW 용)
    var msg_w: [2048]WCHAR = undefined;
    const msg_wlen = std.unicode.utf8ToUtf16Le(&msg_w, msg_slice) catch return;
    if (msg_wlen >= msg_w.len) return;
    msg_w[msg_wlen] = 0;

    const title = std.unicode.utf8ToUtf16LeStringLiteral("About tildaz");
    _ = MessageBoxW(
        owner,
        @ptrCast(msg_w[0..msg_wlen :0]),
        title,
        MB_OK | MB_ICONINFORMATION,
    );
}
