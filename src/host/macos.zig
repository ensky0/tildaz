// macOS host — drop-down terminal entry point.
//
// 진행 상태는 이슈 #108 참고.
//
//   M1 — host 골격 + fail-fast 메시지 (5a336db).
//   M2 — NSWindow + CAMetalLayer 빈 화면 + Cmd+Q (ae2328b).
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
const objc = @import("../macos_objc.zig");
const config = @import("../config.zig");
const ghostty = @import("ghostty-vt");
const display_width = @import("../font/display_width.zig");
const macos_metal = @import("../renderer/macos.zig");
const ui_metrics = @import("../ui_metrics.zig");
const terminal = @import("../terminal.zig");
const terminal_interaction = @import("../terminal_interaction.zig");
const tab_interaction = @import("../tab_interaction.zig");
const tab_layout = @import("../tab_layout.zig");
const tab_actions = @import("../tab_actions.zig");
const session_core = @import("../session_core.zig");
const themes = @import("../themes.zig");
const dialog = @import("../dialog.zig");
const messages = @import("../messages.zig");
const about = @import("../about.zig");
const log = @import("../log.zig");
const autostart = @import("../autostart.zig");
const perf = @import("../perf.zig");

pub fn showPanic(msg: []const u8, addr: usize) noreturn {
    log.appendLine("panic", "{s}  return_addr=0x{x}", .{ msg, addr });
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, messages.panic_format, .{ msg, addr }) catch "panic (format failed)";
    dialog.showError(messages.crash_title, text);
    std.process.exit(1);
}

pub fn showFatalRunError(err: anyerror) void {
    log.appendLine("fatal", "run failed: {s}", .{@errorName(err)});
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
// CGEventTap 이 OS 에 의해 자동 비활성화될 때 callback 으로 들어오는 special
// type (#146). callback 응답 timeout 또는 user input race 시 발생. -1 / -2 의
// signed 값이라 c_int (= CGEventType).
const kCGEventTapDisabledByTimeout: CGEventType = -2;
const kCGEventTapDisabledByUserInput: CGEventType = -1;
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
extern fn CFRunLoopRemoveSource(runloop: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef) void;
extern fn CFMachPortInvalidate(port: CFMachPortRef) void;

// GCD — 콜백 안에서 tap 자기 자신을 destroy 하기 위해 main run loop 의
// 다음 turn 으로 작업 deferral. `dispatch_get_main_queue()` 는 macOS 헤더에
// static inline 이라 link symbol 없음 — 실제 export 되는 `_dispatch_main_q`
// 글로벌 변수의 주소를 dispatch_queue_t 로 직접 사용 (Apple SDK 가 헤더에서
// 그렇게 풀어내는 것과 동일).
extern var _dispatch_main_q: anyopaque;
const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;
extern fn dispatch_async_f(queue: *anyopaque, ctx: ?*anyopaque, work: dispatch_function_t) void;

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
extern "c" fn atexit(func: *const fn () callconv(.c) void) c_int;

/// `atexit` 핸들러 — Cmd+Q (NSApp `terminate:`) 가 defer 거치지 않고 `exit()`
/// 직행하므로 run() 의 `defer logStop` 이 안 불린다. `atexit` 는 `exit()`
/// 호출되면 동작하니 여기서 [exit] 라인 기록.
fn atExitLogStop() callconv(.c) void {
    log.logStop(build_options.version);
}

// NSApplication delegate — `applicationShouldTerminate:` 한 메서드만 구현.
// 모든 `terminate:` 호출 (Cmd+Q / 메뉴 / 마지막 탭 종료) 가 진입하기 전에
// macOS 가 이 hook 을 거치게 해 사용자에게 confirm 을 물음 (#116).
const NSTerminateCancel: c_long = 0;
const NSTerminateNow: c_long = 1;

/// 종료 직전 confirm. count == 0 (마지막 탭 PTY exit 후 자동 종료) 만 skip —
/// 이미 사용자 의도된 종료 path. 단일 탭 (count==1) 도 confirm — 사용자 정책.
fn applicationShouldTerminate(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) c_long {
    const n = g_session.count();
    if (n == 0) return NSTerminateNow;
    const plural: []const u8 = if (n == 1) "" else "s";
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, messages.quit_confirm_format, .{ n, plural }) catch
        return NSTerminateNow;
    return if (dialog.showConfirm(messages.quit_confirm_title, msg)) NSTerminateNow else NSTerminateCancel;
}

var g_app_delegate_class: ?objc.Class = null;
var g_app_delegate_instance: objc.id = null;

fn installAppDelegate() !void {
    if (g_app_delegate_instance != null) return;
    const NSObject = objc.getClass("NSObject");
    const cls = objc.objc_allocateClassPair(NSObject, "TildazAppDelegate", 0) orelse
        return error.AppDelegateAllocFailed;
    // 시그니처: 반환 NSApplicationTerminateReply (NSUInteger 호환 c_long),
    //         self (id) + _cmd (SEL) + sender (NSApplication id).
    if (!objc.class_addMethod(cls, objc.sel("applicationShouldTerminate:"), @ptrCast(&applicationShouldTerminate), "Q@:@"))
        return error.AppDelegateAddMethodFailed;
    objc.objc_registerClassPair(cls);
    g_app_delegate_class = cls;

    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const init_obj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const inst = init_obj(alloc(cls, objc.sel("alloc")) orelse return error.AppDelegateInitFailed, objc.sel("init")) orelse
        return error.AppDelegateInitFailed;
    g_app_delegate_instance = inst;

    const setDelegate = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setDelegate(g_app, objc.sel("setDelegate:"), inst);
}

extern fn MTLCreateSystemDefaultDevice() objc.id;

// 글로벌 toggle 상태 — CGEventTap 콜백 (C 시그니처) 이 NSApp / window / config
// 에 접근하려면 어딘가 보관해야 함. M3 단계에서 host 가 한 인스턴스만 띄우므로
// 모듈 전역으로 충분. M5 이후 multi-window / multi-tab 으로 확장 시 userdata
// 포인터 패턴으로 옮길 예정.
var g_app: objc.id = null;
var g_window: objc.id = null;
var g_visible: bool = false;
var g_config: config.Config = .{};
var g_gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
/// 멀티탭 컬렉션 (#111 M11.1). 현재 단계는 데이터 모델만 도입 — 실제로는
/// 단일 탭만 생성. PTY / Terminal / Stream / 마우스 selection 은 모두 활성
/// 탭의 필드. host 코드는 `g_session.activeTab().?.{pty,terminal,...}` 로 access.
///
/// thread safety (M5.1 노트): UI thread 가 terminal 을 안 읽으므로 PTY read
/// thread 가 직접 stream parsing 해도 race 없음. 멀티탭 도입해도 활성 탭만
/// 렌더링 + 입력 받으니 동일 — 단 closeTab 은 read thread 가 살아 있을 때
/// 위험하므로 후속 milestone 에서 join 처리.
var g_session: session_core.SessionCore = undefined;
/// PTY 자식 종료 시 read thread 가 enqueue, main thread (renderTimerFire) 가
/// drain. session_core 의 tab_exit_fn 이 read thread context 에서 불리는데
/// 거기서 closeTabByPtr 직접 호출하면 self-join deadlock — read thread 가
/// 자기 자신을 join 하게 됨. Windows 의 PostMessage 패턴과 같은 의도이지만
/// CFRunLoop 우회 — 단순 mutex-protected queue 로 충분 (renderTimerFire 가
/// main thread 에서 매 frame drain).
var g_pending_close_buf: std.ArrayList(usize) = .{};
var g_pending_close_mutex: std.Thread.Mutex = .{};
/// session_core.prepareActiveFrame 의 8ms throttle (Windows 동등). 매 frame
/// 시작 시 갱신.
var g_last_render_ms: i64 = 0;

/// 윈도우 표시 모드 (#162). Windows `FullscreenMode` 와 동등 — cross-platform.
///   - .none: dock rect (config.dock_position / width / height / offset 기반)
///   - .monitor: NSScreen.frame 통째 = 메뉴바 + dock 까지 덮음 ("전체화면")
///   - .workarea: NSScreen.visibleFrame = 메뉴바 + dock 회피 ("풀스크린")
///
/// 토글 정책: 들어간 키로만 나옴 (self-symmetric). Cmd+Enter 로 .monitor 진입
/// 시 같은 키로만 dock 복귀, Shift+Cmd+Enter 는 no-op. 같은 패턴으로 .workarea.
/// `.monitor ↔ .workarea` 직접 transition 없음.
const FullscreenMode = enum { none, monitor, workarea };
var g_fullscreen_mode: FullscreenMode = .none;
/// 탭 drag-and-drop reorder state (#111 M11.6a). Windows `tab_interaction.DragState`
/// 그대로 사용 — cross-platform 모듈.
var g_drag: tab_interaction.DragState = .{};
/// 탭바 스크롤 오프셋 (픽셀, #117). 탭바 총 너비가 viewport 너비를 초과하면
/// 활성 탭이 보이도록 자동 이동. Windows `App.tab_scroll_x` 와 동일 정책 — 매
/// frame `renderTimerFire` 에서 `ensureActiveTabVisible` 가 갱신, drag 중에는
/// `tildazMouseDragged` 가 직접 갱신.
var g_tab_scroll_x_px: f32 = 0;
/// 사용자가 `<` / `>` 화살표를 눌러 viewport 를 옮긴 상태 (#117). 이 동안
/// `ensureActiveTabVisible` skip — 활성 탭 가려져도 그대로 (Firefox).
/// 활성 탭 변경 / drag reorder 끝 / 새 탭 생성 시 false 로 리셋.
var g_tab_scroll_user_override: bool = false;
/// 탭 이름 변경 state (#111 M11.6b). 더블클릭으로 시작, Enter commit / Escape cancel.
/// 활성화 동안 모든 키 입력 / 텍스트 입력 (IME insertText 포함) 이 PTY 대신
/// 이쪽으로 라우팅.
var g_rename: tab_interaction.RenameState = .{};
/// `tab_actions.Host` 인스턴스 — module-level state (g_session 등) 를 cross-
/// platform helper API 로 노출. 모든 콜백은 mac specific (NSPasteboard, NSApp
/// terminate). invalidate 는 noop — mac 60fps timer 가 자동 redraw.
var g_host: tab_actions.Host = .{
    .session = &g_session,
    .override_ptr = &g_tab_scroll_user_override,
    .invalidate = macHostInvalidate,
    .rename_active = macHostRenameActive,
    .insert_rename_cp = macHostInsertRenameCp,
    .clipboard_copy = macHostClipboardCopy,
    .terminate = macHostTerminate,
};

fn macHostInvalidate(_: *tab_actions.Host) void {
    // mac 은 renderTimerFire 가 60fps 로 자동 호출 — 즉시 redraw 트리거 불필요.
}

fn macHostRenameActive(_: *const tab_actions.Host) bool {
    return g_rename.isActive();
}

fn macHostInsertRenameCp(_: *tab_actions.Host, cp: u21) void {
    _ = g_rename.insertCodepoint(cp);
}

/// NSPasteboard.general → clearContents → setString:forType:NSPasteboardTypeString.
/// text 는 caller 가 비어있지 않음 보장 (`tab_actions.copyActiveSelection` 가
/// len==0 검사 후 호출).
fn macHostClipboardCopy(_: *tab_actions.Host, text: [:0]const u8) void {
    const NSPasteboard = objc.getClass("NSPasteboard");
    const get_general = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const pb = get_general(NSPasteboard, objc.sel("generalPasteboard"));
    if (pb == null) return;
    const clear = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_long);
    _ = clear(pb, objc.sel("clearContents"));

    // text 가 std.heap allocator 에서 온 non-null-terminated slice — NSString
    // 의 stringWithBytes:length:encoding: 사용 (UTF8 = 4).
    const NSString = objc.getClass("NSString");
    const stringWithBytes = objc.objcSend(fn (objc.Class, objc.SEL, [*]const u8, usize, c_ulong) callconv(.c) objc.id);
    const ns_text = stringWithBytes(NSString, objc.sel("stringWithBytes:length:encoding:"), text.ptr, text.len, NSUTF8StringEncoding);
    if (ns_text == null) return;

    const setString = objc.objcSend(fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) bool);
    const ns_type = objc.nsString("public.utf8-plain-text"); // = NSPasteboardTypeString
    _ = setString(pb, objc.sel("setString:forType:"), ns_text, ns_type);
}

fn macHostTerminate(_: *tab_actions.Host) void {
    log.appendLine("tab", "last tab closed, terminating tildaz", .{});
    const terminate_sel = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    terminate_sel(g_app, objc.sel("terminate:"), null);
}
/// 새 탭 생성 시 재사용할 PTY 파라미터들. 첫 탭 init 시 채우고 그 후 변동 없음.
var g_shell_path: []const u8 = "";
var g_extra_env: [5]terminal.ExtraEnv = undefined;
// M5.3 — Metal 렌더러 + timer + cell metrics. cell_width/height 는 폰트의
// 'M' advance / ascent+descent+leading 으로 동적 측정 (Windows 와 동일 패턴).
var g_metal_layer: objc.id = null;
var g_renderer: ?macos_metal.MetalRenderer = null;
var g_render_timer: CFRunLoopTimerRef = null;
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

/// 픽셀 단위 탭 너비 (DPI scale 적용). hit-test / drag / scroll 모두 같은 값.
fn tabWidthPx() f32 {
    if (g_renderer == null) return 0;
    return @as(f32, @floatFromInt(ui_metrics.TAB_WIDTH_PT)) * g_renderer.?.scale;
}

/// `tab_layout.Layout` alias — 본문 정의는 cross-platform 모듈 (#159 Phase 1).
const TabBarLayout = tab_layout.Layout;

/// `Inputs` 채워서 tab_layout.compute 호출. host 별로 g_renderer.scale /
/// g_session.count / g_tab_scroll_x_px 같은 글로벌을 인자로 변환만 함.
fn tabBarLayoutInputs() ?tab_layout.Inputs {
    if (g_renderer == null) return null;
    const r = &g_renderer.?;
    // count >= MAX_TABS 면 plus 버튼 layout 에서 사라짐 — 마지막 탭이 `>` 화살표
    // 에 인접. count < MAX_TABS 일 때만 plus_w 활성. layout / hit-test / drawing
    // 모두 자동 적응.
    const at_limit = g_session.count() >= session_core.MAX_TABS;
    const plus_w = if (at_limit) 0 else @as(f32, @floatFromInt(ui_metrics.TAB_PLUS_W_PT)) * r.scale;
    return .{
        .viewport_w = @floatFromInt(r.vp_width),
        .tab_count = @intCast(g_session.count()),
        .tab_w = tabWidthPx(),
        .arrow_w = @as(f32, @floatFromInt(ui_metrics.TAB_ARROW_W_PT)) * r.scale,
        .plus_w = plus_w,
        .scroll_x = g_tab_scroll_x_px,
    };
}

fn tabBarLayout() TabBarLayout {
    const inputs = tabBarLayoutInputs() orelse return .{
        .tab_area_x = 0,
        .tab_area_w = 0,
        .arrows_visible = false,
        .arrow_w = 0,
        .plus_w = 0,
        .plus_x = 0,
    };
    return tab_layout.compute(inputs);
}

/// 활성 탭이 viewport 안에 보이도록 `g_tab_scroll_x_px` 갱신 (#117 정책 b).
/// drag / 사용자 화살표 override 중에는 호출 안 함.
fn ensureActiveTabVisible() void {
    const inputs = tabBarLayoutInputs() orelse {
        g_tab_scroll_x_px = 0;
        return;
    };
    const layout = tab_layout.compute(inputs);
    g_tab_scroll_x_px = tab_layout.ensureActiveVisible(inputs, layout, @intCast(g_session.active_tab));
}

/// `<` / `>` 화살표 클릭 처리 (#117). viewport 한 step (= 1 탭 너비) 이동 +
/// user_override 활성. 양 끝 clamp.
fn scrollTabsByArrow(dir: tab_layout.ArrowDir) void {
    const inputs = tabBarLayoutInputs() orelse return;
    const layout = tab_layout.compute(inputs);
    if (tab_layout.scrollByArrow(inputs, layout, dir)) |sx| {
        g_tab_scroll_x_px = sx;
        g_tab_scroll_user_override = true;
    }
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
            log.appendLine("geom", "terminal resize failed: {s}", .{@errorName(err)});
            continue;
        };
        t.backend.resize(new_cols, new_rows) catch |err| {
            log.appendLine("geom", "pty resize failed: {s}", .{@errorName(err)});
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

    // Cmd+C / Cmd+V 우선 — IME 와 무관하게 처리.
    const get_flags = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_ulong);
    const flags = get_flags(event, objc.sel("modifierFlags"));

    const NSEventModifierFlagCommand: c_ulong = 1 << 20;
    const cmd = (flags & NSEventModifierFlagCommand) != 0;
    if (cmd) {
        // Windows 패턴 — Cmd 단축키는 진행 중 입력 (rename + terminal preedit)
        // 모두 commit 후 처리. preedit 만 떠 있는 상태로 단축키 → 새 탭 / 다른
        // 동작으로 넘어가면 preedit 이 dangling 됨.
        commitPendingInput(self_view);
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
            tab_actions.switchTab(&g_host, idx);
            return;
        }
        // Shift+Cmd+[ / Shift+Cmd+] = 이전 / 다음 탭. M11.2.
        if (shift and kc == 0x21) {
            tab_actions.prevTab(&g_host);
            return;
        }
        if (shift and kc == 0x1E) {
            tab_actions.nextTab(&g_host);
            return;
        }
        // Shift+Cmd+R = 활성 탭 reset (#162, kc 0x0F = 'R'). Windows
        // Ctrl+Shift+R 동등. session_core.resetActive 가 fullReset + Ctrl+L
        // (\x0c) 송신 — 다음 render frame 이 새 상태 자동 그림 (60fps timer).
        if (shift and kc == 0x0F) {
            tab_actions.resetActive(&g_host);
            return;
        }
        // Cmd+Enter / Shift+Cmd+Enter (kc 0x24 = Return) = 전체화면 / 풀스크린
        // 토글 (#162). Windows Alt+Enter / Shift+Alt+Enter 동등. self-symmetric
        // — 들어간 키로만 나옴.
        if (kc == 0x24) {
            toggleFullscreenMode(if (shift) .workarea else .monitor);
            return;
        }
        // Shift+Cmd+F12 = perf snapshot dump (#160, dev tool). Windows
        // Ctrl+Shift+F12 동등. perf 카운터를 통합 로그 파일에 block 형태로
        // 기록 + 카운터 reset. session_core 가 cross-platform 으로 자동 측정.
        if (shift and kc == 0x6F) {
            perf.dumpAndReset("snapshot");
            return;
        }
        // 다른 Cmd+key 는 mainMenu 가 처리 (Cmd+Q 등).
        // PTY 로 forward 안 함.
        return;
    }

    // rename (#111 M11.6b) 진행 중이면 비-Cmd 키는 모두 interpretKeyEvents 로
    // 위임 → IME / NSResponder 가 imeInsertText / imeDoCommand 콜백 호출 →
    // 거기서 RenameState 로 라우팅. PTY 로 안 흘림.
    if (g_rename.isActive()) {
        // line begin/end navigation 직접 keyCode intercept — interpretKeyEvents
        // 의 StandardKeyBinding dispatch 가 우리 custom NSView 에선 일부 키
        // (Home/End fn 변형, ^a/^e) 에 안 잡히는 케이스 발견. 신뢰성 위해 직접.
        // Home/End 는 fn+Left/Right (Apple 노트북) 와 외장 키보드 Home/End 키
        // 모두 keyCode 115/119. Ctrl+A/E 는 keyCode 0/14 + Ctrl modifier.
        const NSEventModifierFlagControlEarly: c_ulong = 1 << 18;
        const ctrl_early = (flags & NSEventModifierFlagControlEarly) != 0;
        const get_kc_early = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_ushort);
        const kc_early = get_kc_early(event, objc.sel("keyCode"));
        const rename_nav: ?tab_interaction.RenameKey = blk: {
            if (kc_early == 115) break :blk .home;
            if (kc_early == 119) break :blk .end;
            if (ctrl_early and kc_early == 0) break :blk .home; // Ctrl+A
            if (ctrl_early and kc_early == 14) break :blk .end; // Ctrl+E
            break :blk null;
        };
        if (rename_nav) |k| {
            // preedit 활성 시 먼저 rename buf 로 commit 후 cursor 이동 — native
            // textbox 동작 (자모 보존). preedit 없으면 no-op.
            commitPreeditPreserving(self_view);
            _ = g_rename.handleKey(k);
            const setNeeds = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
            setNeeds(self_view, objc.sel("setNeedsDisplay:"), true);
            return;
        }
        const NSArray = objc.getClass("NSArray");
        const arrayWithObject = objc.objcSend(fn (objc.Class, objc.SEL, objc.id) callconv(.c) objc.id);
        const array = arrayWithObject(NSArray, objc.sel("arrayWithObject:"), event);
        const interpretKeyEvents = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
        interpretKeyEvents(self_view, objc.sel("interpretKeyEvents:"), array);
        return;
    }

    // Ctrl+key (#121) — ASCII control char (예: Ctrl+C = 0x03 SIGINT).
    // Windows `WM_CHAR` 가 자동 변환하는 패턴을 macOS 는 직접. NSEvent 의
    // `characters` 가 modifier 적용된 char — Ctrl+C 누르면 characters="\x03".
    //
    // **IME 조합 중에도** Ctrl+key 는 그대로 PTY 로 보낸다 — shell 의 Ctrl+C
    // 는 "현재 입력 라인 버리기" 의도라 한글 조합도 같이 버리는 게 자연스러움.
    // IME 의 markedText 는 `discardMarkedText` 로 reset 한 후 PTY write.
    // (이전 분기는 g_marked_len==0 일 때만 했어서 한글 조합 중 Ctrl+C 가 IME
    // 의 interpretKeyEvents 로 흘러 SIGINT 안 갔음.)
    const NSEventModifierFlagControl: c_ulong = 1 << 18;
    const NSEventModifierFlagCommandKD: c_ulong = 1 << 20;
    const ctrl = (flags & NSEventModifierFlagControl) != 0;
    const cmd_too = (flags & NSEventModifierFlagCommandKD) != 0;

    // Cmd 가 같이 눌린 ctrl+cmd 조합은 macOS system shortcut (Ctrl+Cmd+Space =
    // Show Emoji & Symbols 등) 의 표식 — PTY 로 안 흘리고 mainMenu 의 menu
    // item keyEquivalent 로 라우팅 (#130). 일반 Ctrl+C (Cmd 없음) 는 그대로
    // PTY 직송.
    if (ctrl and !cmd_too) {
        const get_chars = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
        const chars = get_chars(event, objc.sel("characters"));
        if (chars != null) {
            const get_len = objc.objcSend(fn (objc.id, objc.SEL, usize) callconv(.c) usize);
            const len = get_len(chars, objc.sel("lengthOfBytesUsingEncoding:"), NSUTF8StringEncoding);
            if (len > 0) {
                const get_utf8 = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) [*:0]const u8);
                const cstr = get_utf8(chars, objc.sel("UTF8String"));
                const ctrl_c = (len == 1 and cstr[0] == 0x03);
                if (g_marked_len > 0) {
                    // Ctrl+C 는 line abort 의미라 preedit *discard*. 다른
                    // Ctrl+key (Ctrl+A/E/L/D 등) 은 *commit* — 입력 중인 자모
                    // 보존 후 Ctrl char 발신 (native textbox / iTerm2 동등).
                    if (!ctrl_c) {
                        tab.queueWrite(g_preedit_buf[0..g_preedit_len]);
                    }
                    const get_ic = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
                    const ic = get_ic(self_view, objc.sel("inputContext"));
                    if (ic != null) {
                        const discard = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) void);
                        discard(ic, objc.sel("discardMarkedText"));
                    }
                    g_marked_len = 0;
                    g_preedit_len = 0;
                }
                // Ctrl+C (SIGINT) 만 큐 우회 + 큐 reset — paste 등으로 가득찬
                // write_queue 뒤에 enqueue 되면 셸이 SIGINT 늦게 받아 "Ctrl+C
                // 안 먹힌다" 로 보임.
                if (ctrl_c) {
                    tab.interruptWrite(cstr[0..len]);
                } else {
                    tab.queueWrite(cstr[0..len]);
                }
                return;
            }
        }
    }

    // IME 가 조합 중이 아니면 화살표 / F-key / nav 는 직접 escape sequence
    // (성능 + 정확성). 조합 중이면 interpretKeyEvents 로 보내 IME 가 음절
    // commit 후 doCommandBySelector 로 우리에게 위임 — 우리 imeDoCommand 가
    // escape sequence write.
    if (g_marked_len == 0) {
        const get_keycode = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_ushort);
        const keycode = get_keycode(event, objc.sel("keyCode"));

        const NSEventModifierFlagShift: c_ulong = 1 << 17;
        const NSEventModifierFlagOption: c_ulong = 1 << 19;
        const shift = (flags & NSEventModifierFlagShift) != 0;

        // Esc — emoji picker 가 떠 있으면 dismiss (#130 follow-up). modifier
        // 없는 단순 Esc 만 — Cmd / ctrl 은 위 분기에서 처리 끝 (cmd 는 mainMenu,
        // ctrl-only 는 PTY 직송). shift / option 도 없을 때만. picker 의 visibility
        // 는 `isEmojiPickerOpen()` 이 NSApp.orderedWindows 직접 query — boolean
        // 추적의 stale 문제 회피.
        if (keycode == 53 and !shift and (flags & NSEventModifierFlagOption) == 0 and isEmojiPickerOpen()) {
            const orderFront = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
            orderFront(g_app, objc.sel("orderFrontCharacterPalette:"), null);
            return;
        }

        // Shift+PgUp / Shift+PgDn — viewport scrollback. Windows
        // `session_core.scrollActive` 와 같은 *한 페이지 (visible rows)* 단위.
        // PTY 로 안 흘림.
        if (shift) {
            const rows: isize = @intCast(tab.terminal.rows);
            if (keycode == 116) { // kVK_PageUp — 위쪽 (older).
                tab.terminal.scrollViewport(.{ .delta = -rows });
                return;
            }
            if (keycode == 121) { // kVK_PageDown — 아래쪽 (newer).
                tab.terminal.scrollViewport(.{ .delta = rows });
                return;
            }
        }

        if (keyCodeToEscape(keycode)) |esc| {
            tab.queueWrite(esc);
            return;
        }
    }

    // preedit 활성 + nav 키 (Home/End/Arrows/PgUp/PgDn 등) — interpretKeyEvents
    // 가 Home/End 같은 일부 키에 doCommandBySelector dispatch 안 하는 케이스
    // (IME 가 finalize 만 하고 selector 안 보냄). 직접 keyCode 검사 후 preedit
    // commit + escape 발신.
    if (g_marked_len > 0) {
        const get_keycode2 = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_ushort);
        const keycode2 = get_keycode2(event, objc.sel("keyCode"));
        if (keyCodeToEscape(keycode2)) |esc| {
            commitPreeditPreserving(self_view);
            tab.queueWrite(esc);
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

    tab.queueWrite(cstr[0..len]);
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
            // Home/End 물리 키 — mac Cocoa StandardKeyBinding 이 NSHome/NSEnd
            // FunctionKey 를 moveTo*OfDocument: 으로 dispatch (single-line
            // 이라 line begin/end 와 동등).
            else if (cmd_sel == objc.sel("moveToBeginningOfDocument:")) .home
            else if (cmd_sel == objc.sel("moveToEndOfDocument:")) .end
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
    // Home/End 키 (preedit 활성 → IME finalize 후 nav selector 로 dispatch).
    // Document/Line/Paragraph 셋 다 매핑 — 사용자 키보드 / 키바인딩에 따라 다른
    // selector 가 dispatch 될 수 있음.
    else if (cmd_sel == objc.sel("moveToBeginningOfDocument:"))
        "\x1b[H"
    else if (cmd_sel == objc.sel("moveToEndOfDocument:"))
        "\x1b[F"
    else if (cmd_sel == objc.sel("moveToBeginningOfLine:"))
        "\x1b[H"
    else if (cmd_sel == objc.sel("moveToEndOfLine:"))
        "\x1b[F"
    else if (cmd_sel == objc.sel("moveToBeginningOfParagraph:"))
        "\x1b[H"
    else if (cmd_sel == objc.sel("moveToEndOfParagraph:"))
        "\x1b[F"
    else
        null;
    if (bytes) |b| {
        tab.queueWrite(b);
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
                log.appendLine("geom", "terminal resize failed: {s}", .{@errorName(err)});
                continue;
            };
            t.backend.resize(new_cols, new_rows) catch |err| {
                log.appendLine("geom", "pty resize failed: {s}", .{@errorName(err)});
            };
        }
        log.appendLine("geom", "screen changed: vp={d}x{d}px scale={d:.2} cols={d} rows={d}", .{
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

const TabBarHit = tab_layout.TabHit;
const TabBarArea = tab_layout.Area;

/// 탭바 영역 hit-area 분기 (#117). 화살표 / + 영역에서는 별도 처리, tab_area
/// 안에서는 `tabBarTabHitTest` 가 탭 인덱스 + close 버튼 hit 여부 계산.
fn tabBarHitArea(px: f32, py: f32, layout: TabBarLayout) TabBarArea {
    if (g_renderer == null) return .none;
    const r = &g_renderer.?;
    const tab_bar_h: f32 = @floatFromInt(tabBarHeightPx(r.scale));
    return tab_layout.hitArea(px, py, tab_bar_h, layout);
}

/// tab_area 안에서 px → (탭 인덱스, close 버튼 hit). 호출자가 먼저 hit-area 가
/// `.tab_area` 인지 검사.
fn tabBarTabHitTest(px: f32, py: f32, layout: TabBarLayout) ?TabBarHit {
    if (g_renderer == null) return null;
    const r = &g_renderer.?;
    const tab_w_px = @as(f32, @floatFromInt(ui_metrics.TAB_WIDTH_PT)) * r.scale;
    const tab_pad_px = @as(f32, @floatFromInt(ui_metrics.TAB_PADDING_PT)) * r.scale;
    const close_size_px = @as(f32, @floatFromInt(ui_metrics.TAB_CLOSE_SIZE_PT)) * r.scale;
    const tab_bar_h: f32 = @floatFromInt(tabBarHeightPx(r.scale));
    return tab_layout.hitTab(
        px,
        py,
        layout,
        tab_w_px,
        tab_pad_px,
        close_size_px,
        tab_bar_h,
        g_tab_scroll_x_px,
        @intCast(g_session.count()),
    );
}

/// rename 진행 중이면 종료. `commit=true` 면 buf 의 텍스트를 그 탭의 title 로
/// 적용, false 면 단순 cancel.
fn commitOrCancelRename(commit: bool) void {
    if (commit) {
        if (g_rename.commitRequest()) |req| {
            if (req.tab_index < g_session.count()) {
                g_session.tabs.items[req.tab_index].setCustomTitle(req.title);
            }
        }
    }
    g_rename.clear();
}

/// IME preedit (g_preedit_buf) 을 적절한 sink 로 commit + IME 상태 클리어.
/// rename 은 *유지*. 호출 후 typing 계속 가능. (rename 끝낼 때는 후속
/// commitOrCancelRename 호출.)
/// - rename 활성: preedit 자모 rename buf 에 cursor 위치로 insert
/// - rename 비활성: preedit 자모 활성 탭 PTY 로 직송
fn commitPreeditPreserving(self_view: objc.id) void {
    if (g_preedit_len == 0) return;
    if (g_rename.isActive()) {
        var iter = std.unicode.Utf8Iterator{ .bytes = g_preedit_buf[0..g_preedit_len], .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            if (cp >= 0x20) _ = g_rename.insertCodepoint(cp);
        }
    } else {
        g_session.queueInputToActive(g_preedit_buf[0..g_preedit_len]);
    }
    g_preedit_len = 0;
    g_marked_len = 0;
    const get_ic = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const ic = get_ic(self_view, objc.sel("inputContext"));
    if (ic != null) {
        const discard = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) void);
        discard(ic, objc.sel("discardMarkedText"));
    }
}

/// 진행 중인 모든 입력 (rename text + IME preedit) 을 적절한 곳으로 확정 +
/// IME 상태 클리어. focus 이탈 / 단축키 등 "지금 멈춰" 시점에 호출.
/// - rename 활성 + preedit: preedit 자모를 rename buf 로 commit, rename 도 commit
/// - rename 비활성 + terminal preedit: preedit 을 활성 탭 PTY 로 commit
/// 둘 다 native textbox / Win IME 동등 동작 (cancel 아님).
/// (#164 follow-up — mac Cocoa markedText 는 click / 단축키 시 자동 cancel 안 함)
fn commitPendingInput(self_view: objc.id) void {
    commitPreeditPreserving(self_view);
    commitOrCancelRename(true);
}

/// 탭바 클릭 처리 (#111 M11.5). close hit 면 그 탭 정리, 본체 hit 면 활성화.
fn handleTabBarClick(hit: TabBarHit) void {
    if (hit.on_close) {
        if (tab_actions.closeIndex(&g_host, hit.tab_index) == .changed) syncTerminalGeometry();
        return;
    }
    _ = g_session.setActiveTab(hit.tab_index);
}

/// rename 활성 탭의 text 영역 안 마우스 클릭 시 cursor 위치 변경 후 true.
/// 영역 밖 / 다른 탭 / close 버튼 / 터미널 등은 false → caller 가 commit.
fn tryRenameClickMoveCursor(self_view: objc.id, event: objc.id) bool {
    const rv = g_rename.view() orelse return false;
    if (g_renderer == null or g_session.count() < 2) return false;

    const r = &g_renderer.?;
    const xy = eventToWindowPx(self_view, event);
    const layout = tabBarLayout();

    // 탭바 안 + tab_area 안만.
    if (tabBarHitArea(xy.x, xy.y, layout) != .tab_area) return false;
    const hit = tabBarTabHitTest(xy.x, xy.y, layout) orelse return false;
    if (hit.tab_index != rv.tab_index or hit.on_close) return false;

    // preedit 활성 시 manual commit — preedit 자모 들을 현재 cursor 위치 다음에
    // insert. 그 후 IME marked text state 도 정리 (discardMarkedText). native
    // textbox UX (#164 follow-up).
    if (g_preedit_len > 0) {
        var commit_iter = std.unicode.Utf8Iterator{ .bytes = g_preedit_buf[0..g_preedit_len], .i = 0 };
        while (commit_iter.nextCodepoint()) |cp| {
            if (cp >= 0x20) _ = g_rename.insertCodepoint(cp);
        }
        g_preedit_len = 0;
        g_marked_len = 0;
        const get_ic = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
        const ic = get_ic(self_view, objc.sel("inputContext"));
        if (ic != null) {
            const discard = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) void);
            discard(ic, objc.sel("discardMarkedText"));
        }
    }

    // commit 반영된 새 view + mouse → byte 매핑.
    const rv_new = g_rename.view() orelse return false;
    const tab_w_px: f32 = @as(f32, @floatFromInt(ui_metrics.TAB_WIDTH_PT)) * r.scale;
    const tab_pad_px: f32 = @as(f32, @floatFromInt(ui_metrics.TAB_PADDING_PT)) * r.scale;
    const close_size_px: f32 = @as(f32, @floatFromInt(ui_metrics.TAB_CLOSE_SIZE_PT)) * r.scale;
    const cw: f32 = @floatFromInt(r.font.cell_width);
    const tab_x = @as(f32, @floatFromInt(rv_new.tab_index)) * tab_w_px - g_tab_scroll_x_px + layout.tab_area_x;
    const text_x_start = tab_x + tab_pad_px;
    const max_text_w = tab_w_px - close_size_px - tab_pad_px * 3;

    if (tab_layout.renameTextHit(rv_new.text[0..rv_new.text_len], g_rename.scroll_offset, text_x_start, cw, max_text_w, xy.x)) |new_byte| {
        g_rename.setCursor(new_byte);
        return true;
    }
    return false;
}

fn tildazMouseDown(self_view: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    if (event == null) return;
    const tab = g_session.activeTab() orelse return;

    // rename 활성 탭의 text 영역 안 클릭 → cursor 위치만 변경 (commit X). native
    // textbox UX (#164 follow-up). 그 외 (다른 탭 / close 버튼 / terminal 등)
    // 는 기존 동작 — commit + 다른 logic.
    if (tryRenameClickMoveCursor(self_view, event)) return;

    // 어떤 클릭이든 진행 중 rename 우선 commit. 더블클릭의 경우 commit 후 새
    // rename begin (clear → begin 순서) 라 영향 없음. preedit / marked text 도
    // cancel — terminal click 시 cell preedit 으로 옮겨가지 않게.
    commitPendingInput(self_view);

    // 스크롤바 영역 클릭 (#123) — Windows app_controller.zig:488-498 패턴.
    // cell selection / 탭바 클릭보다 우선.
    if (g_renderer != null) {
        const xy = eventToWindowPx(self_view, event);
        const sbw_px: f32 = @as(f32, @floatFromInt(ui_metrics.SCROLLBAR_W_PT)) * g_renderer.?.scale;
        const vp_w_f: f32 = @floatFromInt(g_renderer.?.vp_width);
        if (xy.x >= vp_w_f - sbw_px) {
            tab.interaction.scrollbar.begin();
            scrollbarScrollToY(xy.y);
            return;
        }
    }

    // 탭바 영역 클릭 (멀티탭 시) → 화살표 / + / 탭 전환 / close / drag-begin /
    // rename.
    if (g_session.count() >= 2 and g_renderer != null) {
        const xy = eventToWindowPx(self_view, event);
        const layout = tabBarLayout();
        switch (tabBarHitArea(xy.x, xy.y, layout)) {
            .left_arrow => {
                if (layout.left_enabled) scrollTabsByArrow(.left);
                return;
            },
            .right_arrow => {
                if (layout.right_enabled) scrollTabsByArrow(.right);
                return;
            },
            .plus => {
                handleNewTab();
                return;
            },
            .none => {
                // 탭바 영역인데 어떤 버튼/탭에도 속하지 않음 (이론상 거의 없음). 무시.
                return;
            },
            .tab_area => {
                if (tabBarTabHitTest(xy.x, xy.y, layout)) |hit| {
                    const get_count = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_long);
                    const click_count = get_count(event, objc.sel("clickCount"));
                    // 더블클릭 (close 버튼 외) → rename 시작.
                    if (click_count >= 2 and !hit.on_close) {
                        if (hit.tab_index < g_session.count()) {
                            const t = g_session.tabs.items[hit.tab_index];
                            g_rename.begin(hit.tab_index, t.title[0..t.title_len]);
                        }
                        return;
                    }
                    if (hit.on_close) {
                        handleTabBarClick(hit);
                        return;
                    }
                    // 본체 클릭 → 활성 전환 + drag-begin. DragState world 좌표.
                    _ = g_session.setActiveTab(hit.tab_index);
                    g_tab_scroll_user_override = false;
                    const tab_w_int: c_int = @intFromFloat(@as(f32, @floatFromInt(ui_metrics.TAB_WIDTH_PT)) * g_renderer.?.scale);
                    const world_x: f32 = (xy.x - layout.tab_area_x) + g_tab_scroll_x_px;
                    _ = g_drag.begin(@intFromFloat(world_x), tab_w_int, g_session.count());
                    return;
                }
                // tab_area 안인데 탭에는 안 맞음 (마지막 탭 우측 빈 공간 등). 무시.
                return;
            },
        }
    }
    const cell = eventToCell(self_view, event) orelse return;
    // double-click → word selection + 자동 copy (Windows `selectWordAt` 와 동등).
    const get_count = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_long);
    const click_count = get_count(event, objc.sel("clickCount"));
    if (click_count >= 2) {
        if (terminal_interaction.selectWord(tab.terminal.screens.active, cell)) {
            handleCopy();
        }
        tab.interaction.selection.cancel(); // word selection 자체 완료, drag 모드 X.
        return;
    }
    tab.interaction.selection.begin(tab.terminal.screens.active, cell);
}

fn tildazMouseDragged(self_view: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    if (event == null) return;
    const tab = g_session.activeTab() orelse return;

    // 스크롤바 drag (#123) — mouseDown 에서 begin 했으면 mouseDragged 마다
    // scrollToY 로 thumb 위치 동기화.
    if (tab.interaction.scrollbar.active) {
        const xy = eventToWindowPx(self_view, event);
        scrollbarScrollToY(xy.y);
        return;
    }

    // 탭 drag (#111 M11.6a) 가 활성이면 drag 만 처리 — cell selection 무관.
    if (g_drag.active) {
        const xy = eventToWindowPx(self_view, event);
        // #117 drag auto-scroll. mouse_x 가 *탭 영역* 의 좌/우 끝 가까이면 scroll
        // 한 step 이동. drag.move 에는 *갱신된* world 좌표 (= local + scroll).
        const layout = tabBarLayout();
        if (g_renderer) |*r| {
            const tab_w = tabWidthPx();
            const total = tab_w * @as(f32, @floatFromInt(g_session.count()));
            const vp = layout.tab_area_w;
            if (vp > 0 and total > vp) {
                const max_sx = total - vp;
                const edge: f32 = 32 * r.scale;
                const step: f32 = 16 * r.scale;
                const local_x = xy.x - layout.tab_area_x;
                if (local_x < edge and g_tab_scroll_x_px > 0) {
                    g_tab_scroll_x_px = @max(0, g_tab_scroll_x_px - step);
                } else if (local_x > vp - edge and g_tab_scroll_x_px < max_sx) {
                    g_tab_scroll_x_px = @min(max_sx, g_tab_scroll_x_px + step);
                }
            }
        }
        const world_x = (xy.x - layout.tab_area_x) + g_tab_scroll_x_px;
        _ = g_drag.move(@intFromFloat(world_x));
        return;
    }

    if (!tab.interaction.selection.active) return;
    const cell = eventToCell(self_view, event) orelse return;
    tab.interaction.selection.update(tab.terminal.screens.active, cell);
}

fn tildazMouseUp(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    const tab = g_session.activeTab() orelse return;

    // 스크롤바 drag 종료 (#123).
    if (tab.interaction.scrollbar.active) {
        tab.interaction.scrollbar.end();
        return;
    }

    // 탭 drag 완료 (#111 M11.6a). dragging 임계 (5px) 넘었으면 reorder.
    if (g_drag.active) {
        if (g_renderer) |*r| {
            const tab_w_int: c_int = @intFromFloat(@as(f32, @floatFromInt(ui_metrics.TAB_WIDTH_PT)) * r.scale);
            if (g_drag.finish(tab_w_int, g_session.count())) |req| {
                _ = g_session.reorderTabs(req.from, req.to) catch |err| {
                    log.appendLine("tab", "reorder failed: {s}", .{@errorName(err)});
                };
                // drag reorder 끝 — 활성 탭 위치 변경, ensure 재가동 (#117).
                g_tab_scroll_user_override = false;
            }
        } else {
            g_drag.reset();
        }
        return;
    }

    // 셀 selection finish — Windows `selection.finish()` → `copyToClipboard`
    // 패턴 (#122). selection 변화 있었으면 자동 clipboard copy. Cmd+C 없이도
    // 드래그 후 즉시 paste 가능.
    if (tab.interaction.selection.finish()) {
        handleCopy();
    }
}

/// 우클릭 paste (#119). cmd.exe console 표준 패턴 — Windows 의 WM_RBUTTONDOWN
/// (변경 후) 와 동일.
fn tildazRightMouseDown(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    handlePaste();
}

/// 스크롤바 클릭 / 드래그 시 thumb 위치 따라 viewport scroll (#123).
/// Windows app_controller.zig:233-266 `scrollToY` 패턴 그대로.
/// `mouse_y_px` 는 윈도우 좌상 기준 top-down pixel.
fn scrollbarScrollToY(mouse_y_px: f32) void {
    const tab = g_session.activeTab() orelse return;
    if (g_renderer == null) return;
    const r = &g_renderer.?;

    const screen = tab.terminal.screens.active;
    const sb = screen.pages.scrollbar();
    if (sb.total <= sb.len) return;

    const pad_px: f32 = @as(f32, @floatFromInt(TERMINAL_PADDING_PT)) * r.scale;
    const tab_bar_px: f32 = @floatFromInt(tabBarHeightPx(r.scale));
    const cell_top_px = pad_px + tab_bar_px;
    const vp_h_f: f32 = @floatFromInt(r.vp_height);
    const track_h: f32 = vp_h_f - cell_top_px;
    if (track_h <= 0) return;

    const sb_min: f32 = @as(f32, @floatFromInt(ui_metrics.SCROLLBAR_MIN_THUMB_H_PT)) * r.scale;
    const ratio_px = track_h / @as(f32, @floatFromInt(sb.total));
    const thumb_h = @max(sb_min, ratio_px * @as(f32, @floatFromInt(sb.len)));
    const available = track_h - thumb_h;
    if (available <= 0) return;

    const rel_y = @max(0, mouse_y_px - cell_top_px);
    const clamped_y = @min(rel_y, available);
    const scroll_ratio = clamped_y / available;
    const target_row: usize = @intFromFloat(scroll_ratio * @as(f32, @floatFromInt(sb.total - sb.len)));

    const current: isize = @intCast(sb.offset);
    const target: isize = @intCast(target_row);
    const delta = target - current;
    if (delta != 0) {
        tab.terminal.scrollViewport(.{ .delta = delta });
    }
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
    // closeActive helper 가 마지막 탭 → terminate, 그 외 → override clear +
    // invalidate. mac 의 사후 처리는 .changed 일 때 syncTerminalGeometry 만 —
    // 2 → 1 전환에서 탭바 사라져 cell 영역 늘어나는 케이스 대응 (#127).
    if (tab_actions.closeActive(&g_host) == .changed) syncTerminalGeometry();
}

/// Cmd+T — 활성 탭의 cols/rows 와 같은 크기로 새 탭 생성 후 syncTerminalGeometry
/// 가 1 → 2 전환 시 탭바 등장으로 줄어드는 cell 영역에 맞춰 모든 탭 resize.
fn handleNewTab() void {
    if (tab_actions.checkAtLimitAndDialog(&g_host)) return;
    const active = g_session.activeTab() orelse return;
    g_session.createTab(active.terminal.cols, active.terminal.rows) catch |err| {
        log.appendLine("tab", "new tab failed: {s}", .{@errorName(err)});
        return;
    };
    syncTerminalGeometry();
    g_tab_scroll_user_override = false;
}

/// 마우스 휠 / 트랙패드 스크롤 → ghostty Terminal 의 viewport scroll. 양수
/// deltaY (콘텐츠가 아래로 = 손가락 위로) 면 scrollback 의 위쪽 (오래된 내용)
/// 보임. trackpad 의 작은 precise delta 도 그대로 1+ row 단위로 변환.
fn handleCopy() void {
    tab_actions.copyActiveSelection(&g_host, g_gpa.allocator());
}

fn handlePaste() void {
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

    // rename routing (printable cp 만 → g_rename) 또는 일반 PTY paste
    // (bracketed paste + wrap 은 session.pasteToActive 가) — 양쪽 분기 helper.
    tab_actions.routePaste(&g_host, cstr[0..len]);
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
    // 우클릭 paste (#119) — cmd.exe console 표준 패턴.
    if (!objc.class_addMethod(cls, objc.sel("rightMouseDown:"), @ptrCast(&tildazRightMouseDown), "v@:@"))
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
        log.appendLine("ime", "WARNING: NSTextInputClient protocol not found", .{});
    }

    objc.objc_registerClassPair(cls);
    return cls;
}

pub fn run() !void {
    // 통합 로그 파일에 boot/exit 라인을 남긴다 (`log.zig`). macOS 는
    // `~/Library/Logs/tildaz.log` — Console.app 이 자동 인덱싱해 GUI 에서
    // 바로 열람 가능.
    log.logStart(build_options.version);
    // Cmd+Q (NSApp terminate:) 는 `exit()` 직행 — defer 안 불림. atexit 등록.
    _ = atexit(&atExitLogStop);

    // 0. Config 읽기 — 잘못된 값 발견 시 macos_config 가 dialog.showFatal 로
    //    다이얼로그 띄우고 즉시 종료 (Windows host 와 동일 정책).
    g_config = config.Config.load(g_gpa.allocator());
    log.appendLine("startup", "config loaded: opacity={d} dock={s} theme={s} auto_start={} hidden_start={}", .{
        g_config.opacity,
        @tagName(g_config.dock_position),
        if (g_config.theme) |_| "set" else "default",
        g_config.auto_start,
        g_config.hidden_start,
    });

    // shell executable 이 실제 존재하고 실행 가능한지 검증. PTY 단계까지 가서
    // execve 실패하면 generic 에러로 끝나 사용자에게 어디 고쳐야 할지 안내 안
    // 됨 — config 로드 직후 fatal 로 종료. Windows host 와 같은 정책.
    @import("../shell_validate.zig").validateOrFatal(g_gpa.allocator(), g_config.shell);

    // Auto-start (LaunchAgent) — Windows `autostart.enable/disable` 동등.
    // 사용자 로그인 시 launchd 가 plist 따라 자동 실행. 매 부팅마다 enable
    // / disable 을 sync 해 사용자가 config 끄면 즉시 효과.
    if (g_config.auto_start) {
        autostart.enable(g_gpa.allocator()) catch |err| {
            log.appendLine("autostart", "enable failed: {s}", .{@errorName(err)});
        };
    } else {
        autostart.disable(g_gpa.allocator());
    }

    // 1. NSApplication.
    const NSApplication = objc.getClass("NSApplication");
    const sharedApp = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    g_app = sharedApp(NSApplication, objc.sel("sharedApplication")) orelse return error.NSApplicationFailed;

    const setActivationPolicy = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) bool);
    _ = setActivationPolicy(g_app, objc.sel("setActivationPolicy:"), NSApplicationActivationPolicyAccessory);

    // macOS "Press and Hold" 기능 끔 — 영어 키 길게 눌러도 accent picker
    // (à á â) 안 뜨고 정상 key repeat 발생. 한글 자모는 IME 경로라 영향
    // 없지만, 영어/숫자/기호는 system 이 repeat 을 막아 *키 한 번* 만 들어옴.
    // ghostty / iTerm2 / Alacritty 모두 같은 방식 — 우리 앱 도메인의
    // NSUserDefaults 에 false 로 set.
    {
        const NSUserDefaults = objc.getClass("NSUserDefaults");
        const stdDefaults = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
        const defaults = stdDefaults(NSUserDefaults, objc.sel("standardUserDefaults"));
        if (defaults != null) {
            const setBoolForKey = objc.objcSend(fn (objc.id, objc.SEL, bool, objc.id) callconv(.c) void);
            setBoolForKey(defaults, objc.sel("setBool:forKey:"), false, objc.nsString("ApplePressAndHoldEnabled"));
        }
    }

    // dialog/macos 가 NSAlert path 쓰도록 — 이 시점부터 우리 NSApp 안에서
    // alert 띄울 때 popup level 보다 위에 올바르게 표시.
    @import("../dialog/macos.zig").markNSAppReady();

    try buildMainMenu(g_app);

    // applicationShouldTerminate: hook (#116) — 다중 탭에서 Cmd+Q / 메뉴 Quit
    // 시 confirm 다이얼로그. NSApp.terminate 모든 path 를 한 곳에서 가로챔
    // (mainMenu 의 Quit + 마지막 탭 닫힘 자동 terminate). 마지막 탭 종료 후
    // 자동 호출되는 path (drainExitedTabs / handleCloseActiveTab /
    // handleTabBarClick) 는 count == 0 이라 자동 통과.
    try installAppDelegate();

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

    // dialog/macos 가 alert 띄울 때 우리 윈도우 level 을 잠깐 normal 로 낮추도록
    // 등록 (alert 가 popup 위에 표시되도록).
    @import("../dialog/macos.zig").setHostWindow(g_window);

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

    // config.opacity (0..255) → NSWindow.alphaValue (0.0..1.0). Windows
    // tildaz 의 layered window alpha 와 동일 의미 — 윈도우 전체 (cell grid +
    // 탭바) 가 그 alpha 만큼 반투명. opacity = 255 (default) 면 alpha = 1.0
    // 완전 불투명.
    const alpha_value: f64 = @as(f64, @floatFromInt(g_config.opacity)) / 255.0;
    const setAlphaValue = objc.objcSend(fn (objc.id, objc.SEL, f64) callconv(.c) void);
    setAlphaValue(g_window, objc.sel("setAlphaValue:"), alpha_value);

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

    // 4. 첫 dock rect 적용 후 표시 (hidden_start 면 표시 생략 — 첫 hotkey 까지
    //    윈도우는 unmapped, F1 처음 눌렀을 때 첫 노출. Windows windows_host.run
    //    의 `if (!config.hidden_start) app.window.show();` 와 동등).
    repositionWindow();
    if (!g_config.hidden_start) {
        showWindow();
    }

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

    // 5. CGEventTap 으로 글로벌 키 hotkey 등록 — F1 (toggle) 만. Cmd+Q 는
    //    NSMenu 의 "Quit TildaZ" item 이 표준 dispatch (#153 — 글로벌 hook
    //    이었던 시절엔 다른 앱 frontmost 일 때도 가로챘음).
    //    Carbon RegisterEventHotKey 는 우리 환경 (macOS Tahoe + ad-hoc sign) 에서
    //    silently fail 하므로 Apple DTS 권장 modern API 인 CGEventTap 사용.
    //    Input Monitoring 권한 필요 — 사용자가 시스템 설정에서 활성화.
    try installEventTap();

    const allocator = g_gpa.allocator();

    // 6. Metal 렌더러 (font 측정 포함). 폰트의 'M' advance + ascent/descent/
    //    leading 으로 cell_width/height 자동 계산 — Windows 의 GetTextMetricsW
    //    + cell_width_scale/line_height_scale 패턴과 동일.
    //
    //    `TILDAZ_FONT` 환경변수로 config 보다 우선 — 빠르게 다른 폰트 시험.
    //    config.font.family 는 *glyph fallback chain* (codepoint 별로 chain 순회).
    const tildaz_font_env = std.process.getEnvVarOwned(allocator, "TILDAZ_FONT") catch null;
    defer if (tildaz_font_env) |s| allocator.free(s);
    var env_chain: [1][]const u8 = undefined;
    const font_family_slice: []const []const u8 = if (tildaz_font_env) |s| blk: {
        env_chain[0] = s;
        break :blk env_chain[0..1];
    } else g_config.font_families[0..g_config.font_family_count];

    // theme 의 background 를 metal renderer 의 default_bg 로 — clear pass color
    // (cell 이 그리지 않는 영역) + 비활성 탭 BG 에 사용.
    const theme_bg: ?[3]u8 = if (g_config.theme) |t| .{ t.background.r, t.background.g, t.background.b } else null;
    g_renderer = macos_metal.MetalRenderer.init(
        allocator,
        device,
        layer,
        font_family_slice,
        @floatFromInt(g_config.font_size),
        g_config.cell_width,
        g_config.line_height,
        theme_bg,
        @floatCast(scale_pt),
    ) catch |err| switch (err) {
        // chain 모두 lookup 실패 — 시도한 폰트 list 명시 (Windows 의
        // `font_not_found_format` 와 같은 의도, multi-font 메시지).
        error.FontCreateFailed => {
            var buf: [1024]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const w = fbs.writer();
            w.writeAll(messages.font_chain_all_failed_msg) catch {};
            for (font_family_slice) |fam| w.print("\n  - {s}", .{fam}) catch {};
            dialog.showFatal(messages.config_error_title, fbs.getWritten());
        },
        else => return err,
    };
    // viewport / cell metrics 모두 pixel 단위로 통일 — pt/px mixing 시 글리프
    // 가 cell 일부만 차지해 깨져 보이는 문제 회피 (#75 댓글 6 의 정정 패턴).
    const vp_w_px: u32 = @intFromFloat(cv_bounds.size.width * scale_pt);
    const vp_h_px: u32 = @intFromFloat(cv_bounds.size.height * scale_pt);
    g_renderer.?.resize(vp_w_px, vp_h_px);

    const cell_w_px: u32 = g_renderer.?.font.cell_width;
    const cell_h_px: u32 = g_renderer.?.font.cell_height;
    const pad_px: u32 = @intFromFloat(@as(f64, @floatFromInt(TERMINAL_PADDING_PT)) * scale_pt);
    log.appendLine("startup", "renderer init: vp={d}x{d}px scale={d:.2} cell={d}x{d}px pad={d}px font={s}", .{
        vp_w_px,
        vp_h_px,
        scale_pt,
        cell_w_px,
        cell_h_px,
        pad_px,
        g_renderer.?.font.font_family,
    });

    // 7. PTY + ghostty-vt Terminal (M5.0 + M5.1). cols/rows 는 (viewport −
    //    좌우 padding) ÷ cell. Windows app_controller 의 size − 2*pad 패턴.
    // shell 결정 우선순위 (#118): config.shell 명시값 > $SHELL env > "/bin/zsh".
    // config.shell == "" (빈 문자열) 이면 env fallback — 사용자가 따로 지정하지
    // 않은 경우 시스템 기본값 따름. cross-platform Config 라 shell 은 []const u8
    // 통일 (Windows 는 default "cmd.exe", macOS 는 default "").
    const shell_env = std.process.getEnvVarOwned(allocator, "SHELL") catch null;
    defer if (shell_env) |s| allocator.free(s);
    const shell_path: []const u8 = if (g_config.shell.len > 0)
        g_config.shell
    else if (shell_env) |s|
        s
    else
        "/bin/zsh";

    const tab_bar_px: u32 = @intCast(tabBarHeightPx(@floatCast(scale_pt)));
    const top_reserved = pad_px + tab_bar_px;
    const usable_w = if (vp_w_px > 2 * pad_px) vp_w_px - 2 * pad_px else cell_w_px;
    const usable_h = if (vp_h_px > top_reserved + pad_px) vp_h_px - top_reserved - pad_px else cell_h_px;
    const term_cols: u16 = @intCast(@max(1, usable_w / cell_w_px));
    const term_rows: u16 = @intCast(@max(1, usable_h / cell_h_px));

    // 자식 셸 환경변수. macOS .app launch 시 부모 environ 에 없을 수 있어 명시
    // 설정. TERM = xterm-256color, LANG = en_US.UTF-8 (bash readline multi-byte
    // 활성화 — 안 하면 한글 byte 를 받아도 echo 안 함). COLORFGBG = TUI dark/
    // light 자동 판별 (Windows `host/windows.zig` 의 buildExtraEnv 와 동등).
    // SHELL = 우리가 spawn 한 셸 path (부모의 SHELL 과 어긋남 방지).
    const colorfgbg_value: []const u8 = if (g_config.theme) |t|
        (if (themes.isDark(t)) "15;0" else "0;15")
    else
        "15;0";
    g_shell_path = try allocator.dupe(u8, shell_path);
    g_extra_env = .{
        .{ .name = "TERM", .value = "xterm-256color" },
        .{ .name = "LANG", .value = "en_US.UTF-8" },
        .{ .name = "LC_CTYPE", .value = "en_US.UTF-8" },
        .{ .name = "COLORFGBG", .value = colorfgbg_value },
        .{ .name = "SHELL", .value = g_shell_path },
    };

    g_session = session_core.SessionCore.init(
        allocator,
        g_shell_path,
        g_config.max_scroll_lines,
        g_config.theme,
        &g_extra_env,
        onSessionTabExit,
        null,
    );

    try g_session.createTab(term_cols, term_rows);
    log.appendLine("startup", "initial tab created: shell={s} cols={d} rows={d} max_scroll_lines={d}", .{
        shell_path,
        term_cols,
        term_rows,
        g_config.max_scroll_lines,
    });

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
    log.appendLine("startup", "enter NSApp run loop", .{});
    const runApp = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) void);
    runApp(g_app, objc.sel("run"));
    log.appendLine("startup", "NSApp run loop exited", .{});
}

/// session_core 의 tab_exit_fn — read thread 에서 호출. read thread 안에서
/// closeTabByPtr 직접 호출하면 self-join deadlock (Tab.deinit 이 read_thread
/// .join 부름) → 글로벌 queue 에 enqueue 만 하고 main thread (renderTimerFire)
/// 가 매 frame 시작 시 drain. Windows 의 PostMessage 패턴과 동등 의도.
fn onSessionTabExit(tab_ptr: usize, _: ?*anyopaque) void {
    g_pending_close_mutex.lock();
    defer g_pending_close_mutex.unlock();
    g_pending_close_buf.append(g_gpa.allocator(), tab_ptr) catch {};
}

/// 매 프레임 시작 시 pending close queue drain. main thread 에서 호출되므로
/// closeTabByPtr → Tab.deinit → read_thread.join 이 deadlock 없이 진행.
/// `tab_actions.closeByPtr` 가 마지막 탭 → terminate 자동 호출 (#117 helper)
/// — 호출처는 .changed 만 분기.
fn drainExitedTabs() bool {
    g_pending_close_mutex.lock();
    const closes = g_pending_close_buf.toOwnedSlice(g_gpa.allocator()) catch &.{};
    g_pending_close_mutex.unlock();
    defer g_gpa.allocator().free(closes);

    var any_changed = false;
    for (closes) |ptr| switch (tab_actions.closeByPtr(&g_host, ptr) orelse continue) {
        .ended => {
            log.appendLine("pty", "tab ptr=0x{x} exited (last tab), terminating tildaz", .{ptr});
            return true;
        },
        .changed => {
            log.appendLine("pty", "tab ptr=0x{x} exited, closed", .{ptr});
            any_changed = true;
        },
    };

    // 2 → 1 전환 시 탭바 사라짐 → cell 영역 늘어남. 모든 탭 resize.
    if (any_changed) syncTerminalGeometry();
    return false;
}

/// 60fps render timer callback. 윈도우 hidden 이거나 renderer 미초기화면 skip.
/// cell_w/h 는 font 가 측정한 pixel 단위 (Retina backing scale 이미 적용됨).
fn renderTimerFire(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    // Per-tab PTY exit 처리 — 마지막 탭이 정리되면 NSApp.terminate (이번 frame
    // 은 더 진행 안 함).
    if (drainExitedTabs()) return;

    // session_core 의 active tab output ring drain + ghostty parse + 8ms
    // throttle. 큰 출력 시 frame budget 안에서만 parse — Windows app_controller
    // 의 패턴 동등. should_render=false 면 ring 에 더 데이터가 있어도 다음
    // frame 에서 처리 (60fps 안정).
    //
    // 단 rename / IME preedit 활성 시 throttle 우회 — 이 두 UI 는 PTY 출력과
    // 무관한 매 keystroke 즉시 화면 갱신 필요. throttle 만 적용하면 typing
    // 도중 화면이 늦게 따라옴 ("뒷부분 안 보임" 회귀, opt 2b2 시연 발견).
    const should_render = g_session.prepareActiveFrame(&g_last_render_ms);
    const force_render = g_rename.isActive() or g_preedit_len > 0;
    if (!should_render and !force_render) return;

    if (!g_visible) return;
    if (g_renderer == null) return;
    const tab = g_session.activeTab() orelse return;

    // #117 — 활성 탭이 viewport 에 보이도록 scroll 갱신. drag / 사용자 화살표
    // override 중에는 skip.
    if (!g_drag.active and !g_tab_scroll_user_override) ensureActiveTabVisible();
    const cell_w_px: i32 = @intCast(g_renderer.?.font.cell_width);
    const cell_h_px: i32 = @intCast(g_renderer.?.font.cell_height);
    const pad_px: i32 = @intFromFloat(@as(f32, @floatFromInt(TERMINAL_PADDING_PT)) * g_renderer.?.scale);
    const tab_bar_px = tabBarHeightPx(g_renderer.?.scale);

    // 탭 제목 stack-allocated slice. 매 프레임 만들지만 alloc 없음. session_core
    // .MAX_TABS = 32 한도와 일치 (cross-platform 동등, Windows 도 [32]).
    var titles_buf: [session_core.MAX_TABS][]const u8 = undefined;
    const tab_count = @min(g_session.count(), titles_buf.len);
    for (g_session.tabs.items[0..tab_count], 0..) |t, i| {
        titles_buf[i] = t.title[0..t.title_len];
    }
    const titles = titles_buf[0..tab_count];

    // IME preedit (`g_preedit_buf`) 라우팅 — rename 활성 시 탭바 cursor 옆에
    // 인라인 표시 (`tab_rename_preedit` 인자), 아니면 cell grid 의 cursor 위치
    // (`cell_preedit` 인자). 둘 동시에 안 나오게 — rename 활성이면 cell 빈 slice.
    const preedit_slice: []const u8 = if (g_preedit_len > 0) g_preedit_buf[0..g_preedit_len] else &.{};
    const cell_preedit: []const u8 = if (g_rename.isActive()) &.{} else preedit_slice;
    const tab_rename_preedit: []const u8 = if (g_rename.isActive()) preedit_slice else &.{};

    g_renderer.?.renderFrame(
        g_metal_layer,
        &tab.terminal,
        cell_w_px,
        cell_h_px,
        tab_bar_px,
        pad_px,
        cell_preedit,
        titles,
        g_session.active_tab,
        g_rename.view(),
        tab_rename_preedit,
        g_drag.view(),
        g_tab_scroll_x_px,
        tabBarLayout(),
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
        // 다이얼로그로 사용자에게 안내 + 로그 한 줄. stdout 으로 안 찍어 — 사용자가
        // .app 으로 띄우면 stdout 안 보고 다이얼로그를 봐야 함.
        var msg_buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf,
            \\TildaZ needs two macOS permissions to work.
            \\Without them the F1 hotkey will not respond.
            \\(Cmd+Q from the menu still works either way.)
            \\
            \\Please follow these steps:
            \\
            \\Step 1 — Input Monitoring
            \\  1. Open the Apple menu  →  System Settings.
            \\  2. In the sidebar, click "Privacy & Security".
            \\  3. Scroll down and click "Input Monitoring".
            \\  4. Look for "tildaz" in the list:
            \\       • If it is there, turn the switch ON.
            \\       • If not, click the "+" button at the bottom,
            \\         find TildaZ.app, click Open, then turn it ON.
            \\
            \\Step 2 — Accessibility
            \\  1. Click "< Privacy & Security" to go back.
            \\  2. Click "Accessibility" instead.
            \\  3. Same as above: turn "tildaz" ON,
            \\     or click "+" to add TildaZ.app and then turn it ON.
            \\
            \\Step 3 — Restart TildaZ
            \\  Quit and relaunch this app for the new permissions to take effect.
            \\
            \\Current status:
            \\  Input Monitoring : {s}
            \\  Accessibility    : {s}
            \\
            \\(Developer note: ad-hoc signed builds get a new identity on each
            \\rebuild, so permissions must be re-granted after every rebuild.)
        , .{
            if (has_input) "GRANTED" else "MISSING",
            if (has_ax) "GRANTED" else "MISSING",
        }) catch "TildaZ needs Input Monitoring and Accessibility permissions. Open System Settings -> Privacy & Security and enable both for tildaz.";

        log.appendLine("perm", "missing — input_monitoring={s} accessibility={s}", .{
            if (has_input) "OK" else "missing",
            if (has_ax) "OK" else "missing",
        });
        dialog.showInfo("TildaZ — Permission required", msg);
        // dialog 가 keyWindow 를 빼앗아 갔다가 닫으면서 우리 윈도우로 안
        // 돌려줌 → 사용자가 직접 클릭해야 keyboard 입력 가능. showWindow 의
        // makeKeyAndOrderFront + activateIgnoringOtherApps + makeFirstResponder
        // 셋 다 다시 호출해서 강제 복원.
        showWindow();
        return;
    }

    try createAndRegisterEventTap();
}

/// CGEventTapCreate + run loop source 등록 + Enable. Permission preflight 는
/// 호출자 (`installEventTap` 또는 recreate path) 가 책임. 실패 시 module-level
/// `g_event_tap` / `g_runloop_source` 는 null 인 채로 남음.
fn createAndRegisterEventTap() !void {
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
        log.appendLine("hotkey", "CGEventTapCreate failed — permissions may need to be renewed", .{});
        return error.TapCreateFailed;
    }

    g_runloop_source = CFMachPortCreateRunLoopSource(null, g_event_tap, 0);
    if (g_runloop_source == null) {
        CFMachPortInvalidate(g_event_tap);
        CFRelease(@ptrCast(g_event_tap));
        g_event_tap = null;
        return error.RunLoopSourceFailed;
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), g_runloop_source, kCFRunLoopCommonModes);
    CGEventTapEnable(g_event_tap, true);
}

/// CGEventTapEnable(true) 만으로 안 살아나는 OS-invalidated tap 을 destroy
/// 후 새로 만들어 등록. 콜백 안에서 자기 자신을 invalidate 하면 안 되므로
/// `dispatch_async_f` 로 main run loop 다음 turn 에서 호출되도록 dispatch.
/// (#152)
fn recreateEventTap() void {
    if (g_runloop_source != null) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), g_runloop_source, kCFRunLoopCommonModes);
        CFRelease(@ptrCast(g_runloop_source));
        g_runloop_source = null;
    }
    if (g_event_tap != null) {
        CFMachPortInvalidate(g_event_tap);
        CFRelease(@ptrCast(g_event_tap));
        g_event_tap = null;
    }
    createAndRegisterEventTap() catch |err| {
        log.appendLine("hotkey", "recreateEventTap failed: {s}", .{@errorName(err)});
        return;
    };
    log.appendLine("hotkey", "CGEventTap recreated", .{});
}

/// `dispatch_async_f` 트램폴린 — context 무시하고 recreateEventTap 호출.
fn recreateEventTapTrampoline(_: ?*anyopaque) callconv(.c) void {
    recreateEventTap();
}

/// CGEventTap 콜백 — keycode + modifier 검사해서 config.hotkey 면
/// \"이벤트 삼킴\" (null 반환), 아니면 그대로 passthrough (event 반환). Cmd+Q 는
/// #153 에서 NSMenu 의 \"Quit TildaZ\" 로 위임 (active 상태에서만 dispatch).
///
/// macOS 가 tap 을 timeout / user-input race 로 자동 비활성화하면 special
/// event type 이 들어옴 (#146). 처리 안 하면 다시 활성화 안 되어 F1 hotkey
/// 영원히 안 옴 — 다른 앱으로 focus 갔다 돌아왔을 때 흔히 재현.
///
/// 1차 시도: `CGEventTapEnable(true)` 로 re-enable (단발 timeout 대부분 OK).
/// 짧은 시간 (REPEAT_WINDOW_MS) 안에 disable 이 반복되면 OS 가 tap 을 truly
/// invalidate 한 케이스 (#152) — `Enable(true)` 가 boolean 성공처럼 리턴해도
/// events 안 옴. tap 을 destroy + recreate 해야 살아남. 콜백 안에서 invalidate
/// 하면 안 되므로 main queue 로 dispatch.
fn eventTapCallback(
    _: ?*anyopaque,
    event_type: CGEventType,
    event: CGEventRef,
    _: ?*anyopaque,
) callconv(.c) CGEventRef {
    if (event_type == kCGEventTapDisabledByTimeout or event_type == kCGEventTapDisabledByUserInput) {
        const REPEAT_WINDOW_MS: i64 = 30_000;
        const now_ms = std.time.milliTimestamp();
        const recent = (now_ms - g_last_tap_disable_ms) < REPEAT_WINDOW_MS;
        g_last_tap_disable_ms = now_ms;
        if (recent) {
            log.appendLine("hotkey", "CGEventTap disabled (type={d}) — repeat within {d}s, scheduling recreate", .{ event_type, @divTrunc(REPEAT_WINDOW_MS, 1000) });
            dispatch_async_f(&_dispatch_main_q, null, recreateEventTapTrampoline);
        } else {
            log.appendLine("hotkey", "CGEventTap disabled (type={d}) — re-enabling", .{event_type});
            if (g_event_tap != null) CGEventTapEnable(g_event_tap, true);
        }
        return event;
    }
    const keycode_i64 = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    const flags = CGEventGetFlags(event);
    const mods = flags & kCGEventFlagsAllModifiers;
    const keycode: u32 = @intCast(keycode_i64);

    // 사용자 toggle hotkey (config.hotkey).
    if (keycode == g_config.hotkey.keycode and mods == g_config.hotkey.modifiers) {
        toggleWindow();
        return null;
    }

    // Cmd+Q 글로벌 가로채기는 #153 에서 제거. NSMenu 의 "Quit TildaZ"
    // (`terminate:` + keyEquivalent="q") 가 active 상태에서 표준 dispatch.
    // TildazWindow 가 `canBecomeKeyWindow` YES override 라 borderless 여도
    // mainMenu shortcut 정상 작동. 글로벌 hook 이 있던 시절엔 다른 앱이
    // frontmost 일 때 Cmd+Q 가 그 앱이 아니라 tildaz 종료 dialog 를 띄우는
    // 버그가 있었음.

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

    const width_pct: f64 = @floatFromInt(g_config.width);
    const height_pct: f64 = @floatFromInt(g_config.height);
    const offset_pct: f64 = @floatFromInt(g_config.offset);

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

    // Fullscreen 모드별 rect 결정 (#162). dock 모드는 위에서 계산한 rect.
    const final_rect = switch (g_fullscreen_mode) {
        .none => NSRect{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } },
        .monitor => frame, // 메뉴바 + dock 까지 덮음
        .workarea => visible, // 메뉴바 + dock 회피
    };
    const setFrameDisplay = objc.objcSend(fn (objc.id, objc.SEL, NSRect, bool) callconv(.c) void);
    setFrameDisplay(g_window, objc.sel("setFrame:display:"), final_rect, true);
}

/// 단축키 (Cmd+Enter / Shift+Cmd+Enter) 핸들러. self-symmetric 토글 — 들어간
/// 키로만 나옴 (Windows `Window.toggleFullscreenMode` 와 동등).
fn toggleFullscreenMode(target: FullscreenMode) void {
    if (g_fullscreen_mode == target) {
        g_fullscreen_mode = .none;
    } else if (g_fullscreen_mode == .none) {
        g_fullscreen_mode = target;
    } else {
        return; // 다른 모드 → no-op
    }
    // 풀-패스 재동기화 — repositionWindow 만 부르면 window frame 만 변경되어
    // cell metric 그대로 → 글자만 늘어나 보임 (시연 회귀). syncGeometryAfter
    // ScreenChange 가 frame 변경 + drawable + renderer viewport + 각 탭의
    // ghostty Terminal / PTY winsize 까지 새 cols/rows 로 resize. 모니터 변경
    // path 와 같음.
    syncGeometryAfterScreenChange();
}

fn showWindow() void {
    // popup level 복구 — emoji picker / dialog 같은 path 가 잠시 normal 로
    // 낮춘 후 다음 toggle 시 popup 으로 자동 복귀.
    const NSPopUpMenuWindowLevel: c_int = 101;
    const setLevel = objc.objcSend(fn (objc.id, objc.SEL, c_int) callconv(.c) void);
    setLevel(g_window, objc.sel("setLevel:"), NSPopUpMenuWindowLevel);

    const makeKeyAndOrderFront = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    makeKeyAndOrderFront(g_window, objc.sel("makeKeyAndOrderFront:"), null);
    const activate = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    activate(g_app, objc.sel("activateIgnoringOtherApps:"), true);
    restoreContentViewFocus();
    g_visible = true;
}

/// contentView (TildazView) 를 firstResponder 로 강제. NSAlert.runModal 후
/// firstResponder 가 dialog OK 버튼에 잡혀 우리 view 로 안 돌아오는 케이스
/// 회피 — 권한 dialog 닫고 사용자가 마우스 클릭 안 해도 바로 타이핑 가능.
fn restoreContentViewFocus() void {
    const contentView_get = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const cv = contentView_get(g_window, objc.sel("contentView"));
    if (cv != null) {
        const makeFirstResponder = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) bool);
        _ = makeFirstResponder(g_window, objc.sel("makeFirstResponder:"), cv);
    }
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

// 마지막 tap-disable 이벤트의 wall-clock millis. 짧은 시간 안에 재발하면
// `CGEventTapEnable(true)` 만으로는 안 살아나는 케이스라 destroy + recreate
// path 로 escalate (#152).
var g_last_tap_disable_ms: i64 = 0;

/// `About TildaZ` menu item action. Selector 는 NSApplication 에 등록되어
/// responder chain 의 마지막 단계 (NSApp) 에서 항상 dispatch 된다 — 윈도우가
/// hide 상태여도 동작.
fn tildazShowAboutAction(self: objc.id, _sel: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = self;
    _ = _sel;
    _ = sender;
    about.showAboutDialog();
}

/// Shift+Cmd+P — config.json 을 default editor 로 열기 (#128). About 와 같은
/// NSApplication-level selector 패턴.
fn tildazOpenConfigAction(self: objc.id, _sel: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = self;
    _ = _sel;
    _ = sender;
    const allocator = g_gpa.allocator();
    const path = @import("../paths.zig").configPath(allocator) catch return;
    defer allocator.free(path);
    @import("../system_open.zig").openInDefaultApp(allocator, path);
}

/// Shift+Cmd+L — tildaz.log 를 default editor 로 열기 (#128).
fn tildazOpenLogAction(self: objc.id, _sel: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = self;
    _ = _sel;
    _ = sender;
    const allocator = g_gpa.allocator();
    const path = @import("../paths.zig").logPath(allocator) catch return;
    defer allocator.free(path);
    @import("../system_open.zig").openInDefaultApp(allocator, path);
}

/// Ctrl+Cmd+Space — Show Emoji & Symbols picker (#130). 우리 popup-level
/// (101) 윈도우가 emoji panel 위에 가리는 문제 회피 위해 잠시 normal level
/// 로 낮춤. 다음 toggle (F1 / hotkey) 시 `showWindow` 가 popup 으로 복구.
///
/// picker 가 cursor-anchored popover 가 아니라 floating panel 로 뜨는 것 +
/// focus 잃어도 자동 dismiss 안 되는 것은 macOS 의 Apple-first-party 우대
/// 한계 (Apple `CharacterPicker.framework` 가 NSTextView 기반 firstResponder
/// 만 popover path 활성, custom NSView 는 floating panel fallback). ghostty
/// / iTerm2 / Alacritty / Kitty 동등. 자세한 분석은 SPEC.md 부록 B.
///
/// Esc 로 dismiss 가능 — `tildazKeyDown` 이 `isEmojiPickerOpen()` 으로 panel
/// 의 *실제 visibility* 를 매번 query (NSApp.orderedWindows 순회 + class name
/// 매칭) → picker 떠 있을 때 modifier 없는 Esc 면 다시 `orderFrontCharacterPalette:`
/// 호출 (toggle 닫힘). picker 가 외부 path 로 닫혀도 stale 안 됨 — boolean
/// 추적이 아닌 직접 query.
fn tildazShowEmojiAction(self: objc.id, _sel: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = self;
    _ = _sel;
    _ = sender;
    const NSNormalWindowLevel: c_int = 0;
    const setLevel = objc.objcSend(fn (objc.id, objc.SEL, c_int) callconv(.c) void);
    setLevel(g_window, objc.sel("setLevel:"), NSNormalWindowLevel);
    const activate = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    activate(g_app, objc.sel("activateIgnoringOtherApps:"), true);
    const orderFront = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    orderFront(g_app, objc.sel("orderFrontCharacterPalette:"), null);
}

// CoreGraphics window list — 모든 process 의 onscreen 윈도우 query (#130).
// emoji picker 는 별도 process (`com.apple.CharacterPaletteIM` 등 Apple Input
// Method bundle) 가 호스팅 → 우리 NSApp.orderedWindows 로는 안 보임.
const CGWindowListOption = u32;
const kCGWindowListOptionOnScreenOnly: CGWindowListOption = 1 << 0;
const kCGWindowListExcludeDesktopElements: CGWindowListOption = 1 << 4;
const kCGNullWindowID: u32 = 0;
extern fn CGWindowListCopyWindowInfo(option: CGWindowListOption, relativeToWindow: u32) objc.id;
extern fn CFRelease(cf: ?*anyopaque) void;
extern const kCGWindowOwnerPID: objc.id;

/// Show Emoji & Symbols panel 이 현재 떠 있는지 — `CGWindowListCopyWindowInfo`
/// 로 onscreen 윈도우 순회, 각 owner PID 를 NSRunningApplication 으로 풀어
/// `bundleIdentifier` 매칭. owner name 은 localized 라 (한글: "이모지 및 기호",
/// 영어: "Emoji & Symbols") bundle ID 로 식별 — locale-independent.
///
/// 매칭 prefix `com.apple.Character` — 현재 macOS 의 `com.apple.CharacterPaletteIM`
/// + 다른 Apple Character* 변형 (`CharacterPicker` / `CharacterViewer` 등 미래
/// 가능성) cover. 권한: `kCGWindowOwnerPID` 는 Screen Recording 권한 불필요.
///
/// 매 Esc keyDown 마다 호출 — CGWindowListCopyWindowInfo 자체는 fast (us 단위),
/// 보통 onscreen 윈도우 ~20 개라 iteration 부담 없음.
fn isEmojiPickerOpen() bool {
    const info = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID,
    );
    if (info == null) return false;
    defer CFRelease(@ptrCast(info));

    const get_count = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) usize);
    const obj_at = objc.objcSend(fn (objc.id, objc.SEL, usize) callconv(.c) objc.id);
    const dict_get = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.id);
    const utf8 = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) ?[*:0]const u8);
    const get_int = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_int);
    const ra_for_pid = objc.objcSend(fn (objc.Class, objc.SEL, c_int) callconv(.c) objc.id);
    const ra_send = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);

    const NSRunningApplication = objc.getClass("NSRunningApplication");
    const count = get_count(info, objc.sel("count"));

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const dict = obj_at(info, objc.sel("objectAtIndex:"), i);
        if (dict == null) continue;
        const pid_obj = dict_get(dict, objc.sel("objectForKey:"), kCGWindowOwnerPID);
        if (pid_obj == null) continue;
        const pid = get_int(pid_obj, objc.sel("intValue"));
        const ra = ra_for_pid(NSRunningApplication, objc.sel("runningApplicationWithProcessIdentifier:"), pid);
        if (ra == null) continue;
        const bid = ra_send(ra, objc.sel("bundleIdentifier"));
        if (bid == null) continue;
        const b_cstr = utf8(bid, objc.sel("UTF8String")) orelse continue;
        const b_slice = std.mem.span(b_cstr);
        if (std.mem.startsWith(u8, b_slice, "com.apple.Character")) return true;
    }
    return false;
}

fn buildMainMenu(app: objc.id) !void {
    const NSMenu = objc.getClass("NSMenu");
    const NSMenuItem = objc.getClass("NSMenuItem");
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const init_obj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);

    // About / Open Config / Open Log 핸들러를 NSApplication 인스턴스 메서드로
    // 등록 — Quit (`terminate:`) 과 같은 패턴. 윈도우 hide 상태라도 NSApp
    // 에서 dispatch.
    const NSApplication = objc.getClass("NSApplication");
    if (!objc.class_addMethod(NSApplication, objc.sel("tildazShowAbout:"), @ptrCast(&tildazShowAboutAction), "v@:@"))
        return error.AddAboutMethodFailed;
    if (!objc.class_addMethod(NSApplication, objc.sel("tildazOpenConfig:"), @ptrCast(&tildazOpenConfigAction), "v@:@"))
        return error.AddOpenConfigMethodFailed;
    if (!objc.class_addMethod(NSApplication, objc.sel("tildazOpenLog:"), @ptrCast(&tildazOpenLogAction), "v@:@"))
        return error.AddOpenLogMethodFailed;
    if (!objc.class_addMethod(NSApplication, objc.sel("tildazShowEmoji:"), @ptrCast(&tildazShowEmojiAction), "v@:@"))
        return error.AddShowEmojiMethodFailed;

    const main_menu = init_obj(alloc(NSMenu, objc.sel("alloc")) orelse return error.MenuAllocFailed, objc.sel("init")) orelse return error.MenuInitFailed;

    const app_item = init_obj(alloc(NSMenuItem, objc.sel("alloc")) orelse return error.MenuItemAllocFailed, objc.sel("init")) orelse return error.MenuItemInitFailed;
    const addItem = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    addItem(main_menu, objc.sel("addItem:"), app_item);

    const app_menu = init_obj(alloc(NSMenu, objc.sel("alloc")) orelse return error.MenuAllocFailed, objc.sel("init")) orelse return error.MenuInitFailed;

    const initItem = objc.objcSend(fn (objc.id, objc.SEL, objc.id, objc.SEL, objc.id) callconv(.c) objc.id);

    const about_alloc = alloc(NSMenuItem, objc.sel("alloc")) orelse return error.MenuItemAllocFailed;
    // Shift+Cmd+I — macOS 표준 modifier (Cmd) + 다른 탭 단축키 (Cmd+T/W/숫자/[/])
    // 와 일관. Accessory mode 라 메뉴바 UI 는 안 보이지만 NSApp 의
    // `performKeyEquivalent:` 가 mainMenu 를 훑어 dispatch 하므로 키만으로
    // 동작 (Cmd+Q 와 같은 메커니즘).
    // shift modifier 가 있으면 keyEquivalent 는 lowercase 로 둠 (Apple HIG).
    const about_item = initItem(
        about_alloc,
        objc.sel("initWithTitle:action:keyEquivalent:"),
        nsString("About TildaZ"),
        objc.sel("tildazShowAbout:"),
        nsString("i"),
    ) orelse return error.AboutItemInitFailed;
    const NSEventModifierFlagShift: c_ulong = 1 << 17;
    const NSEventModifierFlagCommand: c_ulong = 1 << 20;
    const setMask = objc.objcSend(fn (objc.id, objc.SEL, c_ulong) callconv(.c) void);
    setMask(about_item, objc.sel("setKeyEquivalentModifierMask:"), NSEventModifierFlagCommand | NSEventModifierFlagShift);
    addItem(app_menu, objc.sel("addItem:"), about_item);

    // Shift+Cmd+P — Open Config (#128). About 와 같은 NSApp-level dispatch.
    const config_alloc = alloc(NSMenuItem, objc.sel("alloc")) orelse return error.MenuItemAllocFailed;
    const config_item = initItem(
        config_alloc,
        objc.sel("initWithTitle:action:keyEquivalent:"),
        nsString("Open Config"),
        objc.sel("tildazOpenConfig:"),
        nsString("p"),
    ) orelse return error.OpenConfigItemInitFailed;
    setMask(config_item, objc.sel("setKeyEquivalentModifierMask:"), NSEventModifierFlagCommand | NSEventModifierFlagShift);
    addItem(app_menu, objc.sel("addItem:"), config_item);

    // Shift+Cmd+L — Open Log (#128).
    const log_alloc = alloc(NSMenuItem, objc.sel("alloc")) orelse return error.MenuItemAllocFailed;
    const log_item = initItem(
        log_alloc,
        objc.sel("initWithTitle:action:keyEquivalent:"),
        nsString("Open Log"),
        objc.sel("tildazOpenLog:"),
        nsString("l"),
    ) orelse return error.OpenLogItemInitFailed;
    setMask(log_item, objc.sel("setKeyEquivalentModifierMask:"), NSEventModifierFlagCommand | NSEventModifierFlagShift);
    addItem(app_menu, objc.sel("addItem:"), log_item);

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

    // Edit menu — "Emoji & Symbols" menu item 으로 macOS 의 Show Emoji & Symbols
    // system shortcut (Apple default `Ctrl+Cmd+Space`) 라우팅. 이전 시도:
    // selector `orderFrontCharacterPalette:` (Apple 표준) + 빈 keyEquivalent
    // 로 *system 자동 매핑* 기대 — 동작 안 함. 그래서 explicit keyEquivalent
    // 로 hardcode + 우리 selector `tildazShowEmoji:` 로 라우팅 (popup-level
    // toggle 등 추가 처리). Terminal.app / ghostty 모두 비슷한 explicit menu
    // item 패턴.
    const edit_item = init_obj(alloc(NSMenuItem, objc.sel("alloc")) orelse return error.MenuItemAllocFailed, objc.sel("init")) orelse return error.MenuItemInitFailed;
    addItem(main_menu, objc.sel("addItem:"), edit_item);

    const edit_menu_init = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.id);
    const edit_menu = edit_menu_init(alloc(NSMenu, objc.sel("alloc")) orelse return error.MenuAllocFailed, objc.sel("initWithTitle:"), nsString("Edit")) orelse return error.MenuInitFailed;

    // Ctrl+Cmd+Space → tildazShowEmoji: — NSApp.sendEvent 단계에서 menu
    // shortcut 매칭 자동 라우팅 → 우리 view keyDown 까지 안 와서 PTY 안 흘림.
    // 사용자가 System Settings 에서 단축키를 다른 키로 변경한 경우 매칭 안 됨
    // (low-priority 한계, 우회: System Settings 에서 default 복구).
    const NSEventModifierFlagCtrl: c_ulong = 1 << 18;
    {
        const emoji_alloc = alloc(NSMenuItem, objc.sel("alloc")) orelse return error.MenuItemAllocFailed;
        const item = initItem(
            emoji_alloc,
            objc.sel("initWithTitle:action:keyEquivalent:"),
            nsString("Emoji & Symbols"),
            objc.sel("tildazShowEmoji:"),
            nsString(" "),
        ) orelse return error.EmojiItemInitFailed;
        setMask(item, objc.sel("setKeyEquivalentModifierMask:"), NSEventModifierFlagCtrl | NSEventModifierFlagCommand);
        addItem(edit_menu, objc.sel("addItem:"), item);
    }

    setSubmenu(edit_item, objc.sel("setSubmenu:"), edit_menu);

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
