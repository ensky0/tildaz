// macOS host — drop-down terminal entry point.
//
// 진행 상태는 이슈 #108 참고.
//
//   M1 — host 골격 + fail-fast 메시지 (완료, 688d204).
//   M2 — NSWindow + CAMetalLayer 빈 화면 + Cmd+Q. 사용자 리사이즈 비활성화. (현재)
//   M3 — 글로벌 단축키 토글 + dock rect (config.dock_position 적용).
//   M4 — POSIX PTY + ghostty-vt + CoreText/Metal 글리프.
//   M5 — 한글 IME.
//
// M2 의 의도된 한계:
//   - 윈도우는 표준 traffic-light (close/minimize/zoom) 가 보이지만, 빨간 점은
//     윈도우 한 개만 닫고 NSApp 자체는 종료하지 않는다 — `applicationShould
//     TerminateAfterLastWindowClosed:` delegate 를 M2 에서는 만들지 않으므로
//     기본값 NO 가 적용된다. 진짜 종료는 Cmd+Q (mainMenu 의 \"Quit TildaZ\" 항목).
//   - styleMask 에 Resizable 을 넣지 않아 사용자 드래그 리사이즈가 OS 레벨에서
//     차단된다. 이게 옵션 D 의 핵심 — #75 가 막힌 \"드래그 중 잔상\" 시나리오를
//     원천 회피.

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

// AppKit / Metal 상수 (헤더에 정의된 값 그대로).
const NSWindowStyleMaskTitled: c_ulong = 1 << 0;
const NSWindowStyleMaskClosable: c_ulong = 1 << 1;
const NSWindowStyleMaskMiniaturizable: c_ulong = 1 << 2;
// `NSWindowStyleMaskResizable` (1 << 3) 은 의도적으로 빼서 사용자 드래그
// 리사이즈를 OS 레벨에서 차단한다 — 옵션 D 의 핵심.

const NSBackingStoreBuffered: c_ulong = 2;
const NSApplicationActivationPolicyRegular: c_long = 0;

const MTLPixelFormatBGRA8Unorm: c_ulong = 80;

// CGFloat 은 macOS arm64 에서 f64. NSRect / NSPoint / NSSize 도 f64 기반.
const CGFloat = f64;
const NSRect = extern struct { origin: NSPoint, size: NSSize };
const NSPoint = extern struct { x: CGFloat, y: CGFloat };
const NSSize = extern struct { width: CGFloat, height: CGFloat };

extern fn MTLCreateSystemDefaultDevice() objc.id;

pub fn run() !void {
    std.debug.print("TildaZ macOS v{s} — M2 (NSWindow + CAMetalLayer).\n", .{build_options.version});

    // 1. NSApplication 시작.
    const NSApplication = objc.getClass("NSApplication");
    const sharedApp = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const app = sharedApp(NSApplication, objc.sel("sharedApplication")) orelse return error.NSApplicationFailed;

    const setActivationPolicy = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) bool);
    _ = setActivationPolicy(app, objc.sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);

    // 2. mainMenu 에 Quit (Cmd+Q) 등록 — 메뉴 항목이 NSApp.terminate: 으로
    //    매핑되어야 Cmd+Q 가 실제로 종료를 트리거한다.
    try buildMainMenu(app);

    // 3. NSWindow 생성. styleMask 에 Resizable 빠짐.
    const NSWindow = objc.getClass("NSWindow");
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const window_alloc = alloc(NSWindow, objc.sel("alloc")) orelse return error.NSWindowAllocFailed;

    const initWindow = objc.objcSend(fn (objc.id, objc.SEL, NSRect, c_ulong, c_ulong, bool) callconv(.c) objc.id);
    const content_rect = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 800, .height = 400 },
    };
    const style_mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    const window = initWindow(
        window_alloc,
        objc.sel("initWithContentRect:styleMask:backing:defer:"),
        content_rect,
        style_mask,
        NSBackingStoreBuffered,
        false,
    ) orelse return error.NSWindowInitFailed;

    const setTitle = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setTitle(window, objc.sel("setTitle:"), nsString("TildaZ"));

    // 4. contentView 를 layer-hosting 으로 만들고 CAMetalLayer 부착.
    const contentView_get = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const content_view = contentView_get(window, objc.sel("contentView")) orelse return error.ContentViewMissing;

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

    // 단색 배경: layer.backgroundColor = CGColor(0.10, 0.10, 0.12, 1.0).
    // 빈 화면이지만 \"창이 떴다\" 를 시각적으로 확인할 수 있는 용도.
    const bg = createCGColor(0.10, 0.10, 0.12, 1.0);
    defer CGColorRelease(bg);
    const setBgColor = objc.objcSend(fn (objc.id, objc.SEL, ?*anyopaque) callconv(.c) void);
    setBgColor(layer, objc.sel("setBackgroundColor:"), bg);

    const setLayer = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setLayer(content_view, objc.sel("setLayer:"), layer);

    // 5. 화면 중앙 + 표시.
    const center = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) void);
    center(window, objc.sel("center"));

    const makeKeyAndOrderFront = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    makeKeyAndOrderFront(window, objc.sel("makeKeyAndOrderFront:"), null);

    const activateIgnoringOtherApps = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    activateIgnoringOtherApps(app, objc.sel("activateIgnoringOtherApps:"), true);

    // 6. 이벤트 루프. Cmd+Q (mainMenu 의 Quit) 가 NSApp.terminate: 호출.
    const runApp = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) void);
    runApp(app, objc.sel("run"));
}

/// `NSMenu` mainMenu 에 \"Quit TildaZ\" (Cmd+Q → terminate:) 항목 등록.
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

/// UTF-8 literal → autoreleased NSString. NSApp.run 이 도는 동안 살아있으므로
/// 별도 retain 불필요.
fn nsString(s: [:0]const u8) objc.id {
    const NSString = objc.getClass("NSString");
    const stringWithUTF8 = objc.objcSend(fn (objc.Class, objc.SEL, [*:0]const u8) callconv(.c) objc.id);
    return stringWithUTF8(NSString, objc.sel("stringWithUTF8String:"), s.ptr);
}

// CGColor (CoreGraphics).
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
