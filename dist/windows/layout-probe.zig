//! Windows keyboard layout 실측 프로브 ([#496](https://github.com/ensky0/tildaz/issues/496) 항목 ①·②·③).
//!
//! **Windows 전용이다.** macOS 는 [`dist/macos/layout-probe.m`](../macos/layout-probe.m) 이
//! 같은 일을 한다 — 출력 형식을 그쪽과 맞춰 두어 두 platform 결과를 한 표로 합칠 수 있다.
//!
//! 왜 필요한가: 단축키를 **라벨**로 매칭할지 **위치**로 매칭할지 (#496 항목 2) 의 Windows
//! 쪽 근거가 [kbdlayout.info](http://kbdlayout.info/KBDRU/virtualkeys) 문서뿐이고 실기 확인이
//! 없었다. 이 도구가 그것을 채운다.
//!
//! **layout 을 전환하지 않고 여러 개를 한 번에 잰다.** `LoadKeyboardLayoutW` 로 얻은 `hkl` 을
//! `MapVirtualKeyExW` / `ToUnicodeEx` / `VkKeyScanExW` 에 넘기면 된다 (macOS 보다 유리한
//! 점이다 — 그쪽은 입력 소스를 실제로 바꿔야 했다). 단 그 값이 *실제 활성 layout* 과 같은지는
//! `--watch` 로 한 번 대조해야 한다.
//!
//! 빌드 / 실행 (본체 빌드에는 들어가지 않는다):
//! ```powershell
//! zig build-exe dist/windows/layout-probe.zig -O ReleaseSafe --cache-dir C:/ziglang/tildaz-cache
//! .\layout-probe.exe                      # 전체 표 + 판정 + 경계값. 덤프 파일도 쓴다
//! .\layout-probe.exe --out C:\tmp\a.txt   # 덤프 경로 지정
//! .\layout-probe.exe --dirty-state        # ToUnicodeEx 의 dead key 오염 방지 flag 를 빼고 다시
//! .\layout-probe.exe --watch 60           # 창을 띄우고 60 초 — 그 사이 입력 언어를 바꾼다
//! ```
//!
//! `--watch` 가 재는 것 (macOS 세션에서 걸린 함정의 Windows 판):
//!   - **한 프로세스를 살려 둔 채** 입력 언어를 바꿔야 "값이 시작 시점에 고정되는가" 가
//!     드러난다. 단발 실행은 매 회가 새 프로세스라 항상 최신으로 보인다.
//!   - `WM_INPUTLANGCHANGE` 가 실제로 오는지, 그때 `GetKeyboardLayout` 이 바뀌는지.
//!   - 로드해 둔 `hkl` 로 잰 값과 *활성* layout 이 내는 값이 같은지.
//!   - 실제 키를 누르면 `WM_KEYDOWN` 의 vk / scancode 가 무엇으로 오는지.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("layout-probe 는 Windows 전용이다. macOS 는 dist/macos/layout-probe.m 를 쓴다.");
    }
}

// --- Win32 타입 · 선언 (src/window.zig 과 같은 스타일 — SDK 헤더를 쓰지 않는다) ---

const WCHAR = u16;
const BOOL = i32;
const UINT = u32;
const DWORD = u32;
const HKL = ?*anyopaque;
const HWND = ?*anyopaque;
const HANDLE = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const HMENU = ?*anyopaque;
const ATOM = u16;
const LPVOID = ?*anyopaque;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;

const POINT = extern struct { x: i32, y: i32 };

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
    lpfnWndProc: ?*const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?[*:0]const WCHAR,
    lpszClassName: ?[*:0]const WCHAR,
    hIconSm: HICON,
};

extern "user32" fn LoadKeyboardLayoutW([*:0]const WCHAR, UINT) callconv(.c) HKL;
extern "user32" fn UnloadKeyboardLayout(HKL) callconv(.c) BOOL;
extern "user32" fn MapVirtualKeyExW(UINT, UINT, HKL) callconv(.c) UINT;
extern "user32" fn ToUnicodeEx(UINT, UINT, [*]const u8, [*]WCHAR, i32, UINT, HKL) callconv(.c) i32;
extern "user32" fn VkKeyScanExW(WCHAR, HKL) callconv(.c) i16;
extern "user32" fn GetKeyboardLayout(DWORD) callconv(.c) HKL;
extern "user32" fn GetKeyboardLayoutList(i32, ?[*]HKL) callconv(.c) i32;
extern "user32" fn GetKeyboardLayoutNameW([*]WCHAR) callconv(.c) BOOL;
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.c) ATOM;
extern "user32" fn CreateWindowExW(DWORD, [*:0]const WCHAR, [*:0]const WCHAR, DWORD, i32, i32, i32, i32, HWND, HMENU, HINSTANCE, LPVOID) callconv(.c) HWND;
extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT;
extern "user32" fn GetMessageW(*MSG, HWND, UINT, UINT) callconv(.c) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.c) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.c) LRESULT;
extern "user32" fn PostQuitMessage(i32) callconv(.c) void;
extern "user32" fn DestroyWindow(HWND) callconv(.c) BOOL;
extern "user32" fn SetTimer(HWND, usize, UINT, ?*anyopaque) callconv(.c) usize;
extern "user32" fn SetWindowTextW(HWND, [*:0]const WCHAR) callconv(.c) BOOL;
extern "user32" fn GetForegroundWindow() callconv(.c) HWND;
extern "user32" fn GetWindowThreadProcessId(HWND, ?*DWORD) callconv(.c) DWORD;
extern "user32" fn SetForegroundWindow(HWND) callconv(.c) BOOL;
extern "user32" fn LoadCursorW(HINSTANCE, usize) callconv(.c) HCURSOR;

extern "kernel32" fn GetStdHandle(DWORD) callconv(.c) HANDLE;
extern "kernel32" fn WriteFile(HANDLE, [*]const u8, DWORD, *DWORD, ?*anyopaque) callconv(.c) BOOL;
extern "kernel32" fn CreateFileW([*:0]const WCHAR, DWORD, DWORD, ?*anyopaque, DWORD, DWORD, HANDLE) callconv(.c) HANDLE;
extern "kernel32" fn CloseHandle(HANDLE) callconv(.c) BOOL;
extern "kernel32" fn GetModuleHandleW(?[*:0]const WCHAR) callconv(.c) HINSTANCE;
extern "kernel32" fn GetTickCount64() callconv(.c) u64;
extern "kernel32" fn GetCurrentThreadId() callconv(.c) DWORD;
extern "kernel32" fn GetLastError() callconv(.c) DWORD;

const MAPVK_VK_TO_VSC: UINT = 0;
const MAPVK_VSC_TO_VK: UINT = 1;
const MAPVK_VK_TO_CHAR: UINT = 2;
const MAPVK_VSC_TO_VK_EX: UINT = 3;
const MAPVK_VK_TO_VSC_EX: UINT = 4;

const VK_SHIFT: usize = 0x10;
const VK_CONTROL: usize = 0x11;
const VK_MENU: usize = 0x12;

/// `ToUnicodeEx` 의 `wFlags` bit 2 — *"do not change the kernel keyboard state"*
/// (Windows 10 1607+). 없으면 dead key 를 번역한 뒤 그 상태가 커널에 남아 **다음 호출을
/// 오염**시킨다. macOS 경로 C (`CGEventKeyboardGetUnicodeString`) 의 오염과 같은 병이고,
/// 섹션 [E4] 가 실제로 그 차이를 잰다 — 문서 서술을 믿지 않고.
const TU_NO_KERNEL_STATE: UINT = 0x4;

const WM_DESTROY: UINT = 0x0002;
const WM_CLOSE: UINT = 0x0010;
const WM_INPUTLANGCHANGEREQUEST: UINT = 0x0050;
const WM_INPUTLANGCHANGE: UINT = 0x0051;
const WM_KEYDOWN: UINT = 0x0100;
const WM_CHAR: UINT = 0x0102;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_SYSCHAR: UINT = 0x0106;
const WM_TIMER: UINT = 0x0113;

fn W(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

fn hklInt(h: HKL) usize {
    return @intFromPtr(h);
}

/// HKL 의 하위 16 비트가 KLID (언어 식별자). 상위는 layout 핸들이다.
fn klidOf(h: HKL) usize {
    return hklInt(h) & 0xFFFF;
}

// --- 출력 — stdout 과 덤프 파일에 동시에 쓴다 ---
//
// 판정에 쓰는 표를 "화면으로만" 보지 않는다 (macOS 세션 함정 ③). 콘솔 스크롤백은
// 사후에 인용할 수 없고, 비라틴 글리프는 콘솔 폰트가 못 그리는 경우가 많다.

var out_alloc: std.mem.Allocator = undefined;
var dump: std.ArrayList(u8) = .empty;

fn writeHandle(h: HANDLE, bytes: []const u8) void {
    var written: DWORD = 0;
    var off: usize = 0;
    while (off < bytes.len) {
        const chunk: DWORD = @intCast(@min(bytes.len - off, 32768));
        if (WriteFile(h, bytes.ptr + off, chunk, &written, null) == 0) return;
        if (written == 0) return;
        off += written;
    }
}

fn p(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(out_alloc, fmt, args) catch return;
    dump.appendSlice(out_alloc, s) catch {};
    // STD_OUTPUT_HANDLE = -11
    writeHandle(GetStdHandle(@bitCast(@as(i32, -11))), s);
}

// --- layout 목록 ---

const LayoutSpec = struct {
    klid: [:0]const u16,
    klid_utf8: []const u8,
    name: []const u8,
    dll: []const u8,
};

/// 이 기기의 레지스트리 (`HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts`) 에서
/// 확인한 KLID 다. Windows 11 이 French 를 **표준 / 레거시로 쪼갰다** — 둘 다 잰다.
const layout_specs = [_]LayoutSpec{
    .{ .klid = W("00000409"), .klid_utf8 = "00000409", .name = "US QWERTY", .dll = "KBDUS.DLL" },
    .{ .klid = W("0000040c"), .klid_utf8 = "0000040c", .name = "FR legacy AZERTY", .dll = "KBDFR.DLL" },
    .{ .klid = W("0001040c"), .klid_utf8 = "0001040c", .name = "FR standard AZERTY", .dll = "KBDFRNA.DLL" },
    .{ .klid = W("00000419"), .klid_utf8 = "00000419", .name = "Russian", .dll = "KBDRU.DLL" },
    .{ .klid = W("00000412"), .klid_utf8 = "00000412", .name = "Korean", .dll = "KBDKOR.DLL" },
    .{ .klid = W("00000411"), .klid_utf8 = "00000411", .name = "Japanese", .dll = "KBDJPN.DLL" },
    .{ .klid = W("00000407"), .klid_utf8 = "00000407", .name = "German QWERTZ", .dll = "KBDGR.DLL" },
    .{ .klid = W("00010409"), .klid_utf8 = "00010409", .name = "US Dvorak", .dll = "KBDDV.DLL" },
};

var loaded: [layout_specs.len]HKL = @splat(null);

// --- 번역 ---

const Label = struct {
    /// `ToUnicodeEx` 반환값 그대로. -1 = dead key, 0 = 번역 없음, n = 글자 수.
    rc: i32,
    len: usize,
    chars: [8]u16,

    fn fmtTo(self: Label, buf: []u8) []const u8 {
        if (self.rc == 0) return "-";
        var utf8: [32]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&utf8, self.chars[0..self.len]) catch 0;
        const tag = if (self.rc < 0) "dead" else "";
        // 글자와 코드포인트를 함께 적는다 — 콘솔이 글리프를 못 그려도 표를 읽을 수 있어야 한다.
        if (self.len == 1) {
            return std.fmt.bufPrint(buf, "{s}'{s}' U+{X:0>4}", .{ tag, utf8[0..n], self.chars[0] }) catch "?";
        }
        return std.fmt.bufPrint(buf, "{s}\"{s}\" ({d}자)", .{ tag, utf8[0..n], self.len }) catch "?";
    }
};

fn translate(vk: UINT, sc: UINT, hkl: HKL, shift: bool, altgr: bool, flags: UINT) Label {
    var state: [256]u8 = @splat(0);
    if (shift) state[VK_SHIFT] = 0x80;
    if (altgr) {
        state[VK_CONTROL] = 0x80;
        state[VK_MENU] = 0x80;
    }
    var buf: [8]u16 = @splat(0);
    const rc = ToUnicodeEx(vk, sc, &state, &buf, buf.len, flags, hkl);
    const len: usize = if (rc > 0) @intCast(@min(rc, 8)) else if (rc < 0) 1 else 0;
    return .{ .rc = rc, .len = len, .chars = buf };
}

/// dead key 를 번역한 뒤 커널에 남을 수 있는 상태를 비운다. `TU_NO_KERNEL_STATE` 를 쓰면
/// 필요 없지만, 그 flag 가 실제로 듣는지 재는 [E4] 에서는 필요하다.
fn flushDeadKey(hkl: HKL) void {
    var state: [256]u8 = @splat(0);
    var buf: [8]u16 = @splat(0);
    _ = ToUnicodeEx(0x20, 0x39, &state, &buf, buf.len, 0, hkl);
    _ = ToUnicodeEx(0x20, 0x39, &state, &buf, buf.len, 0, hkl);
}

const digit_names = blk: {
    var t: [10][4:0]u8 = undefined;
    for (0..10) |i| t[i] = [4:0]u8{ 'V', 'K', '_', '0' + @as(u8, @intCast(i)) };
    break :blk t;
};

const letter_names = blk: {
    var t: [26][4:0]u8 = undefined;
    for (0..26) |i| t[i] = [4:0]u8{ 'V', 'K', '_', 'A' + @as(u8, @intCast(i)) };
    break :blk t;
};

fn vkName(vk: UINT) []const u8 {
    return switch (vk) {
        0x00 => "-",
        0x08 => "VK_BACK",
        0x09 => "VK_TAB",
        0x0D => "VK_RETURN",
        0x10 => "VK_SHIFT",
        0x11 => "VK_CONTROL",
        0x12 => "VK_MENU",
        0x13 => "VK_PAUSE",
        0x14 => "VK_CAPITAL",
        0x1B => "VK_ESCAPE",
        0x20 => "VK_SPACE",
        0x21 => "VK_PRIOR",
        0x22 => "VK_NEXT",
        0x23 => "VK_END",
        0x24 => "VK_HOME",
        0x2C => "VK_SNAPSHOT",
        0x2D => "VK_INSERT",
        0x2E => "VK_DELETE",
        0x30...0x39 => &digit_names[vk - 0x30],
        0x41...0x5A => &letter_names[vk - 0x41],
        0x5B => "VK_LWIN",
        0x5C => "VK_RWIN",
        0x60...0x69 => "VK_NUMPADn",
        0x6A => "VK_MULTIPLY",
        0x6B => "VK_ADD",
        0x6D => "VK_SUBTRACT",
        0x6E => "VK_DECIMAL",
        0x6F => "VK_DIVIDE",
        0x70...0x87 => "VK_Fn",
        0x90 => "VK_NUMLOCK",
        0x91 => "VK_SCROLL",
        0xA0 => "VK_LSHIFT",
        0xA1 => "VK_RSHIFT",
        0xA2 => "VK_LCONTROL",
        0xA3 => "VK_RCONTROL",
        0xA4 => "VK_LMENU",
        0xA5 => "VK_RMENU",
        0xBA => "VK_OEM_1",
        0xBB => "VK_OEM_PLUS",
        0xBC => "VK_OEM_COMMA",
        0xBD => "VK_OEM_MINUS",
        0xBE => "VK_OEM_PERIOD",
        0xBF => "VK_OEM_2",
        0xC0 => "VK_OEM_3",
        0xDB => "VK_OEM_4",
        0xDC => "VK_OEM_5",
        0xDD => "VK_OEM_6",
        0xDE => "VK_OEM_7",
        0xDF => "VK_OEM_8",
        0xE2 => "VK_OEM_102",
        0xE5 => "VK_PROCESSKEY",
        0xF0 => "VK_OEM_ATTN",
        else => "?",
    };
}

/// US 자판에서 그 scancode 자리에 무엇이 **인쇄**돼 있는가. 물리 키보드는 layout 을 바꿔도
/// QWERTY 각인 그대로이므로, 사용자에게 안내할 때 기준이 되는 것은 이 이름이다.
const us_caps = [_][]const u8{
    "",     "Esc",   "1",      "2",    "3",     "4",     "5",      "6",
    "7",    "8",     "9",      "0",    "-",     "=",     "BkSp",   "Tab",
    "Q",    "W",     "E",      "R",    "T",     "Y",     "U",      "I",
    "O",    "P",     "[",      "]",    "Enter", "Ctrl",  "A",      "S",
    "D",    "F",     "G",      "H",    "J",     "K",     "L",      ";",
    "'",    "`",     "LShift", "\\",   "Z",     "X",     "C",      "V",
    "B",    "N",     "M",      ",",    ".",     "/",     "RShift", "Num*",
    "Alt",  "Space", "Caps",   "F1",   "F2",    "F3",    "F4",     "F5",
    "F6",   "F7",    "F8",     "F9",   "F10",   "NumLk", "ScrLk",  "Num7",
    "Num8", "Num9",  "Num-",   "Num4", "Num5",  "Num6",  "Num+",   "Num1",
    "Num2", "Num3",  "Num0",   "Num.", "",      "",      "ISO\\",  "F11",
    "F12",
};

fn usCap(sc: UINT) []const u8 {
    return if (sc < us_caps.len) us_caps[sc] else "";
}

// --- 섹션 ---

fn sectionHeader() void {
    p("== Windows keyboard layout probe (#496) ==\n\n", .{});

    var klid_buf: [16]WCHAR = @splat(0);
    var klid_utf8: [16]u8 = undefined;
    var n: usize = 0;
    if (GetKeyboardLayoutNameW(&klid_buf) != 0) {
        var len: usize = 0;
        while (len < klid_buf.len and klid_buf[len] != 0) len += 1;
        n = std.unicode.utf16LeToUtf8(&klid_utf8, klid_buf[0..len]) catch 0;
    }
    const cur = GetKeyboardLayout(0);
    p("현재 스레드 활성 layout : HKL 0x{X:0>8}  GetKeyboardLayoutNameW=\"{s}\"\n", .{ hklInt(cur), klid_utf8[0..n] });

    var list: [32]HKL = @splat(null);
    const cnt = GetKeyboardLayoutList(list.len, &list);
    p("GetKeyboardLayoutList   : {d} 개 —", .{cnt});
    var i: usize = 0;
    while (i < @as(usize, @intCast(@max(cnt, 0)))) : (i += 1) p(" 0x{X:0>8}", .{hklInt(list[i])});
    p("\n\n", .{});
}

fn snapshotList(buf: *[32]HKL) usize {
    return @intCast(@max(GetKeyboardLayoutList(buf.len, buf), 0));
}

/// 로드 **전**에 이미 세션에 있던 layout. 정리할 때 이 목록에 없는 것만 되돌린다 —
/// 사용자가 실제로 설치한 layout 을 우리가 내려 버리면 안 된다.
var preexisting: [32]HKL = @splat(null);
var preexisting_n: usize = 0;

fn wasPreexisting(h: HKL) bool {
    for (preexisting[0..preexisting_n]) |x| {
        if (hklInt(x) == hklInt(h)) return true;
    }
    return false;
}

/// 이전 실행이 세션에 남긴 layout 을 치운다 (`--unload-session`). 기본 정리는 *이번
/// 프로세스가* 올린 것만 건드리는데, 그 규칙은 앞선 실행이 남긴 것을 "원래 있던 것" 으로
/// 보게 된다. 이 모드는 그 잔재를 강제로 내린다.
///
/// **사용자가 실제로 설치한 layout 도 내려간다** — 그런 상태라면 쓰지 않는다.
fn unloadSession() void {
    const cur = GetKeyboardLayout(0);
    p("[H] --unload-session — 앞선 실행이 세션에 남긴 layout 을 강제로 내린다\n\n", .{});
    for (layout_specs) |spec| {
        const hkl = LoadKeyboardLayoutW(spec.klid.ptr, 0);
        if (hkl == null) continue;
        if (klidOf(hkl) == klidOf(cur)) {
            p("    {s:<22} 0x{X:0>8}  건너뜀 — 지금 활성 layout 이다\n", .{ spec.name, hklInt(hkl) });
            continue;
        }
        // 한 번 더 올렸으니 참조가 늘었을 수 있다 — 목록에서 사라질 때까지 내린다.
        var tries: usize = 0;
        var gone = false;
        while (tries < 8) : (tries += 1) {
            if (UnloadKeyboardLayout(hkl) == 0) break;
            var list: [32]HKL = @splat(null);
            const n = snapshotList(&list);
            gone = true;
            for (list[0..n]) |x| {
                if (hklInt(x) == hklInt(hkl)) gone = false;
            }
            if (gone) break;
        }
        p("    {s:<22} 0x{X:0>8}  {s} ({d} 회)\n", .{ spec.name, hklInt(hkl), if (gone) "내림" else "남음", tries + 1 });
    }
    var after: [32]HKL = @splat(null);
    const n = snapshotList(&after);
    p("\n    정리 후 GetKeyboardLayoutList: {d} 개 —", .{n});
    var i: usize = 0;
    while (i < n) : (i += 1) p(" 0x{X:0>8}", .{hklInt(after[i])});
    p("\n\n", .{});
}

/// **측정이 기기 상태를 바꾼 채로 끝나지 않게 한다.** `LoadKeyboardLayoutW` 로 올린
/// layout 은 프로세스가 죽어도 **세션에 남는다** (실측: 다음 실행의
/// `GetKeyboardLayoutList` 가 8 개를 냈다). 사용자 언어 목록
/// (`Get-WinUserLanguageList`) 에는 안 보이지만 남아 있는 것은 사실이라 되돌린다.
fn unloadLoaded() void {
    p("[H] 정리 — 우리가 올린 layout 을 내린다 (세션에 남기지 않는다)\n\n", .{});
    for (layout_specs, 0..) |spec, i| {
        const hkl = loaded[i] orelse continue;
        if (wasPreexisting(hkl)) {
            p("    {s:<22} 0x{X:0>8}  건너뜀 — 우리가 올린 게 아니다\n", .{ spec.name, hklInt(hkl) });
            continue;
        }
        const ok = UnloadKeyboardLayout(hkl) != 0;
        // 내린 핸들을 계속 들고 있으면 뒤 섹션이 죽은 hkl 을 API 에 넘긴다.
        if (ok) loaded[i] = null;
        p("    {s:<22} 0x{X:0>8}  {s}\n", .{ spec.name, hklInt(hkl), if (ok) "내림" else "실패 (활성 layout 이면 정상)" });
    }
    var after: [32]HKL = @splat(null);
    const n = snapshotList(&after);
    p("\n    정리 후 GetKeyboardLayoutList: {d} 개 —", .{n});
    var i: usize = 0;
    while (i < n) : (i += 1) p(" 0x{X:0>8}", .{hklInt(after[i])});
    p("   (로드 전 {d} 개)\n\n", .{preexisting_n});
}

fn sectionLoad() void {
    p("[A] layout 로드 — 전환 없이 hkl 만 얻는다 (`LoadKeyboardLayoutW`, flags=0)\n\n", .{});
    preexisting_n = snapshotList(&preexisting);
    const before_n = preexisting_n;

    p("  {s:<22} {s:<10} {s:<12} {s}\n", .{ "이름", "KLID", "HKL", "DLL" });
    for (layout_specs, 0..) |spec, i| {
        const hkl = LoadKeyboardLayoutW(spec.klid.ptr, 0);
        loaded[i] = hkl;
        if (hkl == null) {
            p("  {s:<22} {s:<10} {s:<12} {s}  <- 로드 실패 (GetLastError={d})\n", .{ spec.name, spec.klid_utf8, "실패", spec.dll, GetLastError() });
        } else {
            p("  {s:<22} {s:<10} 0x{X:0>8}   {s}\n", .{ spec.name, spec.klid_utf8, hklInt(hkl), spec.dll });
        }
    }

    var after: [32]HKL = @splat(null);
    const after_n = snapshotList(&after);
    p("\n  부작용 확인 — GetKeyboardLayoutList: 로드 전 {d} 개 -> 로드 후 {d} 개", .{ before_n, after_n });
    if (before_n == after_n) {
        p("  (변화 없음)\n", .{});
    } else {
        p("  <- **늘었다.** 사용자 입력 언어 목록이 바뀌었는지 확인이 필요하다\n", .{});
        p("  로드 후 목록:", .{});
        var i: usize = 0;
        while (i < after_n) : (i += 1) p(" 0x{X:0>8}", .{hklInt(after[i])});
        p("\n", .{});
    }
    p("\n", .{});
}

fn sectionTables(flags: UINT) void {
    p("[C] scancode 0x01..0x58 표 — layout 별\n", .{});
    p("    VK       = MapVirtualKeyExW(sc, MAPVK_VSC_TO_VK_EX, hkl)\n", .{});
    p("    base/shift/altgr = ToUnicodeEx(vk, sc, state, .., hkl)   (wFlags=0x{X})\n", .{flags});
    p("    역방향    = VkKeyScanExW(base 글자, hkl) — low byte 가 VK, high byte 가 shift 상태\n", .{});
    p("               '=' 는 그 VK 가 MapVirtualKeyExW 의 답과 같다는 뜻 (왕복 일치)\n\n", .{});

    for (layout_specs, 0..) |spec, li| {
        const hkl = loaded[li] orelse continue;
        p("--- {s} (KLID {s}, HKL 0x{X:0>8}) ---\n", .{ spec.name, spec.klid_utf8, hklInt(hkl) });
        p("  SC  US각인  VK    VK이름         base                shift               altgr               역방향(base)\n", .{});
        var sc: UINT = 0x01;
        while (sc <= 0x58) : (sc += 1) {
            const vk = MapVirtualKeyExW(sc, MAPVK_VSC_TO_VK_EX, hkl);
            const base = translate(vk, sc, hkl, false, false, flags);
            const shift = translate(vk, sc, hkl, true, false, flags);
            const altgr = translate(vk, sc, hkl, false, true, flags);
            var b1: [48]u8 = undefined;
            var b2: [48]u8 = undefined;
            var b3: [48]u8 = undefined;
            var rev: [48]u8 = undefined;
            const rev_s = if (base.rc > 0 and base.len == 1) blk: {
                const r = VkKeyScanExW(base.chars[0], hkl);
                if (r == -1) break :blk "없음(-1)";
                const bits: u16 = @bitCast(r);
                const rv: UINT = bits & 0xFF;
                const sh: u16 = (bits >> 8) & 0xFF;
                const mark = if (rv == vk) "=" else "!=";
                break :blk std.fmt.bufPrint(&rev, "vk=0x{X:0>2} sh={d} {s}", .{ rv, sh, mark }) catch "?";
            } else "-";
            p("  {X:0>2}  {s:<6} 0x{X:0>2}  {s:<13} {s:<19} {s:<19} {s:<19} {s}\n", .{
                sc, usCap(sc), vk, vkName(vk), base.fmtTo(&b1), shift.fmtTo(&b2), altgr.fmtTo(&b3), rev_s,
            });
        }
        p("\n", .{});
    }
}

fn vkAt(li: usize, sc: UINT) UINT {
    const hkl = loaded[li] orelse return 0;
    return MapVirtualKeyExW(sc, MAPVK_VSC_TO_VK_EX, hkl);
}

fn sectionVerdicts(flags: UINT) void {
    p("[D] 판정\n\n", .{});

    p("  판정 1 — 라틴 layout 에서 VK 가 **라벨**을 따라가는가\n", .{});
    p("    이슈 본문 서술: \"AZERTY 에서 US A 자리(sc 0x1E) 가 VK_Q 로 나온다\"\n\n", .{});
    p("    {s:<22} {s:<28} {s:<28} {s}\n", .{ "layout", "sc 0x1E (US각인 A)", "sc 0x11 (US각인 W)", "sc 0x2C (US각인 Z)" });
    for (layout_specs, 0..) |spec, li| {
        const hkl = loaded[li] orelse continue;
        var cell: [3][64]u8 = undefined;
        var cells: [3][]const u8 = undefined;
        const scs = [_]UINT{ 0x1E, 0x11, 0x2C };
        for (scs, 0..) |sc, k| {
            const vk = MapVirtualKeyExW(sc, MAPVK_VSC_TO_VK_EX, hkl);
            const lab = translate(vk, sc, hkl, false, false, flags);
            var lb: [48]u8 = undefined;
            cells[k] = std.fmt.bufPrint(&cell[k], "0x{X:0>2} {s:<8} {s}", .{ vk, vkName(vk), lab.fmtTo(&lb) }) catch "?";
        }
        p("    {s:<22} {s:<28} {s:<28} {s}\n", .{ spec.name, cells[0], cells[1], cells[2] });
    }

    p("\n  판정 2 — 비라틴 layout 에서 VK 가 **위치**로 떨어지는가\n", .{});
    p("    이슈 본문 서술: \"KBDRU 는 sc 0x11=VK_W, 0x1E=VK_A, 0x10=VK_Q\"\n\n", .{});
    for (layout_specs, 0..) |spec, li| {
        if (loaded[li] == null) continue;
        const q = vkAt(li, 0x10);
        const w = vkAt(li, 0x11);
        const a = vkAt(li, 0x1E);
        const ok = (q == 'Q' and w == 'W' and a == 'A');
        p("    {s:<22} sc0x10->0x{X:0>2} {s:<6}  sc0x11->0x{X:0>2} {s:<6}  sc0x1E->0x{X:0>2} {s:<6}  {s}\n", .{
            spec.name, q, vkName(q), w, vkName(w), a, vkName(a),
            if (ok) "US 위치와 동일" else "다름",
        });
    }

    p("\n  판정 3 — `VK_OEM_3` (0xC0, tildaz 의 `grave` 바인딩) 이 layout 마다 무엇을 내는가\n", .{});
    p("    MapVirtualKeyExW(0xC0, MAPVK_VK_TO_VSC_EX) 로 그 VK 가 앉은 **자리**를 되찾고 라벨을 찍는다\n\n", .{});
    p("    {s:<22} {s:<8} {s:<8} {s:<24} {s}\n", .{ "layout", "sc", "US각인", "base 라벨", "shift 라벨" });
    for (layout_specs, 0..) |spec, li| {
        const hkl = loaded[li] orelse continue;
        const sc_raw = MapVirtualKeyExW(0xC0, MAPVK_VK_TO_VSC_EX, hkl);
        if (sc_raw == 0) {
            p("    {s:<22} {s}\n", .{ spec.name, "이 layout 에 VK_OEM_3 자리가 없다 (0 반환)" });
            continue;
        }
        const sc = sc_raw & 0xFF;
        const base = translate(0xC0, sc, hkl, false, false, flags);
        const shift = translate(0xC0, sc, hkl, true, false, flags);
        var b1: [48]u8 = undefined;
        var b2: [48]u8 = undefined;
        var scb: [16]u8 = undefined;
        const scs = std.fmt.bufPrint(&scb, "0x{X:0>2}", .{sc}) catch "?";
        p("    {s:<22} {s:<8} {s:<8} {s:<24} {s}\n", .{ spec.name, scs, usCap(sc), base.fmtTo(&b1), shift.fmtTo(&b2) });
    }

    p("\n    ② 관련 — `²` 와 그 이웃이 layout 별로 **어느 VK** 인가 (VkKeyScanExW 역방향)\n\n", .{});
    const chars = [_]struct { ch: u16, name: []const u8 }{
        .{ .ch = 0x00B2, .name = "sup2 U+00B2" },
        .{ .ch = '`', .name = "grave U+0060" },
        .{ .ch = 0x00F9, .name = "u-grave U+00F9" },
        .{ .ch = '[', .name = "[ U+005B" },
        .{ .ch = ']', .name = "] U+005D" },
    };
    p("    {s:<22}", .{"layout"});
    for (chars) |c| p(" {s:<22}", .{c.name});
    p("\n", .{});
    for (layout_specs, 0..) |spec, li| {
        const hkl = loaded[li] orelse continue;
        p("    {s:<22}", .{spec.name});
        for (chars) |c| {
            const r = VkKeyScanExW(c.ch, hkl);
            if (r == -1) {
                p(" {s:<22}", .{"없음(-1)"});
            } else {
                const bits: u16 = @bitCast(r);
                const rv: UINT = bits & 0xFF;
                const sh: u16 = (bits >> 8) & 0xFF;
                const sc = MapVirtualKeyExW(rv, MAPVK_VK_TO_VSC_EX, hkl) & 0xFF;
                var b: [48]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "0x{X:0>2}/{s} sh{d} sc{X:0>2}", .{ rv, vkName(rv), sh, sc }) catch "?";
                p(" {s:<22}", .{s});
            }
        }
        p("\n", .{});
    }

    p("\n  판정 4 — 라틴 fallback 이 Windows 에도 필요한가: 각 layout 이 라틴 a-z 를 **몇 개** 내는가\n", .{});
    p("    macOS 는 키릴 · 한글 · 일본어가 0 개라 fallback 없이는 글자 단축키가 전부 죽었다 (실측)\n\n", .{});
    for (layout_specs, 0..) |spec, li| {
        const hkl = loaded[li] orelse continue;
        var have: usize = 0;
        var missing: [26]u8 = undefined;
        var miss_n: usize = 0;
        var c: u16 = 'a';
        while (c <= 'z') : (c += 1) {
            if (VkKeyScanExW(c, hkl) != -1) {
                have += 1;
            } else {
                missing[miss_n] = @intCast(c);
                miss_n += 1;
            }
        }
        if (miss_n == 0) {
            p("    {s:<22} 26/26 — 전부 낼 수 있다\n", .{spec.name});
        } else {
            p("    {s:<22} {d}/26 — 못 내는 글자: {s}\n", .{ spec.name, have, missing[0..miss_n] });
        }
    }
    p("\n", .{});
}

fn sectionEdge() void {
    p("[E] 경계값 — 문서 서술을 믿지 않고 실제로 넣어 본다\n\n", .{});
    const us = loaded[0];
    const fr = loaded[1];

    p("  E1. modifier scancode — 그 자리에 무엇이 오는가 (US)\n", .{});
    for ([_]UINT{ 0x1D, 0x2A, 0x36, 0x38, 0x3A, 0x45 }) |sc| {
        const vk = MapVirtualKeyExW(sc, MAPVK_VSC_TO_VK_EX, us);
        const lab = translate(vk, sc, us, false, false, TU_NO_KERNEL_STATE);
        var b: [48]u8 = undefined;
        p("      sc 0x{X:0>2} ({s:<6}) -> vk 0x{X:0>2} {s:<13} ToUnicodeEx rc={d} {s}\n", .{ sc, usCap(sc), vk, vkName(vk), lab.rc, lab.fmtTo(&b) });
    }

    p("\n  E2. 존재하지 않는 / 범위 밖 scancode\n", .{});
    for ([_]UINT{ 0x00, 0x54, 0x55, 0x59, 0x5A, 0x7F, 0xFF, 0x1FF }) |sc| {
        const vk = MapVirtualKeyExW(sc, MAPVK_VSC_TO_VK_EX, us);
        const lab = translate(vk, sc, us, false, false, TU_NO_KERNEL_STATE);
        var b: [48]u8 = undefined;
        p("      sc 0x{X:0>3} -> vk 0x{X:0>2} {s:<13} ToUnicodeEx rc={d} {s}\n", .{ sc, vk, vkName(vk), lab.rc, lab.fmtTo(&b) });
    }

    p("\n  E3. 그 layout 에 없는 글자를 역방향으로 (VkKeyScanExW 가 -1 을 내는가)\n", .{});
    const probe_chars = [_]u16{ 'w', 'z', 0x0439, 0xAC00, 0x00B2 };
    const probe_names = [_][]const u8{ "w", "z", "U+0439", "U+AC00", "U+00B2" };
    for (layout_specs, 0..) |spec, li| {
        const hkl = loaded[li] orelse continue;
        p("      {s:<22}", .{spec.name});
        for (probe_chars, probe_names) |c, nm| {
            const r = VkKeyScanExW(c, hkl);
            var b: [40]u8 = undefined;
            const s = if (r == -1)
                (std.fmt.bufPrint(&b, "{s}=없음", .{nm}) catch "?")
            else
                (std.fmt.bufPrint(&b, "{s}=0x{X:0>4}", .{ nm, @as(u16, @bitCast(r)) }) catch "?");
            p(" {s:<16}", .{s});
        }
        p("\n", .{});
    }

    p("\n  E4. dead key 와 커널 상태 오염 — `TU_NO_KERNEL_STATE` (0x4) 가 실제로 듣는가\n", .{});
    p("      FR legacy 의 dead key 자리 (US각인 `[`) 다음에 US각인 `I` 자리를 번역했을 때\n", .{});
    p("      결합 글자로 오염되는가. macOS 경로 C 가 같은 병으로 탈락했다.\n\n", .{});
    const dead_sc: UINT = 0x1A;
    const i_sc: UINT = 0x17;
    for ([_]UINT{ 0, TU_NO_KERNEL_STATE }) |flags| {
        flushDeadKey(fr);
        const vk_dead = MapVirtualKeyExW(dead_sc, MAPVK_VSC_TO_VK_EX, fr);
        const vk_i = MapVirtualKeyExW(i_sc, MAPVK_VSC_TO_VK_EX, fr);
        const d = translate(vk_dead, dead_sc, fr, false, false, flags);
        const after = translate(vk_i, i_sc, fr, false, false, flags);
        var b1: [48]u8 = undefined;
        var b2: [48]u8 = undefined;
        p("      wFlags=0x{X}: sc 0x{X:0>2} -> rc={d} {s}   그다음 sc 0x{X:0>2} -> rc={d} {s}\n", .{
            flags, dead_sc, d.rc, d.fmtTo(&b1), i_sc, after.rc, after.fmtTo(&b2),
        });
        flushDeadKey(fr);
    }

    p("\n  E5. `MapVirtualKeyExW` 의 매핑 타입별 답 (US각인 `A` 자리 = sc 0x1E)\n", .{});
    for (layout_specs, 0..) |spec, li| {
        const hkl = loaded[li] orelse continue;
        const ex = MapVirtualKeyExW(0x1E, MAPVK_VSC_TO_VK_EX, hkl);
        const plain = MapVirtualKeyExW(0x1E, MAPVK_VSC_TO_VK, hkl);
        const to_char = MapVirtualKeyExW(ex, MAPVK_VK_TO_CHAR, hkl);
        const back = MapVirtualKeyExW(ex, MAPVK_VK_TO_VSC, hkl);
        p("      {s:<22} VSC_TO_VK_EX=0x{X:0>2}  VSC_TO_VK=0x{X:0>2}  VK_TO_CHAR=0x{X:0>4}  VK_TO_VSC=0x{X:0>2}\n", .{
            spec.name, ex, plain, to_char, back,
        });
    }
    p("\n", .{});
}

/// ①의 대조 — 로드한 hkl 로 잰 값과 **지금 활성 layout** 이 내는 값이 같은가.
/// `hkl = null` 은 Win32 에서 "현재 스레드의 layout" 을 뜻한다.
fn sectionActiveCompare(flags: UINT, when: []const u8) void {
    const cur = GetKeyboardLayout(0);
    p("[G] 활성 layout 대조 ({s}) — 로드한 hkl 과 실제 활성 layout 이 같은 값을 내는가\n", .{when});
    p("    현재 활성 HKL 0x{X:0>8} (KLID 0x{X:0>4})\n\n", .{ hklInt(cur), klidOf(cur) });

    var matched: ?usize = null;
    for (loaded, 0..) |h, i| {
        if (h != null and klidOf(h) == klidOf(cur)) matched = i;
    }
    if (matched) |mi| {
        p("    활성 layout 은 로드 목록의 **{s}** 와 같은 KLID 다. 세 열이 일치해야 한다.\n\n", .{layout_specs[mi].name});
    } else {
        p("    활성 layout 은 로드 목록에 없다 — 마지막 열은 비어 있다.\n\n", .{});
    }

    // **두 API 의 `NULL` 을 따로 찍는다.** 한 열에 합치면 서로 다른 뜻이 섞여 보이지
    // 않는다 — 실측에서 `MapVirtualKeyExW(NULL)` 은 *마지막에 로드한* layout 을,
    // `ToUnicodeEx(NULL)` 은 *활성* layout 을 썼다.
    p("    {s:<6} {s:<7} {s:<22} {s:<22} {s:<20} {s:<20} {s}\n", .{
        "sc",
        "US각인",
        "MapVirtualKeyExW(NULL)",
        "MapVirtualKeyExW(활성)",
        "ToUnicodeEx(NULL)",
        "ToUnicodeEx(활성)",
        "로드한 hkl",
    });
    for ([_]UINT{ 0x10, 0x11, 0x1E, 0x2C, 0x29, 0x1A, 0x1B }) |sc| {
        const vk_null = MapVirtualKeyExW(sc, MAPVK_VSC_TO_VK_EX, null);
        const vk_cur = MapVirtualKeyExW(sc, MAPVK_VSC_TO_VK_EX, cur);
        // 라벨 비교는 **같은 vk** 를 넣어야 뜻이 있다 — hkl 만 바꿔서 답이 갈리는지 본다.
        const l_null = translate(vk_cur, sc, null, false, false, flags);
        const l_cur = translate(vk_cur, sc, cur, false, false, flags);
        var b1: [48]u8 = undefined;
        var b2: [48]u8 = undefined;
        var c0: [40]u8 = undefined;
        var c1: [40]u8 = undefined;
        var c3: [72]u8 = undefined;
        const s0 = std.fmt.bufPrint(&c0, "0x{X:0>2} {s}", .{ vk_null, vkName(vk_null) }) catch "?";
        const s1 = std.fmt.bufPrint(&c1, "0x{X:0>2} {s}", .{ vk_cur, vkName(vk_cur) }) catch "?";
        const s3 = if (matched) |mi| blk: {
            const hkl = loaded[mi];
            const vk = MapVirtualKeyExW(sc, MAPVK_VSC_TO_VK_EX, hkl);
            const lab = translate(vk, sc, hkl, false, false, flags);
            var b3: [48]u8 = undefined;
            break :blk std.fmt.bufPrint(&c3, "0x{X:0>2} {s:<8} {s}", .{ vk, vkName(vk), lab.fmtTo(&b3) }) catch "?";
        } else "-";
        p("    0x{X:0>2}   {s:<7} {s:<22} {s:<22} {s:<20} {s:<20} {s}\n", .{
            sc, usCap(sc), s0, s1, l_null.fmtTo(&b1), l_cur.fmtTo(&b2), s3,
        });
    }
    p("\n", .{});
}

// --- watch 모드 ---

var watch_deadline_ms: u64 = 0;
var watch_last_hkl: usize = 0;
var watch_last_fg_hkl: usize = 0;
var watch_start_ms: u64 = 0;

fn elapsed() f64 {
    return @as(f64, @floatFromInt(GetTickCount64() - watch_start_ms)) / 1000.0;
}

fn updateTitle(hwnd: HWND, note: []const u8) void {
    const cur = GetKeyboardLayout(0);
    var utf8: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&utf8, "layout-probe — 활성 KLID 0x{X:0>4} — {s}", .{ klidOf(cur), note }) catch return;
    var w16: [256]WCHAR = @splat(0);
    const n = std.unicode.utf8ToUtf16Le(w16[0 .. w16.len - 1], s) catch return;
    w16[n] = 0;
    _ = SetWindowTextW(hwnd, @ptrCast(&w16));
}

fn reportLayoutSample(reason: []const u8) void {
    const cur = GetKeyboardLayout(0);
    const fg = GetForegroundWindow();
    const fg_tid = GetWindowThreadProcessId(fg, null);
    const fg_hkl = GetKeyboardLayout(fg_tid);
    // 우리 스레드 id 를 함께 찍는다 — 포그라운드가 *우리* 창인지 남의 창인지를 로그만
    // 보고 갈라야 한다. Windows 의 layout 은 **스레드별**이라 그 구분이 결론을 바꾼다.
    const me = GetCurrentThreadId();
    p("  [{d:>6.2}s] {s:<28} 우리 스레드({d}) HKL 0x{X:0>8}   포그라운드 스레드({d}{s}) HKL 0x{X:0>8}\n", .{
        elapsed(),      reason, me, hklInt(cur), fg_tid,
        if (fg_tid == me) "=우리" else "=남",
        hklInt(fg_hkl),
    });
    // 활성 layout 이 실제로 내는 값 — 로드한 hkl 과 대조할 근거를 매 전환마다 남긴다.
    p("           ", .{});
    for ([_]UINT{ 0x10, 0x11, 0x1E, 0x29 }) |sc| {
        const vk = MapVirtualKeyExW(sc, MAPVK_VSC_TO_VK_EX, cur);
        const lab = translate(vk, sc, cur, false, false, TU_NO_KERNEL_STATE);
        var b: [48]u8 = undefined;
        p(" sc{X:0>2}({s})->0x{X:0>2}/{s} {s}  ", .{ sc, usCap(sc), vk, vkName(vk), lab.fmtTo(&b) });
    }
    p("\n", .{});
    watch_last_hkl = hklInt(cur);
    watch_last_fg_hkl = hklInt(fg_hkl);
}

fn wndProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT {
    switch (msg) {
        WM_INPUTLANGCHANGEREQUEST => {
            p("  [{d:>6.2}s] WM_INPUTLANGCHANGEREQUEST   wParam=0x{X} lParam(HKL)=0x{X:0>8}\n", .{ elapsed(), wParam, @as(usize, @bitCast(lParam)) });
        },
        WM_INPUTLANGCHANGE => {
            p("  [{d:>6.2}s] **WM_INPUTLANGCHANGE**       charset=0x{X} lParam(HKL)=0x{X:0>8}\n", .{ elapsed(), wParam, @as(usize, @bitCast(lParam)) });
            reportLayoutSample("그 직후 상태");
            updateTitle(hwnd, "WM_INPUTLANGCHANGE 수신");
        },
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            const bits: usize = @bitCast(lParam);
            const sc: UINT = @intCast((bits >> 16) & 0xFF);
            const ext = ((bits >> 24) & 1) != 0;
            const vk: UINT = @intCast(wParam);
            const cur = GetKeyboardLayout(0);
            const base = translate(vk, sc, cur, false, false, TU_NO_KERNEL_STATE);
            var b: [48]u8 = undefined;
            p("  [{d:>6.2}s] {s:<13} vk=0x{X:0>2} {s:<13} sc=0x{X:0>2} ext={d} US각인={s:<6} 이 layout base={s}\n", .{
                elapsed(),
                if (msg == WM_KEYDOWN) "WM_KEYDOWN" else "WM_SYSKEYDOWN",
                vk,
                vkName(vk),
                sc,
                @intFromBool(ext),
                usCap(sc),
                base.fmtTo(&b),
            });
            var note: [96]u8 = undefined;
            const ns = std.fmt.bufPrint(&note, "vk=0x{X:0>2} sc=0x{X:0>2}", .{ vk, sc }) catch "";
            updateTitle(hwnd, ns);
        },
        WM_CHAR, WM_SYSCHAR => {
            var one = [_]u16{@intCast(wParam & 0xFFFF)};
            var utf8: [8]u8 = undefined;
            const n = std.unicode.utf16LeToUtf8(&utf8, &one) catch 0;
            p("  [{d:>6.2}s] {s:<13} '{s}' U+{X:0>4}\n", .{
                elapsed(),
                if (msg == WM_CHAR) "WM_CHAR" else "WM_SYSCHAR",
                utf8[0..n],
                one[0],
            });
        },
        WM_TIMER => {
            // **포그라운드 스레드 쪽도 본다.** 우리 창이 백그라운드일 때 남의 창에서
            // layout 을 바꾸면 우리 스레드 값은 안 움직일 수 있는데, 그 경우 우리만
            // 보고 있으면 "전환이 없었다" 로 잘못 읽는다.
            const fg_now = hklInt(GetKeyboardLayout(GetWindowThreadProcessId(GetForegroundWindow(), null)));
            if (hklInt(GetKeyboardLayout(0)) != watch_last_hkl) {
                reportLayoutSample("타이머 — 우리 스레드가 바뀜");
            } else if (fg_now != watch_last_fg_hkl) {
                reportLayoutSample("타이머 — 포그라운드만 바뀜");
            }
            if (GetTickCount64() >= watch_deadline_ms) PostQuitMessage(0);
        },
        WM_CLOSE => {
            _ = DestroyWindow(hwnd);
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

fn runWatch(seconds: u64) void {
    p("[W] watch — 한 프로세스를 살려 둔 채 {d} 초. 이 창에 **포커스를 두고** 입력 언어를 바꾼다.\n", .{seconds});
    p("    단발 실행으로는 \"값이 프로세스 시작 시점에 고정되는가\" 를 못 잰다 (macOS 세션 함정).\n\n", .{});

    const hinst = GetModuleHandleW(null);
    const cls = W("TildazLayoutProbe");
    const wc = WNDCLASSEXW{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinst,
        .hIcon = null,
        .hCursor = LoadCursorW(null, 32512), // IDC_ARROW
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = cls.ptr,
        .hIconSm = null,
    };
    if (RegisterClassExW(&wc) == 0) {
        p("    RegisterClassExW 실패 (GetLastError={d})\n", .{GetLastError()});
        return;
    }
    const hwnd = CreateWindowExW(
        0,
        cls.ptr,
        W("layout-probe").ptr,
        0x00CF0000 | 0x10000000, // WS_OVERLAPPEDWINDOW | WS_VISIBLE
        200,
        200,
        760,
        200,
        null,
        null,
        hinst,
        null,
    );
    if (hwnd == null) {
        p("    CreateWindowExW 실패 (GetLastError={d})\n", .{GetLastError()});
        return;
    }
    _ = SetForegroundWindow(hwnd);
    watch_start_ms = GetTickCount64();
    watch_deadline_ms = watch_start_ms + seconds * 1000;
    _ = SetTimer(hwnd, 1, 250, null);
    reportLayoutSample("시작 시점");
    updateTitle(hwnd, "여기에 포커스를 두고 입력 언어를 바꾸세요");

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
    p("\n  watch 종료. 마지막으로 관측한 활성 HKL 0x{X:0>8}\n\n", .{watch_last_hkl});
}

// --- main ---

fn writeDump(path: []const u8) void {
    var w16: [1024]WCHAR = @splat(0);
    const n = std.unicode.utf8ToUtf16Le(w16[0 .. w16.len - 1], path) catch return;
    w16[n] = 0;
    // GENERIC_WRITE, share none, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL
    const h = CreateFileW(@ptrCast(&w16), 0x40000000, 0, null, 2, 0x80, null);
    if (@intFromPtr(h) == @as(usize, @bitCast(@as(isize, -1)))) {
        p("덤프 실패: CreateFileW GetLastError={d}\n", .{GetLastError()});
        return;
    }
    defer _ = CloseHandle(h);
    // UTF-8 BOM — 메모장 / PowerShell 이 코드페이지로 오해하지 않게 한다.
    writeHandle(h, "\xEF\xBB\xBF");
    writeHandle(h, dump.items);
}

pub fn main(init: std.process.Init) !void {
    out_alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(out_alloc);

    var out_path: []const u8 = "layout-probe-dump.txt";
    var watch_seconds: ?u64 = null;
    var dirty_state = false;
    var unload_session = false;
    var only_klid: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else if (std.mem.eql(u8, a, "--watch")) {
            var v: []const u8 = "30";
            if (i + 1 < args.len) {
                i += 1;
                v = args[i];
            }
            watch_seconds = std.fmt.parseInt(u64, v, 10) catch 30;
        } else if (std.mem.eql(u8, a, "--only") and i + 1 < args.len) {
            i += 1;
            only_klid = args[i];
        } else if (std.mem.eql(u8, a, "--unload-session")) {
            unload_session = true;
        } else if (std.mem.eql(u8, a, "--dirty-state")) {
            // `TU_NO_KERNEL_STATE` 없이 표를 뜬다 — dead key 오염이 표를 얼마나
            // 망가뜨리는지 눈으로 보려는 용도.
            dirty_state = true;
        } else {
            p("알 수 없는 인자: {s}\n", .{a});
        }
    }

    const flags: UINT = if (dirty_state) 0 else TU_NO_KERNEL_STATE;

    sectionHeader();

    // `--only KLID` — 딱 하나만 올리고 `hkl = NULL` 이 무엇을 내는지 본다. NULL 이
    // "활성 layout" 이 아니라 **마지막에 로드한 layout** 이라는 것을 못박는 실험이다.
    if (only_klid) |klid| {
        var w16: [16]WCHAR = @splat(0);
        const n = std.unicode.utf8ToUtf16Le(w16[0 .. w16.len - 1], klid) catch 0;
        w16[n] = 0;
        const hkl = LoadKeyboardLayoutW(@ptrCast(&w16), 0);
        p("[O] --only {s} — 이 하나만 올렸다. HKL 0x{X:0>8}\n\n", .{ klid, hklInt(hkl) });
        sectionActiveCompare(flags, "하나만 로드한 상태");
        if (hkl != null and klidOf(hkl) != klidOf(GetKeyboardLayout(0))) _ = UnloadKeyboardLayout(hkl);
        writeDump(out_path);
        p("덤프: {s}\n", .{out_path});
        return;
    }

    if (unload_session) {
        unloadSession();
        sectionActiveCompare(flags, "세션 정리 후");
        writeDump(out_path);
        p("덤프: {s}\n", .{out_path});
        return;
    }

    // **로드 전에 한 번 잰다.** `hkl = NULL` 이 "현재 활성 layout" 을 뜻한다는 통념이
    // 맞는지 보려면 로드가 그 값을 건드리기 전 상태가 필요하다 — 1 차 측정에서 로드
    // *후*의 NULL 은 활성 layout 이 아니라 **마지막에 로드한** layout 값을 냈다.
    sectionActiveCompare(flags, "layout 로드 전");

    if (watch_seconds) |s| {
        // **watch 는 layout 을 올리지 않는다.** 올린 layout 은 `Win+Space` 전환 목록에
        // 그대로 나타나서, 측정하는 동안 사용자의 입력 전환을 바꿔 버린다 (실측: 8 개를
        // 올려 둔 회차에서 한국어로 한 번에 못 돌아왔고, 목록에 없어야 할 French
        // standard 가 전환됐다). watch 가 보는 것은 *활성* layout 뿐이라 로드가 필요 없다.
        runWatch(s);
        sectionActiveCompare(flags, "watch 종료 후");
        writeDump(out_path);
        p("덤프: {s}\n", .{out_path});
        return;
    }

    sectionLoad();

    {
        sectionTables(flags);
        sectionVerdicts(flags);
        sectionEdge();
        sectionActiveCompare(flags, "layout 로드 후");
    }

    unloadLoaded();
    sectionActiveCompare(flags, "정리 후");

    writeDump(out_path);
    p("덤프: {s}\n", .{out_path});
}
