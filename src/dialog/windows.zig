//! Windows dialog 구현. 모든 정상 info/error/confirm/About/prompt는 TildaZ
//! branded custom modal window로 표시한다. custom window 생성 실패 때만
//! `MessageBoxIndirectW + MB_USERICON`을 비상 fallback으로 사용한다.
//! `dialog.zig` 에서 comptime 으로 select.

const std = @import("std");
const config = @import("../config.zig");
const dialog = @import("../dialog.zig");
const messages = @import("../messages.zig");
const ui_metrics = @import("../ui_metrics.zig");

const WCHAR = u16;
const HWND = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HMENU = ?*anyopaque;
const HDC = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const HFONT = ?*anyopaque;
const HICON = ?*anyopaque;
const HMONITOR = ?*anyopaque;
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
extern "kernel32" fn GetCurrentProcessId() callconv(.c) DWORD;
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
extern "user32" fn GetDpiForWindow(HWND) callconv(.c) UINT;
extern "user32" fn GetSystemMetrics(c_int) callconv(.c) c_int;
extern "user32" fn GetForegroundWindow() callconv(.c) HWND;
extern "user32" fn SetForegroundWindow(HWND) callconv(.c) c_int;
extern "user32" fn GetWindowThreadProcessId(HWND, ?*DWORD) callconv(.c) DWORD;
extern "user32" fn MonitorFromWindow(HWND, DWORD) callconv(.c) HMONITOR;
extern "user32" fn GetMonitorInfoW(HMONITOR, *MONITORINFO) callconv(.c) c_int;
extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT;
extern "user32" fn GetSysColor(c_int) callconv(.c) DWORD;
extern "user32" fn GetSysColorBrush(c_int) callconv(.c) HBRUSH;
extern "user32" fn LoadCursorW(HINSTANCE, ?*const anyopaque) callconv(.c) ?*anyopaque;
extern "gdi32" fn CreateFontW(c_int, c_int, c_int, c_int, c_int, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, [*:0]const WCHAR) callconv(.c) HFONT;
extern "gdi32" fn CreateSolidBrush(DWORD) callconv(.c) HBRUSH;
extern "gdi32" fn DeleteObject(?*anyopaque) callconv(.c) c_int;
extern "gdi32" fn SelectObject(HDC, ?*anyopaque) callconv(.c) ?*anyopaque;
extern "gdi32" fn SetBkColor(HDC, DWORD) callconv(.c) DWORD;
extern "user32" fn GetDC(HWND) callconv(.c) HDC;
extern "user32" fn ReleaseDC(HWND, HDC) callconv(.c) c_int;
extern "user32" fn DrawTextW(HDC, [*]const WCHAR, c_int, *RECT, UINT) callconv(.c) c_int;
// AdjustWindowRectExForDpi — Win10 1607+. 원하는 client 사각형 → 창 전체 사각형
// (title bar / 테두리를 실제 DPI 기준으로 더함). 이 프로세스는 이미 per-monitor
// DPI aware 라 사용 가능.
extern "user32" fn AdjustWindowRectExForDpi(*RECT, DWORD, c_int, DWORD, UINT) callconv(.c) c_int;

const RECT = extern struct { left: c_long, top: c_long, right: c_long, bottom: c_long };
const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};
const MSGBOXPARAMSW = extern struct {
    cbSize: UINT,
    hwndOwner: HWND,
    hInstance: HINSTANCE,
    lpszText: [*:0]const WCHAR,
    lpszCaption: [*:0]const WCHAR,
    dwStyle: DWORD,
    // MB_USERICON이면 문자열 pointer 대신 MAKEINTRESOURCE low-word 값도 받는다.
    // opaque pointer로 선언해야 resource ID 1의 의도된 비정렬 주소를 보존한다.
    lpszIcon: ?*const anyopaque,
    dwContextHelpId: usize,
    lpfnMsgBoxCallback: ?*const anyopaque,
    dwLanguageId: DWORD,
};
const DT_CALCRECT: UINT = 0x0400;
const DT_SINGLELINE: UINT = 0x0020;
const DT_WORDBREAK: UINT = 0x0010;
const DT_EDITCONTROL: UINT = 0x2000;
const DT_NOPREFIX: UINT = 0x0800;
extern "gdi32" fn SetBkMode(HDC, c_int) callconv(.c) c_int;
extern "gdi32" fn SetTextColor(HDC, DWORD) callconv(.c) DWORD;

extern "user32" fn MessageBoxIndirectW(*const MSGBOXPARAMSW) callconv(.c) c_int;
extern "user32" fn LoadIconW(HINSTANCE, ?*const anyopaque) callconv(.c) HICON;
extern "user32" fn LoadImageW(HINSTANCE, ?*const anyopaque, UINT, c_int, c_int, UINT) callconv(.c) HICON;
extern "user32" fn DestroyIcon(HICON) callconv(.c) c_int;

const MB_OK: c_uint = 0x0;
const MB_OKCANCEL: c_uint = 0x1;
const MB_USERICON: c_uint = 0x80;
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
const WS_BORDER: DWORD = 0x00800000;
const WS_VSCROLL: DWORD = 0x00200000;
const SS_CENTER: DWORD = 0x00000001;
const SS_ICON: DWORD = 0x00000003;
const SS_REALSIZECONTROL: DWORD = 0x00000040;
const SS_NOPREFIX: DWORD = 0x00000080;
const SS_CENTERIMAGE: DWORD = 0x00000200;
const BS_DEFPUSHBUTTON: DWORD = 0x0001;
const ES_MULTILINE: DWORD = 0x0004;
const ES_AUTOVSCROLL: DWORD = 0x0040;
const ES_NOHIDESEL: DWORD = 0x0100;
const ES_READONLY: DWORD = 0x0800;
const WS_EX_TOPMOST: DWORD = 0x00000008;
const SW_SHOW: c_int = 5;
const SM_CXSCREEN: c_int = 0;
const SM_CYSCREEN: c_int = 1;
const COLOR_BTNFACE: c_int = 15;
const TRANSPARENT: c_int = 1;
const OPAQUE: c_int = 2;
const CLEARTYPE_QUALITY: DWORD = 5;
const FW_NORMAL: c_int = 400;
const FW_SEMIBOLD: c_int = 600;
const IDC_ARROW: ?*const anyopaque = @ptrFromInt(32512);
const EM_SETSEL: UINT = 0x00B1;
const EM_GETRECT: UINT = 0x00B2;
const STM_SETIMAGE: UINT = 0x0172;
const IMAGE_ICON: UINT = 1;
const LR_DEFAULTCOLOR: UINT = 0;
const MONITOR_DEFAULTTONEAREST: DWORD = 2;
const tildaz_icon_resource: ?*const anyopaque = @ptrFromInt(1);

fn scaled(value: c_int, dpi: UINT) c_int {
    return @intCast(@divTrunc(@as(i64, value) * dpi + 48, 96));
}

fn dialogIconSize(dpi: UINT) c_int {
    return scaled(@intCast(ui_metrics.DIALOG_ICON_SIZE_PT), dpi);
}

fn dialogSeparatorHeight(dpi: UINT) c_int {
    return @max(1, scaled(@intCast(ui_metrics.DIALOG_SEPARATOR_THICKNESS_PT), dpi));
}

const DialogHeaderGeometry = struct {
    title_y: c_int,
    title_h: c_int,
    separator_y: c_int,
    separator_h: c_int,
    body_y: c_int,
};

fn dialogHeaderGeometry(icon_y: c_int, title_h: c_int, body_line_h: c_int, dpi: UINT) DialogHeaderGeometry {
    const title_y = icon_y + dialogIconSize(dpi) + scaled(@intCast(ui_metrics.DIALOG_ICON_GAP_PT), dpi);
    const separator_h = dialogSeparatorHeight(dpi);
    const separator_row_h = @max(body_line_h, separator_h);
    const separator_y = title_y + title_h + @divTrunc(separator_row_h - separator_h, 2);
    return .{
        .title_y = title_y,
        .title_h = title_h,
        .separator_y = separator_y,
        .separator_h = separator_h,
        .body_y = title_y + title_h + separator_row_h,
    };
}

fn dialogSeparatorColor() DWORD {
    const color = ui_metrics.DIALOG_SEPARATOR_COLOR;
    return rgb(color.r, color.g, color.b);
}

fn dialogBodyEditStyle(overflow: bool, preserve_selection: bool) DWORD {
    return WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY |
        (if (preserve_selection) ES_NOHIDESEL else 0) |
        (if (overflow) WS_VSCROLL else 0);
}

/// DrawTextW의 wrap 폭과 실제 multiline EDIT의 formatting 폭을 동일하게 한다.
/// EDIT의 기본 inset은 DPI/font에 따라 정해지므로 logical pixel 상수로 추정하지
/// 않고, 동일 font/style의 숨은 control에서 EM_GETRECT로 직접 측정한다.
fn dialogEditHorizontalInset(hinstance: HINSTANCE, parent_class: [*:0]const WCHAR, font: HFONT, dpi: UINT, work: RECT) ?c_int {
    const scratch_w = scaled(512, dpi);
    const scratch_h = scaled(128, dpi);
    const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
    const parent = CreateWindowExW(0, parent_class, empty, 0, work.left, work.top, scratch_w, scratch_h, null, null, hinstance, null) orelse return null;
    defer _ = DestroyWindow(parent);
    const edit = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        empty,
        dialogBodyEditStyle(false, false) & ~@as(DWORD, WS_VISIBLE),
        0,
        0,
        scratch_w,
        scratch_h,
        parent,
        null,
        hinstance,
        null,
    ) orelse return null;
    setControlFont(edit, font);

    var formatting = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = SendMessageW(edit, EM_GETRECT, 0, @bitCast(@intFromPtr(&formatting)));
    const format_w = formatting.right - formatting.left;
    if (format_w <= 0 or format_w > scratch_w) return null;
    return scratch_w - format_w;
}

fn dialogEditFormatWidth(control_w: c_int, horizontal_inset: c_int) c_int {
    return @max(1, control_w - horizontal_inset);
}

fn dialogControlBackgroundMode(child: HWND, body: HWND) c_int {
    return if (child == body) OPAQUE else TRANSPARENT;
}

fn dialogControlBrush(dc: HDC, child: HWND, body: HWND) HBRUSH {
    const mode = dialogControlBackgroundMode(child, body);
    _ = SetBkMode(dc, mode);
    if (mode == OPAQUE) _ = SetBkColor(dc, GetSysColor(COLOR_BTNFACE));
    return GetSysColorBrush(COLOR_BTNFACE);
}

fn brandedMessageBoxStyle(flags: c_uint) DWORD {
    return flags | MB_USERICON;
}

fn loadDialogIcon(hinstance: HINSTANCE, dpi: UINT) HICON {
    const size = dialogIconSize(dpi);
    return LoadImageW(hinstance, tildaz_icon_resource, IMAGE_ICON, size, size, LR_DEFAULTCOLOR);
}

fn createDialogIconControl(parent: HWND, hinstance: HINSTANCE, icon: HICON, dpi: UINT, client_w: c_int, y: c_int) bool {
    if (parent == null or icon == null) return false;
    const size = dialogIconSize(dpi);
    const x = @divTrunc(client_w - size, 2);
    const control = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        WS_CHILD | WS_VISIBLE | SS_ICON | SS_REALSIZECONTROL,
        x,
        y,
        size,
        size,
        parent,
        null,
        hinstance,
        null,
    ) orelse return false;
    const icon_param: LPARAM = @bitCast(@intFromPtr(icon.?));
    _ = SendMessageW(control, STM_SETIMAGE, IMAGE_ICON, icon_param);
    return true;
}

fn createDialogSeparatorControl(parent: HWND, hinstance: HINSTANCE, dpi: UINT, x: c_int, y: c_int, width: c_int) HWND {
    return CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        WS_CHILD | WS_VISIBLE,
        x,
        y,
        width,
        dialogSeparatorHeight(dpi),
        parent,
        null,
        hinstance,
        null,
    );
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

/// UTF-8 title / message 를 NUL-terminated WCHAR 버퍼에 인코딩 후
/// MessageBoxIndirectW + PE resource ID 1의 TildaZ icon으로 표시한다.
/// 호출. 한도 초과 시 잘라서라도 항상 표시 (#282 C5 — macOS 8KB / Linux 4096B
/// truncate 와 정합). 이전엔 overflow 시 dialog 없이 default 반환이라 긴
/// 메시지(예: config 검증 상세)에서 아무것도 안 떴다.
const message_box_text_capacity: usize = 4096;

fn messageBox(title: []const u8, message: []const u8, flags: c_uint) c_int {
    var title_buf: [256]WCHAR = undefined;
    var msg_buf: [message_box_text_capacity]WCHAR = undefined;
    const tlen = encodeTruncated(&title_buf, title);
    const mlen = encodeTruncated(&msg_buf, message);
    title_buf[tlen] = 0;
    msg_buf[mlen] = 0;

    const params = MSGBOXPARAMSW{
        .cbSize = @sizeOf(MSGBOXPARAMSW),
        .hwndOwner = null,
        .hInstance = GetModuleHandleW(null),
        .lpszText = @ptrCast(msg_buf[0..mlen :0]),
        .lpszCaption = @ptrCast(title_buf[0..tlen :0]),
        .dwStyle = brandedMessageBoxStyle(flags),
        .lpszIcon = tildaz_icon_resource,
        .dwContextHelpId = 0,
        .lpfnMsgBoxCallback = null,
        .dwLanguageId = 0,
    };
    return MessageBoxIndirectW(&params);
}

fn showNative(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    _ = severity;
    _ = messageBox(title, message, MB_OK | MB_TOPMOST);
}

test "Windows native and custom dialog icon metrics are branded and DPI-aware" {
    try std.testing.expect((brandedMessageBoxStyle(MB_OK) & MB_USERICON) != 0);
    try std.testing.expectEqual(@as(c_int, 64), dialogIconSize(96));
    try std.testing.expectEqual(@as(c_int, 96), dialogIconSize(144));
    try std.testing.expectEqual(@as(c_int, 128), dialogIconSize(192));

    const dpis = [_]UINT{ 96, 144, 192 };
    const separator_heights = [_]c_int{ 2, 3, 4 };
    for (dpis, separator_heights) |dpi, expected_height| {
        const icon_y = scaled(20, dpi);
        const title_h = scaled(24, dpi);
        const body_line_h = scaled(20, dpi);
        const header = dialogHeaderGeometry(icon_y, title_h, body_line_h, dpi);
        try std.testing.expectEqual(expected_height, dialogSeparatorHeight(dpi));
        try std.testing.expectEqual(icon_y + dialogIconSize(dpi) + scaled(@intCast(ui_metrics.DIALOG_ICON_GAP_PT), dpi), header.title_y);
        try std.testing.expectEqual(title_h, header.title_h);
        try std.testing.expect(header.separator_y >= header.title_y + header.title_h);
        try std.testing.expect(header.separator_y + header.separator_h <= header.body_y);
        try std.testing.expect(header.body_y > header.title_y + header.title_h);
    }
    try std.testing.expectEqual(@as(DWORD, 0), dialogBodyEditStyle(false, true) & WS_BORDER);
    try std.testing.expectEqual(@as(DWORD, 0), dialogBodyEditStyle(true, false) & WS_BORDER);
    try std.testing.expect((dialogBodyEditStyle(false, true) & WS_VSCROLL) == 0);
    try std.testing.expect((dialogBodyEditStyle(true, false) & WS_VSCROLL) != 0);
}

pub fn show(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    if (showScrollableText(title, message, false) == null) {
        showNative(severity, title, message);
    }
}

var scroll_done = false;
var scroll_result = false;
var scroll_body: HWND = null;
var scroll_separator: HWND = null;
var scroll_separator_brush: HBRUSH = null;
var scroll_class_registered = false;
const scroll_class_name = std.unicode.utf8ToUtf16LeStringLiteral("TildaZScrollableDialogWindow");

fn scrollWndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.c) LRESULT {
    if (msg == WM_COMMAND) {
        const id = wparam & 0xffff;
        if (id == IDOK) {
            scroll_result = true;
            scroll_done = true;
            return 0;
        }
        if (id == IDCANCEL) {
            scroll_result = false;
            scroll_done = true;
            return 0;
        }
    }
    if (msg == WM_CLOSE) {
        scroll_result = false;
        scroll_done = true;
        return 0;
    }
    if (msg == WM_CTLCOLORSTATIC) {
        const child: HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (child == scroll_separator and scroll_separator_brush != null) {
            return @bitCast(@intFromPtr(scroll_separator_brush.?));
        }
        const brush = dialogControlBrush(@ptrFromInt(wparam), child, scroll_body) orelse return 0;
        return @bitCast(@intFromPtr(brush));
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn ensureScrollClass(hinstance: HINSTANCE) bool {
    if (scroll_class_registered) return true;
    const class_icon = LoadIconW(hinstance, tildaz_icon_resource);
    const wc = WNDCLASSEXW{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = scrollWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = class_icon,
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .hbrBackground = @ptrFromInt(COLOR_BTNFACE + 1),
        .lpszMenuName = null,
        .lpszClassName = scroll_class_name,
        .hIconSm = class_icon,
    };
    if (RegisterClassExW(&wc) == 0) return false;
    scroll_class_registered = true;
    return true;
}

fn dialogEditTextAlloc(allocator: std.mem.Allocator, body: []const u8) ![:0]WCHAR {
    var extra: usize = 0;
    for (body, 0..) |byte, i| {
        if (byte == '\n' and (i == 0 or body[i - 1] != '\r')) extra += 1;
    }
    const normalized = try allocator.alloc(u8, body.len + extra);
    defer allocator.free(normalized);

    var out: usize = 0;
    for (body, 0..) |byte, i| {
        if (byte == '\n' and (i == 0 or body[i - 1] != '\r')) {
            normalized[out] = '\r';
            out += 1;
        }
        normalized[out] = byte;
        out += 1;
    }
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, normalized);
}

test "#314 Windows About conversion preserves long UTF-8 and normalizes line endings" {
    const body = "첫째 줄\n" ++ ("경로" ** 800) ++ "\n마지막 줄";
    const wide = try dialogEditTextAlloc(std.testing.allocator, body);
    defer std.testing.allocator.free(wide);
    const round_trip = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, wide);
    defer std.testing.allocator.free(round_trip);

    try std.testing.expect(round_trip.len > 2048);
    try std.testing.expect(std.mem.startsWith(u8, round_trip, "첫째 줄\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, round_trip, "\r\n마지막 줄"));
}

fn longestExplicitLineWidth(dc: HDC, text: []const WCHAR) c_int {
    var longest: c_int = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i < text.len and text[i] != '\r' and text[i] != '\n') continue;
        var line = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = DrawTextW(dc, text.ptr + start, @intCast(i - start), &line, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
        longest = @max(longest, @as(c_int, @intCast(line.right)));
        if (i < text.len and text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
        start = i + 1;
    }
    return longest;
}

fn wrappedDialogTextHeight(dc: HDC, text: []const WCHAR, content_w: c_int, horizontal_inset: c_int) c_int {
    var rect = RECT{
        .left = 0,
        .top = 0,
        .right = dialogEditFormatWidth(content_w, horizontal_inset),
        .bottom = 0,
    };
    _ = DrawTextW(dc, text.ptr, @intCast(text.len), &rect, DT_CALCRECT | DT_WORDBREAK | DT_EDITCONTROL | DT_NOPREFIX);
    return @max(0, rect.bottom);
}

fn dialogWorkArea(owner: HWND) RECT {
    const monitor = MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST);
    if (monitor != null) {
        var info = MONITORINFO{
            .cbSize = @sizeOf(MONITORINFO),
            .rcMonitor = undefined,
            .rcWork = undefined,
            .dwFlags = 0,
        };
        if (GetMonitorInfoW(monitor, &info) != 0) return info.rcWork;
    }
    return .{
        .left = 0,
        .top = 0,
        .right = GetSystemMetrics(SM_CXSCREEN),
        .bottom = GetSystemMetrics(SM_CYSCREEN),
    };
}

fn dialogOwner() HWND {
    const candidate = GetForegroundWindow();
    if (candidate == null) return null;
    var process_id: DWORD = 0;
    _ = GetWindowThreadProcessId(candidate, &process_id);
    return if (process_id == GetCurrentProcessId()) candidate else null;
}

/// null이면 본문이 화면 안에 들어오거나 custom window 준비에 실패해 caller가
/// native 경로를 사용해야 한다. 값이 있으면 window를 표시했으며 confirm 여부에
/// 따라 OK(true) / Cancel(false) 결과를 돌려준다.
fn showScrollableText(title: []const u8, body: []const u8, confirm: bool) ?bool {
    const allocator = std.heap.page_allocator;
    const title_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, title) catch return null;
    defer allocator.free(title_w);
    const body_w = dialogEditTextAlloc(allocator, body) catch return null;
    defer allocator.free(body_w);

    const hinstance = GetModuleHandleW(null);
    if (!ensureScrollClass(hinstance)) return null;

    // 현재 TildaZ window만 owner로 삼는다. focus가 다른
    // process로 넘어간 찰나에 그 앱 window를 disable하는 일은 없어야 한다.
    const owner = dialogOwner();
    const window_dpi = if (owner != null) GetDpiForWindow(owner) else 0;
    const dpi = if (window_dpi != 0) window_dpi else GetDpiForSystem();
    const title_font = createDialogFont(dpi, ui_metrics.DIALOG_TITLE_FONT_PT, FW_NORMAL);
    defer {
        if (title_font != null) _ = DeleteObject(title_font);
    }
    const body_font = createDialogFont(dpi, ui_metrics.DIALOG_BODY_FONT_PT, FW_NORMAL);
    defer {
        if (body_font != null) _ = DeleteObject(body_font);
    }
    const ui_font = createDialogFont(dpi, 10, FW_NORMAL);
    defer {
        if (ui_font != null) _ = DeleteObject(ui_font);
    }
    const work = dialogWorkArea(owner);
    const edit_horizontal_inset = dialogEditHorizontalInset(hinstance, scroll_class_name, body_font, dpi, work) orelse return null;
    const screen_w = work.right - work.left;
    const screen_h = work.bottom - work.top;
    const viewport_margin = scaled(16, dpi);
    const margin = scaled(24, dpi);
    const frame_style = WS_CAPTION | WS_SYSMENU;
    const frame_ex_style = WS_EX_TOPMOST;
    var frame = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = AdjustWindowRectExForDpi(&frame, frame_style, 0, frame_ex_style, dpi);
    const frame_w = frame.right - frame.left;
    const frame_h = frame.bottom - frame.top;

    const available_window_w = @max(1, screen_w - viewport_margin * 2);
    const max_window_w = @min(scaled(@intCast(ui_metrics.DIALOG_MAX_WIDTH_PT), dpi), available_window_w);
    const preferred_window_w = @min(scaled(@intCast(ui_metrics.DIALOG_PREFERRED_WIDTH_PT), dpi), max_window_w);
    const max_client_w = @max(1, max_window_w - frame_w);
    const preferred_client_w = @max(1, preferred_window_w - frame_w);
    const max_content_w = @max(1, max_client_w - margin * 2);
    const preferred_content_w = @max(1, preferred_client_w - margin * 2);
    const min_content_w = @min(scaled(472, dpi), preferred_content_w);
    var content_w = min_content_w;
    var wrapped_h = scaled(130, dpi);
    var title_h = scaled(24, dpi);
    var body_line_h = scaled(20, dpi);
    const dc = GetDC(null);
    if (dc != null) {
        const previous = if (title_font != null)
            SelectObject(dc, title_font)
        else if (body_font != null)
            SelectObject(dc, body_font)
        else
            null;
        var title_rect = RECT{ .left = 0, .top = 0, .right = max_content_w, .bottom = 0 };
        _ = DrawTextW(dc, title_w.ptr, @intCast(title_w.len), &title_rect, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
        if (title_rect.bottom > 0) title_h = @intCast(title_rect.bottom);
        const title_natural_w = @max(0, title_rect.right - title_rect.left);

        if (body_font != null) _ = SelectObject(dc, body_font);
        var body_line_rect = RECT{ .left = 0, .top = 0, .right = max_content_w, .bottom = 0 };
        const body_line_sample = std.unicode.utf8ToUtf16LeStringLiteral("Ag");
        _ = DrawTextW(dc, body_line_sample, 2, &body_line_rect, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
        if (body_line_rect.bottom > 0) body_line_h = @intCast(body_line_rect.bottom);
        const natural_w = longestExplicitLineWidth(dc, body_w);
        // EDIT의 border/formatting inset만큼 control 폭을 더 확보한 뒤 실제
        // formatting 폭으로 wrap 높이를 재서 경계의 마지막 줄도 보존한다.
        const desired_content_w = @max(
            @as(i64, title_natural_w),
            @as(i64, natural_w) + @as(i64, edit_horizontal_inset),
        );
        content_w = @intCast(std.math.clamp(desired_content_w, @as(i64, min_content_w), @as(i64, preferred_content_w)));
        const measured_h = wrappedDialogTextHeight(dc, body_w, content_w, edit_horizontal_inset);
        if (measured_h > 0) wrapped_h = measured_h + scaled(6, dpi);
        if (previous != null) _ = SelectObject(dc, previous);
        _ = ReleaseDC(null, dc);
    }

    const top = scaled(20, dpi);
    const header = dialogHeaderGeometry(top, title_h, body_line_h, dpi);
    const body_y = header.body_y;
    const gap = scaled(16, dpi);
    const button_h = scaled(32, dpi);
    const button_w = scaled(96, dpi);
    const bottom = scaled(20, dpi);
    const max_window_h = @max(1, screen_h - viewport_margin * 2);
    const max_client_h = @max(1, max_window_h - frame_h);
    const max_body_h = @max(1, max_client_h - body_y - gap - button_h - bottom);

    // preferred 폭에서 고정 chrome까지 합친 자연 높이가 screen을 넘을 때만
    // maximum 폭으로 확장해 다시 wrap한다.
    if (wrapped_h > max_body_h and content_w < max_content_w) {
        content_w = max_content_w;
        const measure_dc = GetDC(null);
        if (measure_dc != null) {
            const previous = if (body_font != null) SelectObject(measure_dc, body_font) else null;
            const measured_h = wrappedDialogTextHeight(measure_dc, body_w, content_w, edit_horizontal_inset);
            if (measured_h > 0) wrapped_h = measured_h + scaled(6, dpi);
            if (previous != null) _ = SelectObject(measure_dc, previous);
            _ = ReleaseDC(null, measure_dc);
        }
    }
    const body_h = @min(wrapped_h, max_body_h);
    const overflow = wrapped_h > body_h;
    const client_w = margin + content_w + margin;
    const button_y = body_y + body_h + gap;
    const client_h = button_y + button_h + bottom;

    var wr = RECT{ .left = 0, .top = 0, .right = client_w, .bottom = client_h };
    _ = AdjustWindowRectExForDpi(&wr, frame_style, 0, frame_ex_style, dpi);
    const win_w = wr.right - wr.left;
    const win_h = wr.bottom - wr.top;
    const win_x = work.left + @divTrunc(screen_w - win_w, 2);
    const win_y = work.top + @divTrunc(screen_h - win_h, 2);
    const dialog_icon = loadDialogIcon(hinstance, dpi) orelse return null;
    defer _ = DestroyIcon(dialog_icon);
    const separator_brush = CreateSolidBrush(dialogSeparatorColor()) orelse return null;
    defer _ = DeleteObject(separator_brush);
    defer {
        scroll_body = null;
        scroll_separator = null;
        scroll_separator_brush = null;
    }
    const hwnd = CreateWindowExW(
        frame_ex_style,
        scroll_class_name,
        title_w.ptr,
        frame_style,
        win_x,
        win_y,
        win_w,
        win_h,
        owner,
        null,
        hinstance,
        null,
    ) orelse return null;
    defer _ = DestroyWindow(hwnd);
    if (owner != null) {
        _ = EnableWindow(owner, 0);
        defer {
            _ = EnableWindow(owner, 1);
            _ = SetForegroundWindow(owner);
        }
    }
    if (!createDialogIconControl(hwnd, hinstance, dialog_icon, dpi, client_w, top)) return null;

    const title_control = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        title_w.ptr,
        WS_CHILD | WS_VISIBLE | SS_NOPREFIX,
        margin,
        header.title_y,
        content_w,
        header.title_h,
        hwnd,
        null,
        hinstance,
        null,
    ) orelse return null;
    setControlFont(title_control, title_font);

    const separator = createDialogSeparatorControl(hwnd, hinstance, dpi, margin, header.separator_y, content_w) orelse return null;
    scroll_separator = separator;
    scroll_separator_brush = separator_brush;

    const edit_style = dialogBodyEditStyle(overflow, true);
    const edit = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        edit_style,
        margin,
        body_y,
        content_w,
        body_h,
        hwnd,
        null,
        hinstance,
        null,
    ) orelse return null;
    scroll_body = edit;
    if (SetWindowTextW(edit, body_w.ptr) == 0) return null;
    _ = SendMessageW(edit, EM_SETSEL, 0, 0);

    const button_x = if (confirm)
        client_w - margin - button_w
    else
        @divTrunc(client_w - button_w, 2);
    const ok = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral(messages.button_ok),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
        button_x,
        button_y,
        button_w,
        button_h,
        hwnd,
        @ptrFromInt(IDOK),
        hinstance,
        null,
    ) orelse return null;
    const cancel = if (confirm) CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral(messages.button_cancel),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP,
        button_x - scaled(8, dpi) - button_w,
        button_y,
        button_w,
        button_h,
        hwnd,
        @ptrFromInt(IDCANCEL),
        hinstance,
        null,
    ) else null;
    if (confirm and cancel == null) return null;
    setControlFont(edit, body_font);
    setControlFont(ok, ui_font);
    setControlFont(cancel, ui_font);

    _ = ShowWindow(hwnd, SW_SHOW);
    _ = SetFocus(edit);
    scroll_done = false;
    scroll_result = false;
    var msg: MSG = undefined;
    while (!scroll_done and GetMessageW(&msg, null, 0, 0) > 0) {
        if ((msg.message == WM_KEYDOWN or msg.message == WM_SYSKEYDOWN) and
            (msg.wParam == VK_RETURN or msg.wParam == VK_ESCAPE))
        {
            scroll_result = msg.wParam == VK_RETURN;
            scroll_done = true;
            continue;
        }
        if (IsDialogMessageW(hwnd, &msg) == 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
    }
    return scroll_result;
}

/// About은 본문 선택·복사를 위해 항상 custom text window를 사용한다. 짧으면
/// 본문 자연 높이만 쓰고, 화면을 넘을 때만 OS scrollbar가 나타난다.
pub fn showAboutAlert(title: []const u8, message: []const u8) void {
    if (showScrollableText(title, message, false) == null) showNative(.info, title, message);
}

/// 모든 정상 fatal은 branded custom layout을 사용한다. custom window 생성 자체가
/// 실패할 때만 native MessageBoxIndirectW로 메시지를 보존한다.
pub fn showFatal(title: []const u8, message: []const u8) void {
    if (showScrollableText(title, message, false) == null) showNative(.err, title, message);
}

/// OK / Cancel 두 버튼 확인 다이얼로그. #250 — 표준 매핑(Enter=OK, Esc=Cancel)
/// 으로 통일. 기본 버튼 = 첫 번째(OK) 이므로 `MB_DEFBUTTON2`(Cancel 기본) 제거 →
/// Enter=OK. Esc 는 MB_OKCANCEL 에서 항상 Cancel. (#116 의 'Cancel 기본 — Enter
/// 종료 방지' 폐기 — 다이얼로그 출현 자체가 speed bump.)
/// 반환: OK → true, Cancel / 닫기 → false.
pub fn showConfirm(title: []const u8, message: []const u8) bool {
    if (showScrollableText(title, message, true)) |result| return result;
    // MessageBoxIndirectW 자체 실패(0 반환) 시 result != IDOK → false (안전 default).
    const result = messageBox(
        title,
        message,
        MB_OKCANCEL | MB_TOPMOST,
    );
    return result == IDOK;
}

var prompt_done = false;
var prompt_ok = false;
var prompt_edit: HWND = null;
var prompt_create: HWND = null;
var prompt_status: HWND = null;
var prompt_message: HWND = null;
var prompt_separator: HWND = null;
var prompt_separator_brush: HBRUSH = null;
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
        const child: HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (child == prompt_separator and prompt_separator_brush != null) {
            return @bitCast(@intFromPtr(prompt_separator_brush.?));
        }
        const dc: HDC = @ptrFromInt(wparam);
        if (child == prompt_status) _ = SetTextColor(dc, rgb(196, 43, 28));
        const brush = dialogControlBrush(dc, child, prompt_message) orelse return 0;
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
    const class_icon = LoadIconW(hinstance, tildaz_icon_resource);
    const wc = WNDCLASSEXW{ .cbSize = @sizeOf(WNDCLASSEXW), .style = 0, .lpfnWndProc = promptWndProc, .cbClsExtra = 0, .cbWndExtra = 0, .hInstance = hinstance, .hIcon = class_icon, .hCursor = LoadCursorW(null, IDC_ARROW), .hbrBackground = @ptrFromInt(COLOR_BTNFACE + 1), .lpszMenuName = null, .lpszClassName = prompt_class_name, .hIconSm = class_icon };
    if (RegisterClassExW(&wc) == 0) return false;
    prompt_class_registered = true;
    return true;
}

pub fn promptHotkey(allocator: std.mem.Allocator, title: []const u8, message: []const u8, validator: dialog.HotkeyValidator) ?[]u8 {
    const hinstance = GetModuleHandleW(null);
    if (!ensurePromptClass(hinstance)) return null;
    const temp_allocator = std.heap.page_allocator;
    const title_w = std.unicode.utf8ToUtf16LeAllocZ(temp_allocator, title) catch return null;
    defer temp_allocator.free(title_w);
    const message_w = dialogEditTextAlloc(temp_allocator, message) catch return null;
    defer temp_allocator.free(message_w);

    const owner = dialogOwner();
    const window_dpi = if (owner != null) GetDpiForWindow(owner) else 0;
    const dpi = if (window_dpi != 0) window_dpi else GetDpiForSystem();
    const title_font = createDialogFont(dpi, ui_metrics.DIALOG_TITLE_FONT_PT, FW_NORMAL);
    defer {
        if (title_font != null) _ = DeleteObject(title_font);
    }
    const ui_font = createDialogFont(dpi, ui_metrics.DIALOG_BODY_FONT_PT, FW_NORMAL);
    defer {
        if (ui_font != null) _ = DeleteObject(ui_font);
    }
    const capture_font = createDialogFont(dpi, 16, FW_SEMIBOLD);
    defer {
        if (capture_font != null) _ = DeleteObject(capture_font);
    }
    const work = dialogWorkArea(owner);
    const edit_horizontal_inset = dialogEditHorizontalInset(hinstance, prompt_class_name, ui_font, dpi, work) orelse return null;
    const screen_w = work.right - work.left;
    const screen_h = work.bottom - work.top;
    const viewport_margin = scaled(16, dpi);
    const margin = scaled(24, dpi);
    const gap = scaled(16, dpi);
    const frame_style = WS_CAPTION | WS_SYSMENU;
    const frame_ex_style = WS_EX_TOPMOST;
    var frame = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = AdjustWindowRectExForDpi(&frame, frame_style, 0, frame_ex_style, dpi);
    const frame_w = frame.right - frame.left;
    const frame_h = frame.bottom - frame.top;
    const available_window_w = @max(1, screen_w - viewport_margin * 2);
    const max_window_w = @min(scaled(@intCast(ui_metrics.DIALOG_MAX_WIDTH_PT), dpi), available_window_w);
    const preferred_window_w = @min(scaled(@intCast(ui_metrics.DIALOG_PREFERRED_WIDTH_PT), dpi), max_window_w);
    const max_client_w = @max(1, max_window_w - frame_w);
    const preferred_client_w = @max(1, preferred_window_w - frame_w);
    const max_content_w = @max(1, max_client_w - margin * 2);
    var content_w = @max(1, preferred_client_w - margin * 2);

    // 먼저 실제 wrap 높이를 재고, 고정 input/status/button을 제외한 화면 높이를
    // 넘을 때만 message control을 read-only EDIT + 세로 scrollbar로 바꾼다.
    var msg_h: c_int = scaled(48, dpi);
    var title_h: c_int = scaled(24, dpi);
    var body_line_h: c_int = scaled(20, dpi);
    {
        const dc = GetDC(null);
        if (dc != null) {
            const prev = if (title_font != null)
                SelectObject(dc, title_font)
            else if (ui_font != null)
                SelectObject(dc, ui_font)
            else
                null;
            var title_rect = RECT{ .left = 0, .top = 0, .right = content_w, .bottom = 0 };
            _ = DrawTextW(dc, title_w.ptr, @intCast(title_w.len), &title_rect, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
            if (title_rect.bottom > 0) title_h = @intCast(title_rect.bottom);
            if (ui_font != null) _ = SelectObject(dc, ui_font);
            var body_line_rect = RECT{ .left = 0, .top = 0, .right = content_w, .bottom = 0 };
            const body_line_sample = std.unicode.utf8ToUtf16LeStringLiteral("Ag");
            _ = DrawTextW(dc, body_line_sample, 2, &body_line_rect, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
            if (body_line_rect.bottom > 0) body_line_h = @intCast(body_line_rect.bottom);
            const measured_h = wrappedDialogTextHeight(dc, message_w, content_w, edit_horizontal_inset);
            if (measured_h > 0) msg_h = measured_h;
            if (prev != null) _ = SelectObject(dc, prev);
            _ = ReleaseDC(null, dc);
        }
    }

    // client 좌표로 각 컨트롤 위치를 위→아래로 누적.
    const edit_h = scaled(40, dpi); // 캡처된 키 표시 (큰 폰트)
    const status_h = scaled(28, dpi); // 에러 상태 텍스트
    const button_h = scaled(32, dpi);
    const button_w = scaled(96, dpi);
    const icon_y = scaled(20, dpi);
    const header = dialogHeaderGeometry(icon_y, title_h, body_line_h, dpi);
    const msg_y = header.body_y;
    const bottom = scaled(20, dpi);
    const max_window_h = @max(1, screen_h - viewport_margin * 2);
    const max_client_h = @max(1, max_window_h - frame_h);
    const fixed_after_message = gap + edit_h + scaled(4, dpi) + status_h + gap + button_h + bottom;
    const max_message_h = @max(1, max_client_h - msg_y - fixed_after_message);

    if (msg_h > max_message_h and content_w < max_content_w) {
        content_w = max_content_w;
        const measure_dc = GetDC(null);
        if (measure_dc != null) {
            const previous = if (ui_font != null) SelectObject(measure_dc, ui_font) else null;
            const measured_h = wrappedDialogTextHeight(measure_dc, message_w, content_w, edit_horizontal_inset);
            if (measured_h > 0) msg_h = measured_h;
            if (previous != null) _ = SelectObject(measure_dc, previous);
            _ = ReleaseDC(null, measure_dc);
        }
    }
    const message_overflow = msg_h > max_message_h;
    msg_h = @min(msg_h, max_message_h);
    const edit_y = msg_y + msg_h + gap;
    const status_y = edit_y + edit_h + scaled(4, dpi);
    const button_y = status_y + status_h + gap;
    const client_h = button_y + button_h + bottom;
    const client_w = margin + content_w + margin;
    const create_x = client_w - margin - button_w;
    const cancel_x = create_x - scaled(8, dpi) - button_w;

    // client 사각형 → 창 전체 사각형 (title bar / 테두리 실제 DPI 반영).
    var wr = RECT{ .left = 0, .top = 0, .right = client_w, .bottom = client_h };
    _ = AdjustWindowRectExForDpi(&wr, frame_style, 0, frame_ex_style, dpi);
    const win_w = wr.right - wr.left;
    const win_h = wr.bottom - wr.top;
    const win_x = work.left + @divTrunc(screen_w - win_w, 2);
    const win_y = work.top + @divTrunc(screen_h - win_h, 2);
    const dialog_icon = loadDialogIcon(hinstance, dpi) orelse return null;
    defer _ = DestroyIcon(dialog_icon);
    const separator_brush = CreateSolidBrush(dialogSeparatorColor()) orelse return null;
    defer _ = DeleteObject(separator_brush);
    defer {
        prompt_message = null;
        prompt_separator = null;
        prompt_separator_brush = null;
    }
    const hwnd = CreateWindowExW(frame_ex_style, prompt_class_name, title_w.ptr, frame_style, win_x, win_y, win_w, win_h, owner, null, hinstance, null) orelse return null;
    defer _ = DestroyWindow(hwnd);
    if (owner != null) {
        _ = EnableWindow(owner, 0);
        defer {
            _ = EnableWindow(owner, 1);
            _ = SetForegroundWindow(owner);
        }
    }
    if (!createDialogIconControl(hwnd, hinstance, dialog_icon, dpi, client_w, icon_y)) return null;
    const title_control = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        title_w.ptr,
        WS_CHILD | WS_VISIBLE | SS_NOPREFIX,
        margin,
        header.title_y,
        content_w,
        header.title_h,
        hwnd,
        null,
        hinstance,
        null,
    ) orelse return null;
    setControlFont(title_control, title_font);
    const separator = createDialogSeparatorControl(hwnd, hinstance, dpi, margin, header.separator_y, content_w) orelse return null;
    prompt_separator = separator;
    prompt_separator_brush = separator_brush;
    const message_control = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        message_w.ptr,
        dialogBodyEditStyle(message_overflow, false),
        margin,
        msg_y,
        content_w,
        msg_h,
        hwnd,
        null,
        hinstance,
        null,
    ) orelse return null;
    prompt_message = message_control;
    prompt_edit = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), WS_CHILD | WS_VISIBLE | SS_CENTER | SS_CENTERIMAGE, margin, edit_y, content_w, edit_h, hwnd, @ptrFromInt(100), hinstance, null);
    prompt_status = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), WS_CHILD | WS_VISIBLE | SS_CENTER | SS_CENTERIMAGE, margin, status_y, content_w, status_h, hwnd, null, hinstance, null);
    const cancel = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral(messages.button_cancel), WS_CHILD | WS_VISIBLE | WS_TABSTOP, cancel_x, button_y, button_w, button_h, hwnd, @ptrFromInt(IDCANCEL), hinstance, null);
    prompt_create = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral(messages.button_create), WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, create_x, button_y, button_w, button_h, hwnd, @ptrFromInt(IDOK), hinstance, null);
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
