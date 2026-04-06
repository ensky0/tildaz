const std = @import("std");
const windows = std.os.windows;

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
const CS_OWNDC: UINT = 0x0020;
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
const WM_TAB_CLOSED: UINT = WM_USER + 2;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_LBUTTONDBLCLK: UINT = 0x0203;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_MBUTTONDOWN: UINT = 0x0207;
const WM_MOUSEWHEEL: UINT = 0x020A;
const MK_LBUTTON: WPARAM = 0x0001;

// Other constants
const SW_SHOW: c_int = 5;
const SW_HIDE: c_int = 0;
const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const SWP_NOACTIVATE: UINT = 0x0010;
const SWP_SHOWWINDOW: UINT = 0x0040;
const CW_USEDEFAULT: c_int = @bitCast(@as(c_uint, 0x80000000));
const COLOR_WINDOW: c_int = 5;
const IDC_ARROW: [*:0]const WCHAR = @ptrFromInt(32512);
const GWL_USERDATA: c_int = -21;
const TRANSPARENT: c_int = 1;
const LWA_ALPHA: DWORD = 0x00000002;

const MONITOR_DEFAULTTOPRIMARY: DWORD = 0x00000001;

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
extern "user32" fn GetMessageW(*MSG, HWND, UINT, UINT) callconv(.c) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.c) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.c) LRESULT;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.c) HDC;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.c) BOOL;
extern "user32" fn InvalidateRect(HWND, ?*const RECT, BOOL) callconv(.c) BOOL;
extern "user32" fn SetWindowPos(HWND, HWND, c_int, c_int, c_int, c_int, UINT) callconv(.c) BOOL;
extern "user32" fn SetForegroundWindow(HWND) callconv(.c) BOOL;
extern "user32" fn RegisterHotKey(HWND, c_int, UINT, UINT) callconv(.c) BOOL;
extern "user32" fn UnregisterHotKey(HWND, c_int) callconv(.c) BOOL;
extern "user32" fn GetCursorPos(*POINT) callconv(.c) BOOL;
extern "user32" fn MonitorFromPoint(POINT, DWORD) callconv(.c) ?*anyopaque;
extern "user32" fn GetMonitorInfoW(?*anyopaque, *MONITORINFO) callconv(.c) BOOL;
extern "user32" fn SetLayeredWindowAttributes(HWND, COLORREF, u8, DWORD) callconv(.c) BOOL;
extern "user32" fn SetWindowLongPtrW(HWND, c_int, isize) callconv(.c) isize;
extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(.c) isize;
extern "user32" fn LoadCursorW(HINSTANCE, [*:0]const WCHAR) callconv(.c) HCURSOR;
extern "user32" fn SetTimer(HWND, usize, UINT, ?*anyopaque) callconv(.c) usize;
extern "user32" fn KillTimer(HWND, usize) callconv(.c) BOOL;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.c) BOOL;
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
extern "user32" fn MessageBoxW(HWND, [*:0]const WCHAR, [*:0]const WCHAR, UINT) callconv(.c) c_int;
extern "user32" fn SetCapture(HWND) callconv(.c) HWND;
extern "user32" fn ReleaseCapture() callconv(.c) BOOL;
extern "user32" fn GetDpiForWindow(HWND) callconv(.c) UINT;
extern "user32" fn EmptyClipboard() callconv(.c) BOOL;
extern "user32" fn SetClipboardData(UINT, ?*anyopaque) callconv(.c) ?*anyopaque;
extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(.c) ?*anyopaque;
const GMEM_MOVEABLE: UINT = 0x0002;

const MB_YESNO: UINT = 0x04;
const MB_ICONQUESTION: UINT = 0x20;
const MB_DEFBUTTON2: UINT = 0x100;
const IDYES: c_int = 6;

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

pub const Window = struct {
    hwnd: HWND = null,
    visible: bool = false,
    font: HFONT = null,
    cell_width: c_int = 8,
    cell_height: c_int = 16,
    render_fn: ?*const fn (*Window) void = null,
    resize_fn: ?*const fn (u16, u16, ?*anyopaque) void = null,
    userdata: ?*anyopaque = null,
    write_fn: ?*const fn ([]const u8, ?*anyopaque) void = null,
    app_msg_fn: ?*const fn (UINT, WPARAM, LPARAM, ?*anyopaque) bool = null,
    skip_swap: bool = false,
    shell_exited: bool = false,
    dc: HDC = null, // DC for GDI font measurement

    const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("TildaZWindow");
    const HOTKEY_ID: c_int = 1;
    const VK_F1: UINT = 0x70;
    const RENDER_TIMER_ID: usize = 1;

    pub fn init(self: *Window, font_family: [*:0]const WCHAR, font_size: c_int, opacity: u8, cell_width_scale: f32, line_height_scale: f32) !void {
        const hInstance = GetModuleHandleW(null);

        const wc = WNDCLASSEXW{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = CS_OWNDC | CS_DBLCLKS,
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

        self.hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED,
            CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral("TildaZ"),
            WS_POPUP,
            0,
            0,
            800,
            400,
            null,
            null,
            hInstance,
            null,
        );

        if (self.hwnd == null) {
            return error.CreateWindowFailed;
        }

        // Store self pointer in window userdata
        _ = SetWindowLongPtrW(self.hwnd, GWL_USERDATA, @intCast(@intFromPtr(self)));

        _ = SetLayeredWindowAttributes(self.hwnd, 0, opacity, LWA_ALPHA);

        // Register F1 global hotkey
        if (RegisterHotKey(self.hwnd, HOTKEY_ID, 0, VK_F1) == 0) {
            OutputDebugStringA("WARNING: Failed to register F1 hotkey\n");
        }

        // Scale font_size by DPI (config value is in logical pixels at 96 DPI)
        const dpi = GetDpiForWindow(self.hwnd);
        const effective_dpi: f32 = if (dpi > 0) @floatFromInt(dpi) else 96.0;
        const scaled_font_size: c_int = @intFromFloat(@round(@as(f32, @floatFromInt(font_size)) * effective_dpi / 96.0));

        // Create monospace font (used for measuring cell metrics)
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
            font_family,
        );

        // Measure cell metrics from font
        self.dc = GetDC(self.hwnd);
        if (self.dc != null) {
            const old_f = SelectObject(self.dc, self.font);
            var tm: TEXTMETRICW = undefined;
            _ = GetTextMetricsW(self.dc, &tm);
            const base_w: f32 = @floatFromInt(tm.tmAveCharWidth);
            const base_h: f32 = @floatFromInt(tm.tmHeight + tm.tmExternalLeading);
            self.cell_width = @max(1, @as(c_int, @intFromFloat(@round(base_w * cell_width_scale))));
            self.cell_height = @max(1, @as(c_int, @intFromFloat(@round(base_h * line_height_scale))));
            _ = SelectObject(self.dc, old_f);
        }

        // Start render timer (60fps)
        _ = SetTimer(self.hwnd, RENDER_TIMER_ID, 16, null);
    }

    pub fn deinit(self: *Window) void {
        if (self.hwnd) |hwnd| {
            _ = KillTimer(hwnd, RENDER_TIMER_ID);
            _ = UnregisterHotKey(hwnd, HOTKEY_ID);
            if (self.dc) |dc| _ = ReleaseDC(hwnd, dc);
            _ = DestroyWindow(hwnd);
        }
        if (self.font) |f| _ = DeleteObject(f);
    }

    pub fn show(self: *Window) void {
        if (self.hwnd) |hwnd| {
            _ = ShowWindow(hwnd, SW_SHOW);
            _ = SetForegroundWindow(hwnd);
            self.visible = true;
        }
    }

    pub fn hide(self: *Window) void {
        if (self.hwnd) |hwnd| {
            _ = ShowWindow(hwnd, SW_HIDE);
            self.visible = false;
        }
    }

    pub fn toggle(self: *Window) void {
        if (self.visible) self.hide() else self.show();
    }

    pub fn setPosition(self: *Window, dock: DockPosition, width_pct: u8, height_pct: u8, offset_pct: u8) void {
        var cursor_pos: POINT = .{ .x = 0, .y = 0 };
        _ = GetCursorPos(&cursor_pos);

        const monitor = MonitorFromPoint(cursor_pos, MONITOR_DEFAULTTOPRIMARY);
        var mi: MONITORINFO = undefined;
        mi.cbSize = @sizeOf(MONITORINFO);
        _ = GetMonitorInfoW(monitor, &mi);

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

        _ = SetWindowPos(self.hwnd, HWND_TOPMOST, x, y, w, h, 0);
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
                    if (self.render_fn) |render_fn| {
                        render_fn(self);
                    }
                    self.skip_swap = false;
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
            WM_CHAR => {
                // Let app handle first (e.g. tab rename mode)
                if (self.app_msg_fn) |f| {
                    if (f(msg, wParam, lParam, self.userdata)) return 0;
                }
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
                // Let app handle first (e.g. tab rename mode)
                if (self.app_msg_fn) |f| {
                    if (f(msg, wParam, lParam, self.userdata)) return 0;
                }
                // Ctrl+Shift shortcuts
                if (GetKeyState(VK_CONTROL) < 0 and GetKeyState(VK_SHIFT) < 0) {
                    // Ctrl+Shift+T: new tab
                    if (wParam == 0x54) {
                        if (self.app_msg_fn) |f| {
                            _ = f(WM_KEYDOWN, wParam, lParam, self.userdata);
                        }
                        return 0;
                    }
                    // Ctrl+Shift+W: close active tab
                    if (wParam == 0x57) {
                        if (self.app_msg_fn) |f| {
                            _ = f(WM_KEYDOWN, wParam, lParam, self.userdata);
                        }
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
                        if (self.app_msg_fn) |f| {
                            _ = f(WM_KEYDOWN, wParam, lParam, self.userdata);
                        }
                        return 0;
                    }
                }

                const vk_prior: WPARAM = 0x21; // Page Up
                const vk_next: WPARAM = 0x22; // Page Down

                // Shift+PageUp/Down: scroll viewport
                if (GetKeyState(VK_SHIFT) < 0 and (wParam == vk_prior or wParam == vk_next)) {
                    if (self.app_msg_fn) |f| {
                        _ = f(WM_MOUSEWHEEL, wParam, 0, self.userdata);
                    }
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
                if (self.resize_fn) |resize_fn| {
                    const grid = self.getGridSize();
                    resize_fn(grid.cols, grid.rows, self.userdata);
                }
                return 0;
            },
            WM_CLOSE => {
                // Shell already exited — close without prompt
                if (self.shell_exited) {
                    _ = DestroyWindow(hwnd);
                    return 0;
                }
                // User-initiated close (Alt+F4) — confirm
                const msg_text = std.unicode.utf8ToUtf16LeStringLiteral("Are you sure you want to quit TildaZ?");
                const msg_title = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ");
                const result = MessageBoxW(hwnd, msg_text, msg_title, MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2);
                if (result == IDYES) {
                    _ = DestroyWindow(hwnd);
                }
                return 0;
            },
            WM_DESTROY => {
                PostQuitMessage(0);
                return 0;
            },
            WM_SYSKEYDOWN => {
                // Alt+1 through Alt+9: switch tabs
                if (wParam >= 0x31 and wParam <= 0x39) {
                    if (self.app_msg_fn) |f| {
                        _ = f(msg, wParam, lParam, self.userdata);
                    }
                    return 0;
                }
                return DefWindowProcW(hwnd, msg, wParam, lParam);
            },
            WM_LBUTTONDOWN => {
                if (self.app_msg_fn) |f| {
                    _ = f(msg, wParam, lParam, self.userdata);
                }
                _ = SetCapture(hwnd);
                return 0;
            },
            WM_LBUTTONDBLCLK => {
                if (self.app_msg_fn) |f| {
                    _ = f(msg, wParam, lParam, self.userdata);
                }
                return 0;
            },
            WM_MOUSEMOVE => {
                if (self.app_msg_fn) |f| {
                    _ = f(msg, wParam, lParam, self.userdata);
                }
                return 0;
            },
            WM_LBUTTONUP => {
                if (self.app_msg_fn) |f| {
                    _ = f(msg, wParam, lParam, self.userdata);
                }
                _ = ReleaseCapture();
                return 0;
            },
            WM_MOUSEWHEEL => {
                if (self.app_msg_fn) |f| {
                    _ = f(msg, wParam, lParam, self.userdata);
                }
                return 0;
            },
            WM_MBUTTONDOWN => {
                if (self.write_fn) |write_fn| {
                    self.pasteClipboard(write_fn);
                }
                return 0;
            },
            WM_TAB_CLOSED => {
                if (self.app_msg_fn) |f| {
                    _ = f(msg, wParam, lParam, self.userdata);
                }
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
        const raw_lock = GlobalLock(hmem) orelse return;
        const ptr: [*]u8 = @ptrCast(raw_lock);

        // Write UTF-16 data
        var wide_ptr: [*]u16 = @ptrCast(@alignCast(ptr));
        var view2 = std.unicode.Utf8View.init(text) catch return;
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

    pub const DockPosition = enum { top, bottom, left, right };
};
