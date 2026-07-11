//! Windows 의 dialog 구현 — `MessageBoxW`. UTF-8 → UTF-16 변환 후 호출.
//! `dialog.zig` 에서 comptime 으로 select.

const std = @import("std");
const config = @import("../config.zig");
const dialog = @import("../dialog.zig");

const WCHAR = u16;
const HWND = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HMENU = ?*anyopaque;
const UINT = c_uint;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const DWORD = u32;

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?[*:0]const WCHAR,
    lpszClassName: [*:0]const WCHAR,
    hIconSm: ?*anyopaque,
};
const MSG = extern struct { hwnd: HWND, message: UINT, wParam: WPARAM, lParam: LPARAM, time: DWORD, pt_x: c_long, pt_y: c_long, lPrivate: DWORD };

extern "kernel32" fn GetModuleHandleW(?[*:0]const WCHAR) callconv(.c) HINSTANCE;
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.c) u16;
extern "user32" fn CreateWindowExW(DWORD, [*:0]const WCHAR, [*:0]const WCHAR, DWORD, c_int, c_int, c_int, c_int, HWND, HMENU, HINSTANCE, ?*anyopaque) callconv(.c) HWND;
extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT;
extern "user32" fn DestroyWindow(HWND) callconv(.c) c_int;
extern "user32" fn ShowWindow(HWND, c_int) callconv(.c) c_int;
extern "user32" fn SetFocus(HWND) callconv(.c) HWND;
extern "user32" fn GetMessageW(*MSG, HWND, UINT, UINT) callconv(.c) c_int;
extern "user32" fn TranslateMessage(*const MSG) callconv(.c) c_int;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.c) LRESULT;
extern "user32" fn IsDialogMessageW(HWND, *MSG) callconv(.c) c_int;
extern "user32" fn GetWindowTextLengthW(HWND) callconv(.c) c_int;
extern "user32" fn GetWindowTextW(HWND, [*]WCHAR, c_int) callconv(.c) c_int;
extern "user32" fn SetWindowTextW(HWND, [*:0]const WCHAR) callconv(.c) c_int;
extern "user32" fn EnableWindow(HWND, c_int) callconv(.c) c_int;
extern "user32" fn GetKeyState(c_int) callconv(.c) i16;
extern "user32" fn GetDpiForSystem() callconv(.c) UINT;
extern "user32" fn GetSystemMetrics(c_int) callconv(.c) c_int;

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
const IDCANCEL: usize = 2;
const WM_COMMAND: UINT = 0x0111;
const WM_CLOSE: UINT = 0x0010;
const WM_KEYDOWN: UINT = 0x0100;
const WM_SYSKEYDOWN: UINT = 0x0104;
const EN_CHANGE: usize = 0x0300;
const VK_BACK: usize = 0x08;
const VK_RETURN: usize = 0x0D;
const VK_SHIFT: usize = 0x10;
const VK_CONTROL: usize = 0x11;
const VK_MENU: usize = 0x12;
const VK_ESCAPE: usize = 0x1B;
const VK_LWIN: usize = 0x5B;
const VK_RWIN: usize = 0x5C;
const WS_VISIBLE: DWORD = 0x10000000;
const WS_CHILD: DWORD = 0x40000000;
const WS_CAPTION: DWORD = 0x00C00000;
const WS_SYSMENU: DWORD = 0x00080000;
const WS_TABSTOP: DWORD = 0x00010000;
const WS_BORDER: DWORD = 0x00800000;
const ES_AUTOHSCROLL: DWORD = 0x0080;
const ES_READONLY: DWORD = 0x0800;
const BS_DEFPUSHBUTTON: DWORD = 0x0001;
const WS_EX_TOPMOST: DWORD = 0x00000008;
const WS_EX_CLIENTEDGE: DWORD = 0x00000200;
const SW_SHOW: c_int = 5;
const SM_CXSCREEN: c_int = 0;
const SM_CYSCREEN: c_int = 1;

fn scaled(value: c_int, dpi: UINT) c_int {
    return @intCast(@divTrunc(@as(i64, value) * dpi + 48, 96));
}

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

var prompt_done = false;
var prompt_ok = false;
var prompt_edit: HWND = null;
var prompt_create: HWND = null;
var prompt_class_registered = false;
const prompt_class_name = std.unicode.utf8ToUtf16LeStringLiteral("TildaZPromptWindow");

fn promptWndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.c) LRESULT {
    if (msg == WM_COMMAND) {
        const id = wparam & 0xffff;
        const notification = (wparam >> 16) & 0xffff;
        if (id == 100 and notification == EN_CHANGE and prompt_edit != null and prompt_create != null) {
            _ = EnableWindow(prompt_create, if (promptHasText()) 1 else 0);
            return 0;
        }
        if (id == IDOK or id == IDCANCEL) {
            prompt_ok = id == IDOK;
            prompt_done = true;
            return 0;
        }
    } else if (msg == WM_CLOSE) {
        prompt_ok = false;
        prompt_done = true;
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn promptHasText() bool {
    if (prompt_edit == null) return false;
    var wide: [256]WCHAR = undefined;
    const copied = GetWindowTextW(prompt_edit, &wide, wide.len);
    if (copied <= 0) return false;
    for (wide[0..@intCast(copied)]) |char| {
        if (char != ' ' and char != '\t' and char != '\r' and char != '\n') return true;
    }
    return false;
}

fn handlePromptKey(vkey: usize) bool {
    if (vkey == VK_ESCAPE) {
        prompt_ok = false;
        prompt_done = true;
        return true;
    }
    if (vkey == VK_RETURN) {
        if (promptHasText()) {
            prompt_ok = true;
            prompt_done = true;
        }
        return true;
    }
    if (vkey == VK_BACK) {
        _ = SetWindowTextW(prompt_edit, std.unicode.utf8ToUtf16LeStringLiteral(""));
        return true;
    }
    if (vkey == VK_SHIFT or vkey == VK_CONTROL or vkey == VK_MENU or vkey == VK_LWIN or vkey == VK_RWIN) return true;

    var modifiers: u32 = 0;
    if (GetKeyState(VK_MENU) < 0) modifiers |= config.CAPTURE_MOD_ALT;
    if (GetKeyState(VK_CONTROL) < 0) modifiers |= config.CAPTURE_MOD_CTRL;
    if (GetKeyState(VK_SHIFT) < 0) modifiers |= config.CAPTURE_MOD_SHIFT;
    if (GetKeyState(VK_LWIN) < 0 or GetKeyState(VK_RWIN) < 0) modifiers |= config.CAPTURE_MOD_PRIMARY;
    var text_buf: [64]u8 = undefined;
    const captured = config.capturedHotkeyText(&text_buf, @intCast(vkey), modifiers) orelse return true;
    var wide_buf: [128]WCHAR = undefined;
    const len = std.unicode.utf8ToUtf16Le(&wide_buf, captured) catch return true;
    wide_buf[len] = 0;
    _ = SetWindowTextW(prompt_edit, @ptrCast(wide_buf[0..len :0]));
    return true;
}

fn ensurePromptClass(hinstance: HINSTANCE) bool {
    if (prompt_class_registered) return true;
    const wc = WNDCLASSEXW{ .cbSize = @sizeOf(WNDCLASSEXW), .style = 0, .lpfnWndProc = promptWndProc, .cbClsExtra = 0, .cbWndExtra = 0, .hInstance = hinstance, .hIcon = null, .hCursor = null, .hbrBackground = @ptrFromInt(6), .lpszMenuName = null, .lpszClassName = prompt_class_name, .hIconSm = null };
    if (RegisterClassExW(&wc) == 0) return false;
    prompt_class_registered = true;
    return true;
}

pub fn promptHotkey(allocator: std.mem.Allocator, title: []const u8, message: []const u8) ?[]u8 {
    const hinstance = GetModuleHandleW(null);
    if (!ensurePromptClass(hinstance)) return null;
    var title_buf: [256]WCHAR = undefined;
    var message_buf: [1024]WCHAR = undefined;
    const title_len = std.unicode.utf8ToUtf16Le(&title_buf, title) catch return null;
    const message_len = std.unicode.utf8ToUtf16Le(&message_buf, message) catch return null;
    title_buf[title_len] = 0;
    message_buf[message_len] = 0;
    const dpi = GetDpiForSystem();
    const win_w = scaled(540, dpi);
    const win_h = scaled(240, dpi);
    const win_x = @divTrunc(GetSystemMetrics(SM_CXSCREEN) - win_w, 2);
    const win_y = @divTrunc(GetSystemMetrics(SM_CYSCREEN) - win_h, 2);
    const hwnd = CreateWindowExW(WS_EX_TOPMOST, prompt_class_name, @ptrCast(title_buf[0..title_len :0]), WS_CAPTION | WS_SYSMENU | WS_VISIBLE, win_x, win_y, win_w, win_h, null, null, hinstance, null) orelse return null;
    defer _ = DestroyWindow(hwnd);
    _ = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), @ptrCast(message_buf[0..message_len :0]), WS_CHILD | WS_VISIBLE, scaled(20, dpi), scaled(18, dpi), scaled(490, dpi), scaled(70, dpi), hwnd, null, hinstance, null);
    prompt_edit = CreateWindowExW(WS_EX_CLIENTEDGE, std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), std.unicode.utf8ToUtf16LeStringLiteral(""), WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_BORDER | ES_AUTOHSCROLL | ES_READONLY, scaled(20, dpi), scaled(98, dpi), scaled(490, dpi), scaled(28, dpi), hwnd, @ptrFromInt(100), hinstance, null);
    prompt_create = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral("Create"), WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, scaled(300, dpi), scaled(155, dpi), scaled(100, dpi), scaled(32, dpi), hwnd, @ptrFromInt(IDOK), hinstance, null);
    if (prompt_create != null) _ = EnableWindow(prompt_create, 0);
    _ = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral("Cancel"), WS_CHILD | WS_VISIBLE | WS_TABSTOP, scaled(410, dpi), scaled(155, dpi), scaled(100, dpi), scaled(32, dpi), hwnd, @ptrFromInt(IDCANCEL), hinstance, null);
    _ = ShowWindow(hwnd, SW_SHOW);
    _ = SetFocus(prompt_edit);
    prompt_done = false;
    prompt_ok = false;
    var msg: MSG = undefined;
    while (!prompt_done and GetMessageW(&msg, null, 0, 0) > 0) {
        if ((msg.message == WM_KEYDOWN or msg.message == WM_SYSKEYDOWN) and handlePromptKey(msg.wParam)) continue;
        if (IsDialogMessageW(hwnd, &msg) == 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
    }
    if (!prompt_ok or prompt_edit == null) return null;
    const len = GetWindowTextLengthW(prompt_edit);
    if (len < 0 or len > 255) return null;
    var wide: [256]WCHAR = undefined;
    const copied = GetWindowTextW(prompt_edit, &wide, wide.len);
    if (copied < 0) return null;
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..@intCast(copied)]) catch null;
}
