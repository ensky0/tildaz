const std = @import("std");
const windows = std.os.windows;
const app_event = @import("app_event.zig");
const dialog = @import("dialog.zig");
const paths = @import("paths.zig");

const HANDLE = windows.HANDLE;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const UINT = c_uint;
const WCHAR = u16;
const LONG = c_long;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const HINSTANCE = ?*anyopaque;
const HWND = ?*anyopaque;
const HDC = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const HFONT = ?*anyopaque;
const HGDIOBJ = ?*anyopaque;
const HMENU = ?*anyopaque;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const LPVOID = ?*anyopaque;
const ATOM = u16;
const COLORREF = DWORD;

// Window Styles
const WS_POPUP: DWORD = 0x80000000;
const WS_VISIBLE: DWORD = 0x10000000;
const WS_EX_TOPMOST: DWORD = 0x00000008;
const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
const WS_EX_LAYERED: DWORD = 0x00080000;
const CS_DBLCLKS: UINT = 0x0008;

// Window Messages
const WM_CLOSE: UINT = 0x0010;
const WM_DESTROY: UINT = 0x0002;
const WM_PAINT: UINT = 0x000F;
const WM_KEYDOWN: UINT = 0x0100;
const WM_KEYUP: UINT = 0x0101;
const WM_CHAR: UINT = 0x0102;
const WM_HOTKEY: UINT = 0x0312;
const WM_TIMER: UINT = 0x0113;
const WM_SIZE: UINT = 0x0005;
const WM_USER: UINT = 0x0400;
pub const WM_PTY_OUTPUT: UINT = WM_USER + 1;
pub const WM_TAB_CLOSED: UINT = WM_USER + 2;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_LBUTTONDBLCLK: UINT = 0x0203;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_RBUTTONDOWN: UINT = 0x0204;
const WM_MOUSEWHEEL: UINT = 0x020A;
const WM_DISPLAYCHANGE: UINT = 0x007E;
const WM_DPICHANGED: UINT = 0x02E0;
const WM_SETTINGCHANGE: UINT = 0x001A;
const WM_WINDOWPOSCHANGING: UINT = 0x0046;
const WM_WINDOWPOSCHANGED: UINT = 0x0047;
const WM_NCCALCSIZE: UINT = 0x0083;
const WM_ERASEBKGND: UINT = 0x0014;
const SPI_SETWORKAREA: WPARAM = 0x002F;
const MK_LBUTTON: WPARAM = 0x0001;

// Other constants
const SW_SHOW: c_int = 5;
const SW_HIDE: c_int = 0;
const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
const SWP_NOSIZE: UINT = 0x0001;
const SWP_NOMOVE: UINT = 0x0002;
const SWP_NOREDRAW: UINT = 0x0008;
const SWP_NOACTIVATE: UINT = 0x0010;
const SWP_FRAMECHANGED: UINT = 0x0020;
const SWP_SHOWWINDOW: UINT = 0x0040;
const SWP_NOCOPYBITS: UINT = 0x0100;
/// Fullscreen / dock rect 전환 시 DWM 이 이전 surface 를 캐시해 두고 logical
/// rect 만 바꾸는 상태 (터미널 grid 는 new rect 로 reflow 됐지만 visible frame
/// 은 old rect 에 고정) 를 방어. SWP_NOCOPYBITS 는 이전 client 영역 bit 를
/// 재사용하지 않고 전부 repaint 하도록 강제하고, SWP_FRAMECHANGED 는 DWM 에
/// non-client (window frame) 재계산을 요청 — 이 둘이 같이 들어가야 WS_POPUP +
/// WS_EX_LAYERED 조합에서 visual rect 가 logical rect 를 따라감.
const SWP_REPAINT: UINT = SWP_NOCOPYBITS | SWP_FRAMECHANGED;
const CW_USEDEFAULT: c_int = @bitCast(@as(c_uint, 0x80000000));
const COLOR_WINDOW: c_int = 5;
const IDC_ARROW: [*:0]const WCHAR = @ptrFromInt(32512);
const GWL_USERDATA: c_int = -21;
const TRANSPARENT: c_int = 1;
const LWA_ALPHA: DWORD = 0x00000002;
/// DwmSetWindowAttribute 의 attribute id. Windows 에 "이 창은 transition 애니
/// 메이션 (hide/show/resize 시 shrink/grow 효과) 을 사용하지 말라" 고 알림.
/// WS_POPUP + WS_EX_TOPMOST + WS_EX_LAYERED 창이 Alt+Enter 로 rect 가 바뀐
/// 직후 SW_HIDE 하면 DWM 이 "이전 rect 로 shrink" 애니메이션을 재생하는 것
/// 으로 관측됨 — 그 중간 프레임이 사용자 눈에 "F1 눌렀는데 잠깐 이전 사이즈로
/// 보이는" 글리치로 잡힘.
const DWMWA_TRANSITIONS_FORCEDISABLED: DWORD = 3;
const MONITOR_DEFAULTTOPRIMARY: DWORD = 0x00000001;
const MONITOR_DEFAULTTONEAREST: DWORD = 0x00000002;

// GDI constants
const FW_NORMAL: c_int = 400;
const DEFAULT_CHARSET: DWORD = 1;
const OUT_DEFAULT_PRECIS: DWORD = 0;
const CLIP_DEFAULT_PRECIS: DWORD = 0;
const CLEARTYPE_QUALITY: DWORD = 5;
const FIXED_PITCH: DWORD = 1;
const FF_MODERN: DWORD = 0x30;

const POINT = extern struct { x: LONG, y: LONG };
pub const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };
const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};

const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

/// `WM_WINDOWPOSCHANGING` / `WM_WINDOWPOSCHANGED` 의 `lParam` 이 가리키는
/// 구조체. 윈도우 매니저가 실제 적용하려는 rect 과 flag 를 관측하는 용도.
const WINDOWPOS = extern struct {
    hwnd: HWND,
    hwndInsertAfter: HWND,
    x: c_int,
    y: c_int,
    cx: c_int,
    cy: c_int,
    flags: UINT,
};

const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?[*:0]const WCHAR,
    lpszClassName: [*:0]const WCHAR,
    hIconSm: HICON,
};

// Win32 function declarations
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.c) ATOM;
extern "user32" fn CreateWindowExW(DWORD, [*:0]const WCHAR, [*:0]const WCHAR, DWORD, c_int, c_int, c_int, c_int, HWND, HMENU, HINSTANCE, LPVOID) callconv(.c) HWND;
extern "user32" fn ShowWindow(HWND, c_int) callconv(.c) BOOL;
extern "user32" fn DestroyWindow(HWND) callconv(.c) BOOL;
extern "user32" fn PostQuitMessage(c_int) callconv(.c) void;
extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT;
extern "user32" fn PostMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.c) BOOL;
extern "user32" fn GetMessageW(*MSG, HWND, UINT, UINT) callconv(.c) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.c) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.c) LRESULT;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.c) HDC;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.c) BOOL;
extern "user32" fn InvalidateRect(HWND, ?*const RECT, BOOL) callconv(.c) BOOL;
extern "user32" fn SetWindowPos(HWND, HWND, c_int, c_int, c_int, c_int, UINT) callconv(.c) BOOL;
extern "user32" fn SetForegroundWindow(HWND) callconv(.c) BOOL;
extern "user32" fn GetForegroundWindow() callconv(.c) HWND;
extern "user32" fn GetWindowThreadProcessId(HWND, ?*DWORD) callconv(.c) DWORD;
extern "kernel32" fn GetCurrentThreadId() callconv(.c) DWORD;
extern "user32" fn AttachThreadInput(DWORD, DWORD, BOOL) callconv(.c) BOOL;
extern "user32" fn BringWindowToTop(HWND) callconv(.c) BOOL;
extern "user32" fn SetFocus(HWND) callconv(.c) HWND;
extern "user32" fn RegisterHotKey(HWND, c_int, UINT, UINT) callconv(.c) BOOL;
extern "user32" fn UnregisterHotKey(HWND, c_int) callconv(.c) BOOL;
extern "user32" fn GetCursorPos(*POINT) callconv(.c) BOOL;
extern "user32" fn MonitorFromPoint(POINT, DWORD) callconv(.c) ?*anyopaque;
extern "user32" fn MonitorFromWindow(HWND, DWORD) callconv(.c) ?*anyopaque;
extern "user32" fn GetMonitorInfoW(?*anyopaque, *MONITORINFO) callconv(.c) BOOL;
extern "user32" fn SetLayeredWindowAttributes(HWND, COLORREF, u8, DWORD) callconv(.c) BOOL;
extern "dwmapi" fn DwmSetWindowAttribute(HWND, DWORD, *const anyopaque, DWORD) callconv(.c) std.os.windows.HRESULT;
extern "dwmapi" fn DwmFlush() callconv(.c) std.os.windows.HRESULT;
extern "user32" fn SetWindowLongPtrW(HWND, c_int, isize) callconv(.c) isize;
extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(.c) isize;
extern "user32" fn LoadCursorW(HINSTANCE, [*:0]const WCHAR) callconv(.c) HCURSOR;
extern "user32" fn SetTimer(HWND, usize, UINT, ?*anyopaque) callconv(.c) usize;
extern "user32" fn KillTimer(HWND, usize) callconv(.c) BOOL;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.c) BOOL;
extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.c) BOOL;
extern "user32" fn GetDC(HWND) callconv(.c) HDC;
extern "user32" fn ReleaseDC(HWND, HDC) callconv(.c) c_int;
extern "kernel32" fn GetModuleHandleW(?[*:0]const WCHAR) callconv(.c) HINSTANCE;
extern "kernel32" fn OutputDebugStringA([*:0]const u8) callconv(.c) void;
extern "kernel32" fn GlobalLock(?*anyopaque) callconv(.c) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(?*anyopaque) callconv(.c) BOOL;
extern "user32" fn OpenClipboard(HWND) callconv(.c) BOOL;
extern "user32" fn CloseClipboard() callconv(.c) BOOL;
extern "user32" fn GetClipboardData(UINT) callconv(.c) ?*anyopaque;
extern "user32" fn GetKeyState(c_int) callconv(.c) i16;
extern "user32" fn GetAsyncKeyState(c_int) callconv(.c) i16;
extern "user32" fn SetCapture(HWND) callconv(.c) HWND;
extern "user32" fn ReleaseCapture() callconv(.c) BOOL;
extern "user32" fn GetDpiForWindow(HWND) callconv(.c) UINT;
extern "user32" fn EmptyClipboard() callconv(.c) BOOL;
extern "user32" fn SetClipboardData(UINT, ?*anyopaque) callconv(.c) ?*anyopaque;
extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(.c) ?*anyopaque;
extern "kernel32" fn GlobalFree(?*anyopaque) callconv(.c) ?*anyopaque;
const GMEM_MOVEABLE: UINT = 0x0002;

const CF_UNICODETEXT: UINT = 13;
const VK_CONTROL: c_int = 0x11;
const VK_SHIFT: c_int = 0x10;

// GDI functions
extern "gdi32" fn CreateFontW(c_int, c_int, c_int, c_int, c_int, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, [*:0]const WCHAR) callconv(.c) HFONT;
extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.c) HGDIOBJ;
extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.c) BOOL;
extern "gdi32" fn SetBkMode(HDC, c_int) callconv(.c) c_int;
extern "gdi32" fn SetBkColor(HDC, COLORREF) callconv(.c) COLORREF;
extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(.c) COLORREF;
extern "gdi32" fn TextOutW(HDC, c_int, c_int, [*]const WCHAR, c_int) callconv(.c) BOOL;
extern "gdi32" fn GetTextMetricsW(HDC, *TEXTMETRICW) callconv(.c) BOOL;
extern "gdi32" fn CreateSolidBrush(COLORREF) callconv(.c) HBRUSH;
extern "gdi32" fn FillRect(HDC, *const RECT, HBRUSH) callconv(.c) c_int;
extern "gdi32" fn CreateCompatibleDC(HDC) callconv(.c) HDC;
extern "gdi32" fn CreateCompatibleBitmap(HDC, c_int, c_int) callconv(.c) HGDIOBJ;
extern "gdi32" fn BitBlt(HDC, c_int, c_int, c_int, c_int, HDC, c_int, c_int, DWORD) callconv(.c) BOOL;
extern "gdi32" fn DeleteDC(HDC) callconv(.c) BOOL;

const SRCCOPY: DWORD = 0x00CC0020;

const TEXTMETRICW = extern struct {
    tmHeight: LONG,
    tmAscent: LONG,
    tmDescent: LONG,
    tmInternalLeading: LONG,
    tmExternalLeading: LONG,
    tmAveCharWidth: LONG,
    tmMaxCharWidth: LONG,
    tmWeight: LONG,
    tmOverhang: LONG,
    tmDigitizedAspectX: LONG,
    tmDigitizedAspectY: LONG,
    tmFirstChar: WCHAR,
    tmLastChar: WCHAR,
    tmDefaultChar: WCHAR,
    tmBreakChar: WCHAR,
    tmItalic: u8,
    tmUnderlined: u8,
    tmStruckOut: u8,
    tmPitchAndFamily: u8,
    tmCharSet: u8,
};

fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}

pub const FullscreenMode = enum { none, monitor, workarea };

pub const Window = struct {
    owner_hwnd: HWND = null,
    hwnd: HWND = null,
    visible: bool = false,
    font: HFONT = null,
    cell_width: c_int = 8,
    cell_height: c_int = 16,
    render_fn: ?*const fn (*Window) void = null,
    resize_fn: ?*const fn (u16, u16, ?*anyopaque) void = null,
    userdata: ?*anyopaque = null,
    write_fn: ?*const fn ([]const u8, ?*anyopaque) void = null,
    app_event_fn: ?*const fn (app_event.Event, ?*anyopaque) bool = null,
    /// 사용자가 윈도우 닫기를 요청 (Alt+F4 / 시스템 메뉴 / WM_CLOSE) 했을 때
    /// 호출. true 반환 = 종료 진행 (DestroyWindow), false 반환 = 종료 취소.
    /// macOS `applicationShouldTerminate:` 와 같은 역할 (#116). 다중 탭 confirm
    /// 다이얼로그는 app 측에서 띄우고 결과만 반환.
    quit_request_fn: ?*const fn (?*anyopaque) bool = null,
    /// Invoked after `rebuildFontForDpi` finishes so the app (renderer / UI
    /// layout) can re-raster glyphs and rescale DPI-dependent constants
    /// before `SetWindowPos` cascades into `WM_SIZE`.
    font_change_fn: ?*const fn (*Window, ?*anyopaque) void = null,
    shell_exited: bool = false,
    dc: HDC = null, // DC for GDI font measurement

    // Font-creation parameters — remembered so `rebuildFontForDpi` can
    // recreate the GDI font and re-measure cell metrics at the new DPI
    // when `WM_DPICHANGED` fires.
    font_family: [*:0]const WCHAR = undefined,
    font_size: c_int = 14,
    cell_width_scale: f32 = 1.0,
    line_height_scale: f32 = 1.0,
    current_dpi: UINT = 96,

    // Last position parameters — re-applied on WM_DISPLAYCHANGE / WM_DPICHANGED /
    // WM_SETTINGCHANGE(SPI_SETWORKAREA) and on show(), so the window tracks the
    // current monitor's work area when resolution, DPI, or taskbar changes.
    dock: DockPosition = .top,
    width_pct: u8 = 50,
    height_pct: u8 = 100,
    offset_pct: u8 = 100,
    position_set: bool = false,

    // Alt+Enter 로 토글되는 fullscreen 상태. `show()` / `WM_DISPLAYCHANGE` /
    // `WM_DPICHANGED` / `WM_SETTINGCHANGE(SPI_SETWORKAREA)` 핸들러가
    // 이 값을 보고 `applyFullscreen` (현재 모니터 rcMonitor 전체) 혹은
    // `repositionFromSaved` (저장된 dock/pct) 중 하나로 분기. F1 hide 는
    // 이 값을 유지 — 다시 F1 show 하면 fullscreen 이 복원됨.
    fullscreen_mode: FullscreenMode = .none,

    // WM_DISPLAYCHANGE dedupe — 사용자 환경에 따라 Alt 키 단독 press 같은
    // 이벤트에서도 WM_DISPLAYCHANGE 가 spurious 하게 broadcast 되는 경우가
    // 있음 (Display-Fusion/Nvidia nView 류 유틸 훅 의심). lParam 의 해상도
    // (LOWORD=w, HIWORD=h) 를 캐시해서 실제 해상도가 바뀐 경우에만
    // applyLayout 을 호출 — 그래야 Alt+Enter 직후 spurious WM_DISPLAYCHANGE
    // 가 fullscreen/dock 전환을 시각적으로 취소하는 race 를 피할 수 있음.
    last_display_w: u32 = 0,
    last_display_h: u32 = 0,

    // 우리가 의도한 window rect. `applyRect` 가 매번 갱신. `WM_WINDOWPOSCHANGING`
    // 핸들러가 이 값과 다른 rect 로 이동/리사이즈를 요청받으면 강제로 이 값으로
    // 덮어써서 외부 프로그램 (Alt 키에 반응해 WS_EX_TOPMOST 창을 rcMonitor 전체로
    // 확장시키는 display utility 류) 의 간섭을 차단. `expected_set` 은 최초
    // `setPosition` 호출 전 CreateWindowExW 단계의 내부 resize 는 간섭하지 않기
    // 위한 가드.
    expected_x: c_int = 0,
    expected_y: c_int = 0,
    expected_w: c_int = 0,
    expected_h: c_int = 0,
    expected_set: bool = false,
    layout_transition_active: bool = false,

    /// WM_KEYDOWN 가 소비한 키가 TranslateMessage 로 동시에 WM_CHAR (Enter `\r`,
    /// Escape `\x1b`, Backspace `\x08`) 를 큐에 넣는다. KEYDOWN 핸들러의 `return 0`
    /// 만으로는 그 WM_CHAR 가 막히지 않아 PTY 로 새어 들어감 (예: 탭바 rename
    /// commit 후 prompt 에 빈 줄 입력). KEYDOWN 에서 해당 키를 소비하면 이 flag
    /// 를 set, WM_CHAR 진입 즉시 swallow + clear.
    swallow_next_wm_char: bool = false,

    const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("TildaZWindow");
    const HOTKEY_ID: c_int = 1;
    const VK_F1: UINT = 0x70;
    const VK_RETURN: WPARAM = 0x0D;
    const RENDER_TIMER_ID: usize = 1;
    const LayoutMonitorTarget = enum { cursor, window };

    pub fn init(self: *Window, font_family: [*:0]const WCHAR, font_size: c_int, opacity: u8, cell_width_scale: f32, line_height_scale: f32, hotkey_vkey: u32, hotkey_modifiers: u32) !void {
        const hInstance = GetModuleHandleW(null);

        const wc = WNDCLASSEXW{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = CS_DBLCLKS,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hInstance,
            .hIcon = null,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = CLASS_NAME,
            .hIconSm = null,
        };

        if (RegisterClassExW(&wc) == 0) {
            return error.RegisterClassFailed;
        }

        self.owner_hwnd = CreateWindowExW(
            WS_EX_TOOLWINDOW,
            CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral("TildaZOwner"),
            WS_POPUP,
            0,
            0,
            0,
            0,
            null,
            null,
            hInstance,
            null,
        );

        if (self.owner_hwnd == null) {
            return error.CreateWindowFailed;
        }

        self.hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED,
            CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral("TildaZ"),
            WS_POPUP,
            0,
            0,
            800,
            400,
            self.owner_hwnd,
            null,
            hInstance,
            null,
        );

        if (self.hwnd == null) {
            _ = DestroyWindow(self.owner_hwnd);
            self.owner_hwnd = null;
            return error.CreateWindowFailed;
        }

        // Store self pointer in window userdata
        _ = SetWindowLongPtrW(self.hwnd, GWL_USERDATA, @intCast(@intFromPtr(self)));

        _ = SetLayeredWindowAttributes(self.hwnd, 0, opacity, LWA_ALPHA);

        // DWM window transition 애니메이션 비활성화. Alt+Enter 로 fullscreen ↔
        // dock rect 전환 직후 F1 로 SW_HIDE 하면, DWM 이 "현재 rect 에서 이전
        // rect 로 shrink" 애니메이션을 재생하면서 중간 프레임의 WM_SIZE 를
        // broadcast 하는 현상이 관측됨. 예: fullscreen 상태에서 hide → WM_SIZE
        // 1440x1704 (직전 dock 사이즈) 가 hide 100ms 후 들어옴. 사용자 눈엔
        // "F1 눌렀는데 반화면이 잠깐 나타났다 사라짐" 으로 보임.
        // 이 속성을 켜면 DWM 이 transition 애니메이션을 건너뛰고 상태 전환이
        // 즉시 반영됨.
        const disable: BOOL = 1;
        _ = DwmSetWindowAttribute(self.hwnd, DWMWA_TRANSITIONS_FORCEDISABLED, &disable, @sizeOf(BOOL));

        // Register global hotkey from config (default = F1, modifiers=0).
        // 실패 사유 (시연 중 발견):
        // - Windows OS 가 예약: F12 = kernel debugger 용 (MSDN RegisterHotKey 명시).
        // - 다른 system shortcut 과 충돌: Win+Shift+S (Snip & Sketch) 등 일부 Win+Shift
        //   조합은 Windows shell 이 먼저 가로채서 우리 hotkey 가 안 도달.
        // - 다른 앱이 이미 같은 조합을 등록.
        // 이 셋은 외부 표시 없이 silent fail 하는 게 사고 — drop-down 정체상 hotkey
        // 가 없으면 토글 자체가 안 되어 사용자가 *왜 안 되는지* 모른 채 헤맴.
        // fatal dialog 로 종료 + config 파일 경로 + 알려진 reservation 안내.
        if (RegisterHotKey(self.hwnd, HOTKEY_ID, hotkey_modifiers, hotkey_vkey) == 0) {
            var alloc_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
            const cfg_path = paths.configPath(fba.allocator()) catch "(unknown)";
            var msg_buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "Failed to register the global hotkey (vkey=0x{x:0>2}, modifiers=0x{x}).\n\n" ++
                    "Common causes:\n" ++
                    "\u{2022} The OS reserves the key (F12 is reserved for the kernel debugger and cannot be a global hotkey)\n" ++
                    "\u{2022} Another app already registered the same combination\n" ++
                    "\u{2022} Windows shell intercepts the combination first (some Win+Shift+letter shortcuts)\n\n" ++
                    "Edit the config and restart:\n{s}",
                .{ hotkey_vkey, hotkey_modifiers, cfg_path },
            ) catch "Failed to register the global hotkey. Edit %APPDATA%\\tildaz\\config.json and restart.";
            dialog.showFatal("TildaZ — Hotkey Registration Failed", msg);
        }

        // Remember font-creation parameters so `rebuildFontForDpi` can
        // recreate the font + re-measure cell metrics on DPI changes.
        self.font_family = font_family;
        self.font_size = font_size;
        self.cell_width_scale = cell_width_scale;
        self.line_height_scale = line_height_scale;

        // DC must exist before `rebuildFontForDpi` measures cell metrics.
        self.dc = GetDC(self.hwnd);

        const dpi = GetDpiForWindow(self.hwnd);
        const init_dpi: UINT = if (dpi > 0) dpi else 96;
        self.rebuildFontForDpi(init_dpi);

        // Start render timer (60fps)
        _ = SetTimer(self.hwnd, RENDER_TIMER_ID, 16, null);
    }

    /// (Re)create the GDI font at `new_dpi` and re-measure cell metrics.
    ///
    /// Called from `init` for the first build, and from the `WM_DPICHANGED`
    /// handler when the window moves between monitors with different DPI
    /// scales so glyphs are rasterized at the new monitor's pixel density
    /// instead of the init-time monitor's.
    ///
    /// After this returns, `cell_width` / `cell_height` reflect the new DPI;
    /// call `font_change_fn` so the renderer can rebuild its DirectWrite
    /// font context + glyph atlas at the matching `pixels_per_dip`.
    pub fn rebuildFontForDpi(self: *Window, new_dpi: UINT) void {
        // Release previous font (if any) before creating a replacement.
        if (self.font) |prev| _ = DeleteObject(prev);

        const effective_dpi: f32 = if (new_dpi > 0) @floatFromInt(new_dpi) else 96.0;
        const scaled_font_size: c_int = @intFromFloat(@round(@as(f32, @floatFromInt(self.font_size)) * effective_dpi / 96.0));

        self.font = CreateFontW(
            scaled_font_size,
            0,
            0,
            0,
            FW_NORMAL,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            FIXED_PITCH | FF_MODERN,
            self.font_family,
        );

        if (self.dc != null and self.font != null) {
            const old_f = SelectObject(self.dc, self.font);
            var tm: TEXTMETRICW = undefined;
            _ = GetTextMetricsW(self.dc, &tm);
            const base_w: f32 = @floatFromInt(tm.tmAveCharWidth);
            const base_h: f32 = @floatFromInt(tm.tmHeight + tm.tmExternalLeading);
            self.cell_width = @max(1, @as(c_int, @intFromFloat(@round(base_w * self.cell_width_scale))));
            self.cell_height = @max(1, @as(c_int, @intFromFloat(@round(base_h * self.line_height_scale))));
            _ = SelectObject(self.dc, old_f);
        }

        self.current_dpi = new_dpi;
    }

    pub fn deinit(self: *Window) void {
        if (self.hwnd) |hwnd| {
            _ = KillTimer(hwnd, RENDER_TIMER_ID);
            _ = UnregisterHotKey(hwnd, HOTKEY_ID);
            if (self.dc) |dc| _ = ReleaseDC(hwnd, dc);
            _ = DestroyWindow(hwnd);
        }
        if (self.owner_hwnd) |owner_hwnd| {
            _ = DestroyWindow(owner_hwnd);
        }
        if (self.font) |f| _ = DeleteObject(f);
    }

    /// F1 hide 에서 돌아오는 show. Windows visibility 를 `SW_SHOW` 로 전환하고,
    /// `self.fullscreen` 상태에 따라 fullscreen rect 또는 저장된 dock 설정으로
    /// layout 을 재적용한다.
    ///
    /// `SW_SHOW` 를 쓰는 이유: 과거 한때 `DWMWA_CLOAK` 기반 cloak/uncloak 로
    /// visibility 를 토글한 적이 있는데, cloak 은 DWM compositor 레벨에서만
    /// 보였다/안 보였다를 바꾸고 Windows shell 의 visibility state (external
    /// window manager 들이 enum 할 때 참조하는) 와는 sync 되지 않아서,
    /// "Alt+Enter → F1 hide → F1 show → Alt+Enter" 순서에서 shell state 가
    /// 고착돼 다음 rect 전환이 stale surface 위에 composite 되는 버그가
    /// 있었음 (#87). `SW_SHOW` / `SW_HIDE` 는 Windows 가 공식 인정하는
    /// visibility 전환이라 shell state 가 매 전환마다 clean 하게 재계산됨.
    ///
    /// 과거 `SW_HIDE` 에서 보이던 "shrink transition animation" glitch 는
    /// `init()` 에서 설정한 `DWMWA_TRANSITIONS_FORCEDISABLED` 로 DWM 이
    /// 애니메이션 자체를 skip 하므로 재현되지 않음.
    /// Restore a window hidden by F1.
    /// The saved fullscreen mode is preserved while hidden.
    /// 시작 직후 / F1 hide-show 등 모든 show 경로에서 keyboard focus 가
    /// 안정적으로 우리 창에 잡히도록 강제. 단순 `SetForegroundWindow` 는 MSDN
    /// 의 8 가지 조건 (foreground process 의 자식 / 마지막 input 받은 process /
    /// foreground 무 / debug 중 등) 중 하나라도 안 맞으면 silently fail (return
    /// 0). 진단 로깅으로 시작 직후 setfg_ret=0 + foreground 가 다른 창인 케이스
    /// 직접 측정 확인 (PowerShell `Start-Process` 류로 띄울 때 발생) — 이때
    /// Ctrl+Shift+T 등 단축키가 우리 창에 도달 안 함. F1 hide-show 는 사용자
    /// input 직후라 #3 으로 통과해 setfg_ret=1 — 그래서 두 번째 F1 후엔 정상.
    ///
    /// AttachThreadInput trick: 우리 thread 의 input queue 를 현재 foreground
    /// thread 와 잠시 attach → 두 thread 가 같은 input context 안에 있는 셈이
    /// 되어 SetForegroundWindow 가 통과 → detach. Raymond Chen 의 well-known
    /// idiom. SetFocus 도 같이 호출해 popup 본체가 직접 keyboard focus 를 받도록.
    fn forceForegroundActivation(hwnd: HWND) void {
        const fg_hwnd = GetForegroundWindow();
        const our_thread = GetCurrentThreadId();
        if (fg_hwnd != null and fg_hwnd != hwnd) {
            const fg_thread = GetWindowThreadProcessId(fg_hwnd, null);
            if (fg_thread != 0 and fg_thread != our_thread) {
                _ = AttachThreadInput(our_thread, fg_thread, 1);
                _ = BringWindowToTop(hwnd);
                _ = SetForegroundWindow(hwnd);
                _ = SetFocus(hwnd);
                _ = AttachThreadInput(our_thread, fg_thread, 0);
                return;
            }
        }
        _ = BringWindowToTop(hwnd);
        _ = SetForegroundWindow(hwnd);
        _ = SetFocus(hwnd);
    }

    pub fn show(self: *Window) void {
        if (self.hwnd) |hwnd| {
            self.layout_transition_active = true;
            defer self.layout_transition_active = false;
            self.visible = true;
            _ = ShowWindow(hwnd, SW_SHOW);

            // fullscreen 상태였으면 fullscreen 을 복원, 아니면 dock 설정 복원.
            // F1 hide 는 fullscreen 필드를 건드리지 않으므로 "Alt+Enter → F1
            // hide → F1 show" 는 여전히 fullscreen 상태로 돌아옴.
            // show() 만 cursor-follow 를 유지하고, visible 상태의 relayout 은
            // 창이 이미 올라가 있는 모니터를 기준으로 재계산한다.
            self.applyLayoutFor(.cursor);
            self.syncLayout();

            forceForegroundActivation(hwnd);

            // `applyLayout` 의 SetWindowPos 가 현재 rect 과 동일해서 WM_SIZE
            // 를 생략한 경우 대비 safety net — swap chain / terminal grid 를
            // idempotent 하게 재동기화.
            self.presentNow();

            _ = SetTimer(hwnd, RENDER_TIMER_ID, 16, null);
        }
    }

    /// F1 으로 호출되는 hide. `SW_HIDE` 로 Windows 가 창을 공식적으로 hidden
    /// 으로 인식하게 한다 — external window manager (FancyZones 등) 가 창을
    /// enum 에서 빼고 간섭을 멈추며, shell state 도 clean 해짐.
    ///
    /// `self.fullscreen` 은 건드리지 않음 — 다음 `show()` 에서 `applyLayout` 이
    /// fullscreen 을 그대로 복원한다.
    /// Hide the window without changing the saved fullscreen mode.
    pub fn hide(self: *Window) void {
        if (self.hwnd) |hwnd| {
            self.breakMonitorFullscreenSurface();
            _ = KillTimer(hwnd, RENDER_TIMER_ID);
            self.visible = false;
            _ = ShowWindow(hwnd, SW_HIDE);
            _ = DwmFlush();
        }
    }

    /// `WS_EX_TOPMOST` 를 잠시 해제 — TildaZ 는 그대로 보이지만 z-order 가
    /// normal 그룹으로 내려가서, 새로 launch 되는 editor (config / log 의 default
    /// app) 가 자연스럽게 우리 위로 올라옴. config / log 단축키 (Ctrl+Shift+P/L)
    /// 직후 사용자가 editor 를 즉시 보도록 (시연 중 발견 — editor 가 우리 창
    /// 뒤로 가려져 안 보였던 사고). 사용자가 F1 toggle 해 다시 show() 가 호출
    /// 되면 `applyRect` 의 `HWND_TOPMOST` 가 다시 topmost 로 복귀시킴.
    pub fn yieldTopmostUntilNextShow(self: *Window) void {
        if (self.hwnd) |hwnd| {
            _ = SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }

    pub fn toggle(self: *Window) void {
        if (self.visible) {
            self.hide();
        } else {
            self.show();
        }
    }

    pub fn setPosition(self: *Window, dock: DockPosition, width_pct: u8, height_pct: u8, offset_pct: u8) void {
        // Remember parameters so WM_DISPLAYCHANGE / WM_DPICHANGED /
        // WM_SETTINGCHANGE(SPI_SETWORKAREA) and show() can re-apply them on
        // resolution / monitor / DPI / taskbar changes.
        self.dock = dock;
        self.width_pct = width_pct;
        self.height_pct = height_pct;
        self.offset_pct = offset_pct;
        self.position_set = true;
        self.applyDockedRect(dock, width_pct, height_pct, offset_pct, .cursor);
    }

    fn applyDockedRect(
        self: *Window,
        dock: DockPosition,
        width_pct: u8,
        height_pct: u8,
        offset_pct: u8,
        target: LayoutMonitorTarget,
    ) void {
        const mi = self.monitorInfoFor(target) orelse return;
        const rect = dockRectForMonitor(dock, width_pct, height_pct, offset_pct, &mi);
        self.applyRect(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
    }

    fn dockRectForMonitor(
        dock: DockPosition,
        width_pct: u8,
        height_pct: u8,
        offset_pct: u8,
        mi: *const MONITORINFO,
    ) RECT {
        const sw = mi.rcWork.right - mi.rcWork.left;
        const sh = mi.rcWork.bottom - mi.rcWork.top;
        const sx = mi.rcWork.left;
        const sy = mi.rcWork.top;

        // width = always horizontal %, height = always vertical %
        const w = @divTrunc(sw * @as(c_int, width_pct), 100);
        const h = @divTrunc(sh * @as(c_int, height_pct), 100);

        const x: c_int = switch (dock) {
            .left => sx,
            .right => sx + sw - w,
            .top, .bottom => sx + @divTrunc((sw - w) * @as(c_int, offset_pct), 100),
        };
        const y: c_int = switch (dock) {
            .top => sy,
            .bottom => sy + sh - h,
            .left, .right => sy + @divTrunc((sh - h) * @as(c_int, offset_pct), 100),
        };

        return .{
            .left = x,
            .top = y,
            .right = x + w,
            .bottom = y + h,
        };
    }

    /// Re-apply the last `setPosition` parameters. Used by display/DPI/work-area
    /// change handlers and by `show()` so the window tracks the current monitor
    /// and re-fits after resolution / taskbar / monitor-configuration changes.
    /// No-op if `setPosition` was never called.
    ///
    /// After `SetWindowPos` we explicitly invoke `resize_fn` to guarantee the
    /// terminal grid reflows. `SetWindowPos` skips `WM_SIZE` when the new rect
    /// matches the current one — which happens when:
    ///   - an external monitor is disconnected and Windows has already
    ///     auto-moved the window to the primary monitor, so the saved-%
    ///     rect we compute equals the rect the window is already at
    ///   - DPI changes between monitors of identical pixel resolution (the
    ///     saved % yields the same pixel dimensions)
    /// In those cases `cell_width` / `cell_height` may have changed under
    /// the window but the terminal grid stays stuck at the old rows/cols.
    /// Calling `resize_fn` unconditionally is idempotent: when `WM_SIZE`
    /// does fire, the second invocation hits no-op fast paths in
    /// terminal resize / backend resize / swapchain resize.
    pub fn repositionFromSaved(self: *Window) void {
        if (!self.position_set) return;
        self.applyDockedRect(self.dock, self.width_pct, self.height_pct, self.offset_pct, .window);
        if (!self.layout_transition_active) {
            if (self.resize_fn) |resize_fn| {
                const grid = self.getGridSize();
                resize_fn(grid.cols, grid.rows, self.userdata);
            }
        }
    }

    /// `applyFullscreen` / `setPosition` 이 공유하는 단일 rect 적용 경로.
    ///
    /// 하는 일:
    /// 1. `expected_*` 필드를 새 rect 로 갱신 — `WM_WINDOWPOSCHANGING` 핸들러가
    ///    이 값을 source-of-truth 로 삼아 외부 프로그램 (display utility / window
    ///    manager 류) 의 rect 간섭을 clamp 한다.
    /// 2. `SetWindowPos(HWND_TOPMOST, ..., SWP_REPAINT)` 호출 — WS_POPUP +
    ///    WS_EX_LAYERED 조합에서 visual rect 가 logical rect 를 따라가도록
    ///    `SWP_NOCOPYBITS | SWP_FRAMECHANGED` 를 같이 걸어 DWM 이 이전 surface
    ///    를 재사용하지 않고 non-client 영역도 재계산하게 강제.
    ///
    /// 모든 rect 변경 경로 (dock 재배치 / fullscreen 토글 / display 변경 후
    /// 재적용) 가 이 함수를 지나게 해서 "커지는 방향 / 줄어드는 방향" 동작을
    /// 대칭으로 유지.
    fn applyRect(self: *Window, x: c_int, y: c_int, w: c_int, h: c_int) void {
        const hwnd = self.hwnd orelse return;
        self.expected_x = x;
        self.expected_y = y;
        self.expected_w = w;
        self.expected_h = h;
        self.expected_set = true;
        const flags: UINT = if (self.layout_transition_active) SWP_REPAINT | SWP_NOREDRAW else SWP_REPAINT;
        _ = SetWindowPos(hwnd, HWND_TOPMOST, x, y, w, h, flags);
    }

    fn shellSafeFullscreenRect(mi: *const MONITORINFO) RECT {
        var rect = mi.rcWork;
        const work_w = rect.right - rect.left;
        const work_h = rect.bottom - rect.top;
        const monitor_w = mi.rcMonitor.right - mi.rcMonitor.left;
        const monitor_h = mi.rcMonitor.bottom - mi.rcMonitor.top;

        // If the work area still spans an entire monitor axis, inset that axis
        // symmetrically by 1 px per edge so Windows keeps treating the taskbar
        // as a separate appbar instead of collapsing it under a "fullscreen"
        // popup.
        if (work_w == monitor_w and work_w > 2) {
            rect.left += 1;
            rect.right -= 1;
        }
        if (work_h == monitor_h and work_h > 2) {
            rect.top += 1;
            rect.bottom -= 1;
        }

        return rect;
    }

    fn transitionSafeMonitorRect(mi: *const MONITORINFO) RECT {
        var rect = mi.rcMonitor;
        const monitor_w = rect.right - rect.left;
        const monitor_h = rect.bottom - rect.top;

        // Break the exact monitor-sized rect match by a single px per edge so
        // DWM leaves the special fullscreen path before we hide or restore.
        if (monitor_w > 2) {
            rect.left += 1;
            rect.right -= 1;
        }
        if (monitor_h > 2) {
            rect.top += 1;
            rect.bottom -= 1;
        }

        return rect;
    }

    fn monitorInfoFor(self: *const Window, target: LayoutMonitorTarget) ?MONITORINFO {
        const monitor = switch (target) {
            .cursor => blk: {
                var cursor_pos: POINT = .{ .x = 0, .y = 0 };
                _ = GetCursorPos(&cursor_pos);
                break :blk MonitorFromPoint(cursor_pos, MONITOR_DEFAULTTOPRIMARY);
            },
            .window => blk: {
                const hwnd = self.hwnd orelse return null;
                break :blk MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
            },
        };
        var mi: MONITORINFO = undefined;
        mi.cbSize = @sizeOf(MONITORINFO);
        if (GetMonitorInfoW(monitor, &mi) == 0) return null;
        return mi;
    }

    fn commitTransitionRect(self: *Window, rect: RECT) void {
        const previous_transition = self.layout_transition_active;
        self.layout_transition_active = true;
        defer self.layout_transition_active = previous_transition;
        self.applyRect(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
        self.syncLayout();
        self.presentNow();
    }

    fn breakMonitorFullscreenSurface(self: *Window) void {
        if (!self.visible or self.fullscreen_mode != .monitor) return;
        const mi = self.monitorInfoFor(.window) orelse return;
        self.commitTransitionRect(transitionSafeMonitorRect(&mi));
    }

    /// 현재 창이 올라가 있는 모니터의 `rcWork` (작업 표시줄 제외) 전체로 창을
    /// 확장. `setPosition` 과 달리 저장된 dock 파라미터 (`dock` / `width_pct` /
    /// `height_pct` / `offset_pct`) 는 건드리지 않아서 fullscreen 해제시
    /// `repositionFromSaved` 로 그대로 복원 가능.
    ///
    /// **`rcMonitor` 가 아닌 `rcWork` 를 쓰는 이유**: WS_POPUP + WS_EX_TOPMOST
    /// 창의 rect 가 monitor rect 와 정확히 일치하면 DWM 이 direct-flip 을
    /// engage (compositor 우회 경로) 해서, 이후 rect 가 다시 줄어들 때 캐시된
    /// 이전 fullscreen surface 가 새 frame 위에 겹쳐 보이는 glitch 가 유발됨.
    /// `rcWork` 는 작업 표시줄 높이만큼 작아서 monitor rect 와 불일치 →
    /// direct-flip 이 engage 되지 않고 일반 composition 경로로만 동작.
    ///
    /// 창이 이미 동일 rect 이면 `SetWindowPos` 가 `WM_SIZE` 를 생략하므로
    /// `resize_fn` 을 명시적으로 한 번 호출해서 터미널 grid 가 idempotent 하게
    /// reflow 되도록 한다 (repositionFromSaved 패턴과 동일).
    /// Apply the active fullscreen mode.
    /// `.monitor` uses `rcMonitor`; `.workarea` uses the taskbar-safe work area.
    pub fn applyFullscreen(self: *Window) void {
        self.applyFullscreenFor(.window);
    }

    fn applyFullscreenFor(self: *Window, target: LayoutMonitorTarget) void {
        const mi = self.monitorInfoFor(target) orelse return;

        const rect = switch (self.fullscreen_mode) {
            .monitor => mi.rcMonitor,
            .workarea => shellSafeFullscreenRect(&mi),
            .none => return,
        };
        const x = rect.left;
        const y = rect.top;
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;

        self.applyRect(x, y, w, h);

        if (!self.layout_transition_active) {
            if (self.resize_fn) |resize_fn| {
                const grid = self.getGridSize();
                resize_fn(grid.cols, grid.rows, self.userdata);
            }
        }
    }

    /// `self.fullscreen` 분기 도우미. `show()` 와 display / DPI / workarea
    /// 이벤트 핸들러가 공통으로 사용 — fullscreen 상태가 모든 rect 재계산
    /// 경로에서 일관되게 보존됨.
    /// Shared layout branch for show/display/DPI/work-area events.
    pub fn applyLayout(self: *Window) void {
        self.applyLayoutFor(.window);
    }

    fn applyLayoutFor(self: *Window, target: LayoutMonitorTarget) void {
        switch (self.fullscreen_mode) {
            .none => switch (target) {
                .cursor => self.applyDockedRect(self.dock, self.width_pct, self.height_pct, self.offset_pct, .cursor),
                .window => self.repositionFromSaved(),
            },
            .monitor, .workarea => self.applyFullscreenFor(target),
        }
    }

    fn syncLayout(self: *Window) void {
        if (self.resize_fn) |resize_fn| {
            const grid = self.getGridSize();
            resize_fn(grid.cols, grid.rows, self.userdata);
        }
    }

    fn presentNow(self: *Window) void {
        if (!self.visible) return;
        if (self.render_fn) |render_fn| render_fn(self);
        _ = DwmFlush();
    }

    /// Alt+Enter 로 호출. fullscreen 진입/해제 토글. 해제시엔 `applyLayout` 이
    /// 저장된 dock 설정 (`width_pct` / `height_pct` / `offset_pct`) 으로 복원.
    ///
    /// 과거 구현에서는 여기서 `SW_HIDE → applyLayout → SW_SHOW` 로 DWM refresh
    /// 를 강제했는데, 이 hide/show dance 가 spurious `WM_DISPLAYCHANGE` cascade
    /// 를 유발하고, `SW_SHOW` 가 hide 직전의 surface 를 DWM cache 에서 복원하는
    /// 쪽으로 동작해서 오히려 "rect 가 새 값으로 번쩍였다 이전 값으로 되돌아
    /// 가는" 현상이 났음. `applyFullscreen` 이 `rcWork` 를 쓰므로 direct-flip
    /// 이 engage 되지 않고, 단순 `SetWindowPos` 하나로도 rect 가 안정적으로
    /// 반영된다 — hide/show 가 필요 없음.
    /// Set a concrete fullscreen mode, or `.none` to restore the saved docked rect.
    pub fn setFullscreenMode(self: *Window, mode: FullscreenMode) void {
        const previous_mode = self.fullscreen_mode;
        if (self.visible and previous_mode == .monitor and mode != .monitor) {
            self.breakMonitorFullscreenSurface();
        }
        self.fullscreen_mode = mode;
        if (!self.visible) return;
        self.layout_transition_active = true;
        defer self.layout_transition_active = false;
        self.applyLayout();
        self.syncLayout();
        self.presentNow();
    }

    pub fn toggleFullscreenMode(self: *Window, mode: FullscreenMode) void {
        self.setFullscreenMode(if (self.fullscreen_mode == .none) mode else .none);
    }

    fn dispatchAppEvent(self: *Window, event: app_event.Event) bool {
        if (self.app_event_fn) |f| {
            return f(event, self.userdata);
        }
        return false;
    }

    fn getMouseX(lParam: LPARAM) c_int {
        const raw: u16 = @truncate(@as(usize, @bitCast(lParam)));
        return @as(c_int, @intCast(@as(i16, @bitCast(raw))));
    }

    fn getMouseY(lParam: LPARAM) c_int {
        const raw: u16 = @truncate(@as(usize, @bitCast(lParam)) >> 16);
        return @as(c_int, @intCast(@as(i16, @bitCast(raw))));
    }

    fn getWheelDelta(wParam: WPARAM) i16 {
        const raw: u16 = @truncate(wParam >> 16);
        return @as(i16, @bitCast(raw));
    }

    pub fn messageLoop(_: *Window) void {
        var msg: MSG = undefined;
        while (GetMessageW(&msg, null, 0, 0) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
    }

    fn wndProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT {
        const self = getSelf(hwnd) orelse return DefWindowProcW(hwnd, msg, wParam, lParam);

        switch (msg) {
            WM_HOTKEY => {
                if (wParam == HOTKEY_ID) {
                    self.toggle();
                }
                return 0;
            },
            WM_TIMER => {
                if (wParam == RENDER_TIMER_ID) {
                    if (!self.visible or self.layout_transition_active) return 0;
                    if (self.render_fn) |render_fn| {
                        render_fn(self);
                    }
                }
                return 0;
            },
            WM_PAINT => {
                // Validate the paint region (D2D handles rendering via timer)
                var ps: PAINTSTRUCT = undefined;
                _ = BeginPaint(self.hwnd, &ps);
                _ = EndPaint(self.hwnd, &ps);
                return 0;
            },
            WM_ERASEBKGND => {
                // During fullscreen rect transitions we repaint explicitly from
                // D3D. Letting DefWindowProc erase first can expose a blank
                // intermediate frame, which reads as a flash.
                return 1;
            },
            WM_WINDOWPOSCHANGING => {
                // 외부 프로그램 (Alt 키에 반응해 WS_EX_TOPMOST 창을 rcMonitor
                // 전체로 확장시키는 display utility 류 — Display Fusion /
                // nView / Dual Monitor Tools / FancyZones 등) 의 rect 간섭을
                // 차단. 이런 변경을 방치하면 창이 순간적으로 rcMonitor 와
                // 일치해 DWM direct-flip 이 engage 됐다가, 다음 rect 전환에서
                // stale fullscreen surface 위에 새 프레임이 stretch 되어
                // 보이는 glitch 로 이어짐.
                //
                // `expected_*` 는 `applyRect` 에서만 갱신 → 우리가 의도한
                // rect 가 single source of truth. 우리 자신의 `SetWindowPos`
                // 호출도 이 핸들러를 거치지만 rect 이 이미 `expected_*` 와
                // 같으니 overwrite 는 no-op.
                //
                // - Z-order / activation 만 바꾸는 요청 (SWP_NOMOVE |
                //   SWP_NOSIZE) 은 건드리지 않고 통과.
                // - `visible=false` 동안엔 external 이 창을 enumerate 조차
                //   못 하지만 `ShowWindow(SW_SHOW)` 가 보내는 초기 메시지
                //   순서 때문에 방어적으로 `visible=true` 에서만 clamp.
                const wp: *WINDOWPOS = @ptrFromInt(@as(usize, @bitCast(lParam)));
                if (self.expected_set and self.visible) {
                    if ((wp.flags & SWP_NOMOVE) == 0 and (wp.x != self.expected_x or wp.y != self.expected_y)) {
                        wp.x = self.expected_x;
                        wp.y = self.expected_y;
                    }
                    if ((wp.flags & SWP_NOSIZE) == 0 and (wp.cx != self.expected_w or wp.cy != self.expected_h)) {
                        wp.cx = self.expected_w;
                        wp.cy = self.expected_h;
                    }
                }
                return DefWindowProcW(hwnd, msg, wParam, lParam);
            },
            WM_CHAR => {
                // KEYDOWN 가 같은 키를 소비했으면 짝꿍 WM_CHAR 도 swallow.
                // (rename Enter / Escape commit/cancel 후 PTY 로 \r / \x1b 새는
                // 사고 방지 — 소비자 입장에선 한 번의 keypress.)
                if (self.swallow_next_wm_char) {
                    self.swallow_next_wm_char = false;
                    return 0;
                }
                if (self.dispatchAppEvent(.{ .text_input = @intCast(wParam) })) return 0;
                // Ignore WM_CHAR generated from Ctrl+Shift shortcuts
                // (e.g. Ctrl+Shift+W sends 0x17 which would kill-word in shell)
                if (GetKeyState(VK_CONTROL) < 0 and GetKeyState(VK_SHIFT) < 0) {
                    return 0;
                }
                if (self.write_fn) |write_fn| {
                    const cp: u21 = @intCast(wParam);
                    // Backspace: send DEL (0x7F) instead of BS (0x08)
                    if (cp == 8) {
                        write_fn("\x7f", self.userdata);
                        return 0;
                    }
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch return 0;
                    write_fn(buf[0..len], self.userdata);
                }
                return 0;
            },
            WM_KEYDOWN => {
                const maybe_key: ?app_event.KeyInput = switch (wParam) {
                    0x0D => .enter,
                    0x1B => .escape,
                    0x08 => .backspace,
                    0x25 => .left,
                    0x27 => .right,
                    0x24 => .home,
                    0x23 => .end,
                    0x2E => .delete,
                    else => null,
                };
                if (maybe_key) |key| {
                    if (self.dispatchAppEvent(.{ .key_input = key })) {
                        // Enter / Escape / Backspace 는 TranslateMessage 가
                        // 짝꿍 WM_CHAR 를 큐에 넣는다 — 소비된 keydown 의 의도가
                        // PTY 로 새지 않도록 다음 WM_CHAR 1 회 swallow.
                        switch (wParam) {
                            0x0D, 0x1B, 0x08 => self.swallow_next_wm_char = true,
                            else => {},
                        }
                        return 0;
                    }
                }
                // Ctrl+Shift shortcuts
                if (GetKeyState(VK_CONTROL) < 0 and GetKeyState(VK_SHIFT) < 0) {
                    // Ctrl+Shift+C: copy current selection (#120)
                    if (wParam == 0x43) {
                        _ = self.dispatchAppEvent(.{ .shortcut = .copy_selection });
                        return 0;
                    }
                    // Ctrl+Shift+T: new tab
                    if (wParam == 0x54) {
                        _ = self.dispatchAppEvent(.{ .shortcut = .new_tab });
                        return 0;
                    }
                    // Ctrl+Shift+W: close active tab
                    if (wParam == 0x57) {
                        _ = self.dispatchAppEvent(.{ .shortcut = .close_active_tab });
                        return 0;
                    }
                    // Ctrl+Shift+V: paste from clipboard
                    if (wParam == 0x56) {
                        if (self.write_fn) |write_fn| {
                            self.pasteClipboard(write_fn);
                        }
                        return 0;
                    }
                    // Ctrl+Shift+R: reset terminal
                    if (wParam == 0x52) {
                        _ = self.dispatchAppEvent(.{ .shortcut = .reset_terminal });
                        return 0;
                    }
                    // Ctrl+Shift+P: open config in default editor (#128)
                    if (wParam == 0x50) {
                        _ = self.dispatchAppEvent(.{ .shortcut = .open_config });
                        return 0;
                    }
                    // Ctrl+Shift+L: open log in default editor (#128)
                    if (wParam == 0x4C) {
                        _ = self.dispatchAppEvent(.{ .shortcut = .open_log });
                        return 0;
                    }
                    // Ctrl+Shift+F12: dump perf snapshot (dev tool — moved
                    // from Ctrl+Shift+P which is now Open Config #128)
                    if (wParam == 0x7B) {
                        _ = self.dispatchAppEvent(.{ .shortcut = .dump_perf });
                        return 0;
                    }
                    // Ctrl+Shift+I: show About dialog
                    if (wParam == 0x49) {
                        _ = self.dispatchAppEvent(.{ .shortcut = .show_about });
                        return 0;
                    }
                    // Ctrl+Shift+[ (VK_OEM_4) / Ctrl+Shift+] (VK_OEM_6):
                    // 이전 / 다음 탭 (#125 — macOS Shift+Cmd+[ / ] 와 동등 키 pair).
                    if (wParam == 0xDB) {
                        _ = self.dispatchAppEvent(.{ .shortcut = .prev_tab });
                        return 0;
                    }
                    if (wParam == 0xDD) {
                        _ = self.dispatchAppEvent(.{ .shortcut = .next_tab });
                        return 0;
                    }
                }

                const vk_prior: WPARAM = 0x21; // Page Up
                const vk_next: WPARAM = 0x22; // Page Down

                // Shift+PageUp/Down: scroll viewport
                if (GetKeyState(VK_SHIFT) < 0 and (wParam == vk_prior or wParam == vk_next)) {
                    _ = self.dispatchAppEvent(.{
                        .scroll = .{
                            .page = if (wParam == vk_prior) .up else .down,
                        },
                    });
                    return 0;
                }

                // Only handle keys that do NOT generate WM_CHAR
                if (self.write_fn) |write_fn| {
                    const vk_up: WPARAM = 0x26;
                    const vk_down: WPARAM = 0x28;
                    const vk_left: WPARAM = 0x25;
                    const vk_right: WPARAM = 0x27;
                    const vk_home: WPARAM = 0x24;
                    const vk_end: WPARAM = 0x23;
                    const vk_delete: WPARAM = 0x2E;
                    const vk_insert: WPARAM = 0x2D;

                    switch (wParam) {
                        vk_up => write_fn("\x1b[A", self.userdata),
                        vk_down => write_fn("\x1b[B", self.userdata),
                        vk_right => write_fn("\x1b[C", self.userdata),
                        vk_left => write_fn("\x1b[D", self.userdata),
                        vk_home => write_fn("\x1b[H", self.userdata),
                        vk_end => write_fn("\x1b[F", self.userdata),
                        vk_delete => write_fn("\x1b[3~", self.userdata),
                        vk_insert => write_fn("\x1b[2~", self.userdata),
                        vk_prior => write_fn("\x1b[5~", self.userdata),
                        vk_next => write_fn("\x1b[6~", self.userdata),
                        else => {},
                    }
                }
                return 0;
            },
            WM_SIZE => {
                if (!self.layout_transition_active) {
                    if (self.resize_fn) |resize_fn| {
                        const grid = self.getGridSize();
                        resize_fn(grid.cols, grid.rows, self.userdata);
                    }
                }
                // `resize_fn` 이 D3D11 swap chain 을 `ResizeBuffers` 로 새
                // 크기에 맞춘 직후, 같은 WM_SIZE 턴에서 곧바로 새 크기
                // backbuffer 를 Present 하고, `DwmFlush` 로 DWM compositor 가
                // 지금까지 제출된 모든 composition 을 동기화하도록 block.
                //
                // DXGI BitBlt-model swap chain (`DXGI_SWAP_EFFECT_DISCARD` +
                // `BufferCount=1`) + WS_EX_LAYERED 조합은 rect 변경 직후 이전
                // window bounds 에 backbuffer 를 stretch 매핑해 "반화면을 늘린
                // 전체화면" 아티팩트를 만들기 쉬운데, 같은 턴에서 Present +
                // DwmFlush 를 강제하면 compositor 가 새 rect 로 바로 업데이트됨.
                //
                // `visible=false` 이면 skip — `show()` 가 어차피 layout 재적용
                // 후 첫 render tick 에서 present 하므로.
                if (self.visible and !self.layout_transition_active) {
                    if (self.render_fn) |render_fn| render_fn(self);
                    _ = DwmFlush();
                }
                return 0;
            },
            WM_DISPLAYCHANGE => {
                // 해상도 / bit-depth / monitor configuration 변경 — fullscreen
                // 이면 fullscreen rect, 아니면 저장된 dock % 로 re-fit.
                // `applyLayout` → `SetWindowPos` → `WM_SIZE` 로 PTY / 터미널
                // grid 가 reflow 됨.
                //
                // lParam = LOWORD(width) | HIWORD(height). 사용자 환경에 따라
                // 실제 해상도 변화가 없는 spurious broadcast 가 오는 케이스가
                // 있는데 (display utility 훅 의심 — Alt 키 press 만으로도
                // 발생), Alt+Enter 직후 그 spurious 메시지에서 `applyLayout`
                // 을 다시 돌리면 방금 적용한 rect 를 DWM 이 이전 surface 로
                // 덮어쓰는 race 가 생김. 따라서 실제 해상도가 바뀐 경우에만
                // 재적용.
                //
                // 숨겨진 창이면 건너뜀 — `show()` 가 다음에 어차피 `applyLayout`
                // 을 호출해 재적용.
                const new_w: u32 = @intCast(lParam & 0xFFFF);
                const new_h: u32 = @intCast((lParam >> 16) & 0xFFFF);
                if (new_w == self.last_display_w and new_h == self.last_display_h) {
                    // 같은 해상도 — spurious broadcast. skip.
                    return 0;
                }
                self.last_display_w = new_w;
                self.last_display_h = new_h;
                if (self.visible) self.applyLayout();
                return 0;
            },
            WM_DPICHANGED => {
                // System or per-monitor DPI changed (e.g. moved between an
                // internal 150% panel and an external 100% monitor).
                //
                // Handling order matters:
                //   1. Rebuild the GDI font at the new DPI so `cell_width` /
                //      `cell_height` are in the new monitor's physical px.
                //   2. Let the app rebuild its DirectWrite font + glyph atlas
                //      at the matching `pixels_per_dip` — otherwise glyphs
                //      stay rasterized at the old DPI and look tiny / blurry.
                //   3. Re-apply the layout via `applyLayout` — fullscreen
                //      rect if active, else saved dock percentages. Calls
                //      `SetWindowPos` which cascades into `WM_SIZE`, and
                //      `resize_fn` re-reflows the terminal grid using the
                //      freshly updated `cell_width` / `cell_height`.
                //
                // The suggested rect in lParam is intentionally ignored and
                // returning 0 prevents the default proc from auto-resizing
                // to it, so our own layout wins.
                const new_dpi: UINT = @intCast(wParam & 0xFFFF);
                self.rebuildFontForDpi(new_dpi);
                if (self.font_change_fn) |f| f(self, self.userdata);
                // 숨겨진 창이면 applyLayout 건너뜀 — `show()` 에서 재적용.
                if (self.visible) self.applyLayout();
                return 0;
            },
            WM_SETTINGCHANGE => {
                // 작업 표시줄 / work-area 변경 (예: auto-hide 토글). dock
                // 파라미터는 `rcWork` 기준으로 계산되므로 work-area 가 바뀌면
                // 재적용해 줘야 현재 taskbar 공간을 정확히 비켜감. fullscreen
                // 상태에서도 `applyFullscreen` 이 최신 `rcWork` 로 재계산해
                // 일관성 유지.
                if (wParam == SPI_SETWORKAREA) {
                    // 숨겨진 창이면 applyLayout 건너뜀 — `show()` 에서 재적용.
                    if (self.visible) self.applyLayout();
                }
                return DefWindowProcW(hwnd, msg, wParam, lParam);
            },
            WM_CLOSE => {
                // Shell already exited (마지막 탭 PTY 종료 후 자동 close 요청) —
                // confirm 없이 즉시 종료. closeAfterShellExit 가 set.
                if (self.shell_exited) {
                    _ = DestroyWindow(hwnd);
                    return 0;
                }
                // 사용자 발생 close (Alt+F4 / 시스템 메뉴) — app 에 결정 위임.
                // 단일 탭 skip / 다중 탭 confirm 다이얼로그 (#116) 정책은
                // app_controller 측에서 통일 처리.
                if (self.quit_request_fn) |f| {
                    if (!f(self.userdata)) return 0;
                }
                _ = DestroyWindow(hwnd);
                return 0;
            },
            WM_DESTROY => {
                PostQuitMessage(0);
                return 0;
            },
            WM_SYSKEYDOWN => {
                // Alt+Enter => monitor fullscreen.
                // Shift+Alt+Enter => work-area fullscreen that keeps taskbar visible.
                // Alt+Enter: fullscreen 토글. `DefWindowProcW` 로 위임하지
                // 않음 — Windows 기본 경로가 어떤 SC_ 명령을 생성하든 우리가
                // 정의한 동작 (현재 모니터 `rcWork` ↔ 저장된 dock) 으로 가게.
                if (wParam == VK_RETURN) {
                    self.toggleFullscreenMode(if (GetAsyncKeyState(VK_SHIFT) < 0) .workarea else .monitor);
                    return 0;
                }
                // Alt+1 ~ Alt+9: 탭 전환.
                if (wParam >= 0x31 and wParam <= 0x39) {
                    _ = self.dispatchAppEvent(.{
                        .shortcut = .{
                            .switch_tab = wParam - 0x31,
                        },
                    });
                    return 0;
                }
                return DefWindowProcW(hwnd, msg, wParam, lParam);
            },
            WM_LBUTTONDOWN => {
                _ = self.dispatchAppEvent(.{
                    .mouse_down = .{
                        .x = getMouseX(lParam),
                        .y = getMouseY(lParam),
                    },
                });
                _ = SetCapture(hwnd);
                return 0;
            },
            WM_LBUTTONDBLCLK => {
                _ = self.dispatchAppEvent(.{
                    .mouse_double_click = .{
                        .x = getMouseX(lParam),
                        .y = getMouseY(lParam),
                    },
                });
                return 0;
            },
            WM_MOUSEMOVE => {
                _ = self.dispatchAppEvent(.{
                    .mouse_move = .{
                        .x = getMouseX(lParam),
                        .y = getMouseY(lParam),
                        .left_button = (wParam & MK_LBUTTON) != 0,
                    },
                });
                return 0;
            },
            WM_LBUTTONUP => {
                _ = self.dispatchAppEvent(.{
                    .mouse_up = .{
                        .x = getMouseX(lParam),
                        .y = getMouseY(lParam),
                    },
                });
                _ = ReleaseCapture();
                return 0;
            },
            WM_MOUSEWHEEL => {
                _ = self.dispatchAppEvent(.{
                    .scroll = .{
                        .wheel = getWheelDelta(wParam),
                    },
                });
                return 0;
            },
            // 우클릭 paste (#119) — cmd.exe console 표준 패턴. 이전 가운데 버튼
            // (WM_MBUTTONDOWN) 은 deprecated. macOS 의 tildazRightMouseDown 과
            // 동등. SPEC.md §3 / §11 참고.
            WM_RBUTTONDOWN => {
                if (self.write_fn) |write_fn| {
                    self.pasteClipboard(write_fn);
                }
                return 0;
            },
            WM_TAB_CLOSED => {
                _ = self.dispatchAppEvent(.{ .tab_closed = wParam });
                return 0;
            },
            else => {},
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    fn getSelf(hwnd: HWND) ?*Window {
        const ptr = GetWindowLongPtrW(hwnd, GWL_USERDATA);
        if (ptr == 0) return null;
        return @ptrFromInt(@as(usize, @intCast(ptr)));
    }

    pub fn getClientSize(self: *const Window) struct { w: c_int, h: c_int } {
        if (self.hwnd == null) return .{ .w = 800, .h = 400 };
        var rect: RECT = undefined;
        _ = GetClientRect(self.hwnd, &rect);
        return .{ .w = rect.right - rect.left, .h = rect.bottom - rect.top };
    }

    pub fn closeAfterShellExit(self: *Window) void {
        self.shell_exited = true;
        if (self.hwnd) |hwnd| {
            _ = PostMessageW(hwnd, WM_CLOSE, 0, 0);
        }
    }

    pub fn postTabClosed(self: *const Window, tab_ptr: usize) void {
        if (self.hwnd) |hwnd| {
            _ = PostMessageW(hwnd, WM_TAB_CLOSED, tab_ptr, 0);
        }
    }

    fn pasteClipboard(self: *Window, write_fn: *const fn ([]const u8, ?*anyopaque) void) void {
        if (OpenClipboard(self.hwnd) == 0) return;
        defer _ = CloseClipboard();

        const handle = GetClipboardData(CF_UNICODETEXT) orelse return;
        const raw_ptr = GlobalLock(handle) orelse return;
        defer _ = GlobalUnlock(handle);
        const wide_ptr: [*]const WCHAR = @ptrCast(@alignCast(raw_ptr));

        // Find length of null-terminated UTF-16 string
        var len: usize = 0;
        while (wide_ptr[len] != 0) : (len += 1) {
            if (len >= 65536) break; // safety limit
        }
        if (len == 0) return;

        // Convert UTF-16 to UTF-8 and send to PTY
        var buf: [4]u8 = undefined;
        var i: usize = 0;
        while (i < len) {
            const unit = wide_ptr[i];
            i += 1;
            var cp: u21 = undefined;
            if (unit >= 0xD800 and unit <= 0xDBFF) {
                // Surrogate pair
                if (i < len) {
                    const low = wide_ptr[i];
                    i += 1;
                    cp = @intCast((@as(u21, unit - 0xD800) << 10) + @as(u21, low - 0xDC00) + 0x10000);
                } else break;
            } else {
                cp = @intCast(unit);
            }
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            write_fn(buf[0..n], self.userdata);
        }
    }

    pub fn copyToClipboard(self: *Window, text: [:0]const u8) void {
        if (text.len == 0) return;
        if (OpenClipboard(self.hwnd) == 0) return;
        defer _ = CloseClipboard();

        _ = EmptyClipboard();

        // Convert UTF-8 to UTF-16
        // Count required UTF-16 units
        var utf16_len: usize = 0;
        var view = std.unicode.Utf8View.init(text) catch return;
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            if (cp > 0xFFFF) {
                utf16_len += 2; // surrogate pair
            } else {
                utf16_len += 1;
            }
        }

        // Allocate global memory (UTF-16 + null terminator)
        const alloc_size = (utf16_len + 1) * 2;
        const hmem = GlobalAlloc(GMEM_MOVEABLE, alloc_size) orelse return;
        const raw_lock = GlobalLock(hmem) orelse {
            _ = GlobalFree(hmem);
            return;
        };
        const ptr: [*]u8 = @ptrCast(raw_lock);

        // Write UTF-16 data
        var wide_ptr: [*]u16 = @ptrCast(@alignCast(ptr));
        var view2 = std.unicode.Utf8View.init(text) catch {
            _ = GlobalUnlock(hmem);
            _ = GlobalFree(hmem);
            return;
        };
        var iter2 = view2.iterator();
        var idx: usize = 0;
        while (iter2.nextCodepoint()) |cp| {
            if (cp > 0xFFFF) {
                const adj = cp - 0x10000;
                wide_ptr[idx] = @intCast(0xD800 + (adj >> 10));
                idx += 1;
                wide_ptr[idx] = @intCast(0xDC00 + (adj & 0x3FF));
                idx += 1;
            } else {
                wide_ptr[idx] = @intCast(cp);
                idx += 1;
            }
        }
        wide_ptr[idx] = 0; // null terminator

        _ = GlobalUnlock(hmem);
        _ = SetClipboardData(CF_UNICODETEXT, hmem);
    }

    pub fn getGridSize(self: *const Window) struct { cols: u16, rows: u16 } {
        if (self.hwnd == null) return .{ .cols = 120, .rows = 30 };
        var rect: RECT = undefined;
        _ = GetClientRect(self.hwnd, &rect);
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        const cols: u16 = if (self.cell_width > 0) @intCast(@max(1, @divTrunc(w, self.cell_width))) else 120;
        const rows: u16 = if (self.cell_height > 0) @intCast(@max(1, @divTrunc(h, self.cell_height))) else 30;
        return .{ .cols = cols, .rows = rows };
    }

    /// Re-export — config.DockPosition 이 cross-platform single source.
    pub const DockPosition = @import("config.zig").DockPosition;
};
