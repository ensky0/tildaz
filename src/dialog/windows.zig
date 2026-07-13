//! Windows 의 dialog 구현 — `MessageBoxW`. UTF-8 → UTF-16 변환 후 호출.
//! `dialog.zig` 에서 comptime 으로 select.

const std = @import("std");
const config = @import("../config.zig");
const dialog = @import("../dialog.zig");

const WCHAR = u16;
const HWND = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HMENU = ?*anyopaque;
const HDC = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const HFONT = ?*anyopaque;
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
extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT;
extern "user32" fn GetSysColorBrush(c_int) callconv(.c) HBRUSH;
extern "user32" fn LoadCursorW(HINSTANCE, ?*const anyopaque) callconv(.c) ?*anyopaque;
extern "gdi32" fn CreateFontW(c_int, c_int, c_int, c_int, c_int, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, [*:0]const WCHAR) callconv(.c) HFONT;
extern "gdi32" fn DeleteObject(?*anyopaque) callconv(.c) c_int;
extern "gdi32" fn SelectObject(HDC, ?*anyopaque) callconv(.c) ?*anyopaque;
extern "user32" fn GetDC(HWND) callconv(.c) HDC;
extern "user32" fn ReleaseDC(HWND, HDC) callconv(.c) c_int;
extern "user32" fn DrawTextW(HDC, [*]const WCHAR, c_int, *RECT, UINT) callconv(.c) c_int;
// AdjustWindowRectExForDpi — Win10 1607+. 원하는 client 사각형 → 창 전체 사각형
// (title bar / 테두리를 실제 DPI 기준으로 더함). 이 프로세스는 이미 per-monitor
// DPI aware 라 사용 가능.
extern "user32" fn AdjustWindowRectExForDpi(*RECT, DWORD, c_int, DWORD, UINT) callconv(.c) c_int;

const RECT = extern struct { left: c_long, top: c_long, right: c_long, bottom: c_long };
const DT_CALCRECT: UINT = 0x0400;
const DT_WORDBREAK: UINT = 0x0010;
const DT_NOPREFIX: UINT = 0x0800;
extern "gdi32" fn SetBkMode(HDC, c_int) callconv(.c) c_int;
extern "gdi32" fn SetTextColor(HDC, DWORD) callconv(.c) DWORD;

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
const WM_SETFONT: UINT = 0x0030;
const WM_CTLCOLORSTATIC: UINT = 0x0138;
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
const SS_CENTER: DWORD = 0x00000001;
const SS_CENTERIMAGE: DWORD = 0x00000200;
const BS_DEFPUSHBUTTON: DWORD = 0x0001;
const WS_EX_TOPMOST: DWORD = 0x00000008;
const SW_SHOW: c_int = 5;
const SM_CXSCREEN: c_int = 0;
const SM_CYSCREEN: c_int = 1;
const COLOR_BTNFACE: c_int = 15;
const TRANSPARENT: c_int = 1;
const CLEARTYPE_QUALITY: DWORD = 5;
const FW_NORMAL: c_int = 400;
const FW_SEMIBOLD: c_int = 600;
const IDC_ARROW: ?*const anyopaque = @ptrFromInt(32512);

fn scaled(value: c_int, dpi: UINT) c_int {
    return @intCast(@divTrunc(@as(i64, value) * dpi + 48, 96));
}

fn createDialogFont(dpi: UINT, point_size: u32, weight: c_int) HFONT {
    const height: c_int = -@as(c_int, @intCast(@divTrunc(@as(u64, point_size) * dpi + 36, 72)));
    return CreateFontW(
        height,
        0,
        0,
        0,
        weight,
        0,
        0,
        0,
        1, // DEFAULT_CHARSET
        0,
        0,
        CLEARTYPE_QUALITY,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
}

fn setControlFont(control: HWND, font: HFONT) void {
    if (control == null or font == null) return;
    _ = SendMessageW(control, WM_SETFONT, @intFromPtr(font.?), 1);
}

fn rgb(r: u8, g: u8, b: u8) DWORD {
    return @as(DWORD, r) | (@as(DWORD, g) << 8) | (@as(DWORD, b) << 16);
}

/// UTF-8 을 WCHAR 버퍼에 codepoint 경계에서 잘라 인코딩 — buf 를 넘는 부분은
/// 버린다 (#282 C5). NUL 자리 위해 마지막 1칸을 비워 둠. 반환 = 기록된 WCHAR
/// 수(NUL 제외). 불완전/오류 byte 는 U+FFFD 로 치환해 항상 뭔가 표시.
/// UTF-16 units ≤ UTF-8 bytes 라 truncate 는 codepoint 를 쪼개지 않는다.
fn encodeTruncated(dst: []WCHAR, src: []const u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len and out + 2 < dst.len) { // +2: 최대 surrogate pair + NUL 여유
        const seq_len = std.unicode.utf8ByteSequenceLength(src[i]) catch {
            dst[out] = 0xFFFD;
            out += 1;
            i += 1;
            continue;
        };
        if (i + seq_len > src.len) break;
        const cp = std.unicode.utf8Decode(src[i .. i + seq_len]) catch {
            dst[out] = 0xFFFD;
            out += 1;
            i += 1;
            continue;
        };
        i += seq_len;
        if (cp < 0x10000) {
            if (out + 1 >= dst.len) break;
            dst[out] = @intCast(cp);
            out += 1;
        } else {
            // astral plane → UTF-16 surrogate pair.
            if (out + 2 >= dst.len) break;
            const v = cp - 0x10000;
            dst[out] = @intCast(0xD800 + (v >> 10));
            dst[out + 1] = @intCast(0xDC00 + (v & 0x3FF));
            out += 2;
        }
    }
    return out;
}

/// UTF-8 title / message 를 NUL-terminated WCHAR 버퍼에 인코딩 후 MessageBoxW
/// 호출. 한도 초과 시 잘라서라도 항상 표시 (#282 C5 — macOS 8KB / Linux 4096B
/// truncate 와 정합). 이전엔 overflow 시 dialog 없이 default 반환이라 긴
/// 메시지(예: config 검증 상세)에서 아무것도 안 떴다.
fn messageBox(title: []const u8, message: []const u8, flags: c_uint) c_int {
    var title_buf: [256]WCHAR = undefined;
    var msg_buf: [4096]WCHAR = undefined;
    const tlen = encodeTruncated(&title_buf, title);
    const mlen = encodeTruncated(&msg_buf, message);
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
    _ = messageBox(title, message, flags);
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
    // MessageBoxW 자체 실패(0 반환) 시 result != IDOK → false (안전 default).
    const result = messageBox(
        title,
        message,
        MB_OKCANCEL | MB_ICONQUESTION | MB_TOPMOST,
    );
    return result == IDOK;
}

var prompt_done = false;
var prompt_ok = false;
var prompt_edit: HWND = null;
var prompt_create: HWND = null;
var prompt_status: HWND = null;
var prompt_validator: ?dialog.HotkeyValidator = null;
var prompt_class_registered = false;
const prompt_class_name = std.unicode.utf8ToUtf16LeStringLiteral("TildaZPromptWindow");

fn promptWndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.c) LRESULT {
    if (msg == WM_COMMAND) {
        const id = wparam & 0xffff;
        if (id == IDOK) {
            if (!updatePromptValidation()) return 0;
            prompt_ok = true;
            prompt_done = true;
            return 0;
        }
        if (id == IDCANCEL) {
            prompt_ok = false;
            prompt_done = true;
            return 0;
        }
    } else if (msg == WM_CLOSE) {
        prompt_ok = false;
        prompt_done = true;
        return 0;
    } else if (msg == WM_CTLCOLORSTATIC) {
        const dc: HDC = @ptrFromInt(wparam);
        _ = SetBkMode(dc, TRANSPARENT);
        const child: HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (child == prompt_status) _ = SetTextColor(dc, rgb(196, 43, 28));
        const brush = GetSysColorBrush(COLOR_BTNFACE) orelse return 0;
        return @bitCast(@intFromPtr(brush));
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn promptText(buf: []u8) ?[]const u8 {
    if (prompt_edit == null) return null;
    var wide: [256]WCHAR = undefined;
    const copied = GetWindowTextW(prompt_edit, &wide, wide.len);
    if (copied <= 0) return null;
    const len = std.unicode.utf16LeToUtf8(buf, wide[0..@intCast(copied)]) catch return null;
    return buf[0..len];
}

fn updatePromptValidation() bool {
    var text_buf: [256]u8 = undefined;
    const text = promptText(&text_buf) orelse {
        if (prompt_create != null) _ = EnableWindow(prompt_create, 0);
        if (prompt_status != null) _ = SetWindowTextW(prompt_status, std.unicode.utf8ToUtf16LeStringLiteral(""));
        return false;
    };
    const result = if (prompt_validator) |validator| validator.validate(text) else dialog.HotkeyValidation.check_failed;
    const available = switch (result) {
        .available => true,
        else => false,
    };
    if (prompt_create != null) _ = EnableWindow(prompt_create, if (available) 1 else 0);
    var status_buf: [256]u8 = undefined;
    const status = dialog.hotkeyValidationMessage(&status_buf, result);
    var wide_buf: [512]WCHAR = undefined;
    const len = std.unicode.utf8ToUtf16Le(&wide_buf, status) catch return available;
    wide_buf[len] = 0;
    if (prompt_status != null) _ = SetWindowTextW(prompt_status, @ptrCast(wide_buf[0..len :0]));
    return available;
}

fn handlePromptKey(vkey: usize) bool {
    if (vkey == VK_ESCAPE) {
        prompt_ok = false;
        prompt_done = true;
        return true;
    }
    if (vkey == VK_RETURN) {
        if (updatePromptValidation()) {
            prompt_ok = true;
            prompt_done = true;
        }
        return true;
    }
    if (vkey == VK_BACK) {
        _ = SetWindowTextW(prompt_edit, std.unicode.utf8ToUtf16LeStringLiteral(""));
        _ = updatePromptValidation();
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
    _ = updatePromptValidation();
    return true;
}

fn ensurePromptClass(hinstance: HINSTANCE) bool {
    if (prompt_class_registered) return true;
    const wc = WNDCLASSEXW{ .cbSize = @sizeOf(WNDCLASSEXW), .style = 0, .lpfnWndProc = promptWndProc, .cbClsExtra = 0, .cbWndExtra = 0, .hInstance = hinstance, .hIcon = null, .hCursor = LoadCursorW(null, IDC_ARROW), .hbrBackground = @ptrFromInt(COLOR_BTNFACE + 1), .lpszMenuName = null, .lpszClassName = prompt_class_name, .hIconSm = null };
    if (RegisterClassExW(&wc) == 0) return false;
    prompt_class_registered = true;
    return true;
}

pub fn promptHotkey(allocator: std.mem.Allocator, title: []const u8, message: []const u8, validator: dialog.HotkeyValidator) ?[]u8 {
    const hinstance = GetModuleHandleW(null);
    if (!ensurePromptClass(hinstance)) return null;
    var title_buf: [256]WCHAR = undefined;
    var message_buf: [1024]WCHAR = undefined;
    const title_len = std.unicode.utf8ToUtf16Le(&title_buf, title) catch return null;
    const message_len = std.unicode.utf8ToUtf16Le(&message_buf, message) catch return null;
    title_buf[title_len] = 0;
    message_buf[message_len] = 0;
    const dpi = GetDpiForSystem();
    const ui_font = createDialogFont(dpi, 10, FW_NORMAL);
    defer {
        if (ui_font != null) _ = DeleteObject(ui_font);
    }
    const capture_font = createDialogFont(dpi, 16, FW_SEMIBOLD);
    defer {
        if (capture_font != null) _ = DeleteObject(capture_font);
    }
    // --- 세로 레이아웃: 메시지 실제 높이를 측정해 아래 컨트롤을 쌓고, 필요한
    //     client 높이에서 창 전체 크기를 역산 (고정 상수 대신 근본 방식 — 어떤
    //     메시지 길이 / DPI 에서도 안 잘림). 가로는 24pt 여백 + 472pt 폭 고정.
    const margin = scaled(24, dpi);
    const content_w = scaled(472, dpi);
    const gap = scaled(16, dpi);

    // 메시지 높이 측정 — ui_font 를 select 한 DC 에 DT_CALCRECT | DT_WORDBREAK.
    var msg_h: c_int = scaled(48, dpi);
    {
        const dc = GetDC(null);
        if (dc != null) {
            const prev = if (ui_font != null) SelectObject(dc, ui_font) else null;
            var calc = RECT{ .left = 0, .top = 0, .right = content_w, .bottom = 0 };
            _ = DrawTextW(dc, @ptrCast(message_buf[0..message_len].ptr), @intCast(message_len), &calc, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
            if (calc.bottom > 0) msg_h = @intCast(calc.bottom);
            if (prev != null) _ = SelectObject(dc, prev);
            _ = ReleaseDC(null, dc);
        }
    }

    // client 좌표로 각 컨트롤 위치를 위→아래로 누적.
    const edit_h = scaled(40, dpi); // 캡처된 키 표시 (큰 폰트)
    const status_h = scaled(28, dpi); // 에러 상태 텍스트
    const button_h = scaled(32, dpi);
    const button_w = scaled(96, dpi);
    const msg_y = scaled(20, dpi);
    const edit_y = msg_y + msg_h + gap;
    const status_y = edit_y + edit_h + scaled(4, dpi);
    const button_y = status_y + status_h + gap;
    const client_h = button_y + button_h + scaled(20, dpi);
    const client_w = margin + content_w + margin;
    const create_x = client_w - margin - button_w;
    const cancel_x = create_x - scaled(8, dpi) - button_w;

    // client 사각형 → 창 전체 사각형 (title bar / 테두리 실제 DPI 반영).
    var wr = RECT{ .left = 0, .top = 0, .right = client_w, .bottom = client_h };
    _ = AdjustWindowRectExForDpi(&wr, WS_CAPTION | WS_SYSMENU, 0, WS_EX_TOPMOST, dpi);
    const win_w = wr.right - wr.left;
    const win_h = wr.bottom - wr.top;
    const win_x = @divTrunc(GetSystemMetrics(SM_CXSCREEN) - win_w, 2);
    const win_y = @divTrunc(GetSystemMetrics(SM_CYSCREEN) - win_h, 2);
    const hwnd = CreateWindowExW(WS_EX_TOPMOST, prompt_class_name, @ptrCast(title_buf[0..title_len :0]), WS_CAPTION | WS_SYSMENU, win_x, win_y, win_w, win_h, null, null, hinstance, null) orelse return null;
    defer _ = DestroyWindow(hwnd);
    const message_control = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), @ptrCast(message_buf[0..message_len :0]), WS_CHILD | WS_VISIBLE, margin, msg_y, content_w, msg_h, hwnd, null, hinstance, null);
    prompt_edit = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), WS_CHILD | WS_VISIBLE | SS_CENTER | SS_CENTERIMAGE, margin, edit_y, content_w, edit_h, hwnd, @ptrFromInt(100), hinstance, null);
    prompt_status = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), WS_CHILD | WS_VISIBLE | SS_CENTER | SS_CENTERIMAGE, margin, status_y, content_w, status_h, hwnd, null, hinstance, null);
    const cancel = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral("Cancel"), WS_CHILD | WS_VISIBLE | WS_TABSTOP, cancel_x, button_y, button_w, button_h, hwnd, @ptrFromInt(IDCANCEL), hinstance, null);
    prompt_create = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral("Create"), WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, create_x, button_y, button_w, button_h, hwnd, @ptrFromInt(IDOK), hinstance, null);
    if (prompt_create != null) _ = EnableWindow(prompt_create, 0);
    setControlFont(message_control, ui_font);
    setControlFont(prompt_edit, capture_font);
    setControlFont(prompt_status, ui_font);
    setControlFont(cancel, ui_font);
    setControlFont(prompt_create, ui_font);
    _ = ShowWindow(hwnd, SW_SHOW);
    _ = SetFocus(hwnd);
    prompt_done = false;
    prompt_ok = false;
    prompt_validator = validator;
    defer {
        prompt_validator = null;
        prompt_status = null;
        prompt_create = null;
        prompt_edit = null;
    }
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
