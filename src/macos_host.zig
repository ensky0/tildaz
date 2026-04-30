// macOS host — drop-down terminal entry point.
//
// 진행 상태는 이슈 #108 참고.
//
//   M1 — host 골격 + fail-fast 메시지 (688d204).
//   M2 — NSWindow + CAMetalLayer 빈 화면 + Cmd+Q (bebf897).
//   M3 — borderless + dock rect + F1 글로벌 핫키 토글. (현재)
//   M3.5 — config.zig platform-leak 정리, NSAlert 기반 config 에러.
//   M4 — 모니터/DPI 변화 시 재적용.
//   M5 — POSIX PTY + ghostty-vt + CoreText/Metal 글리프.
//   M6 — 한글 IME.
//
// M3 의 검증 포인트 (옵션 D 핵심 가설):
//   F1 두 번 → 윈도우 hide/show 토글에서 잔상 / 깜박임 없음.
//   사용자 드래그 리사이즈는 borderless + non-resizable styleMask 로 OS 차단.
//   #75 가 6번 시도해도 못 풀던 \"드래그 중 잔상\" 시나리오를 원천 회피.

const std = @import("std");
const build_options = @import("build_options");
const objc = @import("macos_objc.zig");
const macos_config = @import("macos_config.zig");
const macos_pty = @import("macos_pty.zig");
const ghostty = @import("ghostty-vt");
const macos_metal = @import("macos_metal.zig");
const ui_metrics = @import("ui_metrics.zig");
const terminal_interaction = @import("terminal_interaction.zig");
const tab_interaction = @import("tab_interaction.zig");
const macos_session = @import("macos_session.zig");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");
const about = @import("about.zig");

pub fn showPanic(msg: []const u8, addr: usize) noreturn {
    std.debug.print("panic: {s}\nreturn address: 0x{x}\n", .{ msg, addr });
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, messages.panic_format, .{ msg, addr }) catch "panic (format failed)";
    dialog.showError(messages.crash_title, text);
    std.process.exit(1);
}

pub fn showFatalRunError(err: anyerror) void {
    std.debug.print("TildaZ failed to start.\n\nError: {s}\n", .{@errorName(err)});
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, messages.run_failed_format, .{@errorName(err)}) catch "TildaZ failed to start.";
    dialog.showError(messages.error_title, text);
}

// AppKit / Metal 상수.
const NSWindowStyleMaskBorderless: c_ulong = 0;
const NSWindowStyleMaskTitled: c_ulong = 1 << 0;
const NSWindowStyleMaskFullSizeContentView: c_ulong = 1 << 15;
const NSBackingStoreBuffered: c_ulong = 2;
// `Regular` (0) = Dock + Cmd+Tab + 메뉴바 등장 (일반 앱).
// `Accessory` (1) = Dock / Cmd+Tab 안 보임, 메뉴바도 우리 앱 메뉴 안 뜸. drop-down
//   터미널 정체성. Info.plist 의 LSUIElement = true 와 같은 효과지만 코드 레벨이라
//   LaunchServices 캐시 / 직접 실행 / open 실행 무관하게 즉시 적용된다.
const NSApplicationActivationPolicyAccessory: c_long = 1;
const MTLPixelFormatBGRA8Unorm: c_ulong = 80;
// `standardWindowButton:` 인덱스 — close=0, miniaturize=1, zoom=2.
const NSWindowCloseButton: c_long = 0;
const NSWindowMiniaturizeButton: c_long = 1;
const NSWindowZoomButton: c_long = 2;
// `setTitleVisibility:` 의 NSWindowTitleHidden = 1.
const NSWindowTitleHidden: c_long = 1;

// 키 코드 (Apple 의 `Events.h` `kVK_*`). Cmd+Q 는 hardcoded — config 의
// hotkey 와 별개로 macOS native 종료 단축키 그대로.
const kVK_ANSI_Q: i64 = 0x0C;

// CGEventFlags modifier 마스크 (CGEventTypes.h). Carbon modifier (1<<8 등) 와
// 다른 비트 위치. 예: command = 1<<20.
const kCGEventFlagMaskCommand: u64 = 0x00100000;
const kCGEventFlagMaskShift: u64 = 0x00020000;
const kCGEventFlagMaskAlternate: u64 = 0x00080000; // = Option
const kCGEventFlagMaskControl: u64 = 0x00040000;
const kCGEventFlagsAllModifiers: u64 = kCGEventFlagMaskCommand | kCGEventFlagMaskShift | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl;

const CGFloat = f64;
const NSRect = extern struct { origin: NSPoint, size: NSSize };
const NSPoint = extern struct { x: CGFloat, y: CGFloat };
const NSSize = extern struct { width: CGFloat, height: CGFloat };

// CGEventTap FFI (CoreGraphics).
//
// Apple DTS 권장 패턴: CGEventTapCreate 로 system-wide 키보드 이벤트 가로채기
// + CFRunLoopAddSource 로 NSApp 의 main run loop 에 통합. Carbon RegisterEvent
// HotKey 와 달리 Apple Developer 인증서 sign 없이도 동작 (단 \"Input Monitoring\"
// 권한 필요 — 사용자가 시스템 설정에서 활성화).
//
// 참고: ghostty Quick Terminal 의 GlobalEventTap.swift 도 같은 길.
const CGEventRef = ?*anyopaque;
const CFMachPortRef = ?*anyopaque;
const CFRunLoopSourceRef = ?*anyopaque;
const CFRunLoopRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;

const CGEventTapLocation = c_int;
const CGEventTapPlacement = c_int;
const CGEventTapOptions = c_int;
const CGEventMask = u64;
const CGEventField = u32;
const CGEventType = c_int;

const kCGSessionEventTap: CGEventTapLocation = 1;
const kCGHeadInsertEventTap: CGEventTapPlacement = 0;
const kCGEventTapOptionDefault: CGEventTapOptions = 0;
const kCGEventKeyDown: CGEventType = 10;
const kCGKeyboardEventKeycode: CGEventField = 9;

const CGEventTapCallBack = *const fn (
    proxy: ?*anyopaque,
    event_type: CGEventType,
    event: CGEventRef,
    userInfo: ?*anyopaque,
) callconv(.c) CGEventRef;

extern fn CGEventTapCreate(
    tap: CGEventTapLocation,
    place: CGEventTapPlacement,
    options: CGEventTapOptions,
    eventsOfInterest: CGEventMask,
    callback: CGEventTapCallBack,
    userInfo: ?*anyopaque,
) CFMachPortRef;

extern fn CGEventTapEnable(tap: CFMachPortRef, enable: bool) void;

extern fn CGEventGetIntegerValueField(event: CGEventRef, field: CGEventField) i64;
extern fn CGEventGetFlags(event: CGEventRef) u64;

extern fn CFMachPortCreateRunLoopSource(
    allocator: ?*anyopaque,
    port: CFMachPortRef,
    order: usize,
) CFRunLoopSourceRef;

extern fn CFRunLoopGetMain() CFRunLoopRef;
extern fn CFRunLoopAddSource(runloop: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef) void;

// 렌더 timer 용 CFRunLoopTimer FFI. NSTimer 보다 가벼움 — ObjC class /
// selector 등록 없이 C function pointer 그대로 사용.
const CFAbsoluteTime = f64;
const CFTimeInterval = f64;
const CFRunLoopTimerRef = ?*anyopaque;
const CFRunLoopTimerCallback = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
extern fn CFAbsoluteTimeGetCurrent() CFAbsoluteTime;
extern fn CFRunLoopTimerCreate(
    allocator: ?*anyopaque,
    fireDate: CFAbsoluteTime,
    interval: CFTimeInterval,
    flags: u32,
    order: isize,
    callout: CFRunLoopTimerCallback,
    context: ?*anyopaque,
) CFRunLoopTimerRef;
extern fn CFRunLoopAddTimer(runloop: CFRunLoopRef, timer: CFRunLoopTimerRef, mode: CFStringRef) void;

// kCFRunLoopCommonModes 는 CFString 상수 (Apple 의 CFRunLoop.h). Zig 의
// extern var 로 받아 쓴다.
extern const kCFRunLoopCommonModes: CFStringRef;

// Input Monitoring 권한 (macOS 10.15+).
extern fn CGPreflightListenEventAccess() bool;
extern fn CGRequestListenEventAccess() bool;

// Accessibility (손쉬운 사용) 권한 — `kCGEventTapOptionDefault` (active tap)
// 으로 이벤트 변경 / 삼키기 시 macOS 가 추가로 요구. ListenOnly 면 Input
// Monitoring 만으로 충분하지만, 우리는 F1/Cmd+Q 를 다른 앱에 전달 안 되게
// consume 해야 하므로 active 가 필수.
extern fn AXIsProcessTrusted() bool;

extern fn MTLCreateSystemDefaultDevice() objc.id;

// 글로벌 toggle 상태 — CGEventTap 콜백 (C 시그니처) 이 NSApp / window / config
// 에 접근하려면 어딘가 보관해야 함. M3 단계에서 host 가 한 인스턴스만 띄우므로
// 모듈 전역으로 충분. M5 이후 multi-window / multi-tab 으로 확장 시 userdata
// 포인터 패턴으로 옮길 예정.
var g_app: objc.id = null;
var g_window: objc.id = null;
var g_visible: bool = false;
var g_config: macos_config.Config = .{};
var g_gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
/// 멀티탭 컬렉션 (#111 M11.1). 현재 단계는 데이터 모델만 도입 — 실제로는
/// 단일 탭만 생성. PTY / Terminal / Stream / 마우스 selection 은 모두 활성
/// 탭의 필드. host 코드는 `g_session.activeTab().?.{pty,terminal,...}` 로 access.
///
/// thread safety (M5.1 노트): UI thread 가 terminal 을 안 읽으므로 PTY read
/// thread 가 직접 stream parsing 해도 race 없음. 멀티탭 도입해도 활성 탭만
/// 렌더링 + 입력 받으니 동일 — 단 closeTab 은 read thread 가 살아 있을 때
/// 위험하므로 후속 milestone 에서 join 처리.
var g_session: macos_session.SessionCore = undefined;
/// 탭 drag-and-drop reorder state (#111 M11.6a). Windows `tab_interaction.DragState`
/// 그대로 사용 — cross-platform 모듈.
var g_drag: tab_interaction.DragState = .{};
/// 탭 이름 변경 state (#111 M11.6b). 더블클릭으로 시작, Enter commit / Escape cancel.
/// 활성화 동안 모든 키 입력 / 텍스트 입력 (IME insertText 포함) 이 PTY 대신
/// 이쪽으로 라우팅.
var g_rename: tab_interaction.RenameState = .{};
var g_pty_bytes_received: u64 = 0;
/// 새 탭 생성 시 재사용할 PTY 파라미터들. 첫 탭 init 시 채우고 그 후 변동 없음.
var g_shell_path: []const u8 = "";
var g_max_scrollback: usize = 0;
var g_extra_env: [3]macos_pty.Pty.EnvVar = undefined;
// M5.3 — Metal 렌더러 + timer + cell metrics. cell_width/height 는 폰트의
// 'M' advance / ascent+descent+leading 으로 동적 측정 (Windows 와 동일 패턴).
// font_family 는 config 통합 전까지 hardcoded.
var g_metal_layer: objc.id = null;
var g_renderer: ?macos_metal.MetalRenderer = null;
var g_render_timer: CFRunLoopTimerRef = null;
// Menlo — macOS 기본 등록된 monospace. SF Mono 는 system font 라
// CTFontCreateWithName 에서 family 매칭이 안 되면 proportional fallback 으로
// 떨어져 글자 폭이 들쭉날쭉 해진다. 추후 menlo 로 동작 확인되면 SF Mono 는
// CTFontCreateUIFontForLanguage 같은 별도 경로로 다시 시도.
const FONT_FAMILY = "Menlo";
const FONT_SIZE_PT: f32 = 14.0;
// Windows config 의 cell_width / line_height default 와 동일. config 통합
// 후 사용자 설정 가능. 1.0 / 1.0 이면 폰트 그대로, 1.1 / 0.95 는 약간의 가로
// padding + 빽빽한 줄간격.
const CELL_WIDTH_SCALE: f32 = 1.1;
const LINE_HEIGHT_SCALE: f32 = 0.95;
// 터미널 영역 안쪽 padding — `ui_metrics.zig` 의 공통 상수. Windows /
// macOS 동일 값으로 시각적 일관성 유지. pixel 변환은 init 시 retina scale 곱.
const TERMINAL_PADDING_PT = ui_metrics.TERMINAL_PADDING_PT;
const TAB_BAR_HEIGHT_PT = ui_metrics.TAB_BAR_HEIGHT_PT;

/// 탭바가 현재 차지하는 픽셀 높이. 탭이 ≤ 1 개면 0 (자리 안 띄움) — 단일 탭
/// 사용자가 위쪽 빈 공간 거슬려 함 (#111 M11.4 사용자 보고).
/// 탭 ≥ 2 개로 전환 시 자리 등장 + 모든 탭 cols/rows 재계산은 호출처 책임
/// (`syncTerminalGeometry` 가 통합 처리).
fn tabBarHeightPx(scale: f32) i32 {
    if (g_session.count() < 2) return 0;
    return @intFromFloat(@as(f32, @floatFromInt(TAB_BAR_HEIGHT_PT)) * scale);
}

/// 현재 viewport / cell 크기 + 탭 수에 따른 cols/rows 재계산 후 모든 탭의
/// terminal + pty 동기화. 탭 1↔2 전환 시 탭바 등장/사라짐으로 cell 영역이
/// 변하므로 호출 필요. screen change / 탭 추가 / 탭 닫기 모두 같은 함수 사용.
fn syncTerminalGeometry() void {
    if (g_renderer == null) return;
    if (g_session.count() == 0) return;

    const r = &g_renderer.?;
    const cell_w = r.font.cell_width;
    const cell_h = r.font.cell_height;
    const pad: u32 = @intFromFloat(@as(f32, @floatFromInt(TERMINAL_PADDING_PT)) * r.scale);
    const tab_bar: u32 = @intCast(tabBarHeightPx(r.scale));
    const top_reserved = pad + tab_bar;
    const usable_w = if (r.vp_width > 2 * pad) r.vp_width - 2 * pad else cell_w;
    const usable_h = if (r.vp_height > top_reserved + pad) r.vp_height - top_reserved - pad else cell_h;
    const new_cols: u16 = @intCast(@max(1, usable_w / cell_w));
    const new_rows: u16 = @intCast(@max(1, usable_h / cell_h));

    for (g_session.tabs.items) |t| {
        if (new_cols == t.terminal.cols and new_rows == t.terminal.rows) continue;
        t.terminal.resize(g_gpa.allocator(), new_cols, new_rows) catch |err| {
            std.debug.print("[geom] terminal resize failed: {s}\n", .{@errorName(err)});
            continue;
        };
        t.pty.resize(new_cols, new_rows) catch |err| {
            std.debug.print("[geom] pty resize failed: {s}\n", .{@errorName(err)});
        };
    }
}

// NSWindow subclass — `canBecomeKeyWindow` 를 YES 로 override 해서 borderless
// styleMask 에서도 key window 가능하게. Default NSWindow 는 borderless 면
// canBecomeKey=NO 라 mainMenu Cmd+Q 등이 dispatch 안 됨. ghostty Quick Terminal
// 의 `class QuickTerminalWindow: NSPanel { override var canBecomeKey: Bool { true } }`
// 와 동일 효과.
fn tildazCanBecomeKey(_: objc.id, _: objc.SEL) callconv(.c) bool {
    return true;
}

fn tildazCanBecomeMain(_: objc.id, _: objc.SEL) callconv(.c) bool {
    return true;
}

fn registerTildazWindowClass() !objc.Class {
    const NSWindow = objc.getClass("NSWindow");
    const cls = objc.objc_allocateClassPair(NSWindow, "TildazWindow", 0) orelse
        return error.WindowSubclassAllocFailed;
    // Method signature: "B@:" = bool 반환, self (id) + _cmd (SEL) 만 인자.
    if (!objc.class_addMethod(cls, objc.sel("canBecomeKeyWindow"), @ptrCast(&tildazCanBecomeKey), "B@:"))
        return error.WindowSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("canBecomeMainWindow"), @ptrCast(&tildazCanBecomeMain), "B@:"))
        return error.WindowSubclassAddMethodFailed;
    objc.objc_registerClassPair(cls);
    return cls;
}

// TildazView = NSView subclass — keyDown / acceptsFirstResponder override.
// `acceptsFirstResponder` YES 안 하면 NSWindow 가 firstResponder 로 안 잡아
// 키 이벤트가 view 에 안 옴. keyDown: 에서 NSEvent.characters 추출 → PTY 로
// write. 특수 키 (화살표, F-key) 는 별도 escape sequence 매핑 필요 (M5.4b).
fn tildazAcceptsFirstResponder(_: objc.id, _: objc.SEL) callconv(.c) bool {
    return true;
}

const NSEventTypeKeyDown: c_long = 10;
const NSUTF8StringEncoding: usize = 4;

/// macOS hardware keyCode 별 xterm-compatible escape sequence. macOS 의
/// NSEvent.characters 는 화살표 / F-key 를 NSFunctionKey private codepoint
/// (U+F700~) 으로 보내는데 bash / vim / less 등은 표준 xterm escape sequence
/// 만 인식하므로 keyCode 직접 매핑이 필요.
fn keyCodeToEscape(keycode: c_ushort) ?[]const u8 {
    return switch (keycode) {
        // 화살표
        126 => "\x1b[A", // up
        125 => "\x1b[B", // down
        124 => "\x1b[C", // right
        123 => "\x1b[D", // left
        // 네비게이션
        115 => "\x1b[H", // home
        119 => "\x1b[F", // end
        116 => "\x1b[5~", // pgup
        121 => "\x1b[6~", // pgdn
        117 => "\x1b[3~", // forward delete
        // F-keys
        122 => "\x1bOP", // F1 (CGEventTap 이 가로채니 사실 도달 안 함)
        120 => "\x1bOQ", // F2
        99 => "\x1bOR", // F3
        118 => "\x1bOS", // F4
        96 => "\x1b[15~", // F5
        97 => "\x1b[17~", // F6
        98 => "\x1b[18~", // F7
        100 => "\x1b[19~", // F8
        101 => "\x1b[20~", // F9
        109 => "\x1b[21~", // F10
        103 => "\x1b[23~", // F11
        111 => "\x1b[24~", // F12
        else => null,
    };
}

fn tildazKeyDown(self_view: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const tab = g_session.activeTab() orelse return;
    if (event == null) return;

    // rename (#111 M11.6b) 진행 중이면 키를 모두 interpretKeyEvents 로 보냄
    // → IME / NSResponder 가 imeInsertText / imeDoCommand 콜백 호출 → 거기서
    //   RenameState 로 라우팅. PTY 로는 아무 것도 안 흘려.
    //   Cmd 단축키도 rename 진행 중엔 무시 — 의도치 않은 부수효과 방지.
    if (g_rename.isActive()) {
        const NSArray = objc.getClass("NSArray");
        const arrayWithObject = objc.objcSend(fn (objc.Class, objc.SEL, objc.id) callconv(.c) objc.id);
        const array = arrayWithObject(NSArray, objc.sel("arrayWithObject:"), event);
        const interpretKeyEvents = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
        interpretKeyEvents(self_view, objc.sel("interpretKeyEvents:"), array);
        return;
    }

    // Cmd+C / Cmd+V 우선 — IME 와 무관하게 처리.
    const get_flags = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_ulong);
    const flags = get_flags(event, objc.sel("modifierFlags"));
    const NSEventModifierFlagCommand: c_ulong = 1 << 20;
    const cmd = (flags & NSEventModifierFlagCommand) != 0;
    if (cmd) {
        const get_kc = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_ushort);
        const kc = get_kc(event, objc.sel("keyCode"));
        const NSEventModifierFlagShift: c_ulong = 1 << 17;
        const shift = (flags & NSEventModifierFlagShift) != 0;

        // keyCode 8 = 'c', 9 = 'v'.
        if (kc == 8) {
            handleCopy();
            return;
        }
        if (kc == 9) {
            handlePaste();
            return;
        }
        // Cmd+T = 새 탭 (kc 0x11 = 'T'). M11.2.
        if (kc == 0x11 and !shift) {
            handleNewTab();
            return;
        }
        // Cmd+W = 활성 탭 닫기 (kc 0x0D = 'W'). M11.3. 마지막 탭이면 앱 종료
        // (drainExitedTabs 가 다음 frame 에 처리).
        if (kc == 0x0D and !shift) {
            handleCloseActiveTab();
            return;
        }
        // Cmd+1..9 = 해당 인덱스 탭 활성화. M11.2.
        if (keycodeToTabIndex(kc)) |idx| {
            _ = g_session.setActiveTab(idx);
            return;
        }
        // Cmd+Shift+[ / Cmd+Shift+] = 이전 / 다음 탭. M11.2.
        if (shift and kc == 0x21) {
            _ = g_session.activatePrev();
            return;
        }
        if (shift and kc == 0x1E) {
            _ = g_session.activateNext();
            return;
        }
        // 다른 Cmd+key 는 mainMenu 가 처리 (Cmd+Q 등).
        // PTY 로 forward 안 함.
        return;
    }

    // IME 가 조합 중이 아니면 화살표 / F-key / nav 는 직접 escape sequence
    // (성능 + 정확성). 조합 중이면 interpretKeyEvents 로 보내 IME 가 음절
    // commit 후 doCommandBySelector 로 우리에게 위임 — 우리 imeDoCommand 가
    // escape sequence write.
    if (g_marked_len == 0) {
        const get_keycode = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_ushort);
        const keycode = get_keycode(event, objc.sel("keyCode"));
        if (keyCodeToEscape(keycode)) |esc| {
            _ = tab.pty.write(esc) catch {};
            return;
        }
    }

    const NSArray = objc.getClass("NSArray");
    const arrayWithObject = objc.objcSend(fn (objc.Class, objc.SEL, objc.id) callconv(.c) objc.id);
    const array = arrayWithObject(NSArray, objc.sel("arrayWithObject:"), event);
    const interpretKeyEvents = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    interpretKeyEvents(self_view, objc.sel("interpretKeyEvents:"), array);
}

// IME (NSTextInputClient) 상태 — 조합 중 (preedit) 텍스트 buffer.
const NSRange = extern struct { location: usize, length: usize };
const NSNotFound: usize = @as(usize, @bitCast(@as(isize, -1)));
var g_marked_len: usize = 0;
var g_preedit_buf: [128]u8 = undefined;
var g_preedit_len: usize = 0;

/// NSAttributedString 이거나 NSString 인 input → NSString 추출.
fn imeStringFromInput(text: objc.id) objc.id {
    if (text == null) return text;
    const NSAttributedString = objc.getClass("NSAttributedString");
    const isKindOf = objc.objcSend(fn (objc.id, objc.SEL, objc.Class) callconv(.c) bool);
    if (isKindOf(text, objc.sel("isKindOfClass:"), NSAttributedString)) {
        const get_str = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
        return get_str(text, objc.sel("string"));
    }
    return text;
}

/// IME 가 글자 commit 시 호출 (한글 음절 완성, 일본어 conversion 확정 등).
/// PTY 로 write + preedit buffer clear.
fn imeInsertText(_: objc.id, _: objc.SEL, text: objc.id, _: NSRange) callconv(.c) void {
    const tab = g_session.activeTab() orelse return;
    const str = imeStringFromInput(text);
    if (str == null) {
        g_marked_len = 0;
        g_preedit_len = 0;
        return;
    }
    const get_len = objc.objcSend(fn (objc.id, objc.SEL, usize) callconv(.c) usize);
    const len = get_len(str, objc.sel("lengthOfBytesUsingEncoding:"), NSUTF8StringEncoding);
    if (len == 0) {
        g_marked_len = 0;
        g_preedit_len = 0;
        return;
    }
    const get_utf8 = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) [*:0]const u8);
    const cstr = get_utf8(str, objc.sel("UTF8String"));

    g_marked_len = 0;
    g_preedit_len = 0;

    // rename (#111 M11.6b) 진행 중이면 PTY 대신 rename buf 로 라우팅.
    // codepoint 단위 iter 후 각각 insertCodepoint — 한글 등 multi-byte 도 지원.
    if (g_rename.isActive()) {
        var iter = std.unicode.Utf8Iterator{ .bytes = cstr[0..len], .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            _ = g_rename.insertCodepoint(cp);
        }
        return;
    }

    _ = tab.pty.write(cstr[0..len]) catch |err| {
        std.debug.print("[pty] write failed: {s}\n", .{@errorName(err)});
    };
}

/// NSResponder 의 1-arg insertText: (legacy). 일부 IME 가 이걸 호출.
fn imeInsertTextSimple(self_view: objc.id, sel_: objc.SEL, text: objc.id) callconv(.c) void {
    imeInsertText(self_view, sel_, text, .{ .location = NSNotFound, .length = 0 });
}

/// IME 조합 중 텍스트 — preedit buffer 에 저장. PTY 에는 안 보냄. metal
/// renderer 가 cursor 위치 위에 overlay (M6.2).
fn imeSetMarkedText(_: objc.id, _: objc.SEL, text: objc.id, _: NSRange, _: NSRange) callconv(.c) void {
    const str = imeStringFromInput(text);
    if (str == null) {
        g_marked_len = 0;
        g_preedit_len = 0;
        return;
    }
    const get_length = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) usize);
    g_marked_len = get_length(str, objc.sel("length"));

    const get_len = objc.objcSend(fn (objc.id, objc.SEL, usize) callconv(.c) usize);
    const len = get_len(str, objc.sel("lengthOfBytesUsingEncoding:"), NSUTF8StringEncoding);
    if (len == 0) {
        g_preedit_len = 0;
        return;
    }
    const get_utf8 = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) [*:0]const u8);
    const cstr = get_utf8(str, objc.sel("UTF8String"));
    const copy_len = @min(len, g_preedit_buf.len);
    @memcpy(g_preedit_buf[0..copy_len], cstr[0..copy_len]);
    g_preedit_len = copy_len;
}

fn imeUnmarkText(_: objc.id, _: objc.SEL) callconv(.c) void {
    g_marked_len = 0;
    g_preedit_len = 0;
}

fn imeHasMarkedText(_: objc.id, _: objc.SEL) callconv(.c) bool {
    return g_marked_len > 0;
}

fn imeMarkedRange(_: objc.id, _: objc.SEL) callconv(.c) NSRange {
    if (g_marked_len > 0) return .{ .location = 0, .length = g_marked_len };
    return .{ .location = NSNotFound, .length = 0 };
}

fn imeSelectedRange(_: objc.id, _: objc.SEL) callconv(.c) NSRange {
    return .{ .location = 0, .length = 0 };
}

fn imeValidAttributes(_: objc.id, _: objc.SEL) callconv(.c) objc.id {
    const NSArray = objc.getClass("NSArray");
    const array = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    return array(NSArray, objc.sel("array"));
}

fn imeAttrSubstring(_: objc.id, _: objc.SEL, _: NSRange, _: ?*NSRange) callconv(.c) objc.id {
    return null;
}

fn imeCharIndex(_: objc.id, _: objc.SEL, _: f64, _: f64) callconv(.c) usize {
    return NSNotFound;
}

const CGRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
fn imeFirstRect(_: objc.id, _: objc.SEL, _: NSRange, _: ?*NSRange) callconv(.c) CGRect {
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

/// IME 가 모르는 special key (Return, Backspace, Tab, 화살표 등) 을
/// interpretKeyEvents 가 selector 형태로 보냄. escape sequence 매핑.
fn imeDoCommand(_: objc.id, _: objc.SEL, cmd_sel: objc.SEL) callconv(.c) void {
    const tab = g_session.activeTab() orelse return;

    // rename (#111 M11.6b) 진행 중이면 PTY 로 안 보내고 RenameState 로 라우팅.
    if (g_rename.isActive()) {
        const key: ?tab_interaction.RenameKey =
            if (cmd_sel == objc.sel("insertNewline:")) .enter
            else if (cmd_sel == objc.sel("cancelOperation:")) .escape
            else if (cmd_sel == objc.sel("deleteBackward:")) .backspace
            else if (cmd_sel == objc.sel("deleteForward:")) .delete
            else if (cmd_sel == objc.sel("moveLeft:")) .left
            else if (cmd_sel == objc.sel("moveRight:")) .right
            else if (cmd_sel == objc.sel("moveToBeginningOfLine:")) .home
            else if (cmd_sel == objc.sel("moveToEndOfLine:")) .end
            else null;
        if (key) |k| {
            switch (g_rename.handleKey(k)) {
                .commit => commitOrCancelRename(true),
                .cancel => commitOrCancelRename(false),
                else => {},
            }
        }
        // rename 진행 중엔 다른 selector 모두 무시 (Tab key 등이 PTY 로 안 가게).
        return;
    }

    const bytes: ?[]const u8 = if (cmd_sel == objc.sel("insertNewline:"))
        "\r"
    else if (cmd_sel == objc.sel("insertTab:"))
        "\t"
    else if (cmd_sel == objc.sel("insertBacktab:"))
        "\x1b[Z"
    else if (cmd_sel == objc.sel("deleteBackward:"))
        "\x7f"
    else if (cmd_sel == objc.sel("deleteForward:"))
        "\x1b[3~"
    else if (cmd_sel == objc.sel("cancelOperation:"))
        "\x1b"
    else if (cmd_sel == objc.sel("moveUp:"))
        "\x1b[A"
    else if (cmd_sel == objc.sel("moveDown:"))
        "\x1b[B"
    else if (cmd_sel == objc.sel("moveLeft:"))
        "\x1b[D"
    else if (cmd_sel == objc.sel("moveRight:"))
        "\x1b[C"
    else
        null;
    if (bytes) |b| {
        _ = tab.pty.write(b) catch {};
    }
}

/// 모니터 / DPI / dock auto-hide / 해상도 변경 시 호출. NSApplicationDidChange
/// ScreenParameters / NSWindowDidChangeScreen / NSWindowDidChangeBackingProperties
/// notification 모두 같은 handler. 윈도우 frame 재계산 + layer / drawable /
/// renderer / Terminal / PTY 의 cols/rows 재동기화.
fn tildazScreenChanged(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    syncGeometryAfterScreenChange();
}

fn syncGeometryAfterScreenChange() void {
    if (g_renderer == null) return;
    const tab = g_session.activeTab() orelse return;

    // 1. 새 visibleFrame 기준으로 윈도우 위치 / 크기 재설정.
    repositionWindow();

    // 2. contentView bounds + backingScaleFactor 다시 읽기 (DPI 변경 시 scale
    //    바뀜). layer.frame / contentsScale / drawableSize 갱신.
    const get_cv = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const content_view = get_cv(g_window, objc.sel("contentView")) orelse return;
    const get_rect = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) NSRect);
    const cv_bounds = get_rect(content_view, objc.sel("bounds"));
    const get_double = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) f64);
    const scale_pt = get_double(g_window, objc.sel("backingScaleFactor"));

    const set_layer_frame = objc.objcSend(fn (objc.id, objc.SEL, NSRect) callconv(.c) void);
    set_layer_frame(g_metal_layer, objc.sel("setFrame:"), cv_bounds);
    const set_contents_scale = objc.objcSend(fn (objc.id, objc.SEL, f64) callconv(.c) void);
    set_contents_scale(g_metal_layer, objc.sel("setContentsScale:"), scale_pt);
    const set_drawable_size = objc.objcSend(fn (objc.id, objc.SEL, NSSize) callconv(.c) void);
    set_drawable_size(g_metal_layer, objc.sel("setDrawableSize:"), .{
        .width = cv_bounds.size.width * scale_pt,
        .height = cv_bounds.size.height * scale_pt,
    });

    // 3. Renderer viewport + scale 갱신. font cell_width/height 는 init 시
    //    측정한 값 유지 — 같은 모니터에서 DPI 만 바뀐 경우 (드물지만 가능)
    //    엔 cell metric 도 재측정해야 정확한데 그건 큰 변경이라 후속 작업.
    const vp_w_px: u32 = @intFromFloat(cv_bounds.size.width * scale_pt);
    const vp_h_px: u32 = @intFromFloat(cv_bounds.size.height * scale_pt);
    g_renderer.?.resize(vp_w_px, vp_h_px);

    // 4. 새 viewport 에 맞춰 cols/rows 재계산. cell 크기 같으면 viewport 만
    //    변경. ghostty Terminal + PTY 도 같은 cols/rows 로 resize.
    const cell_w_px = g_renderer.?.font.cell_width;
    const cell_h_px = g_renderer.?.font.cell_height;
    const pad_px: u32 = @intFromFloat(@as(f64, @floatFromInt(TERMINAL_PADDING_PT)) * scale_pt);
    const tab_bar_px: u32 = @intCast(tabBarHeightPx(@floatCast(scale_pt)));
    const top_reserved = pad_px + tab_bar_px;
    const usable_w = if (vp_w_px > 2 * pad_px) vp_w_px - 2 * pad_px else cell_w_px;
    const usable_h = if (vp_h_px > top_reserved + pad_px) vp_h_px - top_reserved - pad_px else cell_h_px;
    const new_cols: u16 = @intCast(@max(1, usable_w / cell_w_px));
    const new_rows: u16 = @intCast(@max(1, usable_h / cell_h_px));

    // 모든 탭의 terminal+pty 를 같이 resize 해야 해요 — 보이지 않는 탭의 grid
    // 도 같은 cols/rows 로 유지 (탭 전환 시 화면 깨짐 방지).
    const active_terminal = tab.terminal;
    if (new_cols != active_terminal.cols or new_rows != active_terminal.rows) {
        for (g_session.tabs.items) |t| {
            t.terminal.resize(g_gpa.allocator(), new_cols, new_rows) catch |err| {
                std.debug.print("[geom] terminal resize failed: {s}\n", .{@errorName(err)});
                continue;
            };
            t.pty.resize(new_cols, new_rows) catch |err| {
                std.debug.print("[geom] pty resize failed: {s}\n", .{@errorName(err)});
            };
        }
        std.debug.print("[geom] screen changed: vp={d}x{d} px, scale={d}, cols={d} rows={d}\n", .{
            vp_w_px, vp_h_px, scale_pt, new_cols, new_rows,
        });
    }
}

/// NSEvent 위치 → 윈도우 좌상단 기준 pixel 좌표 (top-down). 탭바 / cell hit
/// test 에서 공용. 윈도우 밖이면 그대로 반환 (호출처가 음수 / 초과 처리).
fn eventToWindowPx(self_view: objc.id, event: objc.id) struct { x: f32, y: f32 } {
    const get_loc = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) NSPoint);
    const win_loc = get_loc(event, objc.sel("locationInWindow"));
    const convertPoint = objc.objcSend(fn (objc.id, objc.SEL, NSPoint, objc.id) callconv(.c) NSPoint);
    const view_loc = convertPoint(self_view, objc.sel("convertPoint:fromView:"), win_loc, @as(objc.id, null));

    const get_rect = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) NSRect);
    const cv_bounds = get_rect(self_view, objc.sel("bounds"));
    const view_h_pt = cv_bounds.size.height;
    const scale = if (g_renderer) |*r| r.scale else 1.0;

    return .{
        .x = @as(f32, @floatCast(view_loc.x)) * scale,
        .y = @as(f32, @floatCast(view_h_pt - view_loc.y)) * scale,
    };
}

/// NSEvent 의 window 좌표 (Y-up) → terminal grid cell 좌표.
/// `null` = window 밖 또는 padding 영역.
fn eventToCell(self_view: objc.id, event: objc.id) ?terminal_interaction.Cell {
    if (g_renderer == null) return null;
    const tab = g_session.activeTab() orelse return null;

    const xy = eventToWindowPx(self_view, event);
    const scale = g_renderer.?.scale;
    const cell_w_px = g_renderer.?.font.cell_width;
    const cell_h_px = g_renderer.?.font.cell_height;
    const pad_px: f32 = @as(f32, @floatFromInt(TERMINAL_PADDING_PT)) * scale;
    const tab_bar_px: f32 = @floatFromInt(tabBarHeightPx(scale));
    const cell_top_px = pad_px + tab_bar_px;

    // 탭바 영역 + padding 안쪽만 cell. 밖이면 null (탭바 클릭은 별도 dispatch).
    if (xy.x < pad_px or xy.y < cell_top_px) return null;
    const x_in: f32 = xy.x - pad_px;
    const y_in: f32 = xy.y - cell_top_px;

    const col_f = x_in / @as(f32, @floatFromInt(cell_w_px));
    const row_f = y_in / @as(f32, @floatFromInt(cell_h_px));
    if (col_f < 0 or row_f < 0) return null;

    const cols = tab.terminal.cols;
    const rows = tab.terminal.rows;
    const col: u16 = @intCast(@min(@as(u32, @intFromFloat(col_f)), @as(u32, cols) - 1));
    const row: u16 = @intCast(@min(@as(u32, @intFromFloat(row_f)), @as(u32, rows) - 1));
    return .{ .col = col, .row = row };
}

const TabBarHit = struct { tab_index: usize, on_close: bool };

/// 탭바 영역 픽셀 좌표 → (탭 인덱스, close 버튼 hit 여부). 탭바 그리기 공식
/// (`drawTabBar`) 의 좌표와 정확히 같은 hit rect 사용.
fn tabBarHitTest(px: f32, py: f32) ?TabBarHit {
    if (g_renderer == null) return null;
    const r = &g_renderer.?;
    const tab_w_px = @as(f32, @floatFromInt(ui_metrics.TAB_WIDTH_PT)) * r.scale;
    const tab_pad_px = @as(f32, @floatFromInt(ui_metrics.TAB_PADDING_PT)) * r.scale;
    const close_size_px = @as(f32, @floatFromInt(ui_metrics.TAB_CLOSE_SIZE_PT)) * r.scale;
    const tab_bar_h: f32 = @floatFromInt(tabBarHeightPx(r.scale));

    if (px < 0 or py < 0 or py >= tab_bar_h) return null;
    const tab_index_f = px / tab_w_px;
    const tab_index = @as(usize, @intFromFloat(tab_index_f));
    if (tab_index >= g_session.count()) return null; // 탭 옆 빈 영역.

    // close 버튼 hit rect — drawTabBar 의 close_x/close_y 와 동일 공식.
    const tab_x = @as(f32, @floatFromInt(tab_index)) * tab_w_px;
    const close_x_min = tab_x + tab_w_px - close_size_px - tab_pad_px;
    const close_x_max = close_x_min + close_size_px;
    const close_y_min = (tab_bar_h - close_size_px) * 0.5;
    const close_y_max = close_y_min + close_size_px;
    const on_close = (px >= close_x_min and px <= close_x_max and
        py >= close_y_min and py <= close_y_max);

    return .{ .tab_index = tab_index, .on_close = on_close };
}

/// rename 진행 중이면 종료. `commit=true` 면 buf 의 텍스트를 그 탭의 title 로
/// 적용, false 면 단순 cancel.
fn commitOrCancelRename(commit: bool) void {
    if (commit) {
        if (g_rename.commitRequest()) |req| {
            if (req.tab_index < g_session.count()) {
                g_session.tabs.items[req.tab_index].setTitle(req.title);
            }
        }
    }
    g_rename.clear();
}

/// 탭바 클릭 처리 (#111 M11.5). close hit 면 그 탭 정리, 본체 hit 면 활성화.
fn handleTabBarClick(hit: TabBarHit) void {
    if (hit.on_close) {
        g_session.closeTab(hit.tab_index);
        if (g_session.count() == 0) {
            std.debug.print("[tab] last tab closed via close button, terminating tildaz.\n", .{});
            const terminate = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
            terminate(g_app, objc.sel("terminate:"), null);
            return;
        }
        // 2 → 1 전환 시 탭바 사라짐 → cell 영역 늘어남.
        syncTerminalGeometry();
        return;
    }
    _ = g_session.setActiveTab(hit.tab_index);
}

fn tildazMouseDown(self_view: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    if (event == null) return;
    const tab = g_session.activeTab() orelse return;

    // 탭바 영역 클릭 (멀티탭 시) → 탭 전환 / close / drag-begin / rename. cell
    // selection 보다 우선.
    if (g_session.count() >= 2 and g_renderer != null) {
        const xy = eventToWindowPx(self_view, event);
        if (tabBarHitTest(xy.x, xy.y)) |hit| {
            // 더블클릭 (#111 M11.6b) → rename 시작. close 버튼 영역 외에서만.
            const get_count = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_long);
            const click_count = get_count(event, objc.sel("clickCount"));
            if (click_count >= 2 and !hit.on_close) {
                if (hit.tab_index < g_session.count()) {
                    g_rename.begin(hit.tab_index, g_session.tabs.items[hit.tab_index].title());
                }
                return;
            }
            // 일반 클릭이면 진행 중 rename 은 commit + 종료 (Windows 패턴).
            commitOrCancelRename(true);

            if (hit.on_close) {
                handleTabBarClick(hit);
                return;
            }
            // 본체 클릭 → 즉시 활성 전환 + drag-begin. drag 가 5px 이상 이동
            // 안 하면 mouseUp 에서 그냥 click 으로 처리 (= 활성 전환만 효과).
            _ = g_session.setActiveTab(hit.tab_index);
            const tab_w_int: c_int = @intFromFloat(@as(f32, @floatFromInt(ui_metrics.TAB_WIDTH_PT)) * g_renderer.?.scale);
            _ = g_drag.begin(@intFromFloat(xy.x), tab_w_int, g_session.count());
            return;
        }
    }

    // 탭바 외 클릭 시 rename 진행 중이면 commit + 종료.
    commitOrCancelRename(true);
    const cell = eventToCell(self_view, event) orelse return;
    // double-click → word selection.
    const get_count = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_long);
    const click_count = get_count(event, objc.sel("clickCount"));
    if (click_count >= 2) {
        _ = terminal_interaction.selectWord(tab.terminal.screens.active, cell);
        tab.interaction.selection.cancel(); // word selection 자체 완료, drag 모드 X.
        return;
    }
    tab.interaction.selection.begin(tab.terminal.screens.active, cell);
}

fn tildazMouseDragged(self_view: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    if (event == null) return;
    const tab = g_session.activeTab() orelse return;

    // 탭 drag (#111 M11.6a) 가 활성이면 drag 만 처리 — cell selection 무관.
    if (g_drag.active) {
        const xy = eventToWindowPx(self_view, event);
        _ = g_drag.move(@intFromFloat(xy.x));
        return;
    }

    if (!tab.interaction.selection.active) return;
    const cell = eventToCell(self_view, event) orelse return;
    tab.interaction.selection.update(tab.terminal.screens.active, cell);
}

fn tildazMouseUp(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    const tab = g_session.activeTab() orelse return;

    // 탭 drag 완료 (#111 M11.6a). dragging 임계 (5px) 넘었으면 reorder.
    if (g_drag.active) {
        if (g_renderer) |*r| {
            const tab_w_int: c_int = @intFromFloat(@as(f32, @floatFromInt(ui_metrics.TAB_WIDTH_PT)) * r.scale);
            if (g_drag.finish(tab_w_int, g_session.count())) |req| {
                _ = g_session.reorderTabs(req.from, req.to) catch |err| {
                    std.debug.print("[tab] reorder failed: {s}\n", .{@errorName(err)});
                };
            }
        } else {
            g_drag.reset();
        }
        return;
    }

    _ = tab.interaction.selection.finish();
}

/// macOS keycode (kVK_ANSI_*) 의 1..9 → 0-base 탭 인덱스. 1 → 0, 2 → 1 식.
/// 키보드 row 가 keycode 순서가 아니라 매핑이 비균일 (`0x12, 0x13, 0x14,
/// 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19`).
fn keycodeToTabIndex(kc: c_ushort) ?usize {
    return switch (kc) {
        0x12 => 0, // 1
        0x13 => 1, // 2
        0x14 => 2, // 3
        0x15 => 3, // 4
        0x17 => 4, // 5
        0x16 => 5, // 6
        0x1A => 6, // 7
        0x1C => 7, // 8
        0x19 => 8, // 9
        else => null,
    };
}

/// Cmd+W — 활성 탭을 즉시 정리. PTY 자식이 살아 있어도 deinit 의 SIGHUP +
/// fd close 로 정상 hangup 후 종료. 마지막 탭이 닫혔는지는 다음 frame 의
/// drainExitedTabs 가 검사 (closeTab 이 컬렉션에서 즉시 제거하므로 사실 이번
/// frame 끝에 count == 0 일 수 있음 — drainExitedTabs 의 빈 컬렉션 분기로
/// 통일).
fn handleCloseActiveTab() void {
    if (g_session.activeTab() == null) return;
    g_session.closeTab(g_session.active_tab);
    if (g_session.count() == 0) {
        std.debug.print("[tab] last tab closed via Cmd+W, terminating tildaz.\n", .{});
        const terminate = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
        terminate(g_app, objc.sel("terminate:"), null);
        return;
    }
    // 2 → 1 전환 시 탭바 사라져 cell 영역 늘어남. 모든 탭 cols/rows 재동기화.
    syncTerminalGeometry();
}

/// Cmd+T — 활성 탭의 cols/rows 와 같은 크기로 새 탭 생성 후 syncTerminalGeometry
/// 가 1 → 2 전환 시 탭바 등장으로 줄어드는 cell 영역에 맞춰 모든 탭 resize.
fn handleNewTab() void {
    const active = g_session.activeTab() orelse return;
    const cols = active.terminal.cols;
    const rows = active.terminal.rows;
    _ = g_session.createTab(
        cols,
        rows,
        g_max_scrollback,
        g_shell_path,
        &g_extra_env,
        onPtyOutput,
        onPtyExit,
    ) catch |err| {
        std.debug.print("[tab] new tab failed: {s}\n", .{@errorName(err)});
        return;
    };
    // 1 → 2 전환 시 탭바 등장 → cell 영역 줄어듦. 모든 탭 resize.
    syncTerminalGeometry();
}

/// 마우스 휠 / 트랙패드 스크롤 → ghostty Terminal 의 viewport scroll. 양수
/// deltaY (콘텐츠가 아래로 = 손가락 위로) 면 scrollback 의 위쪽 (오래된 내용)
/// 보임. trackpad 의 작은 precise delta 도 그대로 1+ row 단위로 변환.
fn handleCopy() void {
    const tab = g_session.activeTab() orelse return;
    const screen: *ghostty.Screen = tab.terminal.screens.active;
    const sel = screen.selection orelse return;
    const alloc = g_gpa.allocator();
    const text = screen.selectionString(alloc, .{ .sel = sel }) catch return;
    defer alloc.free(text);
    if (text.len == 0) return;

    // NSPasteboard.general → clearContents → setString:forType: NSPasteboardTypeString.
    const NSPasteboard = objc.getClass("NSPasteboard");
    const get_general = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const pb = get_general(NSPasteboard, objc.sel("generalPasteboard"));
    if (pb == null) return;
    const clear = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_long);
    _ = clear(pb, objc.sel("clearContents"));

    const NSString = objc.getClass("NSString");
    const stringWithUTF8 = objc.objcSend(fn (objc.Class, objc.SEL, [*:0]const u8) callconv(.c) objc.id);
    const ns_text = stringWithUTF8(NSString, objc.sel("stringWithUTF8String:"), text.ptr);
    if (ns_text == null) return;

    const setString = objc.objcSend(fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) bool);
    const ns_type = objc.nsString("public.utf8-plain-text"); // = NSPasteboardTypeString
    _ = setString(pb, objc.sel("setString:forType:"), ns_text, ns_type);
}

fn handlePaste() void {
    const tab = g_session.activeTab() orelse return;
    const NSPasteboard = objc.getClass("NSPasteboard");
    const get_general = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const pb = get_general(NSPasteboard, objc.sel("generalPasteboard"));
    if (pb == null) return;

    const stringForType = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.id);
    const ns_type = objc.nsString("public.utf8-plain-text");
    const ns_text = stringForType(pb, objc.sel("stringForType:"), ns_type);
    if (ns_text == null) return;

    const get_len = objc.objcSend(fn (objc.id, objc.SEL, usize) callconv(.c) usize);
    const len = get_len(ns_text, objc.sel("lengthOfBytesUsingEncoding:"), NSUTF8StringEncoding);
    if (len == 0) return;

    const get_utf8 = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) [*:0]const u8);
    const cstr = get_utf8(ns_text, objc.sel("UTF8String"));

    _ = tab.pty.write(cstr[0..len]) catch |err| {
        std.debug.print("[paste] PTY write failed: {s}\n", .{@errorName(err)});
    };
}

fn tildazScrollWheel(_: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const tab = g_session.activeTab() orelse return;
    if (event == null) return;

    const get_delta = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) f64);
    const delta_y = get_delta(event, objc.sel("scrollingDeltaY"));
    if (delta_y == 0) return;

    // ceil/floor 로 작은 값도 1 line 으로. multiplier 1.0 이면 약간 느려서
    // 평소 trackpad 사용감 기준 multiplier ~2.
    const scaled = delta_y * 2.0;
    const lines: isize = if (scaled > 0)
        @as(isize, @intFromFloat(@ceil(scaled)))
    else
        @as(isize, @intFromFloat(@floor(scaled)));
    if (lines == 0) return;

    // delta 부호: 양수 deltaY (위로) → scrollback 위쪽 (older) = delta 음수
    // (ghostty `scrollViewport(.{.delta = -N})` 가 위쪽).
    tab.terminal.scrollViewport(.{ .delta = -lines });
}

fn registerTildazViewClass() !objc.Class {
    const NSView = objc.getClass("NSView");
    const cls = objc.objc_allocateClassPair(NSView, "TildazView", 0) orelse
        return error.ViewSubclassAllocFailed;
    if (!objc.class_addMethod(cls, objc.sel("acceptsFirstResponder"), @ptrCast(&tildazAcceptsFirstResponder), "B@:"))
        return error.ViewSubclassAddMethodFailed;
    // "v@:@" = void 반환, self + _cmd + 한 인자 (NSEvent id).
    if (!objc.class_addMethod(cls, objc.sel("keyDown:"), @ptrCast(&tildazKeyDown), "v@:@"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("scrollWheel:"), @ptrCast(&tildazScrollWheel), "v@:@"))
        return error.ViewSubclassAddMethodFailed;
    // 마우스 selection (drag).
    if (!objc.class_addMethod(cls, objc.sel("mouseDown:"), @ptrCast(&tildazMouseDown), "v@:@"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("mouseDragged:"), @ptrCast(&tildazMouseDragged), "v@:@"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("mouseUp:"), @ptrCast(&tildazMouseUp), "v@:@"))
        return error.ViewSubclassAddMethodFailed;
    // 모니터 / DPI / dock auto-hide 등 screen parameter 변경 알림 handler.
    if (!objc.class_addMethod(cls, objc.sel("screenChanged:"), @ptrCast(&tildazScreenChanged), "v@:@"))
        return error.ViewSubclassAddMethodFailed;

    // NSTextInputClient protocol — IME (한글 / 일본어 / 중국어). 등록한 13
    // 메서드는 ghostty / Terminal.app / 표준 NSView terminal 패턴. `NSRange`
    // = `{_NSRange=QQ}` (location, length 둘 다 unsigned long). `CGRect`
    // = `{CGRect={CGPoint=dd}{CGSize=dd}}`.
    if (!objc.class_addMethod(cls, objc.sel("insertText:replacementRange:"), @ptrCast(&imeInsertText), "v@:@{_NSRange=QQ}"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("insertText:"), @ptrCast(&imeInsertTextSimple), "v@:@"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("setMarkedText:selectedRange:replacementRange:"), @ptrCast(&imeSetMarkedText), "v@:@{_NSRange=QQ}{_NSRange=QQ}"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("unmarkText"), @ptrCast(&imeUnmarkText), "v@:"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("hasMarkedText"), @ptrCast(&imeHasMarkedText), "B@:"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("markedRange"), @ptrCast(&imeMarkedRange), "{_NSRange=QQ}@:"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("selectedRange"), @ptrCast(&imeSelectedRange), "{_NSRange=QQ}@:"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("validAttributesForMarkedText"), @ptrCast(&imeValidAttributes), "@@:"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("attributedSubstringForProposedRange:actualRange:"), @ptrCast(&imeAttrSubstring), "@@:{_NSRange=QQ}^{_NSRange=QQ}"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("characterIndexForPoint:"), @ptrCast(&imeCharIndex), "Q@:{CGPoint=dd}"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("firstRectForCharacterRange:actualRange:"), @ptrCast(&imeFirstRect), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}"))
        return error.ViewSubclassAddMethodFailed;
    if (!objc.class_addMethod(cls, objc.sel("doCommandBySelector:"), @ptrCast(&imeDoCommand), "v@::"))
        return error.ViewSubclassAddMethodFailed;

    // protocol 채택 — 이거 안 하면 inputContext 가 view 를 NSTextInputClient
    // 로 인식 안 해서 interpretKeyEvents 가 routing 안 됨.
    if (objc.objc_getProtocol("NSTextInputClient")) |proto| {
        _ = objc.class_addProtocol(cls, proto);
    } else {
        std.debug.print("[ime] WARNING: NSTextInputClient protocol not found\n", .{});
    }

    objc.objc_registerClassPair(cls);
    return cls;
}

pub fn run() !void {
    std.debug.print("TildaZ macOS v{s} — drop-down terminal (M3).\n", .{build_options.version});

    // 0. Config 읽기 — 잘못된 값 발견 시 macos_config 가 dialog.showFatal 로
    //    다이얼로그 띄우고 즉시 종료 (Windows host 와 동일 정책).
    g_config = macos_config.Config.load(g_gpa.allocator());

    // 1. NSApplication.
    const NSApplication = objc.getClass("NSApplication");
    const sharedApp = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    g_app = sharedApp(NSApplication, objc.sel("sharedApplication")) orelse return error.NSApplicationFailed;

    const setActivationPolicy = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) bool);
    _ = setActivationPolicy(g_app, objc.sel("setActivationPolicy:"), NSApplicationActivationPolicyAccessory);

    try buildMainMenu(g_app);

    // 2. NSWindow (TildazWindow subclass) — borderless styleMask. Default
    //    NSWindow 가 borderless 일 때 `canBecomeKeyWindow == NO` 라서 mainMenu
    //    Cmd+Q 가 dispatch 안 되는 문제가 있는데, subclass 에서 그 method 를
    //    YES 로 override 해 우회. titlebar 자체가 없어 위쪽 32pt offset 도
    //    사라진다 (이게 위 padding 비대칭의 진짜 원인 — Titled mask 가 위쪽
    //    titlebar 영역의 layer drawing 을 시스템이 막던 것).
    const TildazWindow = try registerTildazWindowClass();
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const window_alloc = alloc(TildazWindow, objc.sel("alloc")) orelse return error.NSWindowAllocFailed;

    const initWindow = objc.objcSend(fn (objc.id, objc.SEL, NSRect, c_ulong, c_ulong, bool) callconv(.c) objc.id);
    // 초기 rect 는 placeholder — 곧이어 dock rect 로 덮어쓴다.
    const placeholder = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 800, .height = 400 } };
    const style_mask = NSWindowStyleMaskBorderless;
    g_window = initWindow(
        window_alloc,
        objc.sel("initWithContentRect:styleMask:backing:defer:"),
        placeholder,
        style_mask,
        NSBackingStoreBuffered,
        false,
    ) orelse return error.NSWindowInitFailed;

    // 사용자 드래그 / 이동 OS 차단.
    const setMovable = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    setMovable(g_window, objc.sel("setMovable:"), false);
    // Window level = popUpMenu (101) — dock + menu bar + 다른 앱 위에 표시.
    // floating(3) 은 dock 보다 낮아서 dock 이 우리 윈도우 좌측 (또는 dock
    // 위치) 일부를 가려 padding 비대칭으로 보임. ghostty QuickTerminal 도
    // 동일 이유로 popUpMenu 사용 (QuickTerminalController.swift:435 주석
    // "only popUpMenu and above do what we want").
    const NSPopUpMenuWindowLevel: c_int = 101;
    const setLevel = objc.objcSend(fn (objc.id, objc.SEL, c_int) callconv(.c) void);
    setLevel(g_window, objc.sel("setLevel:"), NSPopUpMenuWindowLevel);

    // 윈도우 자체를 opaque=NO + backgroundColor=clear 로 — borderless 라
    // titlebar 자체는 없지만 system 의 default window background (흰색) 가
    // 보일 수 있다. clear 로 하면 metal layer 가 윈도우 전체에 그대로 보임.
    const setOpaque = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    setOpaque(g_window, objc.sel("setOpaque:"), false);
    const NSColor = objc.getClass("NSColor");
    const clearColor_get = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const clear_color = clearColor_get(NSColor, objc.sel("clearColor"));
    const setBackgroundColor = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setBackgroundColor(g_window, objc.sel("setBackgroundColor:"), clear_color);

    // 3. CAMetalLayer + Metal 렌더러. ghostty 의 layer-hosting 패턴 차용:
    //    `setLayer:` 를 먼저 호출하고 그 *다음* `setWantsLayer:YES` — 이러면
    //    NSView 가 우리 layer 를 직접 host (자동 backing layer 안 만들고).
    //
    //    contentView 를 TildazView 로 교체 — keyDown 받아 PTY 로 forwarding.
    //    default NSView 는 keyDown override 안 되어 키 입력 처리 불가. NSWindow
    //    의 default contentView 는 setContentView: 로 바꿀 수 있다.
    //
    //    참고 — 위쪽 32pt 패딩 비대칭의 진짜 원인은 **PTY non-login shell +
    //    `~/.hushlogin` → row 0 empty** 였고 `argv = {shell, "-l"}` 로 해결됨
    //    (`macos_pty.zig`). Borderless styleMask + safeAreaInsets workaround
    //    는 그 때 무관한 회피책이었어서 이번에 정리. Borderless 라 시스템 top
    //    inset 자체가 0 이라 `additionalSafeAreaInsets` 무력화 코드 불필요.
    const TildazView = try registerTildazViewClass();
    const view_alloc = alloc(TildazView, objc.sel("alloc")) orelse return error.ViewAllocFailed;
    const view_init = objc.objcSend(fn (objc.id, objc.SEL, NSRect) callconv(.c) objc.id);
    const tildaz_view = view_init(view_alloc, objc.sel("initWithFrame:"), placeholder) orelse
        return error.ViewInitFailed;
    const setContentView = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setContentView(g_window, objc.sel("setContentView:"), tildaz_view);

    const contentView_get = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const content_view = contentView_get(g_window, objc.sel("contentView")) orelse return error.ContentViewMissing;

    const CAMetalLayer = objc.getClass("CAMetalLayer");
    const init_obj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const layer_alloc = alloc(CAMetalLayer, objc.sel("alloc")) orelse return error.MetalLayerAllocFailed;
    const layer = init_obj(layer_alloc, objc.sel("init")) orelse return error.MetalLayerInitFailed;

    const device = MTLCreateSystemDefaultDevice() orelse return error.MetalDeviceMissing;

    const setLayer = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setLayer(content_view, objc.sel("setLayer:"), layer);
    const setWantsLayer = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    setWantsLayer(content_view, objc.sel("setWantsLayer:"), true);
    // layer 가 view bounds 를 넘으면 자르기 — drawable 이 view 보다 살짝
    // 커도 화면 밖으로 그려지지 않게 (ghostty Metal.zig 패턴).
    const setClipsToBounds = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    setClipsToBounds(content_view, objc.sel("setClipsToBounds:"), true);
    g_metal_layer = layer;

    // 4. 첫 dock rect 적용 후 표시.
    repositionWindow();
    showWindow();

    // 4.5. screen parameter 변경 알림 등록 — 모니터 추가/제거, 해상도 변경,
    //      DPI 변경, dock auto-hide 토글 모두 syncGeometryAfterScreenChange
    //      한 곳에서 처리.
    {
        const NSNotificationCenter = objc.getClass("NSNotificationCenter");
        const get_center = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
        const center = get_center(NSNotificationCenter, objc.sel("defaultCenter"));
        if (center != null) {
            const notif_names = [_][:0]const u8{
                "NSApplicationDidChangeScreenParametersNotification",
                "NSWindowDidChangeScreenNotification",
                "NSWindowDidChangeBackingPropertiesNotification",
            };
            for (notif_names) |name| {
                const ns_name = objc.nsString(name);
                objc.msgSendVoid4(
                    center,
                    objc.sel("addObserver:selector:name:object:"),
                    tildaz_view,
                    objc.sel("screenChanged:"),
                    ns_name,
                    @as(objc.id, null),
                );
            }
        }
    }

    // layer geometry 동기화. additionalSafeAreaInsets 로 시스템 inset 무력화
    // 했으므로 layer 가 cv_bounds 전체 (titlebar 영역 포함) 를 그대로 사용.
    const get_rect = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) NSRect);
    const cv_bounds = get_rect(content_view, objc.sel("bounds"));
    const set_layer_frame = objc.objcSend(fn (objc.id, objc.SEL, NSRect) callconv(.c) void);
    set_layer_frame(layer, objc.sel("setFrame:"), cv_bounds);

    const backing_scale = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) f64);
    const scale_pt = backing_scale(g_window, objc.sel("backingScaleFactor"));
    const set_contents_scale = objc.objcSend(fn (objc.id, objc.SEL, f64) callconv(.c) void);
    set_contents_scale(layer, objc.sel("setContentsScale:"), scale_pt);
    const set_drawable_size = objc.objcSend(fn (objc.id, objc.SEL, NSSize) callconv(.c) void);
    set_drawable_size(layer, objc.sel("setDrawableSize:"), .{
        .width = cv_bounds.size.width * scale_pt,
        .height = cv_bounds.size.height * scale_pt,
    });

    // 5. CGEventTap 으로 글로벌 키 hotkey 등록 — F1 (toggle), Cmd+Q (terminate).
    //    Carbon RegisterEventHotKey 는 우리 환경 (macOS Tahoe + ad-hoc sign) 에서
    //    silently fail 하므로 Apple DTS 권장 modern API 인 CGEventTap 사용.
    //    Input Monitoring 권한 필요 — 사용자 가 시스템 설정에서 활성화.
    try installEventTap();

    const allocator = g_gpa.allocator();

    // 6. Metal 렌더러 (font 측정 포함). 폰트의 'M' advance + ascent/descent/
    //    leading 으로 cell_width/height 자동 계산 — Windows 의 GetTextMetricsW
    //    + cell_width_scale/line_height_scale 패턴과 동일. config 통합 전까지
    //    `TILDAZ_FONT` 환경변수로 빠르게 다른 폰트 시험 가능 (Monaco / Courier
    //    / "SF Mono" 등).
    const tildaz_font_env = std.process.getEnvVarOwned(allocator, "TILDAZ_FONT") catch null;
    defer if (tildaz_font_env) |s| allocator.free(s);
    const font_family: []const u8 = tildaz_font_env orelse FONT_FAMILY;
    std.debug.print("[font] family={s}\n", .{font_family});

    g_renderer = try macos_metal.MetalRenderer.init(
        allocator,
        device,
        layer,
        font_family,
        FONT_SIZE_PT,
        CELL_WIDTH_SCALE,
        LINE_HEIGHT_SCALE,
        null, // 기본 배경색 (Metal renderer 의 default).
        @floatCast(scale_pt),
    );
    // viewport / cell metrics 모두 pixel 단위로 통일 — pt/px mixing 시 글리프
    // 가 cell 일부만 차지해 깨져 보이는 문제 회피 (#75 댓글 6 의 정정 패턴).
    const vp_w_px: u32 = @intFromFloat(cv_bounds.size.width * scale_pt);
    const vp_h_px: u32 = @intFromFloat(cv_bounds.size.height * scale_pt);
    g_renderer.?.resize(vp_w_px, vp_h_px);

    const cell_w_px: u32 = g_renderer.?.font.cell_width;
    const cell_h_px: u32 = g_renderer.?.font.cell_height;
    const pad_px: u32 = @intFromFloat(@as(f64, @floatFromInt(TERMINAL_PADDING_PT)) * scale_pt);
    std.debug.print("[metal] renderer init: vp={d}x{d} px, scale={d}, cell={d}x{d} px, pad={d} px (font measured)\n", .{
        vp_w_px,
        vp_h_px,
        scale_pt,
        cell_w_px,
        cell_h_px,
        pad_px,
    });

    // 7. PTY + ghostty-vt Terminal (M5.0 + M5.1). cols/rows 는 (viewport −
    //    좌우 padding) ÷ cell. Windows app_controller 의 size − 2*pad 패턴.
    const shell_env = std.process.getEnvVarOwned(allocator, "SHELL") catch null;
    defer if (shell_env) |s| allocator.free(s);
    const shell_path = if (shell_env) |s| s else "/bin/zsh";

    const tab_bar_px: u32 = @intCast(tabBarHeightPx(@floatCast(scale_pt)));
    const top_reserved = pad_px + tab_bar_px;
    const usable_w = if (vp_w_px > 2 * pad_px) vp_w_px - 2 * pad_px else cell_w_px;
    const usable_h = if (vp_h_px > top_reserved + pad_px) vp_h_px - top_reserved - pad_px else cell_h_px;
    const term_cols: u16 = @intCast(@max(1, usable_w / cell_w_px));
    const term_rows: u16 = @intCast(@max(1, usable_h / cell_h_px));

    // Terminal init — Windows session_core 의 max_scrollback 계산식 차용.
    // (라인 수 × 한 라인의 byte size 추정값). config 통합은 후속.
    const max_scroll_lines: usize = 100_000;
    const cap = ghostty.page.std_capacity.adjust(.{ .cols = term_cols }) catch
        @as(ghostty.page.Capacity, .{ .cols = term_cols + 1, .rows = 8, .styles = 16, .grapheme_bytes = 0 });
    const bytes_per_row = ghostty.Page.layout(cap).total_size / cap.rows;
    const max_scrollback = max_scroll_lines * bytes_per_row;

    g_session = .{ .allocator = allocator };

    // TERM / LANG 환경변수: .app launch 시 부모 environ 에 없을 수 있어
    // 명시적 설정. TERM=xterm-256color 는 escape sequence + 256-color 표준.
    // LANG=en_US.UTF-8 은 bash readline 의 multi-byte 처리 활성화 — 안 하면
    // 한글 / 일본어 byte 를 받아도 echo 안 함 (ASCII 모드).
    g_extra_env = .{
        .{ .name = "TERM", .value = "xterm-256color" },
        .{ .name = "LANG", .value = "en_US.UTF-8" },
        .{ .name = "LC_CTYPE", .value = "en_US.UTF-8" },
    };
    g_max_scrollback = max_scrollback;
    g_shell_path = try allocator.dupe(u8, shell_path);

    const tab = try g_session.createTab(
        term_cols,
        term_rows,
        max_scrollback,
        g_shell_path,
        &g_extra_env,
        onPtyOutput,
        onPtyExit,
    );
    std.debug.print("[vt] Terminal init: {d}x{d}, max_scrollback={d} bytes\n", .{ term_cols, term_rows, max_scrollback });
    std.debug.print("[pty] {s} spawned, child_pid={d}\n", .{ shell_path, tab.pty.child_pid });

    // 60fps render timer. CFRunLoopTimer 가 NSApp.run 의 main run loop 에서
    // 주기적으로 fire. callback 은 C 함수 — selector / ObjC class 등록 불필요.
    g_render_timer = CFRunLoopTimerCreate(
        null,
        CFAbsoluteTimeGetCurrent(),
        1.0 / 60.0,
        0,
        0,
        renderTimerFire,
        null,
    );
    CFRunLoopAddTimer(CFRunLoopGetMain(), g_render_timer, kCFRunLoopCommonModes);

    // 7. 이벤트 루프.
    const runApp = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) void);
    runApp(g_app, objc.sel("run"));
}

/// PTY read thread 의 콜백 — 받은 데이터를 ghostty-vt Terminal stream parser 로
/// 라우팅. userdata 는 *Tab — 어느 탭의 출력인지 식별 (멀티탭 단계에서 의미).
///
/// thread safety: 이 콜백은 PTY read thread 에서 호출. 현재 단계에선 UI thread
/// 가 terminal 을 안 읽으므로 race 없음. 후속 milestone 에서 ring buffer +
/// drain 패턴 도입 예정.
fn onPtyOutput(data: []const u8, userdata: ?*anyopaque) void {
    const tab: *macos_session.Tab = @ptrCast(@alignCast(userdata orelse return));
    tab.stream.nextSlice(data);
    g_pty_bytes_received += data.len;
}

/// PTY 자식 (셸) 이 종료되면 read thread 가 호출. main thread 에서 부르는
/// closeTab / NSApp.terminate 와 race 를 피하기 위해 per-tab atomic flag 만
/// set. 실제 정리는 render timer 가 검사 후 처리.
/// userdata 는 *Tab — createTab 에서 startReadThread 시 전달됐어요.
fn onPtyExit(userdata: ?*anyopaque) void {
    const tab: *macos_session.Tab = @ptrCast(@alignCast(userdata orelse return));
    tab.exit_flag.store(true, .release);
}

/// 매 프레임 시작 시 모든 탭의 exit_flag 를 검사, set 된 탭은 closeTab 으로
/// 정리. 마지막 탭이 닫히면 NSApp.terminate. main thread 에서 호출되므로
/// closeTab → Tab.deinit → pty read_thread.join 이 deadlock 없이 정상 진행.
fn drainExitedTabs() bool {
    var any_closed = false;
    var i: usize = 0;
    while (i < g_session.tabs.items.len) {
        const t = g_session.tabs.items[i];
        if (t.exit_flag.load(.acquire)) {
            std.debug.print("[pty] tab {d} ('{s}') exited, closing.\n", .{ i, t.title() });
            g_session.closeTab(i);
            any_closed = true;
            // closeTab 후 인덱스가 시프트되므로 i 증가 안 함 — 다음 element 가
            // 같은 i 위치에 있어요.
        } else {
            i += 1;
        }
    }
    if (g_session.count() == 0) {
        std.debug.print("[pty] last tab closed, terminating tildaz.\n", .{});
        const terminate = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
        terminate(g_app, objc.sel("terminate:"), null);
        return true;
    }
    if (any_closed) {
        // 2 → 1 전환 시 탭바 사라짐 → cell 영역 늘어남. 모든 탭 resize.
        syncTerminalGeometry();
    }
    return false;
}

/// 60fps render timer callback. 윈도우 hidden 이거나 renderer 미초기화면 skip.
/// cell_w/h 는 font 가 측정한 pixel 단위 (Retina backing scale 이미 적용됨).
fn renderTimerFire(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    // Per-tab PTY exit 처리 — 마지막 탭이 정리되면 NSApp.terminate (이번 frame
    // 은 더 진행 안 함).
    if (drainExitedTabs()) return;

    if (!g_visible) return;
    if (g_renderer == null) return;
    const tab = g_session.activeTab() orelse return;
    const cell_w_px: i32 = @intCast(g_renderer.?.font.cell_width);
    const cell_h_px: i32 = @intCast(g_renderer.?.font.cell_height);
    const pad_px: i32 = @intFromFloat(@as(f32, @floatFromInt(TERMINAL_PADDING_PT)) * g_renderer.?.scale);
    const tab_bar_px = tabBarHeightPx(g_renderer.?.scale);
    const preedit: []const u8 = if (g_preedit_len > 0) g_preedit_buf[0..g_preedit_len] else &.{};

    // 탭 제목 stack-allocated slice. 매 프레임 만들지만 alloc 없음 (16 개 한도).
    var titles_buf: [16][]const u8 = undefined;
    const tab_count = @min(g_session.count(), titles_buf.len);
    for (g_session.tabs.items[0..tab_count], 0..) |t, i| {
        titles_buf[i] = t.title();
    }
    const titles = titles_buf[0..tab_count];

    const rename_for_render: ?macos_metal.TabRenameView = if (g_rename.view()) |rv|
        .{ .tab_index = rv.tab_index, .text = rv.text[0..rv.text_len] }
    else
        null;

    g_renderer.?.renderFrame(
        g_metal_layer,
        &tab.terminal,
        cell_w_px,
        cell_h_px,
        tab_bar_px,
        pad_px,
        preedit,
        titles,
        g_session.active_tab,
        rename_for_render,
    );
}

/// CGEventTap 생성 + run loop source 등록 + 활성화. 권한 없으면 사용자 안내 후
/// tap 없이 진행 (mainMenu Cmd+Q 는 동작).
fn installEventTap() !void {
    // active CGEventTap 은 두 권한이 모두 필요: Input Monitoring (preflight) +
    // Accessibility (이벤트 consume / 변조). 한쪽만 있으면 CGEventTapCreate 가
    // null 반환.
    const has_input = CGPreflightListenEventAccess();
    const has_ax = AXIsProcessTrusted();
    if (!has_input or !has_ax) {
        if (!has_input) _ = CGRequestListenEventAccess();
        std.debug.print(
            \\
            \\[Permission required for global hotkeys]
            \\
            \\F1 toggle and Cmd+Q quit (system-wide) need TWO permissions:
            \\
            \\  1. System Settings → Privacy & Security → Input Monitoring
            \\     → toggle "tildaz" ON (or click + and add the .app)
            \\  2. System Settings → Privacy & Security → Accessibility
            \\     → toggle "tildaz" ON (or click + and add the .app)
            \\
            \\Both are required because tildaz needs to *consume* hotkey events
            \\so they don't leak to other apps. After granting, re-run tildaz.
            \\
            \\(Dev-mode note: ad-hoc signed builds get a new identity on each
            \\rebuild, so the permissions must be renewed.)
            \\
            \\Status: Input Monitoring={s}, Accessibility={s}
            \\
        , .{
            if (has_input) "OK" else "missing",
            if (has_ax) "OK" else "missing",
        });
        return;
    }

    const mask: u64 = @as(u64, 1) << @as(u6, @intCast(kCGEventKeyDown));
    g_event_tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        eventTapCallback,
        null,
    );
    if (g_event_tap == null) {
        std.debug.print("CGEventTapCreate failed - permissions may need to be renewed.\n", .{});
        return;
    }

    g_runloop_source = CFMachPortCreateRunLoopSource(null, g_event_tap, 0);
    if (g_runloop_source == null) return error.RunLoopSourceFailed;

    CFRunLoopAddSource(CFRunLoopGetMain(), g_runloop_source, kCFRunLoopCommonModes);
    CGEventTapEnable(g_event_tap, true);
}

/// CGEventTap 콜백 — keycode + modifier 검사해서 config.hotkey 또는 Cmd+Q 면
/// \"이벤트 삼킴\" (null 반환), 아니면 그대로 passthrough (event 반환).
fn eventTapCallback(
    _: ?*anyopaque,
    _: CGEventType,
    event: CGEventRef,
    _: ?*anyopaque,
) callconv(.c) CGEventRef {
    const keycode_i64 = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    const flags = CGEventGetFlags(event);
    const mods = flags & kCGEventFlagsAllModifiers;
    const keycode: u32 = @intCast(keycode_i64);

    // 사용자 toggle hotkey (config.hotkey).
    if (keycode == g_config.hotkey.keycode and mods == g_config.hotkey.modifiers) {
        toggleWindow();
        return null;
    }
    // Cmd+Q — macOS native 종료 단축키. config 와 별개로 hardcoded.
    if (keycode_i64 == kVK_ANSI_Q and mods == kCGEventFlagMaskCommand) {
        const terminate = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
        terminate(g_app, objc.sel("terminate:"), null);
        return null;
    }

    return event; // passthrough.
}

/// 현재 메인 스크린의 dock rect 를 `g_config` 의 `dock_position` / `width` /
/// `height` / `offset` 으로 계산해 윈도우에 적용. macOS 좌표계는
/// **bottom-up** — top dock 은 y = (usable max y) - h.
///
/// Dock 처리:
///   - `visibleFrame` 은 메뉴바 + (보이는) Dock 을 뺀 영역.
///   - Dock 자동 숨김 모드 (또는 좌/우/우측 dock) 면 visibleFrame.minY 가
///     frame.minY 와 거의 같아짐 (4pt 미만의 reserved sliver 제외). 그 경우
///     사용자가 \"화면 끝까지 와 줘\" 라고 지정했으므로 frame.minY 까지 사용.
///   - 메뉴바는 어떤 경우에도 회피해야 하므로 `frame.maxY - visibleFrame.maxY`
///     만큼 위쪽을 빼고 사용.
fn repositionWindow() void {
    const NSScreen = objc.getClass("NSScreen");
    const mainScreen = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const screen = mainScreen(NSScreen, objc.sel("mainScreen")) orelse return;

    // arm64 macOS 의 NSRect 반환은 일반 레지스터 ABI — stret variant 불필요.
    const getRectSel = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) NSRect);
    const visible = getRectSel(screen, objc.sel("visibleFrame"));
    const frame = getRectSel(screen, objc.sel("frame"));

    // Dock 이 화면 하단에 보이고 있는지 추정. 자동 숨김 모드는 4pt 정도의
    // \"reserved sliver\" 가 visibleFrame 에 남는 경우가 있어 임계값 10pt.
    const dock_bottom_height = visible.origin.y - frame.origin.y;
    const dock_visible_at_bottom = dock_bottom_height >= 10.0;

    // 사용 가능한 세로 영역 — 메뉴바는 항상 빼고, Dock 은 보일 때만 빼기.
    const usable_max_y = visible.origin.y + visible.size.height; // = frame.maxY - menubarH
    const usable_min_y = if (dock_visible_at_bottom) visible.origin.y else frame.origin.y;
    const usable_height = usable_max_y - usable_min_y;

    // 가로는 visibleFrame 그대로 — 좌/우 dock 의 경우 visibleFrame.width 가
    // 자동으로 줄어 있음.
    const sw = visible.size.width;
    const sx = visible.origin.x;

    const width_pct: f64 = @floatFromInt(g_config.width_pct);
    const height_pct: f64 = @floatFromInt(g_config.height_pct);
    const offset_pct: f64 = @floatFromInt(g_config.offset_pct);

    const w = sw * width_pct / 100.0;
    const h = usable_height * height_pct / 100.0;

    // dock_position 별로 x / y 결정. macOS 의 bottom-up 좌표계 주의.
    const x: f64 = switch (g_config.dock_position) {
        .left => sx,
        .right => sx + sw - w,
        .top, .bottom => sx + (sw - w) * offset_pct / 100.0,
    };
    const y: f64 = switch (g_config.dock_position) {
        .top => usable_max_y - h,
        .bottom => usable_min_y,
        .left, .right => usable_min_y + (usable_height - h) * offset_pct / 100.0,
    };

    const rect = NSRect{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
    const setFrameDisplay = objc.objcSend(fn (objc.id, objc.SEL, NSRect, bool) callconv(.c) void);
    setFrameDisplay(g_window, objc.sel("setFrame:display:"), rect, true);
}

fn showWindow() void {
    const makeKeyAndOrderFront = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    makeKeyAndOrderFront(g_window, objc.sel("makeKeyAndOrderFront:"), null);
    const activate = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    activate(g_app, objc.sel("activateIgnoringOtherApps:"), true);
    // contentView (TildazView) 를 firstResponder 로 — keyDown 이 view 에 옴.
    const contentView_get = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const cv = contentView_get(g_window, objc.sel("contentView"));
    if (cv != null) {
        const makeFirstResponder = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) bool);
        _ = makeFirstResponder(g_window, objc.sel("makeFirstResponder:"), cv);
    }
    g_visible = true;
}

fn hideWindow() void {
    const orderOut = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    orderOut(g_window, objc.sel("orderOut:"), null);
    g_visible = false;
}

fn toggleWindow() void {
    if (g_visible) {
        hideWindow();
    } else {
        // 화면 / Dock 변화 대비해 매번 dock rect 재계산.
        repositionWindow();
        showWindow();
    }
}

// CGEventTap 보관용 module-level 변수. CFRunLoopAddSource 후에도 OS 가 mach
// port 와 source 를 참조하므로 process 수명동안 살아 있어야 한다.
var g_event_tap: CFMachPortRef = null;
var g_runloop_source: CFRunLoopSourceRef = null;

/// `About TildaZ` menu item action. Selector 는 NSApplication 에 등록되어
/// responder chain 의 마지막 단계 (NSApp) 에서 항상 dispatch 된다 — 윈도우가
/// hide 상태여도 동작.
fn tildazShowAboutAction(self: objc.id, _sel: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = self;
    _ = _sel;
    _ = sender;
    about.showAboutDialog();
}

fn buildMainMenu(app: objc.id) !void {
    const NSMenu = objc.getClass("NSMenu");
    const NSMenuItem = objc.getClass("NSMenuItem");
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const init_obj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);

    // About 핸들러를 NSApplication 인스턴스 메서드로 등록 — Quit (`terminate:`)
    // 과 같은 패턴. 윈도우 hide 상태라도 NSApp 에서 dispatch.
    const NSApplication = objc.getClass("NSApplication");
    if (!objc.class_addMethod(NSApplication, objc.sel("tildazShowAbout:"), @ptrCast(&tildazShowAboutAction), "v@:@"))
        return error.AddAboutMethodFailed;

    const main_menu = init_obj(alloc(NSMenu, objc.sel("alloc")) orelse return error.MenuAllocFailed, objc.sel("init")) orelse return error.MenuInitFailed;

    const app_item = init_obj(alloc(NSMenuItem, objc.sel("alloc")) orelse return error.MenuItemAllocFailed, objc.sel("init")) orelse return error.MenuItemInitFailed;
    const addItem = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    addItem(main_menu, objc.sel("addItem:"), app_item);

    const app_menu = init_obj(alloc(NSMenu, objc.sel("alloc")) orelse return error.MenuAllocFailed, objc.sel("init")) orelse return error.MenuInitFailed;

    const initItem = objc.objcSend(fn (objc.id, objc.SEL, objc.id, objc.SEL, objc.id) callconv(.c) objc.id);

    const about_alloc = alloc(NSMenuItem, objc.sel("alloc")) orelse return error.MenuItemAllocFailed;
    // Ctrl+Shift+I — Windows host 와 동일 키바인딩. Accessory mode 라 메뉴바
    // UI 는 안 보이지만 NSApp 의 `performKeyEquivalent:` 가 mainMenu 를 훑어
    // dispatch 하므로 키만으로 동작 (Cmd+Q 와 같은 메커니즘).
    // shift modifier 가 있으면 keyEquivalent 는 lowercase 로 둠 (Apple HIG).
    const about_item = initItem(
        about_alloc,
        objc.sel("initWithTitle:action:keyEquivalent:"),
        nsString("About TildaZ"),
        objc.sel("tildazShowAbout:"),
        nsString("i"),
    ) orelse return error.AboutItemInitFailed;
    const NSEventModifierFlagShift: c_ulong = 1 << 17;
    const NSEventModifierFlagControl: c_ulong = 1 << 18;
    const setMask = objc.objcSend(fn (objc.id, objc.SEL, c_ulong) callconv(.c) void);
    setMask(about_item, objc.sel("setKeyEquivalentModifierMask:"), NSEventModifierFlagControl | NSEventModifierFlagShift);
    addItem(app_menu, objc.sel("addItem:"), about_item);

    // separator
    const NSMenuItem_class = objc.getClass("NSMenuItem");
    const separatorItem = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const sep = separatorItem(NSMenuItem_class, objc.sel("separatorItem")) orelse return error.SeparatorFailed;
    addItem(app_menu, objc.sel("addItem:"), sep);

    const item_alloc = alloc(NSMenuItem, objc.sel("alloc")) orelse return error.MenuItemAllocFailed;
    const quit_item = initItem(
        item_alloc,
        objc.sel("initWithTitle:action:keyEquivalent:"),
        nsString("Quit TildaZ"),
        objc.sel("terminate:"),
        nsString("q"),
    ) orelse return error.QuitItemInitFailed;
    addItem(app_menu, objc.sel("addItem:"), quit_item);

    const setSubmenu = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setSubmenu(app_item, objc.sel("setSubmenu:"), app_menu);

    const setMainMenu = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setMainMenu(app, objc.sel("setMainMenu:"), main_menu);
}

fn nsString(s: [:0]const u8) objc.id {
    const NSString = objc.getClass("NSString");
    const stringWithUTF8 = objc.objcSend(fn (objc.Class, objc.SEL, [*:0]const u8) callconv(.c) objc.id);
    return stringWithUTF8(NSString, objc.sel("stringWithUTF8String:"), s.ptr);
}

extern fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
extern fn CGColorSpaceRelease(cs: ?*anyopaque) void;
extern fn CGColorCreate(cs: ?*anyopaque, components: [*]const CGFloat) ?*anyopaque;
extern fn CGColorRelease(c: ?*anyopaque) void;

fn createCGColor(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) ?*anyopaque {
    const cs = CGColorSpaceCreateDeviceRGB();
    defer CGColorSpaceRelease(cs);
    const components = [_]CGFloat{ r, g, b, a };
    return CGColorCreate(cs, &components);
}
