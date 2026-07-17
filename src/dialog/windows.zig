//! Windows dialog 구현. 일반 info/error/confirm은 `MessageBoxW`, 긴 About은
//! read-only multiline EDIT를 둔 전용 modal window로 표시한다.
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
const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};
const DT_CALCRECT: UINT = 0x0400;
const DT_SINGLELINE: UINT = 0x0020;
const DT_WORDBREAK: UINT = 0x0010;
const DT_EDITCONTROL: UINT = 0x2000;
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
const WS_BORDER: DWORD = 0x00800000;
const WS_VSCROLL: DWORD = 0x00200000;
const SS_CENTER: DWORD = 0x00000001;
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
const CLEARTYPE_QUALITY: DWORD = 5;
const FW_NORMAL: c_int = 400;
const FW_SEMIBOLD: c_int = 600;
const IDC_ARROW: ?*const anyopaque = @ptrFromInt(32512);
const EM_SETSEL: UINT = 0x00B1;
const MONITOR_DEFAULTTONEAREST: DWORD = 2;

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

var about_done = false;
var about_class_registered = false;
const about_class_name = std.unicode.utf8ToUtf16LeStringLiteral("TildaZAboutWindow");

fn aboutWndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.c) LRESULT {
    if (msg == WM_COMMAND and (wparam & 0xffff) == IDOK) {
        about_done = true;
        return 0;
    }
    if (msg == WM_CLOSE) {
        about_done = true;
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn ensureAboutClass(hinstance: HINSTANCE) bool {
    if (about_class_registered) return true;
    const wc = WNDCLASSEXW{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = aboutWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .hbrBackground = @ptrFromInt(COLOR_BTNFACE + 1),
        .lpszMenuName = null,
        .lpszClassName = about_class_name,
        .hIconSm = null,
    };
    if (RegisterClassExW(&wc) == 0) return false;
    about_class_registered = true;
    return true;
}

fn aboutEditTextAlloc(allocator: std.mem.Allocator, body: []const u8) ![:0]WCHAR {
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
    const wide = try aboutEditTextAlloc(std.testing.allocator, body);
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

fn aboutWorkArea(owner: HWND) RECT {
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

fn aboutOwner() HWND {
    const candidate = GetForegroundWindow();
    if (candidate == null) return null;
    var process_id: DWORD = 0;
    _ = GetWindowThreadProcessId(candidate, &process_id);
    return if (process_id == GetCurrentProcessId()) candidate else null;
}

fn showScrollableAbout(title: []const u8, body: []const u8) bool {
    const allocator = std.heap.page_allocator;
    const title_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, title) catch return false;
    defer allocator.free(title_w);
    const body_w = aboutEditTextAlloc(allocator, body) catch return false;
    defer allocator.free(body_w);

    const hinstance = GetModuleHandleW(null);
    if (!ensureAboutClass(hinstance)) return false;

    // About 단축키를 받은 현재 TildaZ window만 owner로 삼는다. focus가 다른
    // process로 넘어간 찰나에 그 앱 window를 disable하는 일은 없어야 한다.
    const owner = aboutOwner();
    const window_dpi = if (owner != null) GetDpiForWindow(owner) else 0;
    const dpi = if (window_dpi != 0) window_dpi else GetDpiForSystem();
    const body_font = createDialogFont(dpi, ui_metrics.DIALOG_BODY_FONT_PT, FW_NORMAL);
    defer {
        if (body_font != null) _ = DeleteObject(body_font);
    }
    const ui_font = createDialogFont(dpi, 10, FW_NORMAL);
    defer {
        if (ui_font != null) _ = DeleteObject(ui_font);
    }

    const work = aboutWorkArea(owner);
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
    const max_window_w = @min(scaled(@intCast(ui_metrics.DIALOG_ABOUT_MAX_WIDTH_PT), dpi), available_window_w);
    const max_client_w = @max(1, max_window_w - frame_w);
    const max_content_w = @max(1, max_client_w - margin * 2);
    const min_content_w = @min(scaled(472, dpi), max_content_w);
    const edit_horizontal_inset = scaled(8, dpi);
    const edit_vertical_inset = scaled(6, dpi);

    var content_w = min_content_w;
    var wrapped_h = scaled(130, dpi);
    const dc = GetDC(null);
    if (dc != null) {
        const previous = if (body_font != null) SelectObject(dc, body_font) else null;
        const natural_w = longestExplicitLineWidth(dc, body_w);
        // EDIT의 border/formatting inset만큼 control 폭을 더 확보한 뒤 실제
        // formatting 폭으로 wrap 높이를 재서 경계의 마지막 줄도 보존한다.
        const desired_content_w = @as(i64, natural_w) + @as(i64, edit_horizontal_inset);
        content_w = @intCast(std.math.clamp(desired_content_w, @as(i64, min_content_w), @as(i64, max_content_w)));
        const format_w = @max(1, content_w - edit_horizontal_inset);
        var wrapped = RECT{ .left = 0, .top = 0, .right = format_w, .bottom = 0 };
        _ = DrawTextW(dc, body_w.ptr, @intCast(body_w.len), &wrapped, DT_CALCRECT | DT_WORDBREAK | DT_EDITCONTROL | DT_NOPREFIX);
        if (wrapped.bottom > 0) wrapped_h = @as(c_int, @intCast(wrapped.bottom)) + edit_vertical_inset;
        if (previous != null) _ = SelectObject(dc, previous);
        _ = ReleaseDC(null, dc);
    }

    const top = scaled(20, dpi);
    const gap = scaled(16, dpi);
    const button_h = scaled(32, dpi);
    const button_w = scaled(96, dpi);
    const bottom = scaled(20, dpi);
    const max_window_h = @max(1, screen_h - viewport_margin * 2);
    const max_client_h = @max(1, max_window_h - frame_h);
    const max_body_h = @max(1, max_client_h - top - gap - button_h - bottom);
    const body_h = @min(wrapped_h, max_body_h);
    const overflow = wrapped_h > body_h;
    const client_w = margin + content_w + margin;
    const button_y = top + body_h + gap;
    const client_h = button_y + button_h + bottom;

    var wr = RECT{ .left = 0, .top = 0, .right = client_w, .bottom = client_h };
    _ = AdjustWindowRectExForDpi(&wr, frame_style, 0, frame_ex_style, dpi);
    const win_w = wr.right - wr.left;
    const win_h = wr.bottom - wr.top;
    const win_x = work.left + @divTrunc(screen_w - win_w, 2);
    const win_y = work.top + @divTrunc(screen_h - win_h, 2);
    const hwnd = CreateWindowExW(
        frame_ex_style,
        about_class_name,
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
    ) orelse return false;
    defer _ = DestroyWindow(hwnd);
    if (owner != null) {
        _ = EnableWindow(owner, 0);
        defer {
            _ = EnableWindow(owner, 1);
            _ = SetForegroundWindow(owner);
        }
    }

    const edit_style = WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_BORDER | ES_MULTILINE | ES_AUTOVSCROLL | ES_NOHIDESEL | ES_READONLY |
        (if (overflow) WS_VSCROLL else 0);
    const edit = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        edit_style,
        margin,
        top,
        content_w,
        body_h,
        hwnd,
        null,
        hinstance,
        null,
    ) orelse return false;
    if (SetWindowTextW(edit, body_w.ptr) == 0) return false;
    _ = SendMessageW(edit, EM_SETSEL, 0, 0);

    const button_x = @divTrunc(client_w - button_w, 2);
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
    ) orelse return false;
    setControlFont(edit, body_font);
    setControlFont(ok, ui_font);

    _ = ShowWindow(hwnd, SW_SHOW);
    _ = SetFocus(edit);
    about_done = false;
    var msg: MSG = undefined;
    while (!about_done and GetMessageW(&msg, null, 0, 0) > 0) {
        if ((msg.message == WM_KEYDOWN or msg.message == WM_SYSKEYDOWN) and
            (msg.wParam == VK_RETURN or msg.wParam == VK_ESCAPE))
        {
            about_done = true;
            continue;
        }
        if (IsDialogMessageW(hwnd, &msg) == 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
    }
    return true;
}

/// About 전용 scrollable window. 일반 info/error/confirm은 기존 MessageBoxW를
/// 유지하며, 사용자 정의 window 준비 실패 시 About도 MessageBoxW로 표시한다.
pub fn showAboutAlert(title: []const u8, message: []const u8) void {
    if (!showScrollableAbout(title, message)) show(.info, title, message);
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
