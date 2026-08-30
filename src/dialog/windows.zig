//! Windows dialog 구현. 모든 정상 info/error/confirm/About/prompt는 TildaZ
//! branded custom modal window로 표시한다. custom window 생성 실패 때만
//! `MessageBoxIndirectW + MB_USERICON`을 비상 fallback으로 사용한다.
//! `dialog.zig` 에서 comptime 으로 select.

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
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
// #540 — 배율이 바뀌면 창과 자식을 다시 놓는다. `GetWindowLongPtrW` 계열은 64-bit
// 전용 export 인데 우리 Windows 타겟은 x86_64 · aarch64 뿐이라 (`build.zig` 의
// `check_targets`) 그대로 쓴다.
extern "user32" fn SetWindowPos(HWND, HWND, c_int, c_int, c_int, c_int, UINT) callconv(.c) c_int;
extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(.c) isize;
extern "user32" fn SetWindowLongPtrW(HWND, c_int, isize) callconv(.c) isize;
extern "user32" fn InvalidateRect(HWND, ?*const RECT, c_int) callconv(.c) c_int;

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
/// #540 — per-monitor v2 프로세스라 창이 다른 배율의 모니터로 옮겨가거나 사용자가
/// 배율을 바꾸면 이 메시지가 온다. `wParam` 하위 워드가 새 DPI, `lParam` 이 OS 가
/// 제안하는 창 rect (화면 좌표) 다.
const WM_DPICHANGED: UINT = 0x02E0;
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
const GWL_STYLE: c_int = -16;
const SWP_NOZORDER: UINT = 0x0004;
const SWP_NOACTIVATE: UINT = 0x0010;
const SWP_FRAMECHANGED: UINT = 0x0020;
const SWP_NOOWNERZORDER: UINT = 0x0200;
const tildaz_icon_resource: ?*const anyopaque = @ptrFromInt(1);

/// 두 다이얼로그 창이 같은 frame 을 쓴다 — 예전엔 두 함수가 각자 지역 상수로
/// 들고 있었다. `AdjustWindowRectExForDpi` 에 넘기는 값이라 한 곳에 둔다.
const dialog_frame_style: DWORD = WS_CAPTION | WS_SYSMENU;
const dialog_frame_ex_style: DWORD = WS_EX_TOPMOST;

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

/// dialog 안쪽 여백 — **본문 폰트 크기에 비례**한다 (#407). 절대값을 박으면 폰트가
/// 커져도 여백이 그대로라 답답해 보인다. 1.8 배 (예전 24 는 1.6 배였다).
fn dialog_margin_px(dpi: UINT) c_int {
    return scaled(@intCast(ui_metrics.DIALOG_BODY_FONT_PT * 9 / 5), dpi);
}

/// confirm / prompt 의 두 버튼 사이 간격 — 같은 기준으로 **폰트 크기의 1.6 배**다.
/// 예전 8 은 0.53 배라 두 버튼이 붙어 보였고, 1.0 배도 좁다는 사용자 지적으로
/// 넓혔다. Linux 의 `dialog_button_gap_pt` 와 같은 비율이다.
fn dialog_button_gap_px(dpi: UINT) c_int {
    return scaled(@intCast(ui_metrics.DIALOG_BODY_FONT_PT * 8 / 5), dpi);
}

/// #540 — client 좌표의 자식 컨트롤 자리. `CreateWindowExW` 와 `SetWindowPos` 가
/// 둘 다 (x, y, w, h) 를 받으므로 Win32 `RECT` 가 아니라 이 모양으로 둔다.
const ControlRect = struct {
    x: c_int = 0,
    y: c_int = 0,
    w: c_int = 0,
    h: c_int = 0,
};

/// `AdjustWindowRectExForDpi` 가 client 사각형에 더하는 테두리 · 제목 표시줄 두께.
/// 더하는 양이 입력 rect 와 무관한 순수 inset 이라, 빈 rect 로 한 번 재어 두면
/// `win_w = client_w + w` 가 항상 성립한다 — 덕분에 배치 계산이 user32 를 부르지
/// 않아도 되고 그래서 단위 테스트가 된다.
const FrameMetrics = struct { w: c_int, h: c_int };

fn dialogFrameMetrics(dpi: UINT) FrameMetrics {
    var frame = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = AdjustWindowRectExForDpi(&frame, dialog_frame_style, 0, dialog_frame_ex_style, dpi);
    return .{ .w = frame.right - frame.left, .h = frame.bottom - frame.top };
}

/// work area 와 frame 만으로 정해지는 폭 후보들. **실측보다 먼저** 정해지므로
/// 텍스트를 재는 쪽과 배치를 계산하는 쪽이 같은 값을 본다.
const DialogWidths = struct {
    margin: c_int,
    max_content_w: c_int,
    preferred_content_w: c_int,
};

fn dialogWidths(dpi: UINT, work: RECT, frame: FrameMetrics) DialogWidths {
    const screen_w = work.right - work.left;
    const viewport_margin = scaled(16, dpi);
    const margin = dialog_margin_px(dpi);
    const available_window_w = @max(1, screen_w - viewport_margin * 2);
    const max_window_w = @min(scaled(@intCast(ui_metrics.DIALOG_MAX_WIDTH_PT), dpi), available_window_w);
    const preferred_window_w = @min(scaled(@intCast(ui_metrics.DIALOG_PREFERRED_WIDTH_PT), dpi), max_window_w);
    const max_client_w = @max(1, max_window_w - frame.w);
    const preferred_client_w = @max(1, preferred_window_w - frame.w);
    return .{
        .margin = margin,
        .max_content_w = @max(1, max_client_w - margin * 2),
        .preferred_content_w = @max(1, preferred_client_w - margin * 2),
    };
}

/// client 높이 상한 — work area 에서 viewport 여백과 frame 을 뺀 값.
fn dialogMaxClientHeight(dpi: UINT, work: RECT, frame: FrameMetrics) c_int {
    const screen_h = work.bottom - work.top;
    const viewport_margin = scaled(16, dpi);
    const max_window_h = @max(1, screen_h - viewport_margin * 2);
    return @max(1, max_window_h - frame.h);
}

/// 두 다이얼로그가 공통으로 재는 값. 나머지 실측 (본문 자연 폭 등) 은 쓰는 쪽이
/// 따로 넘긴다 — prompt 는 자연 폭을 쓰지 않는다.
const TextMetrics = struct {
    title_h: c_int,
    body_line_h: c_int,
};

/// 본문 폭이 정해져야 wrap 높이가 나오므로 콜백으로 받는다. 지금 코드도 **필요할
/// 때만** 두 번째 측정을 하고, 그 동작을 그대로 보존한다. 0 은 "못 쟀다" 는 뜻이고
/// 호출측이 기본값으로 간다 (예전 `dc == null` 경로와 같다).
const WrapMeasurer = struct {
    ctx: *anyopaque,
    height_fn: *const fn (ctx: *anyopaque, content_w: c_int) c_int,

    fn height(self: WrapMeasurer, content_w: c_int) c_int {
        return self.height_fn(self.ctx, content_w);
    }
};

/// GDI 로 실제 wrap 높이를 재는 measurer. `dc` 에 본문 폰트가 이미 select 돼 있어야
/// 한다 — 예전 코드가 한 DC 안에서 재던 것과 같다.
const DcWrapMeasurer = struct {
    dc: HDC,
    text: [:0]const WCHAR,
    inset: c_int,

    fn measure(ctx: *anyopaque, content_w: c_int) c_int {
        const self: *DcWrapMeasurer = @ptrCast(@alignCast(ctx));
        if (self.dc == null) return 0;
        return wrappedDialogTextHeight(self.dc, self.text, content_w, self.inset);
    }

    fn measurer(self: *DcWrapMeasurer) WrapMeasurer {
        return .{ .ctx = self, .height_fn = measure };
    }
};

/// 자식 하나를 자리에 놓는다. z-order 와 활성화는 건드리지 않는다 — 배치만 바꾼다.
fn moveControl(control: HWND, rect: ControlRect, extra_flags: UINT) void {
    if (control == null) return;
    _ = SetWindowPos(control, null, rect.x, rect.y, rect.w, rect.h, SWP_NOZORDER | SWP_NOACTIVATE | extra_flags);
}

/// 본문 `EDIT` 의 세로 scrollbar 유무를 맞춘다. 배율이 바뀌면 다시 wrap 하므로
/// overflow 판정이 뒤집힐 수 있고, 그때는 style 을 갈아야 scrollbar 가 생기거나
/// 사라진다. 반환 = 바뀌었는지 (바뀌었으면 `SWP_FRAMECHANGED` 가 필요하다).
///
/// **`WS_VSCROLL` 비트만 만진다.** style 전체를 우리가 만든 값으로 덮으면 그 사이
/// OS 나 컨트롤이 세운 비트를 지운다.
fn setDialogBodyOverflow(body: HWND, overflow: bool) bool {
    if (body == null) return false;
    const vscroll: isize = @intCast(WS_VSCROLL);
    const current = GetWindowLongPtrW(body, GWL_STYLE);
    const want = if (overflow) current | vscroll else current & ~vscroll;
    if (want == current) return false;
    _ = SetWindowLongPtrW(body, GWL_STYLE, want);
    return true;
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

/// 아이콘 그림을 컨트롤에 건다. `SS_REALSIZECONTROL` 이라 그려지는 크기는 컨트롤
/// 자리가 정하지만, 리소스 자체는 배율에 맞는 픽셀 크기로 불러야 또렷하다 —
/// 그래서 배율이 바뀌면 `loadDialogIcon` 을 다시 하고 이 함수로 갈아 끼운다 (#540).
fn setDialogIconImage(control: HWND, icon: HICON) void {
    if (control == null or icon == null) return;
    const icon_param: LPARAM = @bitCast(@intFromPtr(icon.?));
    _ = SendMessageW(control, STM_SETIMAGE, IMAGE_ICON, icon_param);
}

/// 자식은 **자리를 0 으로** 만들고 `applyScrollLayout` / `applyPromptLayout` 이 놓는다.
/// 좌표를 적는 자리가 코드에 한 곳뿐이어야 생성 경로와 `WM_DPICHANGED` 가 어긋나지
/// 않는다 (#540).
fn createDialogIconControl(parent: HWND, hinstance: HINSTANCE, icon: HICON) HWND {
    if (parent == null or icon == null) return null;
    const control = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        WS_CHILD | WS_VISIBLE | SS_ICON | SS_REALSIZECONTROL,
        0,
        0,
        0,
        0,
        parent,
        null,
        hinstance,
        null,
    ) orelse return null;
    setDialogIconImage(control, icon);
    return control;
}

fn createDialogSeparatorControl(parent: HWND, hinstance: HINSTANCE) HWND {
    return CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        WS_CHILD | WS_VISIBLE,
        0,
        0,
        0,
        0,
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

pub fn show(rt: Runtime, severity: dialog.Severity, title: []const u8, message: []const u8) void {
    _ = rt;
    if (showScrollableText(title, message, false) == null) {
        showNative(severity, title, message);
    }
}

var scroll_done = false;
var scroll_result = false;
var scroll_class_registered = false;
const scroll_class_name = std.unicode.utf8ToUtf16LeStringLiteral("TildaZScrollableDialogWindow");

/// 본문 다이얼로그의 자식 컨트롤들.
const ScrollControls = struct {
    icon: HWND = null,
    title: HWND = null,
    separator: HWND = null,
    body: HWND = null,
    ok: HWND = null,
    cancel: HWND = null,
};

/// 제목 · 본문 · 버튼 폰트 세 벌. 배율마다 새로 만든다.
const ScrollFonts = struct {
    title: HFONT = null,
    body: HFONT = null,
    button: HFONT = null,
};

fn createScrollFonts(dpi: UINT) ScrollFonts {
    return .{
        .title = createDialogFont(dpi, ui_metrics.DIALOG_TITLE_FONT_PT, FW_NORMAL),
        .body = createDialogFont(dpi, ui_metrics.DIALOG_BODY_FONT_PT, FW_NORMAL),
        .button = createDialogFont(dpi, 10, FW_NORMAL),
    };
}

/// 배율 변화 경로에서만 본다. **세 벌이 다 있어야 갈아 끼운다** — 하나라도 null 이면
/// 그 컨트롤은 옛 폰트를 그대로 쓰는데 우리는 곧 그 폰트를 지우므로 dangling 이 된다.
/// (생성 경로는 예전처럼 null 을 허용한다. 그때는 지울 옛 폰트가 없다.)
fn scrollFontsComplete(fonts: ScrollFonts) bool {
    return fonts.title != null and fonts.body != null and fonts.button != null;
}

fn destroyScrollFonts(fonts: ScrollFonts) void {
    if (fonts.title != null) _ = DeleteObject(fonts.title);
    if (fonts.body != null) _ = DeleteObject(fonts.body);
    if (fonts.button != null) _ = DeleteObject(fonts.button);
}

fn setScrollFonts(controls: ScrollControls, fonts: ScrollFonts) void {
    setControlFont(controls.title, fonts.title);
    setControlFont(controls.body, fonts.body);
    setControlFont(controls.ok, fonts.button);
    setControlFont(controls.cancel, fonts.button);
}

/// #540 — 창 프로시저가 배율 변화에 다시 배치하려면 생성 때 쓴 재료가 전부 필요하다.
/// 프로시저는 `callconv(.c)` 라 userdata 를 못 받으므로 모듈 전역에 둔다 (예전에도
/// `scroll_body` · `scroll_separator` 가 같은 이유로 전역이었다). 다이얼로그가 modal
/// 이라 한 번에 하나만 산다.
///
/// **GDI 자원의 소유자가 여기 하나다.** 지역 변수에 두고 `defer` 로 지우면, 배율
/// 변화가 폰트 · 아이콘을 바꿔치기한 뒤 그 지역 변수가 이미 지워진 핸들을 다시
/// 지운다 (double free). 텍스트는 `showScrollableText` 의 지역 버퍼를 가리키는데,
/// ctx 가 그 함수보다 오래 살지 않으므로 (`defer scroll_ctx = null`) dangling 이 없다.
const ScrollContext = struct {
    hwnd: HWND = null,
    hinstance: HINSTANCE,
    dpi: UINT,
    confirm: bool,
    title_text: [:0]const WCHAR,
    body_text: [:0]const WCHAR,
    fonts: ScrollFonts,
    icon: HICON = null,
    separator_brush: HBRUSH = null,
    controls: ScrollControls = .{},
};

var scroll_ctx: ?ScrollContext = null;

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
    if (msg == WM_DPICHANGED) {
        // 우리 다이얼로그일 때만 다시 놓는다. 같은 클래스로 만드는 inset 측정용
        // scratch 창 (`dialogEditHorizontalInset`) 도 이 프로시저를 쓰므로 hwnd 를
        // 대조한다 — 그쪽은 보이지 않는 창이라 기본 처리로 충분하다.
        if (scroll_ctx) |*ctx| {
            if (ctx.hwnd == hwnd and ctx.hwnd != null) {
                const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                relayoutScrollForDpi(ctx, @intCast(wparam & 0xffff), suggested.*);
                return 0;
            }
        }
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    if (msg == WM_CTLCOLORSTATIC) {
        const child: HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const body: HWND = if (scroll_ctx) |ctx| blk: {
            if (child == ctx.controls.separator and ctx.separator_brush != null) {
                return @bitCast(@intFromPtr(ctx.separator_brush.?));
            }
            break :blk ctx.controls.body;
        } else null;
        const brush = dialogControlBrush(@ptrFromInt(wparam), child, body) orelse return 0;
        return @bitCast(@intFromPtr(brush));
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// #540 — 본문 다이얼로그의 배치 전체. **GDI 를 부르지 않는다** — 실측값은 인자로
/// 받고 wrap 높이만 `wrap` 으로 되묻는다. 생성 경로와 `WM_DPICHANGED` 가 이 함수
/// 하나를 쓰므로 두 경로의 배치가 어긋날 수 없고, 순수 함수라 단위 테스트가 된다.
fn scrollLayout(
    dpi: UINT,
    work: RECT,
    frame: FrameMetrics,
    metrics: TextMetrics,
    title_natural_w: c_int,
    body_natural_w: c_int,
    edit_inset: c_int,
    wrap: WrapMeasurer,
    confirm: bool,
) ScrollLayout {
    const widths = dialogWidths(dpi, work, frame);
    const margin = widths.margin;
    const min_content_w = @min(scaled(472, dpi), widths.preferred_content_w);

    // EDIT 의 border/formatting inset 만큼 control 폭을 더 확보한 뒤 실제 formatting
    // 폭으로 wrap 높이를 재서 경계의 마지막 줄도 보존한다.
    const desired_content_w = @max(
        @as(i64, title_natural_w),
        @as(i64, body_natural_w) + @as(i64, edit_inset),
    );
    var content_w: c_int = @intCast(std.math.clamp(
        desired_content_w,
        @as(i64, min_content_w),
        @as(i64, widths.preferred_content_w),
    ));
    var wrapped_h = blk: {
        const measured = wrap.height(content_w);
        break :blk if (measured > 0) measured + scaled(6, dpi) else scaled(130, dpi);
    };

    const top = scaled(20, dpi);
    const header = dialogHeaderGeometry(top, metrics.title_h, metrics.body_line_h, dpi);
    const body_y = header.body_y;
    const gap = scaled(16, dpi);
    const button_h = scaled(32, dpi);
    const button_w = scaled(96, dpi);
    const bottom = scaled(20, dpi);
    const max_client_h = dialogMaxClientHeight(dpi, work, frame);
    const max_body_h = @max(1, max_client_h - body_y - gap - button_h - bottom);

    // preferred 폭에서 고정 chrome 까지 합친 자연 높이가 screen 을 넘을 때만 maximum
    // 폭으로 확장해 다시 wrap 한다.
    if (wrapped_h > max_body_h and content_w < widths.max_content_w) {
        content_w = widths.max_content_w;
        const measured = wrap.height(content_w);
        if (measured > 0) wrapped_h = measured + scaled(6, dpi);
    }
    const body_h = @min(wrapped_h, max_body_h);
    const client_w = margin + content_w + margin;
    const button_y = body_y + body_h + gap;
    const client_h = button_y + button_h + bottom;
    const win_w = client_w + frame.w;
    const win_h = client_h + frame.h;
    const icon_size = dialogIconSize(dpi);
    const ok_x = if (confirm)
        client_w - margin - button_w
    else
        @divTrunc(client_w - button_w, 2);

    return .{
        .win_x = work.left + @divTrunc((work.right - work.left) - win_w, 2),
        .win_y = work.top + @divTrunc((work.bottom - work.top) - win_h, 2),
        .win_w = win_w,
        .win_h = win_h,
        .client_w = client_w,
        .client_h = client_h,
        .icon = .{ .x = @divTrunc(client_w - icon_size, 2), .y = top, .w = icon_size, .h = icon_size },
        .title = .{ .x = margin, .y = header.title_y, .w = content_w, .h = header.title_h },
        .separator = .{ .x = margin, .y = header.separator_y, .w = content_w, .h = header.separator_h },
        .body = .{ .x = margin, .y = body_y, .w = content_w, .h = body_h },
        .ok = .{ .x = ok_x, .y = button_y, .w = button_w, .h = button_h },
        .cancel = if (confirm) .{
            .x = ok_x - dialog_button_gap_px(dpi) - button_w,
            .y = button_y,
            .w = button_w,
            .h = button_h,
        } else .{},
        .overflow = wrapped_h > body_h,
    };
}

const ScrollLayout = struct {
    win_x: c_int,
    win_y: c_int,
    win_w: c_int,
    win_h: c_int,
    client_w: c_int,
    client_h: c_int,
    icon: ControlRect,
    title: ControlRect,
    separator: ControlRect,
    body: ControlRect,
    ok: ControlRect,
    cancel: ControlRect,
    overflow: bool,
};

/// 실측 + 배치. GDI 는 전부 여기서 하고 계산은 `scrollLayout` 이 한다.
/// null = `EDIT` 의 formatting inset 을 못 쟀다 (예전과 같은 실패 조건).
fn measureScrollLayout(
    hinstance: HINSTANCE,
    dpi: UINT,
    work: RECT,
    title_w: [:0]const WCHAR,
    body_w: [:0]const WCHAR,
    fonts: ScrollFonts,
    confirm: bool,
) ?ScrollLayout {
    const edit_inset = dialogEditHorizontalInset(hinstance, scroll_class_name, fonts.body, dpi, work) orelse return null;
    const frame = dialogFrameMetrics(dpi);
    const widths = dialogWidths(dpi, work, frame);

    var metrics = TextMetrics{ .title_h = scaled(24, dpi), .body_line_h = scaled(20, dpi) };
    var title_natural_w: c_int = 0;
    var body_natural_w: c_int = 0;
    var wrap_ctx = DcWrapMeasurer{ .dc = null, .text = body_w, .inset = edit_inset };

    const dc = GetDC(null);
    var previous: ?*anyopaque = null;
    if (dc != null) {
        previous = if (fonts.title != null)
            SelectObject(dc, fonts.title)
        else if (fonts.body != null)
            SelectObject(dc, fonts.body)
        else
            null;
        var title_rect = RECT{ .left = 0, .top = 0, .right = widths.max_content_w, .bottom = 0 };
        _ = DrawTextW(dc, title_w.ptr, @intCast(title_w.len), &title_rect, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
        if (title_rect.bottom > 0) metrics.title_h = @intCast(title_rect.bottom);
        title_natural_w = @max(0, title_rect.right - title_rect.left);

        if (fonts.body != null) _ = SelectObject(dc, fonts.body);
        var body_line_rect = RECT{ .left = 0, .top = 0, .right = widths.max_content_w, .bottom = 0 };
        const body_line_sample = std.unicode.utf8ToUtf16LeStringLiteral("Ag");
        _ = DrawTextW(dc, body_line_sample, 2, &body_line_rect, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
        if (body_line_rect.bottom > 0) metrics.body_line_h = @intCast(body_line_rect.bottom);
        body_natural_w = longestExplicitLineWidth(dc, body_w);
        // 본문 폰트가 select 된 채로 넘긴다 — wrap 측정이 같은 DC 를 쓴다.
        wrap_ctx.dc = dc;
    }

    const layout = scrollLayout(
        dpi,
        work,
        frame,
        metrics,
        title_natural_w,
        body_natural_w,
        edit_inset,
        wrap_ctx.measurer(),
        confirm,
    );

    if (dc != null) {
        if (previous != null) _ = SelectObject(dc, previous);
        _ = ReleaseDC(null, dc);
    }
    return layout;
}

fn applyScrollLayout(hwnd: HWND, controls: ScrollControls, layout: ScrollLayout) void {
    _ = SetWindowPos(
        hwnd,
        null,
        layout.win_x,
        layout.win_y,
        layout.win_w,
        layout.win_h,
        SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
    );
    moveControl(controls.icon, layout.icon, 0);
    moveControl(controls.title, layout.title, 0);
    moveControl(controls.separator, layout.separator, 0);
    const body_style_changed = setDialogBodyOverflow(controls.body, layout.overflow);
    moveControl(controls.body, layout.body, if (body_style_changed) SWP_FRAMECHANGED else 0);
    moveControl(controls.ok, layout.ok, 0);
    moveControl(controls.cancel, layout.cancel, 0);
}

/// #540 — 배율이 바뀌었을 때 창과 자식을 새 DPI 로 다시 놓는다.
///
/// **실패하면 아무것도 바꾸지 않는다.** 폰트 · 아이콘 · 배치를 모두 만들어 본 뒤에야
/// 옛 자원을 놓아주므로, 중간에 실패해도 다이얼로그는 이전 배율 그대로 쓸 수 있다.
/// (자식을 파괴하고 다시 만드는 방식이었다면 그 자리에서 빈 창이 남고, 이 이슈가
/// 고치려는 "마우스로 닫을 수 없다" 가 그대로 재현된다.)
fn relayoutScrollForDpi(ctx: *ScrollContext, new_dpi: UINT, suggested: RECT) void {
    // ① 제안 rect 로 먼저 옮긴다. 창이 새 모니터에 올라가야 `dialogWorkArea` 가 그
    //    모니터의 work area 를 준다 — 크기는 ③에서 다시 정하므로 여기서는 자리만
    //    맞으면 된다.
    _ = SetWindowPos(
        ctx.hwnd,
        null,
        suggested.left,
        suggested.top,
        suggested.right - suggested.left,
        suggested.bottom - suggested.top,
        SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
    );

    // ② 새 배율의 GDI 자원.
    const fonts = createScrollFonts(new_dpi);
    if (!scrollFontsComplete(fonts)) {
        destroyScrollFonts(fonts);
        return;
    }
    const icon = loadDialogIcon(ctx.hinstance, new_dpi) orelse {
        destroyScrollFonts(fonts);
        return;
    };

    // ③ 새 폰트로 다시 재고 배치를 계산한다.
    const work = dialogWorkArea(ctx.hwnd);
    const layout = measureScrollLayout(
        ctx.hinstance,
        new_dpi,
        work,
        ctx.title_text,
        ctx.body_text,
        fonts,
        ctx.confirm,
    ) orelse {
        _ = DestroyIcon(icon);
        destroyScrollFonts(fonts);
        return;
    };

    // ④ 새 폰트를 컨트롤에 건 **뒤에** 옛 것을 지운다 — 쓰이는 중인 GDI 객체를 지우면
    //    안 된다.
    const old_fonts = ctx.fonts;
    const old_icon = ctx.icon;
    ctx.fonts = fonts;
    ctx.icon = icon;
    ctx.dpi = new_dpi;
    setScrollFonts(ctx.controls, fonts);
    setDialogIconImage(ctx.controls.icon, icon);
    applyScrollLayout(ctx.hwnd, ctx.controls, layout);
    _ = InvalidateRect(ctx.hwnd, null, 1);
    destroyScrollFonts(old_fonts);
    if (old_icon != null) _ = DestroyIcon(old_icon);
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

    // #540 — GDI 자원의 소유를 ctx 한 곳으로 모은다. 여기부터의 모든 `return null` 이
    // 아래 defer 하나로 정리되고, 배율 변화가 폰트 · 아이콘을 바꿔치기해도 *마지막*
    // 값이 지워진다 (지역 변수에 두면 바꿔치기된 뒤 이미 지운 핸들을 또 지운다).
    scroll_ctx = .{
        .hinstance = hinstance,
        .dpi = dpi,
        .confirm = confirm,
        .title_text = title_w,
        .body_text = body_w,
        .fonts = createScrollFonts(dpi),
    };
    defer {
        if (scroll_ctx) |leftover| {
            destroyScrollFonts(leftover.fonts);
            if (leftover.icon != null) _ = DestroyIcon(leftover.icon);
            if (leftover.separator_brush != null) _ = DeleteObject(leftover.separator_brush);
        }
        scroll_ctx = null;
    }
    const ctx = &scroll_ctx.?;

    const work = dialogWorkArea(owner);
    const layout = measureScrollLayout(hinstance, dpi, work, title_w, body_w, ctx.fonts, confirm) orelse return null;

    ctx.icon = loadDialogIcon(hinstance, dpi) orelse return null;
    ctx.separator_brush = CreateSolidBrush(dialogSeparatorColor()) orelse return null;

    const hwnd = CreateWindowExW(
        dialog_frame_ex_style,
        scroll_class_name,
        title_w.ptr,
        dialog_frame_style,
        layout.win_x,
        layout.win_y,
        layout.win_w,
        layout.win_h,
        owner,
        null,
        hinstance,
        null,
    ) orelse return null;
    defer _ = DestroyWindow(hwnd);
    ctx.hwnd = hwnd;
    // owner 를 다이얼로그가 닫힐 때까지 비활성으로 둔다 — 이것이 modal 이다 (#567).
    //
    // **`defer` 를 `if` 안에 두면 안 된다.** Zig 의 `defer` 는 함수가 아니라 그
    // 블록이 끝날 때 도는데, 예전 코드는 `if (owner != null) { EnableWindow(0);
    // defer { EnableWindow(1); } }` 라 disable 과 enable 이 연달아 실행됐다. 그래서
    // modal 이 한 번도 안 걸렸다.
    //
    // 되살리는 순서도 정해져 있다 — 이 defer 는 `DestroyWindow` 의 defer 보다 **뒤에**
    // 등록되므로 LIFO 로 **먼저** 돈다. owner 를 살린 뒤에 다이얼로그를 없애야 그 틈에
    // OS 가 남의 앱을 foreground 로 올리지 않는다.
    if (owner != null) _ = EnableWindow(owner, 0);
    defer if (owner != null) {
        _ = EnableWindow(owner, 1);
        _ = SetForegroundWindow(owner);
    };

    // 자식은 자리를 0 으로 만들고 `applyScrollLayout` 이 놓는다 — 좌표를 적는 자리가
    // 한 곳뿐이어야 생성 경로와 `WM_DPICHANGED` 가 어긋나지 않는다 (#540).
    ctx.controls.icon = createDialogIconControl(hwnd, hinstance, ctx.icon) orelse return null;
    ctx.controls.title = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        title_w.ptr,
        WS_CHILD | WS_VISIBLE | SS_NOPREFIX,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        hinstance,
        null,
    ) orelse return null;
    ctx.controls.separator = createDialogSeparatorControl(hwnd, hinstance) orelse return null;
    ctx.controls.body = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        dialogBodyEditStyle(layout.overflow, true),
        0,
        0,
        0,
        0,
        hwnd,
        null,
        hinstance,
        null,
    ) orelse return null;
    if (SetWindowTextW(ctx.controls.body, body_w.ptr) == 0) return null;
    _ = SendMessageW(ctx.controls.body, EM_SETSEL, 0, 0);

    ctx.controls.ok = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral(messages.button_ok),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
        0,
        0,
        0,
        0,
        hwnd,
        @ptrFromInt(IDOK),
        hinstance,
        null,
    ) orelse return null;
    if (confirm) {
        ctx.controls.cancel = CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
            std.unicode.utf8ToUtf16LeStringLiteral(messages.button_cancel),
            WS_CHILD | WS_VISIBLE | WS_TABSTOP,
            0,
            0,
            0,
            0,
            hwnd,
            @ptrFromInt(IDCANCEL),
            hinstance,
            null,
        ) orelse return null;
    }
    setScrollFonts(ctx.controls, ctx.fonts);
    applyScrollLayout(hwnd, ctx.controls, layout);

    _ = ShowWindow(hwnd, SW_SHOW);
    _ = SetFocus(ctx.controls.body);
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
pub fn showAboutAlert(rt: Runtime, title: []const u8, message: []const u8) void {
    _ = rt;
    if (showScrollableText(title, message, false) == null) showNative(.info, title, message);
}

/// 모든 정상 fatal은 branded custom layout을 사용한다. custom window 생성 자체가
/// 실패할 때만 native MessageBoxIndirectW로 메시지를 보존한다.
pub fn showFatal(rt: Runtime, title: []const u8, message: []const u8) void {
    _ = rt;
    if (showScrollableText(title, message, false) == null) showNative(.err, title, message);
}

/// OK / Cancel 두 버튼 확인 다이얼로그. #250 — 표준 매핑(Enter=OK, Esc=Cancel)
/// 으로 통일. 기본 버튼 = 첫 번째(OK) 이므로 `MB_DEFBUTTON2`(Cancel 기본) 제거 →
/// Enter=OK. Esc 는 MB_OKCANCEL 에서 항상 Cancel. (#116 의 'Cancel 기본 — Enter
/// 종료 방지' 폐기 — 다이얼로그 출현 자체가 speed bump.)
/// 반환: OK → true, Cancel / 닫기 → false.
pub fn showConfirm(rt: Runtime, title: []const u8, message: []const u8) bool {
    _ = rt;
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
var prompt_validator: ?dialog.HotkeyValidator = null;
var prompt_class_registered = false;
const prompt_class_name = std.unicode.utf8ToUtf16LeStringLiteral("TildaZPromptWindow");

/// 핫키 캡처 다이얼로그의 자식 컨트롤들. `capture` 는 잡은 조합을 큰 글씨로 보여
/// 주는 STATIC 이다 (편집이 아니라 표시라 `EDIT` 이 아니다).
const PromptControls = struct {
    icon: HWND = null,
    title: HWND = null,
    separator: HWND = null,
    message: HWND = null,
    capture: HWND = null,
    status: HWND = null,
    cancel: HWND = null,
    create: HWND = null,
};

const PromptFonts = struct {
    title: HFONT = null,
    /// 메시지 · 상태 · 버튼이 함께 쓴다.
    body: HFONT = null,
    /// 캡처한 조합 표시 — 크고 굵다.
    capture: HFONT = null,
};

fn createPromptFonts(dpi: UINT) PromptFonts {
    return .{
        .title = createDialogFont(dpi, ui_metrics.DIALOG_TITLE_FONT_PT, FW_NORMAL),
        .body = createDialogFont(dpi, ui_metrics.DIALOG_BODY_FONT_PT, FW_NORMAL),
        .capture = createDialogFont(dpi, 16, FW_SEMIBOLD),
    };
}

/// `scrollFontsComplete` 와 같은 이유 — 배율 변화 경로에서만 본다.
fn promptFontsComplete(fonts: PromptFonts) bool {
    return fonts.title != null and fonts.body != null and fonts.capture != null;
}

fn destroyPromptFonts(fonts: PromptFonts) void {
    if (fonts.title != null) _ = DeleteObject(fonts.title);
    if (fonts.body != null) _ = DeleteObject(fonts.body);
    if (fonts.capture != null) _ = DeleteObject(fonts.capture);
}

fn setPromptFonts(controls: PromptControls, fonts: PromptFonts) void {
    setControlFont(controls.title, fonts.title);
    setControlFont(controls.message, fonts.body);
    setControlFont(controls.capture, fonts.capture);
    setControlFont(controls.status, fonts.body);
    setControlFont(controls.cancel, fonts.body);
    setControlFont(controls.create, fonts.body);
}

/// `ScrollContext` 와 같은 역할 · 같은 소유 규칙이다 (#540).
const PromptContext = struct {
    hwnd: HWND = null,
    hinstance: HINSTANCE,
    dpi: UINT,
    title_text: [:0]const WCHAR,
    message_text: [:0]const WCHAR,
    fonts: PromptFonts,
    icon: HICON = null,
    separator_brush: HBRUSH = null,
    controls: PromptControls = .{},
};

var prompt_ctx: ?PromptContext = null;

fn promptControls() PromptControls {
    return if (prompt_ctx) |ctx| ctx.controls else .{};
}

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
    } else if (msg == WM_DPICHANGED) {
        // `scrollWndProc` 와 같은 규칙 — 우리 창일 때만 다시 놓는다.
        if (prompt_ctx) |*ctx| {
            if (ctx.hwnd == hwnd and ctx.hwnd != null) {
                const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                relayoutPromptForDpi(ctx, @intCast(wparam & 0xffff), suggested.*);
                return 0;
            }
        }
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    } else if (msg == WM_CTLCOLORSTATIC) {
        const child: HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const dc: HDC = @ptrFromInt(wparam);
        const controls = promptControls();
        if (prompt_ctx) |ctx| {
            if (child == controls.separator and ctx.separator_brush != null) {
                return @bitCast(@intFromPtr(ctx.separator_brush.?));
            }
        }
        if (child == controls.status) _ = SetTextColor(dc, rgb(196, 43, 28));
        const brush = dialogControlBrush(dc, child, controls.message) orelse return 0;
        return @bitCast(@intFromPtr(brush));
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn promptText(buf: []u8) ?[]const u8 {
    const capture = promptControls().capture;
    if (capture == null) return null;
    var wide: [256]WCHAR = undefined;
    const copied = GetWindowTextW(capture, &wide, wide.len);
    if (copied <= 0) return null;
    const len = std.unicode.utf16LeToUtf8(buf, wide[0..@intCast(copied)]) catch return null;
    return buf[0..len];
}

fn updatePromptValidation() bool {
    const controls = promptControls();
    var text_buf: [256]u8 = undefined;
    const text = promptText(&text_buf) orelse {
        if (controls.create != null) _ = EnableWindow(controls.create, 0);
        if (controls.status != null) _ = SetWindowTextW(controls.status, std.unicode.utf8ToUtf16LeStringLiteral(""));
        return false;
    };
    const result = if (prompt_validator) |validator| validator.validate(text) else dialog.HotkeyValidation.check_failed;
    const available = switch (result) {
        .available => true,
        else => false,
    };
    if (controls.create != null) _ = EnableWindow(controls.create, if (available) 1 else 0);
    var status_buf: [256]u8 = undefined;
    const status = dialog.hotkeyValidationMessage(&status_buf, result);
    var wide_buf: [512]WCHAR = undefined;
    const len = std.unicode.utf8ToUtf16Le(&wide_buf, status) catch return available;
    wide_buf[len] = 0;
    if (controls.status != null) _ = SetWindowTextW(controls.status, @ptrCast(wide_buf[0..len :0]));
    return available;
}

fn handlePromptKey(vkey: usize) bool {
    const capture = promptControls().capture;
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
        _ = SetWindowTextW(capture, std.unicode.utf8ToUtf16LeStringLiteral(""));
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
    _ = SetWindowTextW(capture, @ptrCast(wide_buf[0..len :0]));
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

const PromptLayout = struct {
    win_x: c_int,
    win_y: c_int,
    win_w: c_int,
    win_h: c_int,
    client_w: c_int,
    client_h: c_int,
    icon: ControlRect,
    title: ControlRect,
    separator: ControlRect,
    message: ControlRect,
    capture: ControlRect,
    status: ControlRect,
    cancel: ControlRect,
    create: ControlRect,
    message_overflow: bool,
};

/// #540 — 핫키 캡처 다이얼로그의 배치 전체. `scrollLayout` 과 같은 규약이다:
/// GDI 를 부르지 않고, wrap 높이만 `wrap` 으로 되묻는다.
///
/// 본문 다이얼로그와 다른 점은 **본문 폭이 텍스트를 따라가지 않는다**는 것이다 —
/// 아래의 캡처 · 상태 · 버튼이 고정 높이라 폭까지 흔들리면 창이 매번 달라 보인다.
fn promptLayout(
    dpi: UINT,
    work: RECT,
    frame: FrameMetrics,
    metrics: TextMetrics,
    wrap: WrapMeasurer,
) PromptLayout {
    const widths = dialogWidths(dpi, work, frame);
    const margin = widths.margin;
    const gap = scaled(16, dpi);
    var content_w = widths.preferred_content_w;
    var msg_h = blk: {
        const measured = wrap.height(content_w);
        break :blk if (measured > 0) measured else scaled(48, dpi);
    };

    // client 좌표로 각 컨트롤 위치를 위→아래로 누적.
    const capture_h = scaled(40, dpi); // 캡처된 키 표시 (큰 폰트)
    const status_h = scaled(28, dpi); // 에러 상태 텍스트
    const button_h = scaled(32, dpi);
    const button_w = scaled(96, dpi);
    const icon_y = scaled(20, dpi);
    const header = dialogHeaderGeometry(icon_y, metrics.title_h, metrics.body_line_h, dpi);
    const msg_y = header.body_y;
    const bottom = scaled(20, dpi);
    const max_client_h = dialogMaxClientHeight(dpi, work, frame);
    const fixed_after_message = gap + capture_h + scaled(4, dpi) + status_h + gap + button_h + bottom;
    const max_message_h = @max(1, max_client_h - msg_y - fixed_after_message);

    if (msg_h > max_message_h and content_w < widths.max_content_w) {
        content_w = widths.max_content_w;
        const measured = wrap.height(content_w);
        if (measured > 0) msg_h = measured;
    }
    const message_overflow = msg_h > max_message_h;
    msg_h = @min(msg_h, max_message_h);
    const capture_y = msg_y + msg_h + gap;
    const status_y = capture_y + capture_h + scaled(4, dpi);
    const button_y = status_y + status_h + gap;
    const client_h = button_y + button_h + bottom;
    const client_w = margin + content_w + margin;
    const create_x = client_w - margin - button_w;
    const cancel_x = create_x - dialog_button_gap_px(dpi) - button_w;
    const win_w = client_w + frame.w;
    const win_h = client_h + frame.h;
    const icon_size = dialogIconSize(dpi);

    return .{
        .win_x = work.left + @divTrunc((work.right - work.left) - win_w, 2),
        .win_y = work.top + @divTrunc((work.bottom - work.top) - win_h, 2),
        .win_w = win_w,
        .win_h = win_h,
        .client_w = client_w,
        .client_h = client_h,
        .icon = .{ .x = @divTrunc(client_w - icon_size, 2), .y = icon_y, .w = icon_size, .h = icon_size },
        .title = .{ .x = margin, .y = header.title_y, .w = content_w, .h = header.title_h },
        .separator = .{ .x = margin, .y = header.separator_y, .w = content_w, .h = header.separator_h },
        .message = .{ .x = margin, .y = msg_y, .w = content_w, .h = msg_h },
        .capture = .{ .x = margin, .y = capture_y, .w = content_w, .h = capture_h },
        .status = .{ .x = margin, .y = status_y, .w = content_w, .h = status_h },
        .cancel = .{ .x = cancel_x, .y = button_y, .w = button_w, .h = button_h },
        .create = .{ .x = create_x, .y = button_y, .w = button_w, .h = button_h },
        .message_overflow = message_overflow,
    };
}

fn measurePromptLayout(
    hinstance: HINSTANCE,
    dpi: UINT,
    work: RECT,
    title_w: [:0]const WCHAR,
    message_w: [:0]const WCHAR,
    fonts: PromptFonts,
) ?PromptLayout {
    const edit_inset = dialogEditHorizontalInset(hinstance, prompt_class_name, fonts.body, dpi, work) orelse return null;
    const frame = dialogFrameMetrics(dpi);
    const widths = dialogWidths(dpi, work, frame);

    var metrics = TextMetrics{ .title_h = scaled(24, dpi), .body_line_h = scaled(20, dpi) };
    var wrap_ctx = DcWrapMeasurer{ .dc = null, .text = message_w, .inset = edit_inset };

    const dc = GetDC(null);
    var previous: ?*anyopaque = null;
    if (dc != null) {
        previous = if (fonts.title != null)
            SelectObject(dc, fonts.title)
        else if (fonts.body != null)
            SelectObject(dc, fonts.body)
        else
            null;
        var title_rect = RECT{ .left = 0, .top = 0, .right = widths.preferred_content_w, .bottom = 0 };
        _ = DrawTextW(dc, title_w.ptr, @intCast(title_w.len), &title_rect, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
        if (title_rect.bottom > 0) metrics.title_h = @intCast(title_rect.bottom);
        if (fonts.body != null) _ = SelectObject(dc, fonts.body);
        var body_line_rect = RECT{ .left = 0, .top = 0, .right = widths.preferred_content_w, .bottom = 0 };
        const body_line_sample = std.unicode.utf8ToUtf16LeStringLiteral("Ag");
        _ = DrawTextW(dc, body_line_sample, 2, &body_line_rect, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
        if (body_line_rect.bottom > 0) metrics.body_line_h = @intCast(body_line_rect.bottom);
        wrap_ctx.dc = dc;
    }

    const layout = promptLayout(dpi, work, frame, metrics, wrap_ctx.measurer());

    if (dc != null) {
        if (previous != null) _ = SelectObject(dc, previous);
        _ = ReleaseDC(null, dc);
    }
    return layout;
}

fn applyPromptLayout(hwnd: HWND, controls: PromptControls, layout: PromptLayout) void {
    _ = SetWindowPos(
        hwnd,
        null,
        layout.win_x,
        layout.win_y,
        layout.win_w,
        layout.win_h,
        SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
    );
    moveControl(controls.icon, layout.icon, 0);
    moveControl(controls.title, layout.title, 0);
    moveControl(controls.separator, layout.separator, 0);
    const message_style_changed = setDialogBodyOverflow(controls.message, layout.message_overflow);
    moveControl(controls.message, layout.message, if (message_style_changed) SWP_FRAMECHANGED else 0);
    moveControl(controls.capture, layout.capture, 0);
    moveControl(controls.status, layout.status, 0);
    moveControl(controls.cancel, layout.cancel, 0);
    moveControl(controls.create, layout.create, 0);
}

/// `relayoutScrollForDpi` 와 같다. **캡처한 조합과 상태 문구는 그대로 남는다** —
/// 자식을 파괴하지 않고 옮기기 때문이다. 배율을 바꿨다고 입력하던 것이 날아가면 안 된다.
fn relayoutPromptForDpi(ctx: *PromptContext, new_dpi: UINT, suggested: RECT) void {
    _ = SetWindowPos(
        ctx.hwnd,
        null,
        suggested.left,
        suggested.top,
        suggested.right - suggested.left,
        suggested.bottom - suggested.top,
        SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
    );

    const fonts = createPromptFonts(new_dpi);
    if (!promptFontsComplete(fonts)) {
        destroyPromptFonts(fonts);
        return;
    }
    const icon = loadDialogIcon(ctx.hinstance, new_dpi) orelse {
        destroyPromptFonts(fonts);
        return;
    };

    const work = dialogWorkArea(ctx.hwnd);
    const layout = measurePromptLayout(
        ctx.hinstance,
        new_dpi,
        work,
        ctx.title_text,
        ctx.message_text,
        fonts,
    ) orelse {
        _ = DestroyIcon(icon);
        destroyPromptFonts(fonts);
        return;
    };

    const old_fonts = ctx.fonts;
    const old_icon = ctx.icon;
    ctx.fonts = fonts;
    ctx.icon = icon;
    ctx.dpi = new_dpi;
    setPromptFonts(ctx.controls, fonts);
    setDialogIconImage(ctx.controls.icon, icon);
    applyPromptLayout(ctx.hwnd, ctx.controls, layout);
    _ = InvalidateRect(ctx.hwnd, null, 1);
    destroyPromptFonts(old_fonts);
    if (old_icon != null) _ = DestroyIcon(old_icon);
}

pub fn promptHotkey(rt: Runtime, allocator: std.mem.Allocator, title: []const u8, message: []const u8, validator: dialog.HotkeyValidator) ?[]u8 {
    _ = rt;
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

    // #540 — `showScrollableText` 와 같은 소유 규칙.
    prompt_ctx = .{
        .hinstance = hinstance,
        .dpi = dpi,
        .title_text = title_w,
        .message_text = message_w,
        .fonts = createPromptFonts(dpi),
    };
    defer {
        if (prompt_ctx) |leftover| {
            destroyPromptFonts(leftover.fonts);
            if (leftover.icon != null) _ = DestroyIcon(leftover.icon);
            if (leftover.separator_brush != null) _ = DeleteObject(leftover.separator_brush);
        }
        prompt_ctx = null;
        prompt_validator = null;
    }
    const ctx = &prompt_ctx.?;

    const work = dialogWorkArea(owner);
    const layout = measurePromptLayout(hinstance, dpi, work, title_w, message_w, ctx.fonts) orelse return null;

    ctx.icon = loadDialogIcon(hinstance, dpi) orelse return null;
    ctx.separator_brush = CreateSolidBrush(dialogSeparatorColor()) orelse return null;

    const hwnd = CreateWindowExW(
        dialog_frame_ex_style,
        prompt_class_name,
        title_w.ptr,
        dialog_frame_style,
        layout.win_x,
        layout.win_y,
        layout.win_w,
        layout.win_h,
        owner,
        null,
        hinstance,
        null,
    ) orelse return null;
    defer _ = DestroyWindow(hwnd);
    ctx.hwnd = hwnd;
    // owner 를 다이얼로그가 닫힐 때까지 비활성으로 둔다 — 이것이 modal 이다 (#567).
    //
    // **`defer` 를 `if` 안에 두면 안 된다.** Zig 의 `defer` 는 함수가 아니라 그
    // 블록이 끝날 때 도는데, 예전 코드는 `if (owner != null) { EnableWindow(0);
    // defer { EnableWindow(1); } }` 라 disable 과 enable 이 연달아 실행됐다. 그래서
    // modal 이 한 번도 안 걸렸다.
    //
    // 되살리는 순서도 정해져 있다 — 이 defer 는 `DestroyWindow` 의 defer 보다 **뒤에**
    // 등록되므로 LIFO 로 **먼저** 돈다. owner 를 살린 뒤에 다이얼로그를 없애야 그 틈에
    // OS 가 남의 앱을 foreground 로 올리지 않는다.
    if (owner != null) _ = EnableWindow(owner, 0);
    defer if (owner != null) {
        _ = EnableWindow(owner, 1);
        _ = SetForegroundWindow(owner);
    };

    ctx.controls.icon = createDialogIconControl(hwnd, hinstance, ctx.icon) orelse return null;
    ctx.controls.title = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        title_w.ptr,
        WS_CHILD | WS_VISIBLE | SS_NOPREFIX,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        hinstance,
        null,
    ) orelse return null;
    ctx.controls.separator = createDialogSeparatorControl(hwnd, hinstance) orelse return null;
    ctx.controls.message = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        message_w.ptr,
        dialogBodyEditStyle(layout.message_overflow, false),
        0,
        0,
        0,
        0,
        hwnd,
        null,
        hinstance,
        null,
    ) orelse return null;
    ctx.controls.capture = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), WS_CHILD | WS_VISIBLE | SS_CENTER | SS_CENTERIMAGE, 0, 0, 0, 0, hwnd, @ptrFromInt(100), hinstance, null);
    ctx.controls.status = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), WS_CHILD | WS_VISIBLE | SS_CENTER | SS_CENTERIMAGE, 0, 0, 0, 0, hwnd, null, hinstance, null);
    ctx.controls.cancel = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral(messages.button_cancel), WS_CHILD | WS_VISIBLE | WS_TABSTOP, 0, 0, 0, 0, hwnd, @ptrFromInt(IDCANCEL), hinstance, null);
    ctx.controls.create = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral(messages.button_create), WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, 0, 0, 0, 0, hwnd, @ptrFromInt(IDOK), hinstance, null);
    if (ctx.controls.create != null) _ = EnableWindow(ctx.controls.create, 0);
    setPromptFonts(ctx.controls, ctx.fonts);
    applyPromptLayout(hwnd, ctx.controls, layout);

    _ = ShowWindow(hwnd, SW_SHOW);
    _ = SetFocus(hwnd);
    prompt_done = false;
    prompt_ok = false;
    prompt_validator = validator;
    var msg: MSG = undefined;
    while (!prompt_done and GetMessageW(&msg, null, 0, 0) > 0) {
        if ((msg.message == WM_KEYDOWN or msg.message == WM_SYSKEYDOWN) and handlePromptKey(msg.wParam)) continue;
        if (IsDialogMessageW(hwnd, &msg) == 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
    }
    const capture = ctx.controls.capture;
    if (!prompt_ok or capture == null) return null;
    const len = GetWindowTextLengthW(capture);
    if (len < 0 or len > 255) return null;
    var wide: [256]WCHAR = undefined;
    const copied = GetWindowTextW(capture, &wide, wide.len);
    if (copied < 0) return null;
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..@intCast(copied)]) catch null;
}

/// #540 회귀 테스트용 가짜 wrap 측정기. **폭이 좁을수록 높이가 커진다** — 실제
/// 텍스트 wrap 과 같은 방향이라, 폭을 넓혀 다시 재는 분기가 제대로 돈다.
const FakeWrap = struct {
    total_px: i64,

    fn measure(ctx: *anyopaque, content_w: c_int) c_int {
        const self: *FakeWrap = @ptrCast(@alignCast(ctx));
        if (content_w <= 0) return 0;
        return @intCast(@divTrunc(self.total_px, @as(i64, content_w)) + 1);
    }

    fn measurer(self: *FakeWrap) WrapMeasurer {
        return .{ .ctx = self, .height_fn = measure };
    }
};

const test_work = RECT{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };

fn testFrame(dpi: UINT) FrameMetrics {
    return .{ .w = scaled(16, dpi), .h = scaled(48, dpi) };
}

fn testMetrics(dpi: UINT) TextMetrics {
    return .{ .title_h = scaled(24, dpi), .body_line_h = scaled(20, dpi) };
}

test "#540 본문 다이얼로그 배치는 어느 배율에서도 화면 안에 들어오고 버튼이 client 안이다" {
    // 이 이슈의 증상이 정확히 "OK 버튼이 창 밖으로 나가 마우스로 못 닫는다" 였다.
    // 배치가 dpi 를 인자로 받는 순수 함수라 GDI 없이 그 조건을 직접 검사할 수 있다.
    for ([_]UINT{ 96, 120, 144, 192 }) |dpi| {
        const frame = testFrame(dpi);
        var wrap = FakeWrap{ .total_px = 400_000 };
        const layout = scrollLayout(
            dpi,
            test_work,
            frame,
            testMetrics(dpi),
            scaled(200, dpi),
            scaled(300, dpi),
            scaled(6, dpi),
            wrap.measurer(),
            true,
        );

        // 창이 work area 를 넘지 않는다.
        try std.testing.expect(layout.win_w <= test_work.right - test_work.left);
        try std.testing.expect(layout.win_h <= test_work.bottom - test_work.top);
        try std.testing.expect(layout.win_x >= test_work.left);
        try std.testing.expect(layout.win_y >= test_work.top);

        // 두 버튼이 client 안에 있고 서로 겹치지 않는다.
        try std.testing.expect(layout.ok.x >= 0);
        try std.testing.expect(layout.ok.x + layout.ok.w <= layout.client_w);
        try std.testing.expect(layout.ok.y + layout.ok.h <= layout.client_h);
        try std.testing.expect(layout.cancel.x >= 0);
        try std.testing.expect(layout.cancel.x + layout.cancel.w <= layout.ok.x);

        // 세로 순서 — 아이콘 → 제목 → 구분선 → 본문 → 버튼.
        try std.testing.expect(layout.icon.y + layout.icon.h <= layout.title.y);
        try std.testing.expect(layout.title.y + layout.title.h <= layout.separator.y);
        try std.testing.expect(layout.separator.y + layout.separator.h <= layout.body.y);
        try std.testing.expect(layout.body.y + layout.body.h <= layout.ok.y);

        // 창 크기는 client 에 frame 두께를 더한 값이다 — `AdjustWindowRectExForDpi`
        // 를 배치 계산 밖으로 뺀 근거가 이 관계다.
        try std.testing.expectEqual(layout.client_w + frame.w, layout.win_w);
        try std.testing.expectEqual(layout.client_h + frame.h, layout.win_h);
    }
}

test "#540 배율을 올리면 배치가 그만큼 커진다 — 옛 배율에 고정되지 않는다" {
    // 증상의 뿌리는 "창틀만 새 배율, 내용은 만들어진 시점의 배율" 이었다. 같은 입력을
    // 96 / 192 로 넣어 자식 자리가 실제로 두 배 근처로 커지는지 본다.
    var wrap_low = FakeWrap{ .total_px = 400_000 };
    var wrap_high = FakeWrap{ .total_px = 400_000 };
    const low = scrollLayout(96, test_work, testFrame(96), testMetrics(96), 200, 300, 6, wrap_low.measurer(), false);
    const high = scrollLayout(192, test_work, testFrame(192), testMetrics(192), 400, 600, 12, wrap_high.measurer(), false);

    try std.testing.expect(high.icon.w == low.icon.w * 2);
    try std.testing.expect(high.ok.w == low.ok.w * 2);
    try std.testing.expect(high.ok.h == low.ok.h * 2);
    try std.testing.expect(high.title.y > low.title.y);
    try std.testing.expect(high.body.y > low.body.y);
    // 폭은 화면 상한에 걸릴 수 있으므로 "커진다" 까지만 본다.
    try std.testing.expect(high.client_w > low.client_w);
}

test "#540 본문이 넘치면 overflow 로 표시된다 — scrollbar style 을 갈 근거다" {
    const dpi: UINT = 96;
    var short_wrap = FakeWrap{ .total_px = 100_000 };
    const short_layout = scrollLayout(dpi, test_work, testFrame(dpi), testMetrics(dpi), 200, 300, 6, short_wrap.measurer(), false);
    try std.testing.expect(!short_layout.overflow);

    var long_wrap = FakeWrap{ .total_px = 4_000_000 };
    const long_layout = scrollLayout(dpi, test_work, testFrame(dpi), testMetrics(dpi), 200, 300, 6, long_wrap.measurer(), false);
    try std.testing.expect(long_layout.overflow);
    // 넘쳐도 창은 화면 안이다 — 본문만 잘리고 버튼은 남는다.
    try std.testing.expect(long_layout.win_h <= test_work.bottom - test_work.top);
    try std.testing.expect(long_layout.ok.y + long_layout.ok.h <= long_layout.client_h);
}

test "#540 핫키 캡처 다이얼로그도 같은 규칙을 지킨다" {
    for ([_]UINT{ 96, 144, 192 }) |dpi| {
        const frame = testFrame(dpi);
        var wrap = FakeWrap{ .total_px = 200_000 };
        const layout = promptLayout(dpi, test_work, frame, testMetrics(dpi), wrap.measurer());

        try std.testing.expect(layout.win_w <= test_work.right - test_work.left);
        try std.testing.expect(layout.win_h <= test_work.bottom - test_work.top);
        try std.testing.expect(layout.win_x >= test_work.left);
        try std.testing.expect(layout.win_y >= test_work.top);

        // 아이콘 → 제목 → 구분선 → 메시지 → 캡처 → 상태 → 버튼.
        try std.testing.expect(layout.icon.y + layout.icon.h <= layout.title.y);
        try std.testing.expect(layout.title.y + layout.title.h <= layout.separator.y);
        try std.testing.expect(layout.separator.y + layout.separator.h <= layout.message.y);
        try std.testing.expect(layout.message.y + layout.message.h <= layout.capture.y);
        try std.testing.expect(layout.capture.y + layout.capture.h <= layout.status.y);
        try std.testing.expect(layout.status.y + layout.status.h <= layout.create.y);

        // Create 는 오른쪽 끝, Cancel 은 그 왼쪽 — 둘 다 client 안이다.
        try std.testing.expectEqual(layout.create.y, layout.cancel.y);
        try std.testing.expect(layout.create.x + layout.create.w <= layout.client_w);
        try std.testing.expect(layout.cancel.x >= 0);
        try std.testing.expect(layout.cancel.x + layout.cancel.w <= layout.create.x);
        try std.testing.expect(layout.create.y + layout.create.h <= layout.client_h);
    }
}

test "#540 화면이 작으면 본문을 줄여서라도 버튼을 남긴다" {
    // 150 % 에서 띄운 뒤 100 % 로 내리는 실측 방향이 이 경우다 — work area 는 그대로인데
    // 창이 커야 할 이유가 사라진다. 반대로 작은 화면에서는 본문이 먼저 줄어야 한다.
    const dpi: UINT = 96;
    const small_work = RECT{ .left = 0, .top = 0, .right = 800, .bottom = 480 };
    var wrap = FakeWrap{ .total_px = 2_000_000 };
    const layout = scrollLayout(dpi, small_work, testFrame(dpi), testMetrics(dpi), 200, 300, 6, wrap.measurer(), true);

    try std.testing.expect(layout.win_w <= small_work.right - small_work.left);
    try std.testing.expect(layout.win_h <= small_work.bottom - small_work.top);
    try std.testing.expect(layout.body.h >= 1);
    try std.testing.expect(layout.overflow);
    try std.testing.expect(layout.ok.y + layout.ok.h <= layout.client_h);
    try std.testing.expect(layout.cancel.x >= 0);
}
