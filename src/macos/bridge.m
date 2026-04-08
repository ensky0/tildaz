// macOS Objective-C 브릿지 구현
// Cocoa + CoreText + CoreGraphics + CGEventTap

#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Carbon/Carbon.h>   // kVK_ 상수

#include "bridge.h"
#include <stdlib.h>
#include <math.h>

// ─── 내부 구조체 ───────────────────────────────────────────────────

@interface TildazAppDelegate : NSObject <NSApplicationDelegate>
@end

@interface TildazMetalNSView : NSView
@property (nonatomic, assign) CAMetalLayer* metalLayer;
@property (nonatomic, assign) TildazRenderFn renderFn;
@property (nonatomic, assign) void* renderUserdata;
@end

@interface TildazWindowImpl : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSPanel* nsWindow;
@property (nonatomic, strong) TildazMetalNSView* metalView;
@property (nonatomic, assign) TildazRenderFn renderFn;
@property (nonatomic, assign) void* renderUserdata;
@property (nonatomic, assign) TildazResizeFn resizeFn;
@property (nonatomic, assign) void* resizeUserdata;
@property (nonatomic, assign) TildazKeyFn keyFn;
@property (nonatomic, assign) void* keyUserdata;
@property (nonatomic, assign) TildazCharFn charFn;
@property (nonatomic, assign) void* charUserdata;
@property (nonatomic, assign) TildazMouseFn mouseFn;
@property (nonatomic, assign) void* mouseUserdata;
@property (nonatomic, assign) TildazScrollFn scrollFn;
@property (nonatomic, assign) void* scrollUserdata;
@property (nonatomic, assign) TildazTabBarFn tabBarFn;
@property (nonatomic, assign) void* tabBarUserdata;
@property (nonatomic, strong) NSTimer* renderTimer;
@property (nonatomic, assign) float cellWidth;
@property (nonatomic, assign) float cellHeight;
@property (nonatomic, assign) int tabBarHeight;
@end

// ─── 글로벌 핫키 상태 ─────────────────────────────────────────────
static CFMachPortRef g_event_tap = NULL;
static CFRunLoopSourceRef g_tap_source = NULL;
static TildazHotkeyFn g_hotkey_fn = NULL;
static void* g_hotkey_userdata = NULL;

// ─── AppDelegate ──────────────────────────────────────────────────

@implementation TildazAppDelegate

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
    (void)sender;
    return NSTerminateNow;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)app hasVisibleWindows:(BOOL)flag {
    (void)app;
    (void)flag;
    return NO;
}

@end

// ─── Metal NSView ──────────────────────────────────────────────────

@implementation TildazMetalNSView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    return self;
}

- (CALayer*)makeBackingLayer {
    CAMetalLayer* layer = [CAMetalLayer layer];
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.opaque = YES;
    self.metalLayer = layer;
    return layer;
}

- (BOOL)wantsUpdateLayer { return YES; }
- (BOOL)isFlipped { return YES; } // 좌상단 원점 (터미널 좌표계와 일치)
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { return YES; }

@end

// ─── WindowImpl ────────────────────────────────────────────────────

@implementation TildazWindowImpl

- (void)windowWillClose:(NSNotification*)note {
    (void)note;
    // 앱 종료 없이 숨기기만
    [self.nsWindow orderOut:nil];
}

- (void)windowDidResize:(NSNotification*)note {
    (void)note;
    if (!self.resizeFn) return;
    NSSize size = self.nsWindow.contentView.bounds.size;
    CGFloat scale = self.nsWindow.backingScaleFactor;
    uint16_t cols = (uint16_t)fmax(1.0, floor(size.width * scale / self.cellWidth));
    uint16_t rows = (uint16_t)fmax(1.0, floor((size.height - self.tabBarHeight) * scale / self.cellHeight));
    self.resizeFn(cols, rows, self.resizeUserdata);
}

- (void)onRenderTick:(NSTimer*)timer {
    (void)timer;
    if (self.renderFn) {
        self.renderFn(self.renderUserdata);
    }
}

@end

// ─── 이벤트 탭 콜백 (글로벌 핫키) ────────────────────────────────

static CGEventRef eventTapCallback(CGEventTapProxy proxy,
                                    CGEventType type,
                                    CGEventRef event,
                                    void* userdata) {
    (void)proxy;
    (void)userdata;
    if (type == kCGEventKeyDown) {
        CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        BOOL noMod = (flags & (kCGEventFlagMaskShift | kCGEventFlagMaskControl |
                               kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand)) == 0;
        // F1 = kVK_F1 (122)
        if (keyCode == 122 && noMod) {
            if (g_hotkey_fn) g_hotkey_fn(g_hotkey_userdata);
            return NULL; // 이벤트 삼키기
        }
    }
    return event;
}

// ─── 공개 API 구현 ─────────────────────────────────────────────────

TildazApp tildazAppCreate(void) {
    [NSApplication sharedApplication];
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory; // Dock에 표시 안 됨
    TildazAppDelegate* delegate = [[TildazAppDelegate alloc] init];
    NSApp.delegate = delegate;
    return (__bridge_retained void*)delegate;
}

void tildazAppRun(TildazApp app) {
    (void)app;
    [NSApp run];
}

void tildazAppTerminate(TildazApp app) {
    (void)app;
    [NSApp terminate:nil];
}

TildazWindow tildazWindowCreate(
    TildazApp app,
    const char* font_name,
    float font_size,
    uint8_t opacity,
    float cell_width_scale,
    float line_height_scale,
    TildazFontMetrics* out_metrics
) {
    (void)app;

    // 폰트 메트릭 측정
    CGFloat scale = NSScreen.mainScreen.backingScaleFactor;
    TildazFontMetrics metrics;
    tildazMeasureFont(font_name, font_size, scale, cell_width_scale, line_height_scale, &metrics);
    if (out_metrics) *out_metrics = metrics;

    // 패널 생성 (타이틀바 없는 부동 윈도우)
    NSRect frame = NSMakeRect(0, 0, 800, 480);
    NSUInteger style = NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel;
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:frame
                  styleMask:style
                    backing:NSBackingStoreBuffered
                      defer:YES];
    panel.level = NSFloatingWindowLevel;
    panel.opaque = NO;
    panel.backgroundColor = [NSColor clearColor];
    panel.alphaValue = opacity / 255.0;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                              | NSWindowCollectionBehaviorIgnoresCycle;
    panel.hidesOnDeactivate = NO;
    panel.acceptsMouseMovedEvents = YES;
    panel.movable = NO;

    // Metal 렌더링 뷰
    TildazMetalNSView* metalView = [[TildazMetalNSView alloc] initWithFrame:frame];
    panel.contentView = metalView;

    TildazWindowImpl* impl = [[TildazWindowImpl alloc] init];
    impl.nsWindow = panel;
    impl.metalView = metalView;
    impl.cellWidth = metrics.cell_width * (float)scale;
    impl.cellHeight = metrics.cell_height * (float)scale;
    impl.tabBarHeight = (int)(24 * scale); // 탭바 높이 24pt
    panel.delegate = impl;

    // 60fps 렌더 타이머
    impl.renderTimer = [NSTimer
        scheduledTimerWithTimeInterval:1.0/60.0
        target:impl
        selector:@selector(onRenderTick:)
        userInfo:nil
        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:impl.renderTimer forMode:NSRunLoopCommonModes];

    return (__bridge_retained void*)impl;
}

void tildazWindowDestroy(TildazWindow win) {
    TildazWindowImpl* impl = (__bridge_transfer TildazWindowImpl*)win;
    [impl.renderTimer invalidate];
    [impl.nsWindow close];
}

void tildazWindowShow(TildazWindow win) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;
    [impl.nsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

void tildazWindowHide(TildazWindow win) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;
    [impl.nsWindow orderOut:nil];
}

bool tildazWindowIsVisible(TildazWindow win) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;
    return impl.nsWindow.isVisible;
}

void tildazWindowSetPosition(TildazWindow win, int dock, uint8_t width_pct, uint8_t height_pct, uint8_t offset_pct) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;

    // 커서가 있는 스크린
    NSPoint mouse = [NSEvent mouseLocation];
    NSScreen* screen = nil;
    for (NSScreen* s in NSScreen.screens) {
        if (NSPointInRect(mouse, s.frame)) { screen = s; break; }
    }
    if (!screen) screen = NSScreen.mainScreen;

    NSRect work = screen.visibleFrame;
    CGFloat sw = work.size.width;
    CGFloat sh = work.size.height;
    CGFloat sx = work.origin.x;
    CGFloat sy = work.origin.y;

    CGFloat w = sw * width_pct / 100.0;
    CGFloat h = sh * height_pct / 100.0;
    CGFloat x, y;

    // dock: 0=top, 1=bottom, 2=left, 3=right
    switch (dock) {
        case 2: // left
            x = sx; y = sy + (sh - h) * offset_pct / 100.0; break;
        case 3: // right
            x = sx + sw - w; y = sy + (sh - h) * offset_pct / 100.0; break;
        case 1: // bottom
            x = sx + (sw - w) * offset_pct / 100.0; y = sy; break;
        case 0: // top (기본)
        default:
            x = sx + (sw - w) * offset_pct / 100.0; y = sy + sh - h; break;
    }

    [impl.nsWindow setFrame:NSMakeRect(x, y, w, h) display:NO];
}

void tildazWindowSetOpacity(TildazWindow win, uint8_t opacity) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;
    impl.nsWindow.alphaValue = opacity / 255.0;
}

TildazMetalView tildazWindowGetMetalView(TildazWindow win) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;
    return (__bridge void*)impl.metalView;
}

void tildazWindowScheduleRedraw(TildazWindow win) {
    (void)win;
    // 타이머가 이미 60fps로 돌고 있음. 즉시 렌더가 필요하면 dispatch 사용.
    dispatch_async(dispatch_get_main_queue(), ^{});
}

void tildazWindowSetRenderCallback(TildazWindow win, TildazRenderFn fn, void* userdata) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;
    impl.renderFn = fn;
    impl.renderUserdata = userdata;
    impl.metalView.renderFn = fn;
    impl.metalView.renderUserdata = userdata;
}

void tildazWindowSetResizeCallback(TildazWindow win, TildazResizeFn fn, void* userdata) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;
    impl.resizeFn = fn;
    impl.resizeUserdata = userdata;
}

void tildazWindowSetKeyCallback(TildazWindow win, TildazKeyFn fn, void* userdata) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;
    impl.keyFn = fn;
    impl.keyUserdata = userdata;
}

void tildazWindowSetCharCallback(TildazWindow win, TildazCharFn fn, void* userdata) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;
    impl.charFn = fn;
    impl.charUserdata = userdata;
}

void tildazWindowSetMouseCallback(TildazWindow win, TildazMouseFn fn, void* userdata) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;
    impl.mouseFn = fn;
    impl.mouseUserdata = userdata;
}

void tildazWindowSetScrollCallback(TildazWindow win, TildazScrollFn fn, void* userdata) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;
    impl.scrollFn = fn;
    impl.scrollUserdata = userdata;
}

void tildazWindowSetTabBarCallback(TildazWindow win, TildazTabBarFn fn, void* userdata) {
    TildazWindowImpl* impl = (__bridge TildazWindowImpl*)win;
    impl.tabBarFn = fn;
    impl.tabBarUserdata = userdata;
}

bool tildazRegisterHotkey(TildazHotkeyFn fn, void* userdata) {
    g_hotkey_fn = fn;
    g_hotkey_userdata = userdata;

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
    g_event_tap = CGEventTapCreate(
        kCGAnnotatedSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        eventTapCallback,
        NULL
    );
    if (!g_event_tap) return false;

    g_tap_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_event_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), g_tap_source, kCFRunLoopCommonModes);
    CGEventTapEnable(g_event_tap, true);
    return true;
}

void tildazUnregisterHotkey(void) {
    if (g_event_tap) {
        CGEventTapEnable(g_event_tap, false);
        CFRelease(g_event_tap);
        g_event_tap = NULL;
    }
    if (g_tap_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), g_tap_source, kCFRunLoopCommonModes);
        CFRelease(g_tap_source);
        g_tap_source = NULL;
    }
}

char* tildazClipboardGet(void) {
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    NSString* str = [pb stringForType:NSPasteboardTypeString];
    if (!str) return NULL;
    const char* utf8 = str.UTF8String;
    if (!utf8) return NULL;
    return strdup(utf8);
}

void tildazClipboardSet(const char* utf8_text) {
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:[NSString stringWithUTF8String:utf8_text] forType:NSPasteboardTypeString];
}

bool tildazMeasureFont(
    const char* font_name,
    float font_size,
    float scale_factor,
    float cell_width_scale,
    float line_height_scale,
    TildazFontMetrics* out
) {
    NSString* name = [NSString stringWithUTF8String:font_name];
    CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)name, font_size, NULL);
    if (!font) {
        // 폴백: 시스템 고정폭 폰트
        font = CTFontCreateWithName(CFSTR("Menlo"), font_size, NULL);
        if (!font) return false;
    }

    CGFloat ascent = CTFontGetAscent(font);
    CGFloat descent = CTFontGetDescent(font);
    CGFloat leading = CTFontGetLeading(font);

    // 'M' 문자의 폭으로 셀 너비 측정
    UniChar ch = 'M';
    CGGlyph glyph;
    CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1);
    CGSize advance;
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, &glyph, &advance, 1);

    float base_w = (float)(advance.width);
    float base_h = (float)(ascent + descent + leading);

    out->cell_width = fmaxf(1.0f, roundf(base_w * cell_width_scale));
    out->cell_height = fmaxf(1.0f, roundf(base_h * line_height_scale));
    out->ascent = (float)ascent;
    out->descent = (float)descent;
    out->leading = (float)leading;

    CFRelease(font);
    (void)scale_factor;
    return true;
}

void tildazGetWorkArea(int* x, int* y, int* w, int* h) {
    NSPoint mouse = [NSEvent mouseLocation];
    NSScreen* screen = nil;
    for (NSScreen* s in NSScreen.screens) {
        if (NSPointInRect(mouse, s.frame)) { screen = s; break; }
    }
    if (!screen) screen = NSScreen.mainScreen;
    NSRect work = screen.visibleFrame;
    *x = (int)work.origin.x;
    *y = (int)work.origin.y;
    *w = (int)work.size.width;
    *h = (int)work.size.height;
}

void* tildazGetNextDrawable(TildazMetalView view) {
    TildazMetalNSView* metalView = (__bridge TildazMetalNSView*)view;
    return (__bridge void*)[metalView.metalLayer nextDrawable];
}
