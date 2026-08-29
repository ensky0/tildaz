const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const windows = std.os.windows;
const app_event = @import("app_event.zig");
const dialog = @import("dialog.zig");
const log = @import("log.zig");
const messages = @import("messages.zig");
const paths = @import("paths.zig");
const perf = @import("perf.zig");
const dwrite_font = @import("font/windows/font.zig");
const font_spec = @import("font/spec.zig");
const config_mod = @import("config.zig");
const physical_key = @import("physical_key.zig");
const key_encode = @import("key_encode.zig");

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
/// redirection bitmap 없는 창 (#89 2단계) — 반투명은 DirectComposition 이
/// 담당하므로 legacy layered(BitBlt) 표면이 아예 안 만들어지게.
const WS_EX_NOREDIRECTIONBITMAP: DWORD = 0x00200000;
const CS_DBLCLKS: UINT = 0x0008;

// Window Messages
const WM_CLOSE: UINT = 0x0010;
const WM_DESTROY: UINT = 0x0002;
const WM_PAINT: UINT = 0x000F;
const WM_KEYDOWN: UINT = 0x0100;
const WM_KEYUP: UINT = 0x0101;
const WM_CHAR: UINT = 0x0102;
const WM_HOTKEY: UINT = 0x0312;
pub const WM_NEW_INSTANCE_REQUEST: UINT = 0x8000 + 267;
pub const WM_HOTKEY_CAPTURE_BEGIN: UINT = 0x8000 + 268;
pub const WM_HOTKEY_CAPTURE_END: UINT = 0x8000 + 269;
const WM_TIMER: UINT = 0x0113;
const WM_SIZE: UINT = 0x0005;
const WM_USER: UINT = 0x0400;
/// #439 — PTY 출력이 ring 에 들어갔다는 통보. **read thread 가 post 한다.**
///
/// 이것이 없던 동안 유휴 UI 스레드는 `WaitMessage` 로 자다가 `WM_FRAME_TICK` 이 와야
/// 비로소 ring 을 봤고, 그래서 프레임 주기가 그대로 응답 지연이 됐다 (실측 평균 8.40 ms ·
/// 최악 18.37 ms). 이 메시지가 그 대기를 끊는다.
///
/// **핸들러가 `renderFrameTick` 을 부른다.** Windows 는 렌더가 `WM_FRAME_TICK` /
/// `WM_TIMER` 에만 묶여 있어서, 깨우기만으로는 드레인만 되고 화면은 다음 tick 을 기다린다.
/// tick 은 vsync 위상과 무관한 순수 타이머라 (`frameClockThread` 주석) tick 밖에서 그려도
/// cadence 가 깨지지 않는다.
pub const WM_PTY_OUTPUT: UINT = WM_USER + 1;
pub const WM_TAB_CLOSED: UINT = WM_USER + 2;
/// #386 — 프레임 tick. clock 스레드가 화면 주사율 주기로 post 한다.
///
/// **메시지로 유지하는 것이 설계의 핵심**이다. 이전에는 `SetTimer` + `WM_TIMER` 였는데,
/// `SetTimer` 의 elapse 는 시스템 틱 (15.625 ms) 격자에서만 서비스돼서 `16` 이 실측 25.8 ms
/// (38.8 fps) 가 됐다. 주기만 타이머 밖으로 빼고 전달은 그대로 메시지로 두면, `MessageBoxW`
/// 같은 **모달 펌프도 이 tick 을 dispatch** 해서 다이얼로그를 띄운 채로도 배경 터미널이 계속
/// 그려지는 성질이 유지된다 (#282 C4 가 Linux 를 맞춘 기준이 이 성질이다).
pub const WM_FRAME_TICK: UINT = WM_USER + 3;
/// `WM_FRAME_TICK` 핸들러가 렌더 전에 비우는 입력 범위 (`pumpPendingInput`).
const WM_KEYFIRST: UINT = 0x0100;
const WM_KEYLAST: UINT = 0x0109;
const WM_MOUSEFIRST: UINT = 0x0200;
const WM_MOUSELAST: UINT = 0x020E;
const PM_REMOVE: UINT = 0x0001;
/// `PeekMessageW` 는 `GetMessageW` 처럼 반환값 0 으로 종료를 알리지 않으므로 (#387 의
/// `messageLoop`) 직접 비교한다.
const WM_QUIT: UINT = 0x0012;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_LBUTTONDBLCLK: UINT = 0x0203;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_RBUTTONDOWN: UINT = 0x0204;
const WM_MOUSEWHEEL: UINT = 0x020A;
// #502 — 가운데 버튼은 mouse reporting 이 실을 버튼 하나 (`Cb` 1). 이전에 우클릭
// paste 로 대체되며 빠졌던 메시지 (#119) 를 reporting 전용으로 되살린다.
const WM_MBUTTONDOWN: UINT = 0x0207;
const WM_MBUTTONUP: UINT = 0x0208;
const WM_DISPLAYCHANGE: UINT = 0x007E;
const WM_DPICHANGED: UINT = 0x02E0;
const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
const WM_IME_COMPOSITION: UINT = 0x010F;
const GCS_COMPSTR: DWORD = 0x0008;
const GCS_RESULTSTR: DWORD = 0x0800;
const WM_SETTINGCHANGE: UINT = 0x001A;
const WM_WINDOWPOSCHANGING: UINT = 0x0046;
const WM_WINDOWPOSCHANGED: UINT = 0x0047;
const WM_NCCALCSIZE: UINT = 0x0083;
const WM_ERASEBKGND: UINT = 0x0014;
const WM_SETCURSOR: UINT = 0x0020;
const HTCLIENT: u16 = 1;
const WM_ACTIVATEAPP: UINT = 0x001C;
const SPI_SETWORKAREA: WPARAM = 0x002F;
const MK_LBUTTON: WPARAM = 0x0001;
const MK_RBUTTON: WPARAM = 0x0002;
const MK_SHIFT: WPARAM = 0x0004;
const MK_CONTROL: WPARAM = 0x0008;
const MK_MBUTTON: WPARAM = 0x0010;

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
// LoadCursorW 의 두 번째 param 은 `MAKEINTRESOURCE(id)` — 실제 pointer 가 아닌
// resource id 로 reinterpret 됨. WCHAR (align 2) ptr 로 declare 하면 odd ID
// (`IDC_IBEAM = 32513`) 가 alignment 위반. `?*const anyopaque` 로 alignment
// 요구 제거.
const IDC_ARROW: ?*const anyopaque = @ptrFromInt(32512);
const IDC_IBEAM: ?*const anyopaque = @ptrFromInt(32513);
// #483 — 분할선 리사이즈 커서 (winuser.h: IDC_SIZEWE 32644 · IDC_SIZENS 32645).
const IDC_SIZEWE: ?*const anyopaque = @ptrFromInt(32644);
const IDC_SIZENS: ?*const anyopaque = @ptrFromInt(32645);
const GWL_USERDATA: c_int = -21;
const TRANSPARENT: c_int = 1;
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
extern "user32" fn TranslateMessage(*const MSG) callconv(.c) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.c) LRESULT;
extern "user32" fn PeekMessageW(*MSG, HWND, UINT, UINT, UINT) callconv(.c) BOOL;
/// #387 — 메시지 큐가 빌 때 블록한다. `messageLoop` 이 `GetMessageW` 대신 쓰는 이유는
/// 그 함수 주석에 있다.
extern "user32" fn WaitMessage() callconv(.c) BOOL;
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
// #496 1-c — 위치 표기 hotkey 를 잡는 저수준 훅. 왜 `RegisterHotKey` 가 아닌지는
// `Window.installPositionHotkey` 주석에 있다.
const LowLevelKeyboardProc = fn (c_int, WPARAM, LPARAM) callconv(.c) LRESULT;
extern "user32" fn SetWindowsHookExW(c_int, *const LowLevelKeyboardProc, ?*anyopaque, DWORD) callconv(.c) ?*anyopaque;
extern "user32" fn UnhookWindowsHookEx(?*anyopaque) callconv(.c) BOOL;
extern "user32" fn CallNextHookEx(?*anyopaque, c_int, WPARAM, LPARAM) callconv(.c) LRESULT;
// modifier 상태는 아래 `GetAsyncKeyState` 로 읽는다 (이미 선언돼 있다).
/// `WH_KEYBOARD_LL` 콜백이 받는 구조체. **`scanCode` 가 이 훅을 쓰는 이유다** — layout
/// 이 개입하지 않은 raw 값이고, 위치 표기가 뜻하는 것이 정확히 그 값이다.
const KBDLLHOOKSTRUCT = extern struct {
    vkCode: DWORD,
    scanCode: DWORD,
    flags: DWORD,
    time: DWORD,
    dwExtraInfo: usize,
};
extern "user32" fn GetCursorPos(*POINT) callconv(.c) BOOL;
extern "user32" fn MonitorFromPoint(POINT, DWORD) callconv(.c) ?*anyopaque;
extern "user32" fn MonitorFromWindow(HWND, DWORD) callconv(.c) ?*anyopaque;
extern "user32" fn GetMonitorInfoW(?*anyopaque, *MONITORINFO) callconv(.c) BOOL;
// #451 — 0.16 이 `std.os.windows.HRESULT` 를 없앴다 (NtDll 이관 정리). 우리 코드가
// 이미 두 곳에서 같은 정의를 쓰고 있어 (`font/windows/directwrite.zig` ·
// `renderer/windows/d3d11.zig`) 같은 모양으로 여기에도 둔다.
const HRESULT = c_long;
extern "dwmapi" fn DwmSetWindowAttribute(HWND, DWORD, *const anyopaque, DWORD) callconv(.c) HRESULT;
extern "dwmapi" fn DwmFlush() callconv(.c) HRESULT;
extern "user32" fn SetWindowLongPtrW(HWND, c_int, isize) callconv(.c) isize;
extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(.c) isize;
extern "user32" fn LoadCursorW(HINSTANCE, ?*const anyopaque) callconv(.c) HCURSOR;
extern "user32" fn SetCursor(HCURSOR) callconv(.c) HCURSOR;
extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.c) BOOL;
extern "user32" fn SetTimer(HWND, usize, UINT, ?*anyopaque) callconv(.c) usize;
extern "user32" fn KillTimer(HWND, usize) callconv(.c) BOOL;
// #386 — 프레임 clock. `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION` 은 `timeBeginPeriod(1)` 로
// 시스템 전체 타이머 해상도를 올리지 않고도 정밀한 주기를 얻는 수단이다 (Win10 1803+).
// `SetTimer` 를 못 쓰는 이유는 `WM_FRAME_TICK` 주석에 있다.
extern "kernel32" fn CreateWaitableTimerExW(?*anyopaque, ?[*:0]const WCHAR, DWORD, DWORD) callconv(.c) ?*anyopaque;
extern "kernel32" fn SetWaitableTimer(?*anyopaque, *const i64, LONG, ?*anyopaque, ?*anyopaque, BOOL) callconv(.c) BOOL;
extern "kernel32" fn WaitForSingleObject(?*anyopaque, DWORD) callconv(.c) DWORD;
extern "kernel32" fn CloseHandle(?*anyopaque) callconv(.c) BOOL;
extern "gdi32" fn GetDeviceCaps(HDC, c_int) callconv(.c) c_int;
/// #386 ② — 이 메시지들은 렌더 게이트를 **열지 않는다.** 그 밖의 모든 메시지는 연다
/// (`wndProc` 참고 — 빠뜨려서 화면이 안 갱신되는 쪽보다 한 프레임 더 그리는 쪽이 낫다).
///
/// - 프레임 tick 두 개: 게이트를 여는 주체가 아니라 게이트를 *묻는* 주체다.
/// - **`WM_IME_NOTIFY`**: 이게 없으면 게이트가 절대 닫히지 않는다. 우리는 렌더 끝에
///   `imeSetCompositionPos` (`ImmSetCompositionWindow`) 를 부르는데, IMM 이 그 응답으로
///   `WM_IME_NOTIFY` 를 보낸다 → 게이트가 열려 다음 프레임을 그리고 → 또 부르고… 로
///   **자기 자신을 먹여 살리는 루프**가 된다 (실측: 유휴에 초당 120 회 = 프레임당 2 회).
///   IME 후보 창은 **OS 가** 그리므로 이 알림은 우리 렌더와 무관하다. 조합 내용 자체는
///   `WM_IME_COMPOSITION` (0x010F) 으로 오고 그건 게이트를 연다.
fn isFrameGateExempt(msg: UINT) bool {
    return msg == WM_FRAME_TICK or msg == WM_TIMER or msg == WM_IME_NOTIFY;
}

const WM_IME_NOTIFY: UINT = 0x0282;
const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: DWORD = 0x0002;
const TIMER_ALL_ACCESS: DWORD = 0x1F0003;
const WAIT_INFINITE: DWORD = 0xFFFFFFFF;
const WAIT_OBJECT_0: DWORD = 0;
/// `GetDeviceCaps` index — 현재 디스플레이 모드의 세로 재생률 (Hz).
const VREFRESH: c_int = 116;
/// 재생률을 못 읽었을 때 (`GetDeviceCaps` 가 0 / 1 = unknown) 쓸 값.
const FALLBACK_REFRESH_HZ: i64 = 60;
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
// #533 — Alt 조합의 글자를 얻는다. `WM_SYSKEYDOWN` 에는 글자가 실려 오지 않아서
// (`WM_SYSCHAR` 는 Alt 를 이미 먹은 뒤라 쓸 수 없다) 직접 번역한다.
extern "user32" fn ToUnicodeEx(UINT, UINT, [*]const u8, [*]WCHAR, c_int, UINT, ?*anyopaque) callconv(.c) c_int;
extern "user32" fn GetKeyboardLayout(DWORD) callconv(.c) ?*anyopaque;
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
const VK_MENU: c_int = 0x12; // Alt
const VK_LBUTTON: c_int = 0x01;
const VK_MBUTTON: c_int = 0x04;
const VK_LWIN: c_int = 0x5B;
const VK_RWIN: c_int = 0x5C;

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

// === Imm32 (IME) ===
// HIMC = IME context handle. GCS_COMPSTR = preedit (조합 중), GCS_RESULTSTR =
// commit 결과. 둘 다 직접 추출한다. RESULTSTR를 DefWindowProcW에 넘기면 WM_CHAR가
// action 뒤에 queue되므로, 원래 입력 대상에 동기 dispatch한 뒤 message를 소비한다.
const HIMC = ?*opaque {};
extern "imm32" fn ImmGetContext(HWND) callconv(.c) HIMC;
extern "imm32" fn ImmReleaseContext(HWND, HIMC) callconv(.c) BOOL;
extern "imm32" fn ImmGetCompositionStringW(HIMC, DWORD, ?*anyopaque, DWORD) callconv(.c) c_long;
extern "imm32" fn ImmSetCompositionStringW(HIMC, DWORD, ?*const anyopaque, DWORD, ?*const anyopaque, DWORD) callconv(.c) BOOL;
extern "imm32" fn ImmNotifyIME(HIMC, DWORD, DWORD, DWORD) callconv(.c) BOOL;
extern "imm32" fn ImmSetCompositionWindow(HIMC, *COMPOSITIONFORM) callconv(.c) BOOL;
const NI_COMPOSITIONSTR: DWORD = 0x0015;
const CPS_COMPLETE: DWORD = 0x1;
const CPS_CANCEL: DWORD = 0x4;
const SCS_SETSTR: DWORD = 0x0009;
const CFS_POINT: DWORD = 0x0002;
/// IME composition / candidate window 위치 지정 (#164 1d). dwStyle = CFS_POINT
/// 면 IME 가 ptCurrentPos 근처에 popup. 일본 / 중국 IME 의 한자 후보 list 가
/// cursor 옆 자연스럽게 따라옴.
const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

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

pub const FullscreenMode = enum { none, monitor, workarea };

pub const Window = struct {
    /// `WM_SETCURSOR` (#193) — client 영역 안의 위치별 cursor 분류. 결정은
    /// host (app) 가 — cell 영역만 알면 되고, 그 외는 `.other` 로 default arrow.
    /// #483 5단계 — 분할선 위는 좌우 / 상하 리사이즈 커서 (`IDC_SIZEWE` / `IDC_SIZENS`).
    pub const CursorRegion = enum { cell, other, separator_v, separator_h };

    /// #451 — `Io` · 환경변수 묶음. host 의 `run(rt, …)` 이 창을 만들 때 넣는다.
    rt: Runtime,
    owner_hwnd: HWND = null,
    hwnd: HWND = null,
    visible: bool = false,
    font: HFONT = null,
    cell_width_px: c_int = 8,
    cell_height_px: c_int = 16,
    render_fn: ?*const fn (*Window) void = null,
    /// #352 — "창 크기가 바뀌었다" 는 **알림만** 한다. 이전에는 `fn (u16, u16, …)` 로
    /// 터미널 격자 cols/rows 를 인자로 넘겼는데, window layer 는 padding · scrollbar ·
    /// 탭바를 몰라서 (그건 `App` 소유) 그 값을 만들려고 `getGridSize` 라는 *두 번째,
    /// 틀린* 격자 함수를 길러야 했고 — 정작 콜백(`App.onResize`)은 인자를 버리고
    /// `getTerminalGridSize` 로 다시 계산했다. 계약에서 격자를 빼면 그 함수와 그 안의
    /// 가짜 fallback 이 함께 사라진다.
    resize_fn: ?*const fn (?*anyopaque) void = null,
    /// #493 3-c — `[keys]` 의 바인딩. `host/windows.zig` 의 `run()` 이 config 수명
    /// 동안 유효한 slice 를 넣는다. 비어 있으면 단축키가 하나도 없는 상태이고,
    /// 그것은 사용자가 `[keys]` 를 전부 `[]` 로 둔 경우와 같다.
    key_bindings: []const config_mod.KeyBinding = &.{},
    userdata: ?*anyopaque = null,
    write_fn: ?*const fn ([]const u8, ?*anyopaque) void = null,
    app_event_fn: ?*const fn (app_event.Event, ?*anyopaque) bool = null,
    /// #533 — 키 인코딩 옵션 (DEC mode · kitty flags). `window.zig` 는 `SessionCore` 를
    /// 모르므로 `app_event_fn` 과 같은 콜백 패턴으로 받는다. 없으면 기본값이라 터미널이
    /// 켠 mode 가 반영되지 않는다.
    encode_options_fn: ?*const fn (?*anyopaque) key_encode.Options = null,
    /// #387 — 메시지 큐가 빈 순간에 밀린 PTY 출력을 한 번 더 파싱하는 host 콜백.
    /// 반환값은 "더 할 일이 있나" — 참이면 `messageLoop` 이 블록하지 않고 다시 돈다.
    /// `window.zig` 는 `SessionCore` 를 모르므로 `app_event_fn` 과 같은 콜백 패턴을 쓴다.
    idle_drain_fn: ?*const fn (?*anyopaque) bool = null,
    /// #245 — drag-select auto-scroll 상태. 타이머 활성 여부 + 마지막 마우스 위치
    /// (타이머가 이 좌표로 synthetic mouse_move 재전송).
    auto_scroll_active: bool = false,
    last_mouse_x: c_int = 0,
    last_mouse_y: c_int = 0,
    /// #386 — 프레임 clock. 화면 주사율 주기로 `WM_FRAME_TICK` 을 post 하는 스레드와
    /// 그 스레드가 기다리는 고해상도 waitable timer. `SetTimer` 를 쓰지 않는 이유는
    /// `WM_FRAME_TICK` 주석에 있다.
    frame_clock: ?std.Thread = null,
    frame_timer: ?*anyopaque = null,
    frame_clock_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// tick coalescing. UI 스레드가 앞의 tick 을 아직 처리하지 않았으면 새로 post 하지
    /// 않는다 — 없으면 큐에 tick 이 쌓여 밀린 프레임을 몰아 그리게 된다. 하네스 `frame`
    /// 층이 "놓친 vsync 를 따라잡지 않는다" 로 모사한 정책과 같다.
    frame_tick_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// #439 — `WM_PTY_OUTPUT` coalescing. `frame_tick_pending` 과 같은 이유다 — 폭포 중에는
    /// read thread 가 초당 수천 번 통보하는데, 그대로 post 하면 메시지 큐가 그만큼 쌓여
    /// 정작 입력이 뒤로 밀린다. 미처리분이 있으면 더 넣지 않는다.
    output_wake_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// #439 — 직전 프레임이 **그릴 것이 없어 건너뛰었는가** (= 유휴인가). `App.onRender` 가
    /// 갱신하고 read thread 가 읽어 통보 여부를 정한다 (`notifyPtyOutput`).
    frame_idle: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 한 프레임의 길이 (100ns 단위). `startFrameClock` 이 재생률로 계산한다.
    frame_period_100ns: i64 = 0,
    /// #386 ② — 유휴 렌더 게이트. macOS `g_needs_render` · Linux `needs_redraw` 동등.
    ///
    /// **기본이 "그린다"** 이다 (`true` 로 시작하고 `wndProc` 이 프레임 tick 이 아닌 모든
    /// 메시지에서 연다). macOS 처럼 20 여 곳에 `requestRender()` 를 흩으면 한 곳만 빠져도
    /// 화면이 안 갱신되는 사용자 가시 버그가 되는데, Windows 는 입력이 전부 `wndProc` 을
    /// 지나므로 **범위로 열고 tick 만 막는** 편이 안전하다. 한 프레임 더 그리는 쪽으로
    /// 치우쳐도 유휴에는 tick 말고 오는 메시지가 없어서 절전 효과는 그대로다.
    ///
    /// 렌더한 프레임에서 `app_controller` 가 clear 한다.
    needs_render: bool = true,
    /// 사용자가 윈도우 닫기를 요청 (Alt+F4 / 시스템 메뉴 / WM_CLOSE) 했을 때
    /// 호출. true 반환 = 종료 진행 (DestroyWindow), false 반환 = 종료 취소.
    /// macOS `applicationShouldTerminate:` 와 같은 역할 (#116). 다중 탭 confirm
    /// 다이얼로그는 app 측에서 띄우고 결과만 반환.
    quit_request_fn: ?*const fn (?*anyopaque) bool = null,
    /// F1 hide 직전 호출 (#175). app 측이 preedit 등 진행 중인
    /// 입력 상태를 commit 처리. show 분기는 호출 안 함.
    before_hide_fn: ?*const fn (?*anyopaque) void = null,
    /// #282 A11 — IME 조합 시작 시 활성 탭을 맨 아래로 (scroll-on-keystroke,
    /// #242). 스크롤백 올린 상태에서 조합 시작 시 preedit 이 안 보이는 것 방지.
    /// macOS/Linux 는 preedit 경로에서 이미 호출 — Windows 만 빠져 있었음.
    scroll_to_bottom_fn: ?*const fn (?*anyopaque) void = null,
    /// Invoked after `rebuildFontForDpi` finishes so the app (renderer / UI
    /// layout) can re-raster glyphs and rescale DPI-dependent constants
    /// before `SetWindowPos` cascades into `WM_SIZE`.
    font_change_fn: ?*const fn (*Window, ?*anyopaque) void = null,
    /// `WM_SETCURSOR` — client 영역 안 좌표 (`x`, `y`) 가 cell 영역인지 그 외인지
    /// 결정하는 host callback. null 이면 항상 default arrow (#193). host 의
    /// `effectiveTabBarHeight` / `SCROLLBAR_W` / `TERMINAL_PADDING` 를 다 알아야
    /// 정확한 hit test 가능 — Window 가 모르는 정보라 callback 으로 외부화.
    cursor_region_fn: ?*const fn (x: c_int, y: c_int, userdata: ?*anyopaque) CursorRegion = null,
    /// `WM_SETCURSOR` 마다 LoadCursorW 호출 비용 피하려 init 에서 캐시 (#193).
    cursor_arrow: HCURSOR = null,
    cursor_ibeam: HCURSOR = null,
    cursor_sizewe: HCURSOR = null,
    cursor_sizens: HCURSOR = null,
    shell_exited: bool = false,
    dc: HDC = null, // DC for GDI font measurement

    // Font-creation parameters — remembered so `rebuildFontForDpi` can
    // recreate the GDI font and re-measure cell metrics at the new DPI
    // when `WM_DPICHANGED` fires.
    /// font.family chain — `[0]` 이 primary (GDI CreateFontW 의 face name + 셀
    /// 메트릭 측정 base). chain entry 1+ 는 renderer 의 DWriteFontContext 에서
    /// codepoint glyph 폴백 우선순위로 사용. config.MAX_FONT_FAMILIES (8) 와
    /// 동일 크기 — 동기화 유지.
    font_chain: [8][*:0]const WCHAR = undefined,
    font_chain_count: u8 = 0,
    terminal_font: font_spec.Spec = .{
        .size_logical = 15.0,
        .cell_width_ratio = 1.0,
        .line_height_ratio = 1.1,
    },
    current_dpi: UINT = 96,

    // Last position parameters — re-applied on WM_DISPLAYCHANGE / WM_DPICHANGED /
    // WM_SETTINGCHANGE(SPI_SETWORKAREA) and on show(), so the window tracks the
    // current monitor's work area when resolution, DPI, or taskbar changes.
    dock: DockPosition = .top,
    width_percent: f32 = 50.0,
    height_percent: f32 = 100.0,
    offset_percent: f32 = 100.0,
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

    /// BMP 밖 codepoint (이모지 U+1F300+ 등) 입력 시 Windows 가 UTF-16 surrogate
    /// pair 로 두 번 WM_CHAR 를 보냄 — 첫 번째 high surrogate (0xD800..0xDBFF)
    /// 는 단독으론 invalid codepoint 라 PTY 전송 실패. 첫
    /// surrogate 를 보관 → 두 번째 (low surrogate, 0xDC00..0xDFFF) 도착하면
    /// 결합해 단일 u21 codepoint 로 dispatch. emoji picker (`Win+.`) 입력이
    /// 안 되던 사고 (시연 중 발견 — 2026-05-03).
    pending_high_surrogate: u16 = 0,

    /// WM_KEYDOWN 가 소비한 키가 TranslateMessage 로 동시에 WM_CHAR (Enter `\r`,
    /// Escape `\x1b`, Backspace `\x08`) 를 큐에 넣는다. KEYDOWN 핸들러의 `return 0`
    /// 만으로는 그 WM_CHAR 가 막히지 않아 PTY 로 새어 들어감 (예: command menu
    /// 가 소비한 Enter 가 prompt 에 빈 줄 입력). KEYDOWN 에서 해당 키를 소비하면
    /// 이 flag 를 set, WM_CHAR 진입 즉시 swallow + clear.
    swallow_next_wm_char: bool = false,

    /// IME composition (preedit) 버퍼 — UTF-8. WM_IME_COMPOSITION 의 GCS_COMPSTR
    /// 를 ImmGetCompositionStringW 로 받아 UTF-16 → UTF-8 변환 후 저장 (#164).
    /// renderer 가 매 frame 읽어 cursor 옆 inline overlay (mac 동등). 한글 / 일본
    /// 어 / 중국어 등 모든 IMM 기반 IME 가 같은 path. GCS_RESULTSTR도 이 message
    /// 안에서 동기 처리해 action보다 먼저 원래 입력 대상에 반영한다 (#313).
    preedit_buf: [256]u8 = undefined,
    preedit_len: usize = 0,
    /// `imeCompleteComposition`의 ImmNotifyIME가 nested WM_IME_COMPOSITION을
    /// 동기 발생시켰는지 확인한다. 결과를 동기 처리하지 못하면 caller가 action을
    /// 보류해 queued WM_CHAR가 새 탭/새 prompt로 이동하지 않게 한다.
    ime_complete_in_progress: bool = false,
    ime_complete_result_ok: bool = false,
    /// Ctrl chord의 실제 key가 preedit result보다 늦게 queue될 수 있어, 바로
    /// 앞의 GCS_RESULTSTR를 target에 보내지 않고 잠깐 보관한다. 다음 non-modifier
    /// key/action에서 input_policy에 따라 commit/discard/IMM composition 복원 중
    /// 하나로 정확히 한 번 소비한다 (#313 B1).
    ime_deferred_result: ?[]u8 = null,
    ime_preserve_requested: bool = false,
    hotkey_vkey: UINT = 0,
    hotkey_modifiers: UINT = 0,
    hotkey_registered: bool = false,
    /// #496 1-c — 위치 표기로 적은 hotkey 의 자리. null 이면 라벨 binding 이다.
    /// 이 값이 non-null 이면 등록 경로가 통째로 갈린다 — `hotkeyAcquire` 참고.
    hotkey_code: ?physical_key.PhysicalCode = null,

    /// #496 1-c — 위치 표기 hotkey 의 훅 상태.
    ///
    /// **왜 인스턴스 필드가 아니라 여기인가.** `WH_KEYBOARD_LL` 콜백은 `hwnd` 를 받지
    /// 않아 `getSelf` 로 창을 찾을 수 없다. 전역 hotkey 를 가진 창은 프로세스에 하나뿐
    /// (`HOTKEY_ID` 가 상수 하나인 것과 같은 전제) 이므로 콜백이 볼 값을 container 범위에
    /// 둔다. 콜백은 이 값들을 **읽기만** 한다.
    var g_hook: ?*anyopaque = null;
    var g_hook_hwnd: ?HWND = null;
    var g_hook_scan: u16 = 0;
    var g_hook_extended: bool = false;
    var g_hook_modifiers: UINT = 0;

    const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral(@import("instances.zig").window_class_name);
    const HOTKEY_ID: c_int = 1;
    const WH_KEYBOARD_LL: c_int = 13;
    const HC_ACTION: c_int = 0;
    /// `KBDLLHOOKSTRUCT.flags` bit 0 — `0xE0` prefix 자리다 (control pad / numpad 구분).
    const LLKHF_EXTENDED: DWORD = 0x01;
    // 필요한 `VK_*` (`CONTROL` · `SHIFT` · `MENU` · `LWIN` · `RWIN`) 는 파일 범위에 이미 있다.
    const VK_F1: UINT = 0x70;
    const VK_RETURN: WPARAM = 0x0D;
    const RENDER_TIMER_ID: usize = 1;
    // #245 — drag-select auto-scroll. 포인터가 터미널 경계 밖에 머무는 동안
    // 마지막 mouse_move 를 주기적으로 재전송 → app 의 updateTerminalSelection 이
    // 연속 스크롤 (이벤트 없어도 굴러감). app_controller 가 setAutoScroll 로 on/off.
    const AUTOSCROLL_TIMER_ID: usize = 2;
    const AUTOSCROLL_INTERVAL_MS: UINT = 40;
    const LayoutMonitorTarget = enum { cursor, window };

    pub fn init(self: *Window, font_chain: []const [*:0]const WCHAR, terminal_font: font_spec.Spec, opacity: u8) !void {
        if (font_chain.len == 0) return error.EmptyFontChain;
        const hInstance = GetModuleHandleW(null);

        // #193 — cursor handle 캐시. WM_SETCURSOR 매 호출마다 LoadCursorW 안 함.
        // LoadCursorW(null, IDC_*) 는 system shared resource — DestroyCursor 불필요.
        self.cursor_arrow = LoadCursorW(null, IDC_ARROW);
        self.cursor_ibeam = LoadCursorW(null, IDC_IBEAM);
        self.cursor_sizewe = LoadCursorW(null, IDC_SIZEWE);
        self.cursor_sizens = LoadCursorW(null, IDC_SIZENS);

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

        var title_buf: [32]u16 = undefined;
        var title_utf8_buf: [32]u8 = undefined;
        // #382 — 타이틀은 이 프로세스의 **역할**에서 나온다 (`instance_context.Role`).
        // Windows 는 worker 창을 타이틀로 찾으므로 (`instance_request.send` 의
        // `FindWindowW(class, "TildaZ-0")` · `hotkey_capture.broadcast` 의 같은 조회)
        // 측정 창이 worker 타이틀을 쓰면 그 조회가 측정 창을 집을 수 있다.
        //
        // Linux 도 같은 함수를 쓴다 — GNOME · Cinnamon extension 이 창 타이틀과 app_id 로
        // worker 창을 찾기 때문이다 (`host/linux/wayland_minimal.zig` 의
        // `createXdgToplevel`). host 마다 `switch` 를 두면 한쪽만 고쳐진다.
        const title_utf8 = @import("instances.zig").windowTitleForCurrentRole(&title_utf8_buf) catch "TildaZ";
        const title_len = std.unicode.utf8ToUtf16Le(&title_buf, title_utf8) catch 0;
        title_buf[title_len] = 0;
        // #89 — WS_EX_LAYERED 를 아예 쓰지 않는다. layered 창은 renderer 가
        // 구형 BitBlt swap chain(DISCARD, redirection bitmap 경유)으로 강제되어
        // fullscreen↔dock rect 전환 시 stale frame stretch 의 구조적 원인.
        // - opacity 100% (기본값): 일반 창 → renderer 가 hwnd flip-model.
        // - opacity <100% (#89 2단계): WS_EX_NOREDIRECTIONBITMAP 으로
        //   redirection bitmap 자체를 제거하고, renderer 가 DirectComposition
        //   swap chain + DComp visual SetOpacity(uniform) 로 반투명 합성 —
        //   LWA_ALPHA 와 같은 창 전체 균일 알파 의미론.
        const ex_style: DWORD = WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
            (if (opacity < 255) WS_EX_NOREDIRECTIONBITMAP else 0);
        self.hwnd = CreateWindowExW(
            ex_style,
            CLASS_NAME,
            @ptrCast(title_buf[0..title_len :0]),
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

        // DWM window transition 애니메이션 비활성화. Alt+Enter 로 fullscreen ↔
        // dock rect 전환 직후 F1 로 SW_HIDE 하면, DWM 이 "현재 rect 에서 이전
        // rect 로 shrink" 애니메이션을 재생하면서 중간 프레임의 WM_SIZE 를
        // broadcast 하는 현상이 관측됨. 예: fullscreen 상태에서 hide → WM_SIZE
        // 1440x1704 (직전 dock 사이즈) 가 hide 100ms 후 들어옴. 사용자 눈엔
        // "F1 눌렀는데 반화면이 잠깐 나타났다 사라짐" 으로 보임.
        // 이 속성을 켜면 DWM 이 transition 애니메이션을 건너뛰고 상태 전환이
        // 즉시 반영됨.
        const disable: BOOL = .TRUE;
        _ = DwmSetWindowAttribute(self.hwnd, DWMWA_TRANSITIONS_FORCEDISABLED, &disable, @sizeOf(BOOL));

        // Remember font chain + font-creation parameters so `rebuildFontForDpi`
        // can recreate the font + re-measure cell metrics on DPI changes.
        const limit = @min(font_chain.len, self.font_chain.len);
        for (font_chain[0..limit], 0..) |fam, i| self.font_chain[i] = fam;
        self.font_chain_count = @intCast(limit);
        self.terminal_font = terminal_font;

        // DC must exist before `rebuildFontForDpi` measures cell metrics.
        self.dc = GetDC(self.hwnd);

        const dpi = GetDpiForWindow(self.hwnd);
        const init_dpi: UINT = if (dpi > 0) dpi else 96;
        self.rebuildFontForDpi(init_dpi);

        // #386 — 프레임 clock 시작 (이전엔 여기서 `SetTimer(…, 16, …)` 이었다).
        self.startFrameClock();
    }

    /// 전역 핫키 등록 (config 기본값 = F1, modifiers=0). 실패 사유 (시연 중 발견):
    /// - Windows OS 가 예약: F12 = kernel debugger 용 (MSDN RegisterHotKey 명시).
    /// - 다른 system shortcut 과 충돌: Win+Shift+S (Snip & Sketch) 등 일부 Win+Shift
    ///   조합은 Windows shell 이 먼저 가로채서 우리 hotkey 가 안 도달.
    /// - 다른 앱이 이미 같은 조합을 등록.
    /// 이 셋은 외부 표시 없이 silent fail 하는 게 사고 — drop-down 정체상 hotkey 가
    /// 없으면 토글 자체가 안 되어 사용자가 *왜 안 되는지* 모른 채 헤맴. fatal dialog 로
    /// 종료 + config 파일 경로 + 알려진 reservation 안내.
    ///
    /// ## 왜 `init` 밖으로 분리했는가 (#382)
    ///
    /// 등록 여부는 **host 의 정책**이다 — 측정 모드는 등록하지 않는다 (평소 쓰는
    /// TildaZ 와 같은 키에 두 프로세스가 반응하므로). 그 정책을 `init` 의 인자로
    /// 넘기면서 `vkey 0` 을 "등록하지 않는다" 는 뜻으로 쓰고 `init` 한복판에서
    /// `return` 했던 것이 사고였다: 그 `return` 이 뒤따르는 font chain 저장 · `GetDC` ·
    /// `rebuildFontForDpi` · 렌더 타이머까지 함께 삼켜서, 측정 인스턴스가 **셀 메트릭을
    /// 재지 않은 기본값** (`cell_width_px` / `cell_height_px` = 8x16) 으로 떴다
    /// (Windows 실기: 같은 config 인데 정상 인스턴스 `cell=9x20` vs 측정 인스턴스
    /// `cell=8x16`). 그 상태로 `-size` 가 창을 만들면 격자 *수*는 맞아도 셀당 픽셀이
    /// 실제 폰트와 달라 (글리프 18px 이 16px 셀에 들어간다) "같은 격자 · 같은 폰트로
    /// 다른 터미널과 비교" 라는 옵션의 목적이 깨진다.
    ///
    /// 그래서 (1) 매직 값을 없애고 (2) 등록을 별도 단계로 뒀다. host 가
    /// `if (!opts.isStressRun()) window.registerGlobalHotkey(...)` 로 정책을 드러내며,
    /// macOS 의 `installEventTap` · Linux 의 `sway_ipc.registerToggleIfSway` 와 같은
    /// 형태다. 이제 이 정책 분기가 창 초기화를 삼킬 구조 자체가 없다.
    ///
    /// #496 1-c — 위치 표기 (`ctrl+[Backquote]`) 도 받는다. 그쪽은 `RegisterHotKey` 를
    /// 쓰지 않는다 — 이유는 `installPositionHotkey` 주석에 있다.
    pub fn registerGlobalHotkey(
        self: *Window,
        hotkey_vkey: u32,
        hotkey_modifiers: u32,
        hotkey_code: ?physical_key.PhysicalCode,
    ) void {
        self.hotkey_code = hotkey_code;
        self.hotkey_modifiers = hotkey_modifiers;
        self.hotkey_vkey = hotkey_vkey;
        if (!self.hotkeyAcquire(self.requireHwnd())) {
            var alloc_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
            const cfg_path = paths.configPath(self.rt, fba.allocator()) catch messages.unknown_path_msg;
            var msg_buf: [1024]u8 = undefined;
            // 두 경로의 실패 원인이 겹치지 않으므로 안내도 갈라야 한다 — 위치 표기는
            // 훅 설치가 막힌 것이고, 라벨은 OS hotkey 표가 이미 차 있는 것이다.
            const msg = if (self.hotkey_code) |code|
                std.fmt.bufPrint(
                    &msg_buf,
                    messages.hotkey_hook_failed_format,
                    .{ physical_key.name(code), self.hotkey_modifiers, cfg_path },
                ) catch messages.hotkey_hook_failed_fallback_msg
            else
                std.fmt.bufPrint(
                    &msg_buf,
                    messages.hotkey_registration_failed_format,
                    .{ self.hotkey_vkey, self.hotkey_modifiers, cfg_path },
                ) catch messages.hotkey_registration_failed_fallback_msg;
            dialog.showFatal(self.rt, messages.hotkey_registration_failed_title, msg);
        }
        // 등록에 성공한 경로에만 세운다 — `deinit` 의 `UnregisterHotKey` 와
        // `WM_HOTKEY_CAPTURE_BEGIN` / `_END` 가 이 flag 를 본다.
        //
        // 측정 인스턴스에서는 `false` 로 남는데, **세 곳이 다 no-op 은 아니다.**
        // `WM_HOTKEY_CAPTURE_END` 는 `!hotkey_registered` 일 때 등록을 *시도*하고
        // (`RegisterHotKey(hwnd, HOTKEY_ID, hotkey_modifiers, hotkey_vkey)`), 측정
        // 인스턴스는 두 필드가 기본값 0 이라 그 호출이 실패해 `0` 을 돌려준다 (호출자는
        // `HotkeyCaptureSyncFailed` 로 읽는다). 그러니까 `vkey 0` 의 의미가 인자에서
        // **필드 기본값**으로 옮겨간 것이고, 오늘 이 경로에 도달하지 않는 이유는 이 flag 가
        // 아니라 **창 타이틀이 분리돼 있어서** 다 — `hotkey_capture.broadcast` 는
        // `FindWindowW` 로 worker 타이틀을 찾으므로 측정 창을 집지 않는다
        // (`instances.windowTitleForCurrentRole`).
        self.hotkey_registered = true;
    }

    /// #496 1-c — 전역 hotkey 를 잡는다. **두 표기가 서로 다른 OS 기능을 쓴다.**
    ///
    /// 등록 · 해제가 세 곳에서 일어나므로 (`registerGlobalHotkey` ·
    /// `WM_HOTKEY_CAPTURE_BEGIN`/`_END` · `deinit`) 분기를 이 한 쌍에 모은다. 예전에는
    /// 세 곳이 각자 `RegisterHotKey` / `UnregisterHotKey` 를 불렀는데, 표기에 따라 기능이
    /// 갈리면 그 형태로는 한 곳만 고쳐도 어긋난다.
    fn hotkeyAcquire(self: *Window, hwnd: HWND) bool {
        if (self.hotkey_code) |code| return self.installPositionHotkey(hwnd, code);
        return RegisterHotKey(hwnd, HOTKEY_ID, self.hotkey_modifiers, self.hotkey_vkey).toBool();
    }

    fn hotkeyRelease(self: *Window, hwnd: HWND) bool {
        if (self.hotkey_code != null) return removePositionHotkey();
        return UnregisterHotKey(hwnd, HOTKEY_ID).toBool();
    }

    /// #496 1-c — 위치 표기 hotkey 를 `WH_KEYBOARD_LL` 훅으로 잡는다.
    ///
    /// **왜 `RegisterHotKey` 가 아닌가.** 그 API 는 virtual-key 만 받는데 **VK 는 layout
    /// DLL 이 배정하는 값이라 자판마다 자리가 움직인다** (실측: `VK_OEM_3` 이 US `0x29` ·
    /// 프랑스어 legacy `0x28` · 독일어 `0x27`). 그래서 자리를 VK 로 한 번 풀어 등록하면
    /// 그 값은 *그 layout 에서만* 맞는 파생값이 된다. 처음 구현이 그 파생값을 캐시하고
    /// `WM_INPUTLANGCHANGE` 에서 다시 풀었는데, 그 메시지는 **스레드별이고 포커스를 얻을
    /// 때 온다**. 드롭다운은 숨어 있는 것이 기본 상태라, 숨은 동안 layout 이 바뀌면
    /// 캐시가 낡은 채 남고 — 실측 — **핫키가 다른 물리 키로 옮겨갔다.** 위치 표기가
    /// 없애려던 바로 그 증상이다. 게다가 핫키가 먹어야 포커스를 얻고 포커스를 얻어야
    /// 캐시가 갱신되는 순환이라, 그 구조로는 창을 좁힐 수만 있고 닫을 수 없다.
    ///
    /// `KBDLLHOOKSTRUCT.scanCode` 는 layout 이 개입하지 않은 raw 값이고 위치 표기가 뜻하는
    /// 것이 정확히 그 값이다. 변환도 캐시도 없어 갱신할 대상 자체가 생기지 않는다.
    ///
    /// **라벨 표기는 계속 `RegisterHotKey` 다.** 라벨은 OS 가 keypress 시점에 layout DLL 로
    /// 풀어 주는 것이 옳은 동작이라 우리가 개입할 이유가 없다. 그래서 훅의 대가는 위치
    /// 표기를 쓴 사용자에게만 발생한다.
    ///
    /// 훅은 `hMod = null` · `threadId = 0` 으로 건다 — `WH_KEYBOARD_LL` 은 별 DLL 없이
    /// 이 프로세스의 콜백을 시스템이 부르는 형태다 (다른 훅 종류와 다르다).
    fn installPositionHotkey(self: *Window, hwnd: HWND, code: physical_key.PhysicalCode) bool {
        if (g_hook != null) _ = removePositionHotkey();
        const sc = physical_key.scanCode(code);
        g_hook_scan = sc.value;
        g_hook_extended = sc.extended;
        g_hook_modifiers = self.hotkey_modifiers;
        g_hook_hwnd = hwnd;
        g_hook = SetWindowsHookExW(WH_KEYBOARD_LL, &lowLevelKeyboardProc, null, 0);
        if (g_hook == null) {
            g_hook_hwnd = null;
            log.appendLine("hotkey", "position hotkey hook install failed for [{s}]", .{physical_key.name(code)});
            return false;
        }
        log.appendLine(
            "hotkey",
            "position hotkey armed: [{s}] scan=0x{x:0>2} extended={} modifiers=0x{x}",
            .{ physical_key.name(code), sc.value, sc.extended, g_hook_modifiers },
        );
        return true;
    }

    fn removePositionHotkey() bool {
        const hook = g_hook orelse return true;
        const ok = UnhookWindowsHookEx(hook).toBool();
        g_hook = null;
        g_hook_hwnd = null;
        return ok;
    }

    /// #496 1-c — 위치 표기 hotkey 의 훅 콜백.
    ///
    /// **여기서는 비교와 `PostMessageW` 만 한다.** 이 콜백은 시스템이 입력 스레드에서
    /// 부르고, `LowLevelHooksTimeout` (기본 300 ms) 을 넘기면 **훅이 조용히 제거된다** —
    /// 그러면 오류도 로그도 없이 핫키가 죽는다. 그래서 토글 같은 실제 작업은 창의
    /// 메시지 큐로 넘기고, 여기서는 절대 블로킹하지 않는다. `WM_HOTKEY` 를 그대로 쓰므로
    /// 라벨 경로와 처리부가 하나로 남는다.
    ///
    /// 맞으면 `1` 을 돌려 **삼킨다** — 아래 앱에 그 키가 새면 사용자가 핫키를 누를 때마다
    /// 편집기에 문자가 들어간다. `RegisterHotKey` 도 같은 자리에서 키를 소비한다.
    ///
    /// **injected 입력을 걸러내지 않는다** (`LLKHF_INJECTED`). `RegisterHotKey` 가 합성
    /// 입력에도 반응하므로 (실측) 그쪽과 동작을 맞춘다 — 자동화 · 접근성 도구가 핫키를
    /// 누를 수 있어야 하고, 두 표기가 여기서 갈릴 이유가 없다.
    fn lowLevelKeyboardProc(code: c_int, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT {
        match: {
            if (code != HC_ACTION) break :match;
            if (wParam != WM_KEYDOWN and wParam != WM_SYSKEYDOWN) break :match;
            const hwnd = g_hook_hwnd orelse break :match;
            const kb: *const KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
            if (@as(u16, @truncate(kb.scanCode)) != g_hook_scan) break :match;
            if (((kb.flags & LLKHF_EXTENDED) != 0) != g_hook_extended) break :match;
            if (!modifiersExactlyHeld(g_hook_modifiers)) break :match;
            _ = PostMessageW(hwnd, WM_HOTKEY, @intCast(HOTKEY_ID), 0);
            return 1;
        }
        return CallNextHookEx(null, code, wParam, lParam);
    }

    /// 요구한 modifier 가 눌려 있고 **나머지는 눌려 있지 않은지**. `RegisterHotKey` 가
    /// 그렇게 동작한다 — `Ctrl+Alt+X` 는 `ctrl+x` 를 발동시키지 않는다. 그 규칙을 여기서
    /// 다시 만들지 않으면 두 표기가 같은 config 로 다르게 동작한다.
    ///
    /// 훅은 modifier 상태를 주지 않으므로 `GetAsyncKeyState` 로 읽는다. 이 콜백은 키가
    /// 눌린 그 순간에 불리므로 시점이 어긋나지 않는다.
    fn modifiersExactlyHeld(mods: UINT) bool {
        const held = struct {
            fn f(vk: c_int) bool {
                return (@as(u16, @bitCast(GetAsyncKeyState(vk))) & 0x8000) != 0;
            }
        }.f;
        const want_alt = (mods & config_mod.Hotkey.MOD_ALT) != 0;
        const want_ctrl = (mods & config_mod.Hotkey.MOD_CTRL) != 0;
        const want_shift = (mods & config_mod.Hotkey.MOD_SHIFT) != 0;
        const want_super = (mods & config_mod.Hotkey.MOD_SUPER) != 0;
        if (held(VK_MENU) != want_alt) return false;
        if (held(VK_CONTROL) != want_ctrl) return false;
        if (held(VK_SHIFT) != want_shift) return false;
        if ((held(VK_LWIN) or held(VK_RWIN)) != want_super) return false;
        return true;
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

        const effective_dpi: u32 = if (new_dpi > 0) new_dpi else 96;
        const scaled_font_size: c_int = @intCast(self.terminal_font.physicalSizeRatioCeilPx(effective_dpi, 96));

        // GDI CreateFontW 는 single face — chain 의 primary (chain[0]) 만 셀
        // 메트릭 (advance width / line height) 측정에 사용. 글리프 폴백은
        // renderer 의 DWriteFontContext 가 chain 전체로 처리.
        //
        // 음수 cHeight = *em-size 컨벤션* (DWrite native + WT BackendD3D 동등).
        // 양수면 cell-height 컨벤션 — GDI 가 em 을 작게 잡아서 (Cascadia 18pt
        // → em 15.5) tmHeight 가 작아짐. 그러면 cell_h < DWrite 가 raster 한
        // glyph 의 ascent+descent 라 글자가 cell 밖으로 삐져나옴 (#148 B-2 후
        // 발견). 음수면 GDI 도 em=18 → tmHeight ≈ 21 → cell_h 가 DWrite asc+desc
        // 와 정합.
        const primary_family = if (self.font_chain_count > 0) self.font_chain[0] else std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
        self.font = CreateFontW(
            -scaled_font_size,
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
            primary_family,
        );

        // 정공 cell metric (#148 후속) — DWrite design metric 으로 직접 산출.
        // GDI tm.tmHeight 는 ascent+descent rounding 에 더해 tmExternalLeading
        // 까지 포함해서 cell_h 가 4px 정도 부풀려짐 (Cascadia em=24 기준 32 vs
        // 자연 28). DWrite asc+desc+lineGap 으로 가면 28 — WT 와 정합.
        const font_size_px = self.terminal_font.physicalSizeRatioPx(effective_dpi, 96);
        const measured = dwrite_font.measureCell(primary_family, font_size_px) catch null;
        if (measured) |m| {
            self.cell_width_px = @intCast(font_spec.ceilPositivePx(m.cell_w * self.terminal_font.cell_width_ratio));
            self.cell_height_px = @intCast(font_spec.ceilPositivePx(m.cell_h * self.terminal_font.line_height_ratio));
        } else if (self.dc != null and self.font != null) {
            // DWrite 측정 실패 fallback — GDI tm. 사용자 환경에서 이 path 거의
            // 안 탐 (font 사전 검증 통과 후라).
            const old_f = SelectObject(self.dc, self.font);
            var tm: TEXTMETRICW = undefined;
            _ = GetTextMetricsW(self.dc, &tm);
            const base_w: f32 = @floatFromInt(tm.tmAveCharWidth);
            const base_h: f32 = @floatFromInt(tm.tmHeight);
            self.cell_width_px = @intCast(font_spec.ceilPositivePx(base_w * self.terminal_font.cell_width_ratio));
            self.cell_height_px = @intCast(font_spec.ceilPositivePx(base_h * self.terminal_font.line_height_ratio));
            _ = SelectObject(self.dc, old_f);
        }

        self.current_dpi = new_dpi;
    }

    /// #358 — `init` 성공 이후 `hwnd` 는 항상 있다. `CreateWindowExW` 실패는
    /// `init` 이 `error.CreateWindowFailed` 로 올리고 host 의 `try` 가 `run()` 을
    /// 중단시키므로 (`host/windows.zig` 의 `try app.window.init(...)`), 그 뒤로
    /// "창이 없는 Window" 는 도달 불가다.
    ///
    /// 그 불변식을 이 접근자 하나로 모은다. 이전에는 호출 지점 15곳이 각자
    /// `orelse return` / `orelse return null` / `orelse return false` 로 조용히
    /// no-op 해서 호출처가 실패를 구분할 수 없었고, "도달 불가 분기도 뭔가를
    /// 돌려줘야 한다" 는 압력이 #352 에서 걷어낸 가짜 값 (`120x30` · `800x400`)
    /// 을 낳은 원인이었다.
    ///
    /// `.?` 가 아니라 `orelse @panic` 인 이유: `.?` 는 ReleaseFast 에서 검사가
    /// 빠져 UB 가 된다. 공식 빌드가 ReleaseFast 라 그러면 "위반 시 즉시 드러난다"
    /// 는 이 접근자의 취지가 사라진다.
    ///
    /// 이름이 `handle` 이 아닌 이유: 이 파일에 `handle` 이라는 지역 상수가 이미
    /// 둘 (`WM_SETCURSOR` 의 `HCURSOR`, `pasteClipboard` 의 clipboard handle) 있어
    /// Zig 가 shadowing 을 거부한다.
    fn requireHwnd(self: *const Window) *anyopaque {
        return self.hwnd orelse @panic("Window used before init (#358)");
    }

    pub fn deinit(self: *Window) void {
        self.imeClearDeferredResult(false);
        // #358 — 여기는 `requireHwnd()` 로 바꾸지 않는다. 정리 함수가 불변식을 강제해
        // panic 하면, 실패 처리 순서를 바꿀 때 곧바로 crash 가 된다. 이 검사는
        // 도달 불가 방어가 아니라 "만들어졌으면 정리한다" 는 계약이다.
        if (self.hwnd) |hwnd| {
            // clock 스레드를 **창을 부수기 전에** join 한다 — 아니면 죽은 hwnd 로
            // `PostMessageW` 가 갈 수 있다.
            self.stopFrameClock();
            if (self.hotkey_registered) _ = self.hotkeyRelease(hwnd);
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
                _ = AttachThreadInput(our_thread, fg_thread, .TRUE);
                _ = BringWindowToTop(hwnd);
                _ = SetForegroundWindow(hwnd);
                _ = SetFocus(hwnd);
                _ = AttachThreadInput(our_thread, fg_thread, .FALSE);
                return;
            }
        }
        _ = BringWindowToTop(hwnd);
        _ = SetForegroundWindow(hwnd);
        _ = SetFocus(hwnd);
    }

    pub fn show(self: *Window) void {
        const hwnd = self.requireHwnd();
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
        // #386 ② — show 는 wndProc 밖에서도 불린다 (핫키 · 새 instance 요청). 게이트를
        // 직접 열어 두지 않으면 표시 직후 첫 프레임을 건너뛸 수 있다.
        self.requestRender();
        self.presentNow();

        self.startFrameClock();
    }

    /// F1 으로 호출되는 hide. `SW_HIDE` 로 Windows 가 창을 공식적으로 hidden
    /// 으로 인식하게 한다 — external window manager (FancyZones 등) 가 창을
    /// enum 에서 빼고 간섭을 멈추며, shell state 도 clean 해짐.
    ///
    /// `self.fullscreen` 은 건드리지 않음 — 다음 `show()` 에서 `applyLayout` 이
    /// fullscreen 을 그대로 복원한다.
    /// Hide the window without changing the saved fullscreen mode.
    pub fn hide(self: *Window) void {
        const hwnd = self.requireHwnd();
        self.breakMonitorFullscreenSurface();
        self.stopFrameClock();
        self.visible = false;
        _ = ShowWindow(hwnd, SW_HIDE);
        _ = DwmFlush();
    }

    /// `WS_EX_TOPMOST` 를 잠시 해제 — TildaZ 는 그대로 보이지만 z-order 가
    /// normal 그룹으로 내려가서, 새로 launch 되는 editor (config / log 의 default
    /// app) 가 자연스럽게 우리 위로 올라옴. config / log 단축키 (Ctrl+Shift+P/L)
    /// 직후 사용자가 editor 를 즉시 보도록 (시연 중 발견 — editor 가 우리 창
    /// 뒤로 가려져 안 보였던 사고). 사용자가 F1 toggle 해 다시 show() 가 호출
    /// 되면 `applyRect` 의 `HWND_TOPMOST` 가 다시 topmost 로 복귀시킴.
    pub fn yieldTopmostUntilNextShow(self: *Window) void {
        _ = SetWindowPos(self.requireHwnd(), HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }

    pub fn toggle(self: *Window) void {
        if (self.visible) {
            // #175 — F1 hide 도 focus_loss = commit. show 분기에선 호출 안 함.
            if (self.before_hide_fn) |f| f(self.userdata);
            // per-toggle — verbose (#197 Option B, 3 플랫폼 공통 category "toggle").
            log.appendLineVerbose("toggle", "hide", .{});
            self.hide();
        } else {
            log.appendLineVerbose("toggle", "show", .{});
            self.show();
        }
    }

    pub fn setPosition(self: *Window, dock: DockPosition, width_percent: f32, height_percent: f32, offset_percent: f32) void {
        // Remember parameters so WM_DISPLAYCHANGE / WM_DPICHANGED /
        // WM_SETTINGCHANGE(SPI_SETWORKAREA) and show() can re-apply them on
        // resolution / monitor / DPI / taskbar changes.
        self.dock = dock;
        self.width_percent = width_percent;
        self.height_percent = height_percent;
        self.offset_percent = offset_percent;
        self.position_set = true;
        self.applyDockedRect(dock, width_percent, height_percent, offset_percent, .cursor);
    }

    /// #382 — 셀 개수로 창을 잡을 때 쓰는 환산. 창 크기 경로는 퍼센트 기반이고 (DPI ·
    /// 해상도 변경 시 그 값으로 재적용된다) 그 구조를 그대로 두는 게 안전하므로, 필요한
    /// 픽셀을 현재 모니터 작업영역 대비 퍼센트로 바꿔 기존 경로에 넣는다.
    ///
    /// 호출자는 **여유를 더한 픽셀**을 넘겨야 한다. `viewportForGrid` 는 요청한 격자가
    /// 나오는 *가장 작은* 크기를 내는데, 퍼센트 환산에서 1 px 이라도 줄면 격자가 한 칸
    /// 줄어든다. 셀 크기의 절반을 더하면 내림이 흡수한다.
    /// #506 — `percentForPixels` 의 결과 타입에 이름을 준다. 익명 struct 는 선언 자리마다
    /// 다른 타입이라, 이 값을 그대로 돌려주는 `App.gridWindowPercent` 가 같은 모양을 다시
    /// 적으면 타입이 안 맞는다.
    pub const SizePercent = struct { w: f32, h: f32 };

    pub fn percentForPixels(self: *Window, w_px: i64, h_px: i64) ?SizePercent {
        const mi = self.monitorInfoFor(.cursor) orelse return null;
        const sw: i64 = mi.rcWork.right - mi.rcWork.left;
        const sh: i64 = mi.rcWork.bottom - mi.rcWork.top;
        if (sw <= 0 or sh <= 0) return null;
        return .{
            .w = @min(100.0, @as(f32, @floatFromInt(w_px)) / @as(f32, @floatFromInt(sw)) * 100.0),
            .h = @min(100.0, @as(f32, @floatFromInt(h_px)) / @as(f32, @floatFromInt(sh)) * 100.0),
        };
    }

    /// [#506](https://github.com/ensky0/tildaz/issues/506) — `-size` 요청이 이 화면에
    /// 들어가는지 판정할 때 쓰는 작업 영역 크기 (physical px). `percentForPixels` 와
    /// **같은 모니터** (커서가 있는 화면) 를 봐야 판정과 실제 창이 어긋나지 않는다.
    pub fn workAreaSize(self: *const Window) ?struct { w: i64, h: i64 } {
        const mi = self.monitorInfoFor(.cursor) orelse return null;
        const w: i64 = mi.rcWork.right - mi.rcWork.left;
        const h: i64 = mi.rcWork.bottom - mi.rcWork.top;
        if (w <= 0 or h <= 0) return null;
        return .{ .w = w, .h = h };
    }

    fn applyDockedRect(
        self: *Window,
        dock: DockPosition,
        width_percent: f32,
        height_percent: f32,
        offset_percent: f32,
        target: LayoutMonitorTarget,
    ) void {
        const mi = self.monitorInfoFor(target) orelse return;
        const rect = dockRectForMonitor(dock, width_percent, height_percent, offset_percent, &mi);
        self.applyRect(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
    }

    fn dockRectForMonitor(
        dock: DockPosition,
        width_percent: f32,
        height_percent: f32,
        offset_percent: f32,
        mi: *const MONITORINFO,
    ) RECT {
        const sw = mi.rcWork.right - mi.rcWork.left;
        const sh = mi.rcWork.bottom - mi.rcWork.top;
        const sx = mi.rcWork.left;
        const sy = mi.rcWork.top;

        const sw_f: f32 = @floatFromInt(sw);
        const sh_f: f32 = @floatFromInt(sh);

        // width = always horizontal %, height = always vertical %.
        // f32 percent → pixel: round 후 c_int. 정수 나눗셈 보다 정확한 세밀 조정
        // (예: 33.3% 가 sw=1920 일 때 639.36 → 639 px).
        const w: c_int = @round(sw_f * width_percent / 100.0);
        const h: c_int = @round(sh_f * height_percent / 100.0);

        const x: c_int = switch (dock) {
            .left => sx,
            .right => sx + sw - w,
            .top, .bottom => sx + @as(c_int, @round(@as(f32, @floatFromInt(sw - w)) * offset_percent / 100.0)),
        };
        const y: c_int = switch (dock) {
            .top => sy,
            .bottom => sy + sh - h,
            .left, .right => sy + @as(c_int, @round(@as(f32, @floatFromInt(sh - h)) * offset_percent / 100.0)),
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
        self.applyDockedRect(self.dock, self.width_percent, self.height_percent, self.offset_percent, .window);
        if (!self.layout_transition_active) {
            if (self.resize_fn) |resize_fn| resize_fn(self.userdata);
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
        const hwnd = self.requireHwnd();
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

        // Shell fullscreen detection (taskbar collapse) and the DWM direct-flip
        // path only trigger when the window rect covers the ENTIRE monitor —
        // which for a work-area rect happens only with an auto-hide taskbar
        // (rcWork == rcMonitor). Only then inset 1 px per edge to break the
        // exact match. A visible taskbar already shrinks one axis, so no inset
        // is needed and the rect fills the work area edge-to-edge.
        if (work_w == monitor_w and work_h == monitor_h) {
            if (work_w > 2) {
                rect.left += 1;
                rect.right -= 1;
            }
            if (work_h > 2) {
                rect.top += 1;
                rect.bottom -= 1;
            }
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
            .window => MonitorFromWindow(self.requireHwnd(), MONITOR_DEFAULTTOPRIMARY),
        };
        var mi: MONITORINFO = undefined;
        mi.cbSize = @sizeOf(MONITORINFO);
        if (!GetMonitorInfoW(monitor, &mi).toBool()) return null;
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
    /// 확장. `setPosition` 과 달리 저장된 dock 파라미터 (`dock` / `width_percent` /
    /// `height_percent` / `offset_percent`) 는 건드리지 않아서 fullscreen 해제시
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

        // fullscreen 적용 시점의 OS monitor/work rect 와 적용 rect (verbose).
        // #89 진단에서 유용했던 기록 — fullscreen 표시 문제 재발 시 앱 측
        // rect 산출이 정상인지 로그만으로 판정 가능.
        log.appendLineVerbose("fullscreen", "apply {s}: monitor=({d},{d},{d},{d}) work=({d},{d},{d},{d}) applied=({d},{d} {d}x{d})", .{
            @tagName(self.fullscreen_mode),
            mi.rcMonitor.left,
            mi.rcMonitor.top,
            mi.rcMonitor.right,
            mi.rcMonitor.bottom,
            mi.rcWork.left,
            mi.rcWork.top,
            mi.rcWork.right,
            mi.rcWork.bottom,
            x,
            y,
            w,
            h,
        });

        self.applyRect(x, y, w, h);

        if (!self.layout_transition_active) {
            if (self.resize_fn) |resize_fn| resize_fn(self.userdata);
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
                .cursor => self.applyDockedRect(self.dock, self.width_percent, self.height_percent, self.offset_percent, .cursor),
                .window => self.repositionFromSaved(),
            },
            .monitor, .workarea => self.applyFullscreenFor(target),
        }
    }

    fn syncLayout(self: *Window) void {
        if (self.resize_fn) |resize_fn| resize_fn(self.userdata);
    }

    /// #386 ② — 다음 프레임을 그리게 한다. `needs_render` 주석 참고.
    pub fn requestRender(self: *Window) void {
        self.needs_render = true;
    }

    /// #386 — 렌더 전에 **우리 창의 입력을 먼저 비운다.**
    ///
    /// Windows 메시지 우선순위는 `sent → posted → 입력(하드웨어) → paint → timer` 다.
    /// 이전의 `WM_TIMER` 는 최하위라 입력에 절대 앞서지 않았는데, `WM_FRAME_TICK` 은
    /// **posted 라 입력보다 앞선다.** 프레임 작업이 한 주기를 다 채우면 큐에 항상 tick 이
    /// 있어서 키 입력이 영원히 뒤로 밀린다 — 실측으로 `cjk` 폭포 중 Ctrl+Shift+F12 를
    /// 10 번 보내 **0 번** 처리됐다 (같은 조건에서 `SetTimer` 빌드는 처리됐다). 폭포 중
    /// Ctrl+C 가 안 먹는다는 뜻이라 그대로 둘 수 없다.
    ///
    /// 범위를 키 · 마우스로, 대상을 **우리 hwnd 로** 좁힌다. `null` hwnd 로 비우면 모달
    /// 다이얼로그의 메시지까지 가로채서 그쪽 키보드 네비게이션 (`IsDialogMessage`) 이
    /// 깨진다. 상한(`guard`)은 입력이 계속 쏟아질 때 렌더를 굶기지 않기 위한 것이다.
    fn pumpPendingInput(self: *Window) void {
        const ranges = [_][2]UINT{
            .{ WM_KEYFIRST, WM_KEYLAST },
            .{ WM_MOUSEFIRST, WM_MOUSELAST },
        };
        var msg: MSG = undefined;
        for (ranges) |range| {
            var guard: u32 = 0;
            while (guard < 64 and PeekMessageW(&msg, self.hwnd, range[0], range[1], PM_REMOVE).toBool()) : (guard += 1) {
                _ = TranslateMessage(&msg);
                _ = DispatchMessageW(&msg);
            }
        }
    }

    /// #386 — 프레임 한 번. `WM_FRAME_TICK` (정상) 과 `WM_TIMER` (fallback) 이 공유한다.
    /// #439 — `WM_PTY_OUTPUT` (출력 통보) 도 여기로 들어온다.
    fn renderFrameTick(self: *Window) void {
        if (!self.visible or self.layout_transition_active) return;
        if (self.render_fn) |render_fn| render_fn(self);
    }

    /// #439 — PTY read thread 가 부르는 통보. **다른 스레드에서 불린다** — `PostMessageW` 는
    /// thread-safe 하고, `hwnd` 가 아직 없으면 (창 생성 전) 조용히 흘린다. 그때는 볼 화면도
    /// 없고, 창이 서면 첫 tick 이 ring 을 집는다.
    ///
    /// ⚠ **유휴일 때만 보낸다 (`frame_idle`). 이것이 없으면 폭포에서 크게 느려진다.**
    ///
    /// `messageLoop` 은 `PeekMessage` 가 빈 순간에만 `idle_drain_fn` (#387 사양 A) 을 부른다.
    /// 그런데 폭포에서 이 메시지를 계속 post 하면 큐가 비지 않아 **그 드레인이 굶고**, 프레임
    /// 밖에서 하던 일이 통째로 `WM_FRAME_TICK` 안으로 밀려든다. macOS 에서 같은 구조
    /// (`kCFRunLoopBeforeWaiting` 이 안 옴) 로 폭포 중 입력 지연이 **1.5 → 8.2 ms** 로
    /// 나빠지는 것을 실측 A/B 로 확인했다 (`host/macos.zig` 의 `macOutputWake` 주석).
    ///
    /// 타이머가 이미 매 프레임 그리고 있으면 통보는 할 일이 없다 — 다음 tick 이 어차피 즉시
    /// 집는다. 통보가 필요한 것은 *아무도 안 깨우는* 유휴뿐이다.
    pub fn notifyPtyOutput(self: *Window) void {
        if (!self.frame_idle.load(.acquire)) return;
        const hwnd = self.hwnd orelse return;
        if (self.output_wake_pending.swap(true, .acq_rel)) return;
        _ = PostMessageW(hwnd, WM_PTY_OUTPUT, 0, 0);
    }

    /// #386 — 프레임 clock 시작. `hide` 동안 깨어나지 않도록 `show` / create 에서만 켠다
    /// (이전 `SetTimer` 와 같은 수명). 이미 돌고 있으면 no-op.
    fn startFrameClock(self: *Window) void {
        if (self.frame_clock != null) return;
        const hwnd = self.hwnd orelse return;
        // 이전 start 가 실패해 fallback 타이머가 붙어 있을 수 있다. 아래에서 clock 이
        // 성공하면 그건 꺼야 하고, 또 실패하면 어차피 다시 무장한다.
        _ = KillTimer(hwnd, RENDER_TIMER_ID);

        // 재생률은 창이 올라가 있는 디스플레이 모드의 값이다. `GetDeviceCaps` 는 0 / 1 을
        // "default / unknown" 으로 돌려주므로 (MSDN) 그때만 fallback 을 쓴다.
        const refresh_hz: i64 = blk: {
            const hz = if (self.dc) |dc| GetDeviceCaps(dc, VREFRESH) else 0;
            if (hz > 1) break :blk @intCast(hz);
            break :blk FALLBACK_REFRESH_HZ;
        };
        self.frame_period_100ns = @divTrunc(10_000_000, refresh_hz);

        // 고해상도 타이머가 없으면 프레임이 아예 안 온다 — 그건 창이 멈추는 것이라
        // 이전 방식으로 되돌린다. 주기는 부정확하지만 (#386 의 원인) 프레임이 없는 것보다 낫다.
        const timer = CreateWaitableTimerExW(null, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS) orelse {
            log.appendLine("startup", "frame clock: high-resolution timer unavailable — using WM_TIMER fallback", .{});
            _ = SetTimer(hwnd, RENDER_TIMER_ID, 16, null);
            return;
        };
        // clock 스레드는 단조 시계로 deadline 을 누적한다.
        //
        // #451 — 예전에는 여기서 `std.time.Instant.now()` 를 한 번 불러 단조 시계가
        // 쓸 수 있는지 확인하고, 안 되면 `WM_TIMER` 로 물러났다. 0.16 의 `Io.Timestamp`
        // 는 **조회가 실패하지 않는다** (해상도가 없으면 무한대로 취급하고, 필요하면
        // `Io.Clock.resolution` 으로 따로 묻는다 — 릴리즈 노트 *Time*). 그래서 그 사전
        // 검사가 표현할 대상이 없어져 지운다. `WM_TIMER` fallback 경로 자체는 아래
        // thread spawn 실패에 그대로 남아 있다.

        self.frame_timer = timer;
        self.frame_clock_run.store(true, .release);
        self.frame_clock = std.Thread.spawn(.{}, frameClockThread, .{self}) catch |err| {
            log.appendLine("startup", "frame clock: thread spawn failed ({s}) — using WM_TIMER fallback", .{@errorName(err)});
            self.frame_clock_run.store(false, .release);
            _ = CloseHandle(timer);
            self.frame_timer = null;
            _ = SetTimer(hwnd, RENDER_TIMER_ID, 16, null);
            return;
        };
        log.appendLine("startup", "frame clock started: refresh={d}Hz period={d:.2}ms", .{
            refresh_hz,
            @as(f64, @floatFromInt(self.frame_period_100ns)) / 10_000.0,
        });
    }

    /// #386 — 프레임 clock 정지. `WM_TIMER` fallback 으로 돌고 있었을 수도 있으니 그쪽도
    /// 함께 끈다.
    fn stopFrameClock(self: *Window) void {
        if (self.hwnd) |hwnd| _ = KillTimer(hwnd, RENDER_TIMER_ID);
        const thread = self.frame_clock orelse return;
        self.frame_clock_run.store(false, .release);
        // 별도 stop 이벤트를 두지 않는다 — 스레드가 한 주기 (≤17 ms) 안에 루프 조건을
        // 다시 보고 빠져나온다. 그만큼의 join 지연을 허용하는 대신 코드가 단순해진다.
        thread.join();
        self.frame_clock = null;
        if (self.frame_timer) |t| {
            _ = CloseHandle(t);
            self.frame_timer = null;
        }
        self.frame_tick_pending.store(false, .release);
    }

    /// #386 — clock 스레드 본체. 한 주기 기다린 뒤 coalescing 을 거쳐 `WM_FRAME_TICK`
    /// 을 post 한다. 이 스레드는 그리지 않는다 — 렌더는 그대로 UI 스레드가 한다.
    ///
    /// **기준 시각에서 누적한 deadline 으로 잔다.** 매번 "주기만큼" 상대 시간을 주면
    /// 깨어나는 지연이 프레임마다 누적돼 주기가 길어진다 — 실측으로 60 Hz 요청이
    /// 17.03 ms (58.7 fps) 로 나왔다 (프레임당 약 0.4 ms). 재생률이 높을수록 그 비율이
    /// 커진다 (144 Hz 면 6 %). 누적 deadline 은 그 지연을 다음 잠으로 상쇄한다.
    ///
    /// vsync *위상* 에는 맞추지 않는다 — present 와 무관해야 유휴 skip (#386 ②) 과
    /// 합쳐지므로 주기만 정확하면 된다.
    fn frameClockThread(self: *Window) void {
        const timer = self.frame_timer orelse return;
        const period_ns: u64 = @intCast(self.frame_period_100ns * 100);
        if (period_ns == 0) return;
        // #451 — `std.time.Instant` ➡️ `Io.Timestamp` (`.awake` = 절전을 안 세는 단조
        // 시계). `since` 대신 `durationTo` 로 두 시각의 차이를 얻는다.
        var base = std.Io.Timestamp.now(self.rt.io, .awake);
        var ticks: u64 = 0;
        while (self.frame_clock_run.load(.acquire)) {
            ticks += 1;
            const now = std.Io.Timestamp.now(self.rt.io, .awake);
            const elapsed: u64 = @intCast(@max(0, base.durationTo(now).nanoseconds));
            const deadline = ticks *| period_ns;
            if (deadline > elapsed) {
                // 음수 = 상대 시간 (100ns 단위). one-shot 으로 매번 재장전한다 — 주기
                // 인자 (`lPeriod`) 는 ms 정수라 16.67 ms 를 표현할 수 없다.
                const due: i64 = -@as(i64, @intCast((deadline - elapsed) / 100));
                if (!SetWaitableTimer(timer, &due, 0, null, null, .FALSE).toBool()) break;
                if (WaitForSingleObject(timer, WAIT_INFINITE) != WAIT_OBJECT_0) break;
            } else {
                // 이 스레드 자신이 밀렸다 (스케줄링). 밀린 만큼을 몰아 내지 않고 지금을
                // 새 기준으로 삼는다 — 다음 iteration 은 정상적으로 잔다 (spin 아님).
                base = now;
                ticks = 0;
            }
            if (!self.frame_clock_run.load(.acquire)) break;
            const hwnd = self.hwnd orelse break;
            if (!self.frame_tick_pending.swap(true, .acq_rel)) {
                _ = PostMessageW(hwnd, WM_FRAME_TICK, 0, 0);
            }
        }
    }

    fn presentNow(self: *Window) void {
        if (!self.visible) return;
        if (self.render_fn) |render_fn| render_fn(self);
        _ = DwmFlush();
    }

    /// Alt+Enter 로 호출. fullscreen 진입/해제 토글. 해제시엔 `applyLayout` 이
    /// 저장된 dock 설정 (`width_percent` / `height_percent` / `offset_percent`) 으로 복원.
    ///
    /// 과거 구현에서는 여기서 `SW_HIDE → applyLayout → SW_SHOW` 로 DWM refresh
    /// 를 강제했는데, 이 hide/show dance 가 spurious `WM_DISPLAYCHANGE` cascade
    /// 를 유발하고, `SW_SHOW` 가 hide 직전의 surface 를 DWM cache 에서 복원하는
    /// 쪽으로 동작해서 오히려 "rect 가 새 값으로 번쩍였다 이전 값으로 되돌아
    /// 가는" 현상이 났음. `applyFullscreen` 이 `rcWork` 를 쓰므로 direct-flip
    /// 이 engage 되지 않고, 단순 `SetWindowPos` 하나로도 rect 가 안정적으로
    /// 반영된다 — hide/show 가 필요 없음.
    /// #329 — command menu 의 Shift+Tab 역방향 이동 판정용. WM_CHAR 0x09 에는
    /// shift 정보가 없어 host 가 이 helper 로 확인한다.
    pub fn isShiftDown(self: *const Window) bool {
        _ = self;
        return GetKeyState(VK_SHIFT) < 0;
    }

    /// #483 5단계 — `+` Alt+클릭 판정. `mouseMods` 와 같은 `GetKeyState(VK_MENU)`.
    pub fn isAltDown(self: *const Window) bool {
        _ = self;
        return GetKeyState(VK_MENU) < 0;
    }

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

    /// 같은 단축키 self-symmetric 토글. 들어간 키로만 나옴 — Alt+Enter 로
    /// `.monitor` 진입 시 같은 키로만 dock 복귀, Shift+Alt+Enter 는 no-op.
    /// `.workarea` 도 대칭. `.monitor ↔ .workarea` 직접 transition 없음 (사용자
    /// 가 mode 전환 원하면 dock 거쳐 두 번). 이전 구현은 `.none` 외 모든 상태
    /// 에서 어느 인자든 `.none` 으로 강제 복귀했으나, 실수로 다른 키 누름 시
    /// dock 짧게 깜빡이는 UX 문제 → self-symmetric 으로 변경 (cross-platform
    /// macOS 와 통일).
    pub fn toggleFullscreenMode(self: *Window, mode: FullscreenMode) void {
        if (self.fullscreen_mode == mode) {
            self.setFullscreenMode(.none);
        } else if (self.fullscreen_mode == .none) {
            self.setFullscreenMode(mode);
        }
        // 다른 모드 → no-op (예: .monitor 상태에서 인자 .workarea).
    }

    fn dispatchAppEvent(self: *Window, event: app_event.Event) bool {
        if (self.app_event_fn) |f| {
            return f(event, self.userdata);
        }
        return false;
    }

    /// #245 — drag-select auto-scroll 타이머 on/off. on 이면 AUTOSCROLL_INTERVAL_MS
    /// 마다 WM_TIMER → 마지막 마우스 위치로 mouse_move 재전송. idempotent (이미 같은
    /// 상태면 no-op). app_controller 의 updateTerminalSelection(경계 밖이면 on) /
    /// mouse_up(off) 가 호출.
    pub fn setAutoScroll(self: *Window, on: bool) void {
        if (on == self.auto_scroll_active) return;
        const hwnd = self.requireHwnd();
        if (on) {
            _ = SetTimer(hwnd, AUTOSCROLL_TIMER_ID, AUTOSCROLL_INTERVAL_MS, null);
        } else {
            _ = KillTimer(hwnd, AUTOSCROLL_TIMER_ID);
        }
        self.auto_scroll_active = on;
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

    /// #502 — 마우스 메시지의 modifier. Shift · Ctrl 은 `wParam` 에 있지만 **Alt 는
    /// 없어서** `GetKeyState(VK_MENU)` 로 읽는다. `GetKeyState` (비동기 아님) 는
    /// 큐에서 처리된 메시지 기준의 논리 상태라 이 메시지 시점과 일관된다.
    fn mouseMods(wParam: WPARAM) app_event.MouseMods {
        return .{
            .shift = (wParam & MK_SHIFT) != 0,
            .ctrl = (wParam & MK_CONTROL) != 0,
            .alt = GetKeyState(VK_MENU) < 0,
        };
    }

    /// #502 — capture 는 **스레드당 하나**다. 그래서 뗌 하나가 무조건 놓아 버리면
    /// 아직 눌려 있는 다른 버튼의 드래그가 끊긴다 (왼쪽 + 가운데를 함께 누른 뒤
    /// 한쪽만 떼는 경우). 보고 대상 버튼이 하나도 안 남았을 때만 놓는다.
    ///
    /// 오른쪽은 대상이 아니다 — press · release 를 보고하지 않고 motion 도
    /// `mouse_report.motionReportable` 이 걸러낸다 (우클릭 = paste, #119).
    ///
    /// `GetKeyState` (비동기 아님) 는 큐에서 처리된 메시지 기준의 **논리** 버튼이라
    /// 이 메시지 시점과 일관되고, 좌우 스왑 사용자에게도 올바르다 —
    /// `WM_LBUTTONDOWN` 의 capture 판정과 같은 이유다 (#329).
    fn releaseCaptureIfNoReportedButtonHeld() void {
        if (GetKeyState(VK_LBUTTON) < 0 or GetKeyState(VK_MBUTTON) < 0) return;
        _ = ReleaseCapture();
    }

    /// 휠 메시지의 client 좌표. `WM_MOUSEWHEEL` 의 `lParam` 은 **screen** 좌표라
    /// (버튼 메시지와 다르다) `ScreenToClient` 변환이 필요하다 — 빼면 reporting 이
    /// 창 밖 좌표를 보낸다.
    fn wheelClientPos(hwnd: HWND, lParam: LPARAM) POINT {
        var pt: POINT = .{ .x = getMouseX(lParam), .y = getMouseY(lParam) };
        _ = ScreenToClient(hwnd, &pt);
        return pt;
    }

    /// #387 — 사양 A ("드레인 한 번이 UI 를 예산 이상 잡지 않는다") 의 Windows 쪽 구현.
    ///
    /// `DRAIN_FRAME_BUDGET_NS` 는 `drainFrame` **한 번의 호출**에 걸리는 응답성 상한이고
    /// 처리량 상한이 아니다. 그런데 이전에는 드레인이 프레임 tick 안에만 있어서
    /// (`WM_FRAME_TICK` → `render_fn` → `App.onRender` → `drainOutputForRender`) 프레임당
    /// 1 회로 묶였고, 그러면 duty 상한이 `예산 / 프레임간격` 이 된다 — **화면 주사율이
    /// 처리량을 결정**했다 (당시 예산 8 ms 로 60 Hz 48 % · 120 Hz 96 %, #386 실측).
    ///
    /// **Linux 도 같은 종속이 있었다** (#436, 2026-08-10). 이 주석은 예산 8 ms 시절 값으로
    /// *"Linux 는 드레인이 poll loop 에 있어 주사율과 무관했다 (`cjk` duty 가 60 · 120 Hz 에서
    /// 77.8 / 77.9 %)"* 라고 적어 두었는데, 4 ms 로 내린 뒤 60 Hz 에서 duty 가 41 % 로
    /// 떨어지는 것이 확인됐다. Linux 의 poll loop 는 iteration 마다 드레인하지만 폭포 중 그
    /// iteration 을 깨우는 것이 `wl_surface.frame` callback 하나여서 회전이 프레임에 묶였다
    /// (프레임당 1.45 회). 지금은 밀린 출력이 있으면 poll timeout 을 0 으로 두어 아래
    /// `continue` 와 같은 재진입을 한다 (SPEC §13.1 · §13.2).
    ///
    /// 그래서 **대기 중인 메시지가 없을 때** 한 번 더 드레인한다. 순서가 설계의 핵심이다:
    ///
    /// 1. `PeekMessage` 가 먼저다 → 입력 · 프레임 tick 이 **항상 드레인보다 우선**한다.
    ///    Linux 는 iteration 마다 무조건 드레인하는데 이쪽은 "할 일이 없을 때만" 이다.
    /// 2. 드레인 한 번은 예산을 넘지 않으므로 입력 지연 상한이 그대로다 (= 사양 A).
    /// 3. 둘 다 없으면 `WaitMessage` 로 블록해 **유휴 절전 (#386 ②) 을 유지**한다.
    ///    `GetMessageW` 를 쓰면 메시지를 꺼내 버려서 1 번의 우선순위를 만들 수 없다.
    ///
    /// **스핀하지 않는 근거**: 콜백이 참이면 실제로 파싱했거나 ring 에 남아 있다는 뜻이다
    /// (`drainOutputChunk` 은 `output_ring.pop() == 0` 이면 false). 남아 있으면 다음 호출이
    /// 반드시 진행하므로 진행 없는 반복이 없다. 폭포 중에는 producer 가 계속 채워 루프가
    /// 블록하지 않는데 그건 의도한 동작이고 (일이 있는 동안 일한다), ring 이 비면 참이 안
    /// 나와 `WaitMessage` 로 내려간다.
    pub fn messageLoop(self: *Window) void {
        var msg: MSG = undefined;
        while (true) {
            if (PeekMessageW(&msg, null, 0, 0, PM_REMOVE).toBool()) {
                if (msg.message == WM_QUIT) return;
                _ = TranslateMessage(&msg);
                _ = DispatchMessageW(&msg);
                continue;
            }
            if (self.idle_drain_fn) |f| {
                if (f(self.userdata)) continue;
            }
            _ = WaitMessage();
        }
    }

    fn wndProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT {
        const self = getSelf(hwnd) orelse return DefWindowProcW(hwnd, msg, wParam, lParam);

        // #386 ② — 화면이 바뀔 수 있는 메시지면 렌더 게이트를 연다. 프레임 tick 만 막는다.
        // 어떤 메시지를 빠뜨리면 "화면이 안 갱신된다" 는 사용자 가시 버그가 되므로, 한
        // 프레임 더 그리는 쪽으로 치우치게 둔다. 유휴에는 tick 외에 오는 메시지가 없어서
        // 이 정책으로도 유휴 렌더는 사라진다. (`WM_TIMER` 의 auto-scroll 분기는 화면을
        // 바꾸므로 그 안에서 따로 연다.)
        if (!isFrameGateExempt(msg)) self.requestRender();

        switch (msg) {
            WM_NEW_INSTANCE_REQUEST => {
                if (@import("instance_context.zig").requireWorkerIndex() == 0) {
                    self.show();
                    @import("new_instance.zig").handle(self.rt, std.heap.page_allocator);
                }
                // SendMessageW caller가 동기 처리 성공을 판별하는 protocol result.
                return 1;
            },
            // #496 1-c — `WM_INPUTLANGCHANGE` 를 듣지 않는다. 위치 표기가 훅으로 바뀌어
            // layout 에 따라 다시 풀 값이 없어졌다 (`installPositionHotkey` 주석).
            WM_HOTKEY_CAPTURE_BEGIN => {
                if (self.hotkey_registered) {
                    if (!self.hotkeyRelease(hwnd)) return 0;
                    self.hotkey_registered = false;
                }
                return 1;
            },
            WM_HOTKEY_CAPTURE_END => {
                if (!self.hotkey_registered) {
                    if (!self.hotkeyAcquire(hwnd)) return 0;
                    self.hotkey_registered = true;
                }
                return 1;
            },
            WM_HOTKEY => {
                if (wParam == HOTKEY_ID) {
                    if (!self.dispatchAppEvent(.{ .shortcut = .toggle_visibility })) self.toggle();
                }
                return 0;
            },
            WM_FRAME_TICK => {
                // coalescing 해제는 **렌더 전** 에 한다. 렌더 중에 도착한 tick 이 큐에
                // 하나 들어와 바로 다음 프레임이 되게 하려는 것이다 — 렌더 뒤에 열면
                // 프레임이 한 주기를 넘길 때마다 다음 tick 을 통째로 잃어 주기가 두 배로
                // 뛴다 (#386 이 고치려는 바로 그 증상). coalescing 이 있으니 큐에 쌓이는
                // tick 은 최대 하나라 "놓친 프레임을 몰아 그리는" 일은 생기지 않는다.
                self.frame_tick_pending.store(false, .release);
                // posted tick 이 입력을 굶기지 않게 — 위 `pumpPendingInput` 주석 참고.
                self.pumpPendingInput();
                self.renderFrameTick();
                return 0;
            },
            // #439 — PTY 출력 도착. 유휴에서 `WaitMessage` 를 끊는 것이 이 메시지의 본래
            // 목적이고, 여기서 바로 그려야 지연이 준다 (`WM_PTY_OUTPUT` 주석).
            WM_PTY_OUTPUT => {
                // `WM_FRAME_TICK` 과 같은 이유로 **렌더 전** 에 연다 — 그리는 동안 도착한
                // 출력이 다음 통보를 만들 수 있어야 한다.
                self.output_wake_pending.store(false, .release);
                self.renderFrameTick();
                return 0;
            },
            WM_TIMER => {
                if (wParam == RENDER_TIMER_ID) {
                    // #386 — 고해상도 타이머를 못 만들었을 때의 fallback 경로.
                    self.renderFrameTick();
                } else if (wParam == AUTOSCROLL_TIMER_ID) {
                    // #386 ② — 이 tick 은 viewport 를 움직이므로 게이트를 연다.
                    self.requestRender();
                    // #245 — 마지막 마우스 위치로 mouse_move(left_button=true) 재전송.
                    // app 의 updateTerminalSelection 이 다시 돌아 경계 밖이면 한 step
                    // 더 스크롤 + 선택 갱신. 경계 안으로 돌아오면 그쪽에서 타이머 off.
                    _ = self.dispatchAppEvent(.{
                        .mouse_move = .{
                            .x = self.last_mouse_x,
                            .y = self.last_mouse_y,
                            .left_button = true,
                        },
                    });
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
            WM_IME_STARTCOMPOSITION => {
                // IME 조합 시작 — preedit buffer 비우고 default IME composition
                // window 차단 (return 0). 우리 inline overlay 가 대신 (#164).
                self.preedit_len = 0;
                // #282 A11 — 조합 시작 시 활성 탭 맨 아래로 (macOS/Linux 동등).
                if (self.scroll_to_bottom_fn) |f| f(self.userdata);
                return 0;
            },
            WM_IME_COMPOSITION => {
                // RESULTSTR를 먼저 원래 대상에 동기 dispatch한다. DefWindowProcW에
                // 넘기면 결과 WM_CHAR가 현재 KEYDOWN action 뒤에 queue되어 새 탭
                // 또는 새 prompt 뒤로 이동한다 (#313).
                const lp_dword: DWORD = @truncate(@as(usize, @bitCast(lParam)));
                var handled = false;
                if ((lp_dword & GCS_RESULTSTR) != 0) {
                    const result = self.imeReadCompositionResult() orelse {
                        // 읽기/변환/dispatch 실패 시 OS default를 보존한다. 강제
                        // complete caller는 action을 보류하므로 target이 바뀌지 않는다.
                        return DefWindowProcW(hwnd, msg, wParam, lParam);
                    };
                    defer std.heap.page_allocator.free(result);

                    // MS-IME는 Ctrl keydown만으로도 실제 shortcut key보다 먼저
                    // result/end를 queue할 수 있다. Ctrl chord 중이면 다음
                    // non-modifier keydown이 policy action인지 확인할 때까지 보류한다.
                    const defer_for_policy = !self.ime_complete_in_progress and
                        (self.ime_preserve_requested or GetKeyState(VK_CONTROL) < 0);
                    if (defer_for_policy) {
                        if (!self.imeStoreDeferredResult(result)) {
                            if (!self.imeDispatchCommittedText(result)) return DefWindowProcW(hwnd, msg, wParam, lParam);
                            self.preedit_len = 0;
                        }
                    } else {
                        if (!self.imeDispatchCommittedText(result)) return DefWindowProcW(hwnd, msg, wParam, lParam);
                        self.preedit_len = 0;
                        if (self.ime_complete_in_progress) self.ime_complete_result_ok = true;
                    }
                    handled = true;
                }
                if ((lp_dword & GCS_COMPSTR) != 0) {
                    self.imeReadCompositionPreedit();
                    handled = true;
                }
                if (handled) return 0;
                return DefWindowProcW(hwnd, msg, wParam, lParam);
            },
            WM_IME_ENDCOMPOSITION => {
                if (self.ime_deferred_result != null) {
                    // read-only action이 먼저 실행된 순서면 여기서 실제 IMM
                    // composition을 복원. result가 action보다 먼저였으면 action
                    // resolver가 commit/preserve/discard를 결정할 때까지 유지.
                    if (self.ime_preserve_requested) _ = self.imeRestoreDeferredComposition();
                    return 0;
                }
                self.preedit_len = 0;
                return 0;
            },
            WM_CHAR => {
                // KEYDOWN 가 같은 키를 소비했으면 짝꿍 WM_CHAR 도 swallow.
                // (menu Enter / Escape 소비 후 PTY 로 \r / \x1b 새는
                // 사고 방지 — 소비자 입장에선 한 번의 keypress.)
                if (self.swallow_next_wm_char) {
                    self.swallow_next_wm_char = false;
                    self.pending_high_surrogate = 0; // 안전 — 잘못 매달린 surrogate 잡힘
                    return 0;
                }

                // UTF-16 surrogate pair → single u21 codepoint 결합. 이모지 같은
                // BMP 밖 codepoint (U+10000+) 는 high (0xD800..0xDBFF) + low
                // (0xDC00..0xDFFF) 두 WM_CHAR 로 따로 도착. high 단독은 invalid
                // codepoint 라 utf8Encode 실패해 PTY 전송이 안 됨
                // (`Win+.` 이모지 picker 가 ❤️ 같은 BMP 외엔 다 누락하던 사고).
                const w16: u16 = @intCast(wParam);
                const cp: u21 = blk: {
                    if (w16 >= 0xD800 and w16 <= 0xDBFF) {
                        // high surrogate — 보관 후 짝꿍 기다림.
                        self.pending_high_surrogate = w16;
                        return 0;
                    }
                    if (w16 >= 0xDC00 and w16 <= 0xDFFF) {
                        const high = self.pending_high_surrogate;
                        self.pending_high_surrogate = 0;
                        if (high == 0) return 0; // 잘못된 lone low — 무시
                        const high_off: u32 = @as(u32, high) - 0xD800;
                        const low_off: u32 = @as(u32, w16) - 0xDC00;
                        break :blk @intCast(0x10000 + (high_off << 10) + low_off);
                    }
                    // 그 외 일반 BMP — 이전 high surrogate 가 매달려 있으면 정리.
                    self.pending_high_surrogate = 0;
                    break :blk w16;
                };

                if (self.dispatchAppEvent(.{ .text_input = cp })) return 0;
                // Ignore WM_CHAR generated from Ctrl+Shift shortcuts
                // (e.g. Ctrl+Shift+W sends 0x17 which would kill-word in shell)
                if (GetKeyState(VK_CONTROL) < 0 and GetKeyState(VK_SHIFT) < 0) {
                    return 0;
                }
                if (self.write_fn) |write_fn| {
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
                perf.markInput(); // #441 축 ② — 응답 지연은 여기서 시작한다.
                // Ctrl keydown이 먼저 끝낸 composition result는 modifier keydown을
                // 건너뛰어 실제 chord key까지 유지한다. leave 정책이 필요한
                // C(copy/interrupt), Ctrl+Shift+V(paste), F12(perf)는 app resolver가
                // preserve/commit/discard를 결정한다. 그 밖의 key는 여기서 먼저
                // commit해 Ctrl+A/E/control char나 state-changing action보다 앞선다.
                if (self.ime_deferred_result != null and
                    wParam != @as(WPARAM, @intCast(VK_CONTROL)) and
                    wParam != @as(WPARAM, @intCast(VK_SHIFT)) and
                    !imeKeyDownUsesDeferredPolicy(wParam))
                {
                    if (!self.imeDispatchDeferredResult()) return 0;
                }
                // #533 — 앱이 kitty keyboard protocol 을 켰는지. 켜져 있으면 `Ctrl`+글자를
                // 제어문자가 아니라 `CSI u` 로 보내야 하고 (`Ctrl+C` → `CSI 99;5u`), 그때는
                // 인터럽트도 **앱이 스스로** 처리한다. Linux · macOS 는 인코더를 타므로 이미
                // 그렇게 동작했고 Windows 만 legacy 였다 (#533 Windows 실기에서 드러남).
                const kitty_active = self.keyEncodeOptions().kitty_flags.int() != 0;

                // IME 가 아직 정리되지 않은 상태. preedit 뿐 아니라 **보류된 result**
                // 도 본다 — `imeStoreDeferredResult` 가 보류분을 `preedit_buf` 에
                // 복사하므로 보통은 둘이 같이 서지만, 결과가 그 버퍼(256B)보다 길면
                // `preedit_len` 이 안 서서 preedit 만 보면 놓친다.
                const ime_pending = self.imePreeditSlice().len != 0 or self.ime_deferred_result != null;

                // Ctrl+C는 WM_CHAR(ETX)보다 먼저 공통 입력 정책으로 보낸다.
                // terminal preedit는 IMM cancel, 그 외에는 ETX를 한 번
                // 전송한다. TranslateMessage가 queue할 짝꿍 WM_CHAR는 swallow.
                //
                // **kitty 여도 IME 가 걸려 있으면 이 경로로 온다** (#533 Windows 실기).
                // `Ctrl+C` 는 `imeKeyDownUsesDeferredPolicy` 대상이라 핸들러 상단에서
                // 조합을 확정하지 않고 판정을 미루는데, 그 판정을 하는 유일한 자리가
                // 여기다. kitty 라고 통째로 비켜서면 판정 주체가 사라져 `WM_CHAR` 가
                // `\x03` 을 먼저 내보내고 보류된 음절이 `WM_KEYUP` 의 flush 로 뒤늦게
                // PTY 에 샌다 (`03 ed 95 9c` — 실측). 아래 kitty `Ctrl`+글자 블록이
                // 이미 "조합 중이면 손대지 않는다" 로 서 있으므로 그것과 같은 원칙이다.
                if ((!kitty_active or ime_pending) and wParam == 0x43 and GetKeyState(VK_CONTROL) < 0 and GetKeyState(VK_SHIFT) >= 0) {
                    if (self.dispatchAppEvent(.{ .interrupt = {} })) {
                        self.swallow_next_wm_char = true;
                        return 0;
                    }
                }
                const maybe_key: ?app_event.KeyInput = switch (wParam) {
                    0x0D => .enter,
                    0x1B => .escape,
                    0x08 => .backspace,
                    0x25 => .left,
                    0x27 => .right,
                    0x24 => .home,
                    0x23 => .end,
                    0x2E => .delete,
                    // dispatch 가 command menu 열림 시 swallow(true), 아니면
                    // false → 아래 escape switch 로 fall through 해 기존대로
                    // PTY 전달 (히스토리 이동 등).
                    0x26 => .up,
                    0x28 => .down,
                    0x21 => .page_up,
                    0x22 => .page_down,
                    0x2D => .insert,
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
                // #493 3-c — 여기부터는 `[keys]` 가 정한다. 예전엔 `Ctrl+Shift+*`
                // 열두 개와 `Ctrl+PgUp` / `Ctrl+PgDn` 이 `wParam` 상수로 하드코딩돼
                // 있었다. `Ctrl+C` (interrupt) 만 위에서 먼저 보고, 아래 Shift+PgUp
                // (scrollback) 과 PTY 경로는 config 대상이 아니라 그대로 남는다.
                if (self.lookupKeyAction(wParam, lParam)) |action| {
                    self.runKeyAction(action);
                    return 0;
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

                // #533 — 특수키를 인코더로 보낸다. 예전엔 modifier 를 싣지 않는 VK
                // switch 라 `Shift+←` · `Alt+←` 가 아무것도 내지 않았다.
                //
                // **글자 키는 여기서 보내지 않는다** — Windows 는 그것을 `WM_CHAR` 로
                // 따로 주므로 두 번 나간다. `isNavOrFunction` 이 그 경계다.
                const kd_scan: u32 = @intCast((@as(usize, @bitCast(lParam)) >> 16) & 0xFF);
                const kd_extended = ((@as(usize, @bitCast(lParam)) >> 24) & 1) != 0;
                if (physical_key.fromScanCode(kd_scan, kd_extended)) |code| {
                    if (key_encode.isNavOrFunction(code)) _ = self.sendEncodedKeyWin(@intCast(wParam), lParam, "");
                }

                // #533 — kitty protocol 이 켜져 있을 때만 `Ctrl`+글자도 인코더로 보낸다.
                // 평소에는 `WM_CHAR` 가 배열이 반영된 제어문자를 주므로 손대지 않는다 (그
                // 경로가 AZERTY 의 `Ctrl+A` 를 `^A` 로 정확히 낸다 — 실기 확인). kitty 에서는
                // 제어문자가 아니라 `CSI u` 여야 해서 여기서 가로챈다.
                //
                // **단축키 다음이다** — `Ctrl+Shift+T` 같은 binding 은 위 `lookupKeyAction` 이
                // 이미 가져갔다. IME 가 조합 중이면 건드리지 않는다 (한글 조합이 깨진다).
                if (kitty_active and
                    GetKeyState(VK_CONTROL) < 0 and
                    self.imePreeditSlice().len == 0)
                {
                    var ctrl_chars: [8]u8 = undefined;
                    const ctrl_text = winCharWithoutCtrlAlt(
                        @intCast(wParam),
                        kd_scan,
                        GetKeyState(VK_SHIFT) < 0,
                        &ctrl_chars,
                    );
                    if (ctrl_text.len > 0 and self.sendEncodedKeyWin(@intCast(wParam), lParam, ctrl_text)) {
                        // TranslateMessage 가 큐에 넣을 짝꿍 `WM_CHAR`(제어문자) 를 삼킨다 —
                        // 그러지 않으면 `CSI u` 와 `\x03` 이 둘 다 나간다.
                        self.swallow_next_wm_char = true;
                        return 0;
                    }
                }
                return 0;
            },
            WM_KEYUP => {
                // preserve 요청 뒤 IME result가 전혀 오지 않은 IME에서는 chord가
                // 끝날 때 요청만 해제. 예상 read-only result가 보류됐는데 action이
                // 소비하지 못한 예외에는 결과를 확정해 입력 손실/가짜 overlay 방지.
                if (GetKeyState(VK_CONTROL) >= 0 and GetKeyState(VK_SHIFT) >= 0) {
                    self.ime_preserve_requested = false;
                    if (self.ime_deferred_result != null) _ = self.imeDispatchDeferredResult();
                }
                return DefWindowProcW(hwnd, msg, wParam, lParam);
            },
            WM_SIZE => {
                if (!self.layout_transition_active) {
                    if (self.resize_fn) |resize_fn| resize_fn(self.userdata);
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
                // ⚠️ 미구현 (#386 §2.4, 우선순위 낮음) — **프레임 주기를 다시 읽지 않는다.**
                // `frame_period_100ns` 는 `startFrameClock` 이 `GetDeviceCaps(VREFRESH)` 로 한
                // 번 정하고, 그 함수는 clock 이 이미 돌고 있으면 no-op 이다. 그래서 사용자가
                // 재생률을 바꾸면 (120 → 60 Hz 등) 주기가 옛 값으로 남아, 화면보다 빠르게
                // tick 을 post 하거나 (렌더 낭비 + 사양 A 의 드레인 시간을 빼앗음) 느리게
                // post 한다 (성능 손실). 창을 다른 주사율 모니터로 **옮기는** 경우는 이
                // 메시지가 아예 오지 않아 더 넓은 설계가 필요하다 (`WM_DPICHANGED` 는 DPI 가
                // 다를 때만 온다).
                //
                // 고치는 방법은 `stopFrameClock(); startFrameClock();` 로 충분해 보인다 —
                // stop 이 스레드를 join 하고 (≤ 한 주기) clock 스레드는 UI 스레드를 기다리지
                // 않으므로 `wndProc` 안에서 불러도 deadlock 이 없다. **검증에는 재생률이 둘
                // 이상인 환경이 필요하다** (Windows ② 는 59 Hz 고정이라 못 잼).
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
                // count == 0 (PTY 자동 종료) 만 skip, 단일 / 다중 탭 *항상*
                // confirm — macOS `applicationShouldTerminate:` 와 동등 정책
                // (#116). app_controller `onQuitRequest` 가 통일 처리.
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
                // #493 3-c — Alt 조합은 Windows 가 `WM_SYSKEYDOWN` 으로 보내므로
                // 여기서도 같은 `[keys]` 조회를 한다. 예전엔 `VK_RETURN` (fullscreen,
                // Shift 를 다시 읽어 workarea 판정) 과 `0x31`~`0x39` (탭 전환) 가
                // 하드코딩돼 있었다.
                //
                // `DefWindowProcW` 로 위임하지 않는 것은 그대로다 — Windows 기본
                // 경로가 어떤 `SC_` 명령을 만들든 우리가 정의한 동작으로 가게 한다.
                if (self.lookupKeyAction(wParam, lParam)) |action| {
                    self.runKeyAction(action);
                    return 0;
                }
                // #282 A7 — F10 은 Windows 가 메뉴 활성 키로 WM_SYSKEYDOWN 을 보낸다
                // (WM_KEYDOWN 안 옴). TUI(htop 종료 등)용 xterm sequence 로 PTY 전달하고
                // DefWindowProc(메뉴 활성)로 넘기지 않는다. Alt 동반이 아닌 순수 F10 만.
                if (wParam == 0x79 and GetAsyncKeyState(VK_MENU) >= 0) {
                    if (self.write_fn) |write_fn| write_fn("\x1b[21~", self.userdata);
                    return 0;
                }

                // #533 — Alt 조합을 자식 프로세스로 보낸다. 예전엔 여기서 곧장
                // `DefWindowProcW` 로 넘겨 아무것도 나가지 않았다 (신고 그대로 —
                // zellij 의 `Alt+n` 이 안 먹는 이유).
                //
                // **`Alt+Space` 는 OS 에 남긴다.** 시스템 메뉴는 Windows 사용자가 어느
                // 앱에서나 기대하는 동작이라 우리가 먹으면 안 된다. (다만 이 창은
                // `WS_POPUP` 이라 `WS_SYSMENU` 가 없어 실제로는 메뉴가 뜨지 않는다 —
                // 우리가 가로채지 않는다는 것만 지킨다. 실측: PTY 로 나가는 바이트 0 개.)
                //
                // **`Alt+F4` 는 이 가드까지 오지 않는다.** 위 `lookupKeyAction` 이 먼저 돌고
                // 기본 config 의 `quit = ["alt+f4"]` 가 거기서 잡아 `WM_CLOSE` → 종료 확인
                // 대화상자로 간다. 사용자가 보는 결과는 같지만 경로가 다르므로, 그 binding 을
                // 지운 사용자를 위해 가드는 남겨 둔다.
                const sys_vk_space: WPARAM = 0x20;
                const sys_vk_f4: WPARAM = 0x73;
                if (wParam != sys_vk_space and wParam != sys_vk_f4) {
                    const sys_scan: UINT = @intCast((@as(usize, @bitCast(lParam)) >> 16) & 0xFF);
                    var char_buf: [8]u8 = undefined;
                    // `WM_SYSKEYDOWN` 에는 글자가 실려 오지 않으므로 직접 번역한다.
                    // Ctrl · Alt 를 뺀 글자여야 인코더가 `ESC` 를 붙여 `^[n` 을 만든다.
                    const text = winCharWithoutCtrlAlt(
                        @intCast(wParam),
                        sys_scan,
                        GetKeyState(VK_SHIFT) < 0,
                        &char_buf,
                    );
                    if (self.sendEncodedKeyWin(@intCast(wParam), lParam, text)) return 0;
                }
                return DefWindowProcW(hwnd, msg, wParam, lParam);
            },
            WM_LBUTTONDOWN => {
                _ = self.dispatchAppEvent(.{
                    .mouse_down = .{
                        .x = getMouseX(lParam),
                        .y = getMouseY(lParam),
                        .button = .left,
                        .mods = mouseMods(wParam),
                    },
                });
                // capture 는 drag(selection / tab / scrollbar) 추적용 — 버튼이
                // *아직 눌려 있을 때만* 잡는다. callback 이 동기 modal(About 등)
                // 을 열면 그 사이 release 가 끝나 있는데, 그때 무조건 잡으면
                // 버튼도 안 눌린 stale capture 가 다음 click 을 가로챈다 (#329).
                // GetKeyState(비동기 아님) = 큐에서 처리된 메시지 기준의 **논리**
                // 버튼 — modal 이 pump 한 WM_LBUTTONUP 을 반영하고, 좌우 스왑
                // 사용자도 올바르다 (GetAsyncKeyState 는 물리 버튼이라 스왑
                // 사용자에게 항상 false — 재감사 발견. wParam 스냅샷도 modal
                // 이후 상태를 못 봄).
                if (GetKeyState(VK_LBUTTON) < 0) _ = SetCapture(hwnd);
                return 0;
            },
            WM_LBUTTONDBLCLK => {
                _ = self.dispatchAppEvent(.{
                    .mouse_double_click = .{
                        .x = getMouseX(lParam),
                        .y = getMouseY(lParam),
                        .button = .left,
                        .mods = mouseMods(wParam),
                    },
                });
                return 0;
            },
            WM_MOUSEMOVE => {
                // #245 — 마지막 위치 저장 (auto-scroll 타이머가 재전송에 사용).
                self.last_mouse_x = getMouseX(lParam);
                self.last_mouse_y = getMouseY(lParam);
                _ = self.dispatchAppEvent(.{
                    .mouse_move = .{
                        .x = self.last_mouse_x,
                        .y = self.last_mouse_y,
                        .left_button = (wParam & MK_LBUTTON) != 0,
                        .middle_button = (wParam & MK_MBUTTON) != 0,
                        .right_button = (wParam & MK_RBUTTON) != 0,
                        .mods = mouseMods(wParam),
                    },
                });
                return 0;
            },
            // #193 — OS cursor shape (cell hover I-beam, 그 외 arrow). HTCLIENT
            // 외 (border / caption 등) 는 DefWindowProcW 의 system cursor 유지.
            // GetCursorPos + ScreenToClient 로 정확한 client 좌표 받음 (lParam 은
            // WM_SETCURSOR 에서 사용 불가 — hit-test code + msg id 만 들어있음).
            // host (App) 의 cursorRegion callback 가 cell vs other 결정.
            WM_SETCURSOR => {
                const hit_test: u16 = @truncate(@as(usize, @bitCast(lParam)) & 0xFFFF);
                if (hit_test == HTCLIENT) {
                    if (self.cursor_region_fn) |region_fn| {
                        var pt: POINT = .{ .x = 0, .y = 0 };
                        if (GetCursorPos(&pt).toBool() and ScreenToClient(hwnd, &pt).toBool()) {
                            const region = region_fn(@intCast(pt.x), @intCast(pt.y), self.userdata);
                            const handle: HCURSOR = switch (region) {
                                .cell => self.cursor_ibeam,
                                .other => self.cursor_arrow,
                                .separator_v => self.cursor_sizewe,
                                .separator_h => self.cursor_sizens,
                            };
                            _ = SetCursor(handle);
                            return 1; // TRUE — 우리가 처리 (DefWindowProcW 안 부름)
                        }
                    }
                }
                return DefWindowProcW(hwnd, msg, wParam, lParam);
            },
            WM_LBUTTONUP => {
                _ = self.dispatchAppEvent(.{
                    .mouse_up = .{
                        .x = getMouseX(lParam),
                        .y = getMouseY(lParam),
                        .button = .left,
                        .mods = mouseMods(wParam),
                    },
                });
                releaseCaptureIfNoReportedButtonHeld();
                return 0;
            },
            WM_MOUSEWHEEL => {
                const pt = wheelClientPos(hwnd, lParam);
                _ = self.dispatchAppEvent(.{
                    .scroll = .{
                        .wheel = .{
                            .delta = getWheelDelta(wParam),
                            .x = pt.x,
                            .y = pt.y,
                            .mods = mouseMods(wParam),
                        },
                    },
                });
                return 0;
            },
            // #502 — 가운데 버튼은 chrome 에 쓰이지 않으므로 (우클릭 paste 로
            // 대체되며 빠졌음, #119) mouse reporting 전용 경로다. reporting 이
            // 꺼져 있으면 app_controller 가 그냥 무시한다.
            WM_MBUTTONDOWN => {
                _ = self.dispatchAppEvent(.{
                    .mouse_down = .{
                        .x = getMouseX(lParam),
                        .y = getMouseY(lParam),
                        .button = .middle,
                        .mods = mouseMods(wParam),
                    },
                });
                // 왼쪽과 같은 이유로 capture 를 잡는다 — 없으면 창 밖으로 끌고 나간
                // 드래그의 motion 이 끊기고, **창 밖에서 뗀 release 가 우리에게 오지
                // 않아** 앱이 가운데 버튼을 영원히 눌린 것으로 안다
                // (`mouse_report` 가 "뗌은 어디서 놓든 항상 보고한다" 로 막으려는
                // 상태인데, 이벤트 자체가 안 오면 인코더가 손쓸 수 없다).
                if (GetKeyState(VK_MBUTTON) < 0) _ = SetCapture(hwnd);
                return 0;
            },
            WM_MBUTTONUP => {
                _ = self.dispatchAppEvent(.{
                    .mouse_up = .{
                        .x = getMouseX(lParam),
                        .y = getMouseY(lParam),
                        .button = .middle,
                        .mods = mouseMods(wParam),
                    },
                });
                releaseCaptureIfNoReportedButtonHeld();
                return 0;
            },
            // 우클릭 paste (#119) — cmd.exe console 표준 패턴. 이전 가운데 버튼
            // (WM_MBUTTONDOWN) 은 deprecated. macOS 의 tildazRightMouseDown 과
            // 동등. SPEC.md §3 / §11 참고.
            WM_RBUTTONDOWN => {
                // #329 — 열린 command menu 가 우클릭을 소비하면 (menu 닫기)
                // paste 하지 않는다. 그 외에는 기존 즉시 paste 유지 (#119).
                // #483 5단계 — 좌표를 싣는다 (비활성 pane 우클릭 = 포커스만).
                if (self.dispatchAppEvent(.{ .mouse_right_down = .{
                    .x = getMouseX(lParam),
                    .y = getMouseY(lParam),
                    .button = .right,
                    .mods = mouseMods(wParam),
                } })) return 0;
                if (self.write_fn) |write_fn| {
                    self.pasteClipboard(write_fn);
                }
                return 0;
            },
            WM_TAB_CLOSED => {
                _ = self.dispatchAppEvent(.{ .tab_closed = wParam });
                return 0;
            },
            // #195 — 다른 app 활성화 시 우리 z-order 양보. visible 유지 (drop-down
            // 본분 — hide 안 함, 다른 app 뒤에 보임). `WS_EX_TOPMOST` 만 잠시 해제
            // (`HWND_NOTOPMOST`) → 그 app 이 z-order 위로. 다시 우리 활성화 시
            // `HWND_TOPMOST` 복귀. mac `applicationDidResignActive` / `applicationDidBecomeActive`
            // 동등 패턴. wParam=FALSE (0) = becoming inactive, TRUE (1) = becoming active.
            WM_ACTIVATEAPP => {
                if (self.visible) {
                    const top = if (wParam == 0) HWND_NOTOPMOST else HWND_TOPMOST;
                    _ = SetWindowPos(hwnd, top, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                    // #390 — z-order 양보와 같은 지점에서 열린 command menu 도
                    // 닫는다. `WM_ACTIVATEAPP` 은 *다른 프로세스* 창 활성화에만
                    // 오므로 (같은 스레드의 `MessageBoxW` 는 안 옴) 오탐이 없다.
                    if (wParam == 0) _ = self.dispatchAppEvent(.{ .focus_lost = {} });
                }
                return DefWindowProcW(hwnd, msg, wParam, lParam);
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

    /// client 영역 크기 (px). 창이 없거나 `GetClientRect` 가 실패하면 `{0, 0}`.
    ///
    /// #352 — 이전에는 창이 없을 때 `{800, 400}` (창 생성 시 초기 크기) 을 돌려줬다.
    /// 일어날 수 없는 상태에 그럴듯한 가짜 값을 채운 것이다 — `Window.init` 은
    /// `CreateWindowExW` 실패 시 `error.CreateWindowFailed` 를 반환하고 host 가 `try`
    /// 로 받아 `run()` 을 중단하므로, 이 함수가 불리는 시점에 `hwnd` 는 항상 있다.
    /// 그리고 `GetClientRect` 의 `BOOL` 을 버려서 **실패 시 초기화되지 않은 `rect` 를
    /// 읽었다** — 그쪽이 진짜 문제였다. 이제 실패를 `{0, 0}` 으로 드러내고, 격자
    /// 계산은 `ui_metrics.terminalCols` / `terminalRows` 의 "최소 1" 계약이 받는다.
    /// #358 — 위 문단의 "hwnd 는 항상 있다" 를 이제 `requireHwnd()` 가 표현한다. 남은
    /// `{0, 0}` 은 `GetClientRect` 실패용이고, 그건 도달 불가가 아니다.
    pub fn getClientSize(self: *const Window) struct { w: c_int, h: c_int } {
        const hwnd = self.requireHwnd();
        var rect: RECT = std.mem.zeroes(RECT);
        if (!GetClientRect(hwnd, &rect).toBool()) return .{ .w = 0, .h = 0 };
        return .{ .w = rect.right - rect.left, .h = rect.bottom - rect.top };
    }

    pub fn closeAfterShellExit(self: *Window) void {
        self.shell_exited = true;
        _ = PostMessageW(self.requireHwnd(), WM_CLOSE, 0, 0);
    }

    pub fn postTabClosed(self: *const Window, tab_ptr: usize) void {
        _ = PostMessageW(self.requireHwnd(), WM_TAB_CLOSED, tab_ptr, 0);
    }

    /// WM_IME_COMPOSITION (GCS_COMPSTR) → ImmGetCompositionStringW UTF-16 → UTF-8
    /// `preedit_buf` 저장. 길이 0 / 음수 / 변환 실패 시 preedit_len = 0. 한글 /
    /// 일본어 / 중국어 / 베트남어 등 모든 IMM IME 가 같은 API path.
    fn imeReadCompositionPreedit(self: *Window) void {
        const hwnd = self.requireHwnd();
        const himc = ImmGetContext(hwnd);
        if (himc == null) {
            self.preedit_len = 0;
            return;
        }
        defer _ = ImmReleaseContext(hwnd, himc);

        // 1차 호출: 길이 (bytes) 만 알아냄. 0 → 빈 preedit (조합 막 시작 / 백
        // 스페이스로 모두 지움).
        const len_bytes = ImmGetCompositionStringW(himc, GCS_COMPSTR, null, 0);
        if (len_bytes <= 0) {
            self.preedit_len = 0;
            return;
        }
        var w16_buf: [128]u16 = undefined;
        const len_chars: u32 = @min(@as(u32, @intCast(len_bytes)) / 2, @as(u32, @intCast(w16_buf.len)));
        const got = ImmGetCompositionStringW(himc, GCS_COMPSTR, &w16_buf, len_chars * 2);
        if (got <= 0) {
            self.preedit_len = 0;
            return;
        }

        // UTF-16 LE → UTF-8 변환. surrogate pair 도 자동 결합.
        const w16_slice = w16_buf[0..len_chars];
        const written = std.unicode.utf16LeToUtf8(self.preedit_buf[0..], w16_slice) catch {
            self.preedit_len = 0;
            return;
        };
        self.preedit_len = written;
    }

    /// renderer 가 매 frame 호출 — 현재 IME preedit (UTF-8). 빈 slice 면 비활성.
    pub fn imePreeditSlice(self: *const Window) []const u8 {
        return self.preedit_buf[0..self.preedit_len];
    }

    /// IME composition / candidate window 위치 갱신 — IME 가 한자 후보 list 등
    /// popup 을 (x_px, y_px) 근처에 띄움. 일본 / 중국 IME 의 한자 변환 후보가
    /// cursor 옆 자연스럽게 따라옴. 한국어는 후보 popup 거의 X — 영향 미미.
    /// (#164 1d) 매 frame onRender 끝에 호출 — cursor 이동 시 popup 도 따라감.
    pub fn imeSetCompositionPos(self: *const Window, x_px: c_int, y_px: c_int) void {
        const hwnd = self.requireHwnd();
        const himc = ImmGetContext(hwnd);
        if (himc == null) return;
        defer _ = ImmReleaseContext(hwnd, himc);
        var form: COMPOSITIONFORM = .{
            .dwStyle = CFS_POINT,
            .ptCurrentPos = .{ .x = x_px, .y = y_px },
            .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        };
        _ = ImmSetCompositionWindow(himc, &form);
    }

    /// GCS_RESULTSTR를 UTF-16으로 읽고 소유 UTF-8 slice로 변환한다. caller가
    /// page_allocator로 해제한다.
    fn imeReadCompositionResult(self: *Window) ?[]u8 {
        const hwnd = self.requireHwnd();
        const himc = ImmGetContext(hwnd);
        if (himc == null) return null;
        defer _ = ImmReleaseContext(hwnd, himc);

        const len_bytes_raw = ImmGetCompositionStringW(himc, GCS_RESULTSTR, null, 0);
        if (len_bytes_raw <= 0 or @mod(len_bytes_raw, 2) != 0) return null;
        const len_bytes: usize = @intCast(len_bytes_raw);
        const len_units = len_bytes / 2;
        const alloc = std.heap.page_allocator;
        const w16_buf = alloc.alloc(u16, len_units) catch return null;
        defer alloc.free(w16_buf);
        const got_raw = ImmGetCompositionStringW(himc, GCS_RESULTSTR, w16_buf.ptr, @intCast(len_bytes));
        if (got_raw <= 0 or got_raw > len_bytes_raw or @mod(got_raw, 2) != 0) return null;
        const got_units: usize = @intCast(@divTrunc(got_raw, 2));
        return std.unicode.utf16LeToUtf8Alloc(alloc, w16_buf[0..got_units]) catch null;
    }

    /// 이미 읽은 commit 결과를 현재 app 입력 대상에 동기 반영한다. 이 함수가
    /// 성공한 WM_IME_COMPOSITION은 caller가 소비하므로 같은 결과의 WM_CHAR가
    /// 생성되지 않는다. 다중 codepoint도 원래 순서대로 정확히 한 번 처리한다.
    fn imeDispatchCommittedText(self: *Window, utf8: []const u8) bool {
        if (utf8.len == 0) return false;
        var view = std.unicode.Utf8View.init(utf8) catch return false;
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            if (self.dispatchAppEvent(.{ .text_input = cp })) continue;
            const write_fn = self.write_fn orelse return false;
            var encoded: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(cp, &encoded) catch return false;
            write_fn(encoded[0..encoded_len], self.userdata);
        }
        return true;
    }

    /// Ctrl chord result를 input_policy까지 가져가야 하는 leave/discard 경계.
    /// 나머지는 WM_KEYDOWN 시작에서 commit해 key/action보다 먼저 처리한다.
    fn imeKeyDownUsesDeferredPolicy(wParam: WPARAM) bool {
        if (GetKeyState(VK_CONTROL) >= 0) return false;
        if (wParam == 0x43) return true;
        if (GetKeyState(VK_SHIFT) >= 0) return false;
        return wParam == 0x56 or wParam == 0x7B;
    }

    fn imeStoreDeferredResult(self: *Window, utf8: []const u8) bool {
        const alloc = std.heap.page_allocator;
        if (self.ime_deferred_result) |previous| {
            const joined = alloc.alloc(u8, previous.len + utf8.len) catch {
                // 극단적인 allocation 실패에서도 먼저 도착한 결과를 먼저
                // 반영하고 현재 결과는 다시 보류해 입력 순서/손실을 지킨다.
                if (!self.imeDispatchDeferredResult()) return false;
                self.ime_deferred_result = alloc.dupe(u8, utf8) catch return false;
                if (utf8.len <= self.preedit_buf.len) {
                    @memcpy(self.preedit_buf[0..utf8.len], utf8);
                    self.preedit_len = utf8.len;
                }
                return true;
            };
            @memcpy(joined[0..previous.len], previous);
            @memcpy(joined[previous.len..], utf8);
            alloc.free(previous);
            self.ime_deferred_result = joined;
        } else {
            self.ime_deferred_result = alloc.dupe(u8, utf8) catch return false;
        }
        const deferred = self.ime_deferred_result.?;
        if (deferred.len <= self.preedit_buf.len) {
            @memcpy(self.preedit_buf[0..deferred.len], deferred);
            self.preedit_len = deferred.len;
        }
        return true;
    }

    fn imeClearDeferredResult(self: *Window, clear_preedit: bool) void {
        if (self.ime_deferred_result) |result| std.heap.page_allocator.free(result);
        self.ime_deferred_result = null;
        self.ime_preserve_requested = false;
        if (clear_preedit) self.preedit_len = 0;
    }

    pub fn imeHasDeferredResult(self: *const Window) bool {
        return self.ime_deferred_result != null;
    }

    fn imeDispatchDeferredResult(self: *Window) bool {
        const result = self.ime_deferred_result orelse return true;
        if (!self.imeDispatchCommittedText(result)) return false;
        self.imeClearDeferredResult(true);
        return true;
    }

    fn imeSetCompositionString(self: *Window, utf8: []const u8) bool {
        const utf16_len = std.unicode.calcUtf16LeLen(utf8) catch return false;
        if (utf16_len == 0) return false;
        const alloc = std.heap.page_allocator;
        const utf16 = alloc.alloc(u16, utf16_len) catch return false;
        defer alloc.free(utf16);
        const written = std.unicode.utf8ToUtf16Le(utf16, utf8) catch return false;
        const hwnd = self.requireHwnd();
        const himc = ImmGetContext(hwnd);
        if (himc == null) return false;
        defer _ = ImmReleaseContext(hwnd, himc);
        return ImmSetCompositionStringW(himc, SCS_SETSTR, utf16[0..written].ptr, @intCast(written * 2), null, 0).toBool();
    }

    /// read-only action 앞에서 MS-IME가 이미 result/end를 낸 경우 그 결과를
    /// 실제 IMM composition으로 되돌린다. 복원 실패 시 결과를 한 번 commit해
    /// 입력을 잃거나 renderer에 가짜 overlay만 남기지 않는다.
    fn imeRestoreDeferredComposition(self: *Window) bool {
        const result = self.ime_deferred_result orelse return true;
        self.ime_preserve_requested = false;
        if (self.imeSetCompositionString(result)) {
            self.imeClearDeferredResult(false);
            return true;
        }
        return self.imeDispatchDeferredResult();
    }

    /// pending=leave인 input에서 실제 IMM composition을 유지한다.
    /// result가 이미 보류됐으면 즉시 복원하고, action이 먼저면 뒤따르는
    /// result/end에서 복원하도록 요청을 기록한다. mouse paste처럼 IMM이
    /// composition을 끝내지 않는 action은 native state를 그대로 둔다.
    pub fn imePreserveComposition(self: *Window) bool {
        if (self.ime_deferred_result != null) return self.imeRestoreDeferredComposition();
        if (self.preedit_len == 0) return true;
        if (GetKeyState(VK_CONTROL) < 0) self.ime_preserve_requested = true;
        return true;
    }

    /// 현재 IMM composition을 강제 complete. 한국어 IME 실기에서
    /// ImmNotifyIME가 GCS_RESULTSTR/END를 nested dispatch한다. RESULTSTR를 위에서
    /// 동기 처리한 경우에만 true라 action이 결과 문자 뒤에 실행됨을 보장한다.
    pub fn imeCompleteComposition(self: *Window) bool {
        if (self.ime_deferred_result != null) return self.imeDispatchDeferredResult();
        if (self.preedit_len == 0) return true;
        const hwnd = self.requireHwnd();
        const himc = ImmGetContext(hwnd);
        if (himc == null) return false;
        defer _ = ImmReleaseContext(hwnd, himc);

        self.ime_complete_in_progress = true;
        self.ime_complete_result_ok = false;
        defer self.ime_complete_in_progress = false;
        if (!ImmNotifyIME(himc, NI_COMPOSITIONSTR, CPS_COMPLETE, 0).toBool()) return false;
        return self.ime_complete_result_ok;
    }

    /// IME composition 강제 cancel — preedit_buf 비우고 IME state 도 reset.
    /// IME 가 다음 GCS_RESULTSTR 보내지 않게 cancel. 한국어 / 일본어
    /// / 중국어 모두 같은 IMM API path. (#164 follow-up)
    pub fn imeCancelComposition(self: *Window) bool {
        if (self.ime_deferred_result != null) {
            self.imeClearDeferredResult(true);
            return true;
        }
        self.ime_preserve_requested = false;
        if (self.preedit_len == 0) return true;
        const hwnd = self.requireHwnd();
        const himc = ImmGetContext(hwnd);
        if (himc == null) return false;
        defer _ = ImmReleaseContext(hwnd, himc);
        const ok = ImmNotifyIME(himc, NI_COMPOSITIONSTR, CPS_CANCEL, 0).toBool();
        self.preedit_len = 0;
        return ok;
    }

    /// #493 3-c — `[keys]` 조회. `WM_KEYDOWN` 과 `WM_SYSKEYDOWN` 이 **같은 판정**을
    /// 쓴다 (Alt 조합만 후자로 오므로 예전엔 두 곳에 따로 적혀 있었다).
    ///
    /// Windows 는 문자 키에서 **라벨** 기반이다 — `VK_W` 는 Shift 여부와 무관하게
    /// 0x57 이고 `VK_OEM_4` 도 그렇다. 그래서 Linux 와 달리 정규화가 필요 없다.
    ///
    /// `lParam` 에서 scan code 와 extended 비트를 꺼내 **물리 위치**도 함께 넘긴다
    /// (#496) — 위치로 적은 binding (`ctrl+shift+[KeyW]`) 이 그것으로 매칭된다.
    /// extended 비트가 없으면 control pad 와 numpad 가 구분되지 않는다
    /// (`physical_key.zig` 의 충돌 표).
    fn lookupKeyAction(self: *Window, wParam: WPARAM, lParam: LPARAM) ?config_mod.KeyAction {
        var modifiers: u32 = 0;
        if (GetKeyState(VK_CONTROL) < 0) modifiers |= config_mod.Hotkey.MOD_CTRL;
        if (GetKeyState(VK_SHIFT) < 0) modifiers |= config_mod.Hotkey.MOD_SHIFT;
        if (GetKeyState(VK_MENU) < 0) modifiers |= config_mod.Hotkey.MOD_ALT;
        if (GetKeyState(VK_LWIN) < 0 or GetKeyState(VK_RWIN) < 0) modifiers |= config_mod.Hotkey.MOD_SUPER;

        const bits: usize = @bitCast(lParam);
        const scan: u32 = @intCast((bits >> 16) & 0xFF);
        const extended = ((bits >> 24) & 1) != 0;
        const code = physical_key.fromScanCode(scan, extended);

        return config_mod.lookupAction(
            self.key_bindings,
            .{ .vkey = @intCast(wParam), .modifiers = modifiers },
            code,
        );
    }

    /// #493 3-c — 액션 실행. 예전엔 `wParam` 으로 다시 분기했다 (분류와 실행 두 곳에
    /// 같은 키 표가 있었다는 뜻이고, 그 이중 기술이 갈라지는 것이 #484 의 원인이었다).
    fn runKeyAction(self: *Window, action: config_mod.KeyAction) void {
        const mapped = config_mod.inputForAction(action);
        // `paste` 는 `app_event.Shortcut` 에 없다 — 클립보드 읽기가 host 쪽 일이고
        // preedit commit 정책도 달라서 (`Input.paste`) 따로 처리한다.
        if (mapped.input == .paste) {
            if (self.write_fn) |write_fn| self.pasteClipboard(write_fn);
            return;
        }
        const shortcut: app_event.Shortcut = switch (mapped.input.shortcut) {
            .new_tab => .new_tab,
            .close_tab => .close_active_tab,
            .next_tab => .next_tab,
            .prev_tab => .prev_tab,
            // 인덱스는 액션 이름에서 왔다 (`switch_tab3` → 2). 예전엔 여기서
            // `wParam - 0x31` 로 뽑았다.
            .switch_tab => .{ .switch_tab = mapped.tab_index orelse return },
            .reset_terminal => .reset_terminal,
            .show_about => .show_about,
            .open_config => .open_config,
            .open_log => .open_log,
            .copy_selection => .copy_selection,
            .dump_perf => .dump_perf,
            // #493 3-c — 두 fullscreen 이 별 액션이 됐다. 예전엔 `GetAsyncKeyState`
            // 로 Shift 를 다시 읽어 갈랐는데, 사용자가 `fullscreen_workarea` 에
            // Shift 없는 조합을 줄 수도 있으므로 그 규칙으로는 안 된다.
            .fullscreen => .{ .fullscreen = false },
            .fullscreen_workarea => .{ .fullscreen = true },
            .quit => {
                // Alt+F4 는 원래 `DefWindowProcW` 가 `SC_CLOSE` → `WM_CLOSE` 로
                // 처리했다. 이제 액션으로 잡으므로 같은 메시지를 직접 보낸다 —
                // `onQuitRequest` 의 확인 다이얼로그 경로가 그대로 이어진다.
                //
                // 사용자가 `quit` 을 다른 키로 옮겨도 Alt+F4 자체는 OS 가 계속
                // 닫는다. 그것을 막으려면 `SC_CLOSE` 를 가로채야 하는데, 시스템
                // 메뉴의 닫기까지 무력화되므로 하지 않는다.
                _ = PostMessageW(self.requireHwnd(), WM_CLOSE, 0, 0);
                return;
            },
            // 이 host 의 키 경로가 내지 않는 것들 — toggle 은 전역 핫키가, menu 는
            // 마우스가 진입점이다.
            .toggle_visibility, .open_command_menu, .open_shortcuts => return,
            // #483 4a — 분할 액션. `app_event.Shortcut` 매핑과 배선은 5단계 (Linux 4b 먼저).
            // #483 5단계 — 분할 · 포커스 · 크기 · 균등 · 최대화. 방향은 액션 이름에서 왔다 (`split_vertical` → `.right`).
            .split => .{ .split = mapped.direction orelse return },
            .focus_pane => .{ .focus_pane = mapped.direction orelse return },
            .resize_pane => .{ .resize_pane = mapped.direction orelse return },
            .equalize_panes => .equalize_panes,
            .zoom_pane => .zoom_pane,
            .close_pane => .close_pane,
        };
        if (!self.dispatchAppEvent(.{ .shortcut = shortcut })) {
            // app 이 소비하지 않은 fullscreen 은 window 가 직접 처리한다 (기존 동작).
            switch (shortcut) {
                .fullscreen => |workarea| self.toggleFullscreenMode(if (workarea) .workarea else .monitor),
                else => {},
            }
        }
    }

    /// #533 — `Ctrl` · `Alt` 를 뺀 채 이 키가 내는 글자. `Alt+n` → `n`,
    /// `Shift+Alt+n` → `N`. 인코더가 그 앞에 `ESC` 를 붙인다.
    ///
    /// Shift 만 남기는 것은 macOS 의 `charactersByApplyingModifiers:` 와 같은 기준이다
    /// — Shift 는 진짜로 글자를 바꾸는 modifier 이고, Ctrl · Alt 는 인코더가 센다.
    /// codepoint 만 넘기면 Shift 가 반영되지 않아 `Shift+Alt+n` 이 `^[n` 이 된다 (실측).
    fn winCharWithoutCtrlAlt(vk: UINT, scan: UINT, shift: bool, buf: []u8) []const u8 {
        // 256 항목 키보드 상태. Shift 만 켜고 나머지는 눌리지 않은 것으로 둔다.
        var state = [_]u8{0} ** 256;
        if (shift) {
            state[@intCast(VK_SHIFT)] = 0x80;
        }

        var wide: [8]WCHAR = undefined;
        // `hkl` 은 반드시 명시한다 — `NULL` 은 `ToUnicodeEx` 에서 *활성* layout 이지만
        // 같은 자리의 다른 API 와 뜻이 갈려 표가 섞인다 (#496 Windows 실측).
        // `wFlags` bit 2 는 **키보드 상태를 바꾸지 않게** 한다 — 없으면 dead key 가
        // 다음 글자를 오염시킨다 (프랑스 자판의 `^` 다음 글자가 `î` 가 된다).
        const n = ToUnicodeEx(vk, scan, &state, &wide, wide.len, 0b100, GetKeyboardLayout(0));
        if (n <= 0) return "";

        const len = std.unicode.utf16LeToUtf8(buf, wide[0..@intCast(n)]) catch return "";
        return buf[0..len];
    }

    /// #533 — 키 하나를 `key_encode` 로 인코딩해 PTY 로 보낸다. 보낼 것이 없으면
    /// `false` — 호출자가 기존 경로로 흘리거나 `DefWindowProcW` 에 넘긴다.
    ///
    /// `utf8` 은 이 키가 만든 글자다. Windows 는 그것을 `WM_CHAR` 로 따로 주므로 이
    /// 경로는 대개 빈 문자열이고, 인코더가 `code` 와 `mods` 로 바이트를 만든다.
    fn sendEncodedKeyWin(self: *Window, vk: UINT, lParam: LPARAM, utf8: []const u8) bool {
        const write_fn = self.write_fn orelse return false;

        // scan code 는 lParam 16~23 비트, extended 는 24 비트. 둘을 함께 봐야
        // control pad 와 numpad 가 섞이지 않는다 (`physical_key.zig` 헤더).
        const scan: UINT = @intCast((@as(usize, @bitCast(lParam)) >> 16) & 0xFF);
        const extended = ((@as(usize, @bitCast(lParam)) >> 24) & 1) != 0;

        const shift = GetKeyState(VK_SHIFT) < 0;
        const ctrl = GetKeyState(VK_CONTROL) < 0;
        const alt = GetKeyState(VK_MENU) < 0;

        // #533 — 수식키를 다 뺀 글자의 첫 코드포인트. kitty keyboard protocol 의 항목
        // `code` 이고, 0 이면 그 프로토콜에서 Ctrl · Alt 조합이 통째로 사라진다.
        var unshifted_buf: [8]u8 = undefined;
        const unshifted_text = winCharWithoutCtrlAlt(vk, scan, false, &unshifted_buf);
        const unshifted: u21 = if (unshifted_text.len == 0) 0 else blk: {
            var it = std.unicode.Utf8Iterator{ .bytes = unshifted_text, .i = 0 };
            break :blk it.nextCodepoint() orelse 0;
        };

        // #533 후속 — 비라틴 배열 (러시아어 등) 에서 Alt 조합에 붙일 ASCII. 그 배열은 글자 키가
        // Cyrillic 을 내므로 인코더가 `ESC` 를 붙일 1 바이트를 못 찾아 그 글자가 그냥 나간다 —
        // `Alt+n` (zellij · tmux) 이 안 닿는다. 물리 키의 US 글자로 되짚는다 (macOS · Linux 와 같은 수).
        var text = utf8;
        var us_buf: [1]u8 = undefined;
        if (alt and (text.len != 1 or text[0] > 0x7f)) {
            if (key_encode.usAscii(physical_key.fromScanCode(scan, extended))) |c| {
                us_buf[0] = if (shift and c >= 'a' and c <= 'z') c - 32 else c;
                text = us_buf[0..1];
            }
        }
        var out_buf: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&out_buf);
        key_encode.encode(&writer, .{
            .code = physical_key.fromScanCode(scan, extended),
            .mods = .{ .shift = shift, .ctrl = ctrl, .alt = alt },
            // #533 정책 ③ — Windows 의 AltGr 은 `Ctrl+Alt` 로 도착하고, 그 조합이 글자를
            // 만들면 `WM_CHAR` 가 그 글자를 따로 보낸다. 이 경로는 글자를 만들지 않는
            // 키를 다루므로 소비된 modifier 가 없다.
            .consumed_mods = .{},
            .utf8 = text,
            .unshifted_codepoint = unshifted,
        }, self.keyEncodeOptions()) catch return false;

        const bytes = writer.buffered();
        if (bytes.len == 0) return false;
        // Ctrl+C 의 큐 우회는 `App.onKeyInput` 이 판정한다 (macOS · Linux 와 달리 이
        // host 는 write 통로가 하나다).
        write_fn(bytes, self.userdata);
        return true;
    }

    fn keyEncodeOptions(self: *Window) key_encode.Options {
        const f = self.encode_options_fn orelse return .{};
        return f(self.userdata);
    }

    fn pasteClipboard(self: *Window, write_fn: *const fn ([]const u8, ?*anyopaque) void) void {
        if (!OpenClipboard(self.hwnd).toBool()) return;
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

        // UTF-16 → UTF-8. paste text 통째로 buffer 에 모아서 #142 의 paste event
        // dispatch — app_controller 가 PTY 로 한 번에 write.
        // #298 — UTF-16 surrogate 수동 디코딩 → std.unicode.utf16LeToUtf8
        // (BMP=3B, surrogate pair=4B 라 len*3+4 로 충분).
        const alloc = std.heap.page_allocator;
        const u8_buf = alloc.alloc(u8, len * 3 + 4) catch return;
        defer alloc.free(u8_buf);
        const u8_len = std.unicode.utf16LeToUtf8(u8_buf, wide_ptr[0..len]) catch return;
        if (u8_len == 0) return;

        const utf8 = u8_buf[0..u8_len];
        // app_controller.onAppEvent(.paste) 가 항상 처리 —
        // SessionCore.pasteToActive (bracketed paste mode 검사 + wrap).
        // 이전엔 false 반환 + write_fn 직접 호출이라 bracketed paste wrap
        // 적용 못 됨.
        _ = self.dispatchAppEvent(.{ .paste = utf8 });
        _ = write_fn;
    }

    pub fn requestPaste(self: *Window) void {
        if (self.write_fn) |write_fn| self.pasteClipboard(write_fn);
    }

    pub fn copyToClipboard(self: *Window, text: [:0]const u8) void {
        if (text.len == 0) return;
        if (!OpenClipboard(self.hwnd).toBool()) return;
        defer _ = CloseClipboard();

        _ = EmptyClipboard();

        // #298 — UTF-8 → UTF-16 surrogate 수동 인코딩(길이 세기 + 짝꿍 조립)을
        // std.unicode 로. GlobalAlloc 버퍼(UTF-16 units + null terminator)에 직접 write.
        const utf16_len = std.unicode.calcUtf16LeLen(text) catch return;
        const alloc_size = (utf16_len + 1) * 2;
        const hmem = GlobalAlloc(GMEM_MOVEABLE, alloc_size) orelse return;
        const raw_lock = GlobalLock(hmem) orelse {
            _ = GlobalFree(hmem);
            return;
        };
        const wide_ptr: [*]u16 = @ptrCast(@alignCast(raw_lock));
        const n = std.unicode.utf8ToUtf16Le(wide_ptr[0..utf16_len], text) catch {
            _ = GlobalUnlock(hmem);
            _ = GlobalFree(hmem);
            return;
        };
        wide_ptr[n] = 0; // null terminator

        _ = GlobalUnlock(hmem);
        _ = SetClipboardData(CF_UNICODETEXT, hmem);
    }

    /// Re-export — config.DockPosition 이 cross-platform single source.
    pub const DockPosition = @import("config.zig").DockPosition;
};
