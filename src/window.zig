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
const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };
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
extern "kernel32" fn GlobalLock(?*anyopaque) callconv(.c) ?[*]const WCHAR;
extern "kernel32" fn GlobalUnlock(?*anyopaque) callconv(.c) BOOL;
extern "user32" fn OpenClipboard(HWND) callconv(.c) BOOL;
extern "user32" fn CloseClipboard() callconv(.c) BOOL;
extern "user32" fn GetClipboardData(UINT) callconv(.c) ?*anyopaque;
extern "user32" fn GetKeyState(c_int) callconv(.c) i16;
extern "user32" fn MessageBoxW(HWND, [*:0]const WCHAR, [*:0]const WCHAR, UINT) callconv(.c) c_int;

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
    render_fn: ?*const fn (*Window, HDC) void = null,
    resize_fn: ?*const fn (u16, u16, ?*anyopaque) void = null,
    userdata: ?*anyopaque = null,
    write_fn: ?*const fn ([]const u8, ?*anyopaque) void = null,
    shell_exited: bool = false,

    const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("TildaZWindow");
    const HOTKEY_ID: c_int = 1;
    const VK_F1: UINT = 0x70;
    const RENDER_TIMER_ID: usize = 1;

    pub fn init(self: *Window) !void {
        const hInstance = GetModuleHandleW(null);

        const wc = WNDCLASSEXW{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
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

        // Set transparency (90% opaque)
        _ = SetLayeredWindowAttributes(self.hwnd, 0, 230, LWA_ALPHA);

        // Register F1 global hotkey
        if (RegisterHotKey(self.hwnd, HOTKEY_ID, 0, VK_F1) == 0) {
            OutputDebugStringA("WARNING: Failed to register F1 hotkey\n");
        }

        // Create monospace font
        self.font = CreateFontW(
            16,
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
            std.unicode.utf8ToUtf16LeStringLiteral("Consolas"),
        );

        // Measure cell metrics from font
        const hdc = GetDC(self.hwnd);
        if (hdc != null) {
            const old_f = SelectObject(hdc, self.font);
            var tm: TEXTMETRICW = undefined;
            _ = GetTextMetricsW(hdc, &tm);
            self.cell_width = tm.tmAveCharWidth;
            self.cell_height = tm.tmHeight;
            _ = SelectObject(hdc, old_f);
            _ = ReleaseDC(self.hwnd, hdc);
        }

        // Start render timer (60fps)
        _ = SetTimer(self.hwnd, RENDER_TIMER_ID, 16, null);
    }

    pub fn deinit(self: *Window) void {
        if (self.hwnd) |hwnd| {
            _ = KillTimer(hwnd, RENDER_TIMER_ID);
            _ = UnregisterHotKey(hwnd, HOTKEY_ID);
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
                    _ = InvalidateRect(hwnd, null, 0);
                }
                return 0;
            },
            WM_PAINT => {
                self.paint();
                return 0;
            },
            WM_CHAR => {
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
                // Ctrl+Shift+V: paste from clipboard
                if (wParam == 0x56) { // VK_V
                    if (GetKeyState(VK_CONTROL) < 0 and GetKeyState(VK_SHIFT) < 0) {
                        if (self.write_fn) |write_fn| {
                            self.pasteClipboard(write_fn);
                        }
                        return 0;
                    }
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
                    const vk_prior: WPARAM = 0x21; // Page Up
                    const vk_next: WPARAM = 0x22; // Page Down

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
            else => {},
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    fn getSelf(hwnd: HWND) ?*Window {
        const ptr = GetWindowLongPtrW(hwnd, GWL_USERDATA);
        if (ptr == 0) return null;
        return @ptrFromInt(@as(usize, @intCast(ptr)));
    }

    fn paint(self: *Window) void {
        var ps: PAINTSTRUCT = undefined;
        const hdc = BeginPaint(self.hwnd, &ps);
        defer _ = EndPaint(self.hwnd, &ps);

        if (hdc == null) return;

        var client_rect: RECT = undefined;
        _ = GetClientRect(self.hwnd, &client_rect);
        const w = client_rect.right - client_rect.left;
        const h = client_rect.bottom - client_rect.top;

        // Double buffering: create off-screen DC
        const mem_dc = CreateCompatibleDC(hdc);
        if (mem_dc == null) return;
        defer _ = DeleteDC(mem_dc);

        const mem_bmp = CreateCompatibleBitmap(hdc, w, h);
        if (mem_bmp == null) return;
        const old_bmp = SelectObject(mem_dc, mem_bmp);
        defer {
            _ = SelectObject(mem_dc, old_bmp);
            _ = DeleteObject(mem_bmp);
        }

        // Draw everything to memory DC
        const bg_brush = CreateSolidBrush(rgb(30, 30, 30));
        _ = FillRect(mem_dc, &client_rect, bg_brush);
        _ = DeleteObject(bg_brush);

        const old_font = SelectObject(mem_dc, self.font);
        defer _ = SelectObject(mem_dc, old_font);

        // Get font metrics for cell size
        var tm: TEXTMETRICW = undefined;
        _ = GetTextMetricsW(mem_dc, &tm);
        self.cell_width = tm.tmAveCharWidth;
        self.cell_height = tm.tmHeight;

        _ = SetBkMode(mem_dc, TRANSPARENT);
        _ = SetTextColor(mem_dc, rgb(204, 204, 204));

        // Render terminal content to memory DC
        if (self.render_fn) |render_fn| {
            render_fn(self, mem_dc);
        }

        // Copy to screen in one operation
        _ = BitBlt(hdc, 0, 0, w, h, mem_dc, 0, 0, SRCCOPY);
    }

    fn pasteClipboard(self: *Window, write_fn: *const fn ([]const u8, ?*anyopaque) void) void {
        if (OpenClipboard(self.hwnd) == 0) return;
        defer _ = CloseClipboard();

        const handle = GetClipboardData(CF_UNICODETEXT) orelse return;
        const wide_ptr = GlobalLock(handle) orelse return;
        defer _ = GlobalUnlock(handle);

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
