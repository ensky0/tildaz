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

pub fn showPanic(msg: []const u8, addr: usize) noreturn {
    std.debug.print("panic: {s}\nreturn address: 0x{x}\n", .{ msg, addr });
    std.process.exit(1);
}

pub fn showFatalRunError(err: anyerror) void {
    std.debug.print("TildaZ failed to start.\n\nError: {s}\n", .{@errorName(err)});
}

// AppKit / Metal 상수.
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

// 키 코드 (Apple 의 `Events.h` `kVK_*`).
const kVK_F1: i64 = 0x7A;
const kVK_ANSI_Q: i64 = 0x0C;

// CGEventFlags modifier 마스크 (CGEventTypes.h). Carbon modifier (1<<8 등) 와
// 다른 비트 위치. 예: command = 1<<20.
const kCGEventFlagMaskCommand: u64 = 0x00100000;
const kCGEventFlagMaskShift: u64 = 0x00020000;
const kCGEventFlagMaskAlternate: u64 = 0x00080000; // = Option
const kCGEventFlagMaskControl: u64 = 0x00040000;
const kCGEventFlagsAllModifiers: u64 = kCGEventFlagMaskCommand | kCGEventFlagMaskShift | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl;

// hardcoded dock 파라미터 — config 통합은 M3.5 에서.
// Windows tildaz 의 config.zig default 와 같음 (top / 50% / 100% / 100%).
const DOCK_WIDTH_PCT: f64 = 50;
const DOCK_HEIGHT_PCT: f64 = 100;
const DOCK_OFFSET_PCT: f64 = 100;

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

// kCFRunLoopCommonModes 는 CFString 상수 (Apple 의 CFRunLoop.h). Zig 의
// extern var 로 받아 쓴다.
extern const kCFRunLoopCommonModes: CFStringRef;

// Input Monitoring 권한 (macOS 10.15+).
extern fn CGPreflightListenEventAccess() bool;
extern fn CGRequestListenEventAccess() bool;

extern fn MTLCreateSystemDefaultDevice() objc.id;

// 글로벌 toggle 상태 — Carbon 핫키 콜백 (C 시그니처) 이 NSApp / window 에
// 접근하려면 어딘가 보관해야 함. M3 단계에서 host 가 한 인스턴스만 띄우므로
// 모듈 전역으로 충분. M5 이후 multi-window / multi-tab 으로 확장 시
// userdata 포인터 패턴으로 옮길 예정.
var g_app: objc.id = null;
var g_window: objc.id = null;
var g_visible: bool = false;

pub fn run() !void {
    std.debug.print("TildaZ macOS v{s} — drop-down terminal (M3).\n", .{build_options.version});

    // 1. NSApplication.
    const NSApplication = objc.getClass("NSApplication");
    const sharedApp = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    g_app = sharedApp(NSApplication, objc.sel("sharedApplication")) orelse return error.NSApplicationFailed;

    const setActivationPolicy = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) bool);
    _ = setActivationPolicy(g_app, objc.sel("setActivationPolicy:"), NSApplicationActivationPolicyAccessory);

    try buildMainMenu(g_app);

    // 2. NSWindow — Titled + FullSizeContentView + traffic-light 버튼 / 타이틀
    //    숨김 패턴 (ghostty Quick Terminal 동일). \"진짜 borderless\"
    //    (styleMask = 0) 로 가면 \`canBecomeKeyWindow == NO\` 라서 mainMenu
    //    Cmd+Q 가 dispatch 안 되는 문제가 있어 Titled 를 유지한다. Resizable
    //    빼고 setMovable:NO 로 사용자 드래그 / 이동 OS 차단은 그대로.
    const NSWindow = objc.getClass("NSWindow");
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const window_alloc = alloc(NSWindow, objc.sel("alloc")) orelse return error.NSWindowAllocFailed;

    const initWindow = objc.objcSend(fn (objc.id, objc.SEL, NSRect, c_ulong, c_ulong, bool) callconv(.c) objc.id);
    // 초기 rect 는 placeholder — 곧이어 dock rect 로 덮어쓴다.
    const placeholder = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 800, .height = 400 } };
    const style_mask = NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView;
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

    // 타이틀바 영역까지 contentView 가 차지하도록 + 타이틀 / traffic-light 숨김.
    const setTitlebarTransparent = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    setTitlebarTransparent(g_window, objc.sel("setTitlebarAppearsTransparent:"), true);
    const setTitleVisibility = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) void);
    setTitleVisibility(g_window, objc.sel("setTitleVisibility:"), NSWindowTitleHidden);

    const standardWindowButton = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) objc.id);
    const setHidden = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    inline for ([_]c_long{ NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton }) |btn_id| {
        if (standardWindowButton(g_window, objc.sel("standardWindowButton:"), btn_id)) |btn| {
            setHidden(btn, objc.sel("setHidden:"), true);
        }
    }

    // 3. CAMetalLayer (M2 와 동일).
    const contentView_get = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const content_view = contentView_get(g_window, objc.sel("contentView")) orelse return error.ContentViewMissing;

    const setWantsLayer = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    setWantsLayer(content_view, objc.sel("setWantsLayer:"), true);

    const CAMetalLayer = objc.getClass("CAMetalLayer");
    const init_obj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const layer_alloc = alloc(CAMetalLayer, objc.sel("alloc")) orelse return error.MetalLayerAllocFailed;
    const layer = init_obj(layer_alloc, objc.sel("init")) orelse return error.MetalLayerInitFailed;

    const device = MTLCreateSystemDefaultDevice() orelse return error.MetalDeviceMissing;
    const setDevice = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setDevice(layer, objc.sel("setDevice:"), device);

    const setPixelFormat = objc.objcSend(fn (objc.id, objc.SEL, c_ulong) callconv(.c) void);
    setPixelFormat(layer, objc.sel("setPixelFormat:"), MTLPixelFormatBGRA8Unorm);

    const bg = createCGColor(0.10, 0.10, 0.12, 1.0);
    defer CGColorRelease(bg);
    const setBgColor = objc.objcSend(fn (objc.id, objc.SEL, ?*anyopaque) callconv(.c) void);
    setBgColor(layer, objc.sel("setBackgroundColor:"), bg);

    const setLayer = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setLayer(content_view, objc.sel("setLayer:"), layer);

    // 4. 첫 dock rect 적용 후 표시.
    repositionWindow();
    showWindow();

    // 5. CGEventTap 으로 글로벌 키 hotkey 등록 — F1 (toggle), Cmd+Q (terminate).
    //    Carbon RegisterEventHotKey 는 우리 환경 (macOS Tahoe + ad-hoc sign) 에서
    //    silently fail 하므로 Apple DTS 권장 modern API 인 CGEventTap 사용.
    //    Input Monitoring 권한 필요 — 사용자가 시스템 설정에서 활성화.
    try installEventTap();

    // 6. 이벤트 루프.
    const runApp = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) void);
    runApp(g_app, objc.sel("run"));
}

/// CGEventTap 생성 + run loop source 등록 + 활성화. 권한 없으면 사용자 안내 후
/// tap 없이 진행 (mainMenu Cmd+Q 는 동작).
fn installEventTap() !void {
    if (!CGPreflightListenEventAccess()) {
        _ = CGRequestListenEventAccess();
        std.debug.print(
            \\
            \\[Input Monitoring 권한 필요]
            \\
            \\글로벌 핫키 (F1 토글 / Cmd+Q 종료) 가 동작하려면 시스템 권한 필요해요.
            \\
            \\  1. 시스템 설정 → 개인정보 보호 및 보안 → 입력 모니터링
            \\  2. 목록에서 \"tildaz\" 토글 ON (없으면 + 버튼으로 .app 추가)
            \\  3. tildaz 다시 실행
            \\
            \\(개발 단계: ad-hoc 서명이라 매 빌드마다 권한 갱신 필요. 별도 후속 이슈로 자동화 검토 중.)
            \\
        , .{});
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
        std.debug.print("CGEventTapCreate 실패 — 권한 갱신 후 재시도 필요.\n", .{});
        return;
    }

    g_runloop_source = CFMachPortCreateRunLoopSource(null, g_event_tap, 0);
    if (g_runloop_source == null) return error.RunLoopSourceFailed;

    CFRunLoopAddSource(CFRunLoopGetMain(), g_runloop_source, kCFRunLoopCommonModes);
    CGEventTapEnable(g_event_tap, true);
}

/// CGEventTap 콜백 — keycode + modifier 검사해서 우리 hotkey 면 \"이벤트 삼킴\"
/// (null 반환), 아니면 그대로 passthrough (event 반환).
fn eventTapCallback(
    _: ?*anyopaque,
    _: CGEventType,
    event: CGEventRef,
    _: ?*anyopaque,
) callconv(.c) CGEventRef {
    const keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    const flags = CGEventGetFlags(event);
    const mods = flags & kCGEventFlagsAllModifiers;

    // F1 (modifier 없음).
    if (keycode == kVK_F1 and mods == 0) {
        toggleWindow();
        return null;
    }
    // Cmd+Q.
    if (keycode == kVK_ANSI_Q and mods == kCGEventFlagMaskCommand) {
        const terminate = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
        terminate(g_app, objc.sel("terminate:"), null);
        return null;
    }

    return event; // passthrough.
}

/// 현재 메인 스크린의 dock rect 를 계산해 윈도우에 적용. macOS 좌표계는
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
    const menubar_height = (frame.origin.y + frame.size.height) - (visible.origin.y + visible.size.height);
    const usable_max_y = visible.origin.y + visible.size.height; // = frame.maxY - menubarH
    const usable_min_y = if (dock_visible_at_bottom) visible.origin.y else frame.origin.y;
    const usable_height = usable_max_y - usable_min_y;
    _ = menubar_height; // 위 식으로 이미 반영됨; 변수는 의도 명시 용도로 남김.

    // 가로는 visibleFrame 그대로 — 좌/우 dock 의 경우 visibleFrame.width 가
    // 자동으로 줄어 있음.
    const sw = visible.size.width;
    const sx = visible.origin.x;

    const w = sw * DOCK_WIDTH_PCT / 100.0;
    const h = usable_height * DOCK_HEIGHT_PCT / 100.0;
    const x = sx + (sw - w) * DOCK_OFFSET_PCT / 100.0;
    // dock = top: usable 영역의 위쪽 끝에 부착.
    const y = usable_max_y - h;

    const rect = NSRect{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
    const setFrameDisplay = objc.objcSend(fn (objc.id, objc.SEL, NSRect, bool) callconv(.c) void);
    setFrameDisplay(g_window, objc.sel("setFrame:display:"), rect, true);
}

fn showWindow() void {
    const makeKeyAndOrderFront = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    makeKeyAndOrderFront(g_window, objc.sel("makeKeyAndOrderFront:"), null);
    const activate = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    activate(g_app, objc.sel("activateIgnoringOtherApps:"), true);
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

fn buildMainMenu(app: objc.id) !void {
    const NSMenu = objc.getClass("NSMenu");
    const NSMenuItem = objc.getClass("NSMenuItem");
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const init_obj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);

    const main_menu = init_obj(alloc(NSMenu, objc.sel("alloc")) orelse return error.MenuAllocFailed, objc.sel("init")) orelse return error.MenuInitFailed;

    const app_item = init_obj(alloc(NSMenuItem, objc.sel("alloc")) orelse return error.MenuItemAllocFailed, objc.sel("init")) orelse return error.MenuItemInitFailed;
    const addItem = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    addItem(main_menu, objc.sel("addItem:"), app_item);

    const app_menu = init_obj(alloc(NSMenu, objc.sel("alloc")) orelse return error.MenuAllocFailed, objc.sel("init")) orelse return error.MenuInitFailed;

    const initItem = objc.objcSend(fn (objc.id, objc.SEL, objc.id, objc.SEL, objc.id) callconv(.c) objc.id);
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
