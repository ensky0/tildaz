//! macOS 의 dialog 구현 — 두 path:
//!
//! 1. **NSAlert** (NSApp init 후): About / 일반 info 다이얼로그.
//! 2. **`osascript display dialog`** (NSApp init 전 fallback): config 에러
//!    같이 부트스트랩 실패 시. NSApp 무관 별도 process 라 항상 동작.
//!
//! `dialog.zig` 에서 comptime 으로 select. `markNSAppReady()` 를 host run
//! 안에서 한 번 호출 — 그 이후는 NSAlert path.
//!
//! 가시성 trick: 우리 NSWindow 가 popup level (101) 인데 NSAlert.runModal 의
//! panel 은 default modal level (8). 그대로면 alert 가 우리 윈도우 뒤에 가려.
//! `[alert window]` 의 setLevel 로 panel 을 popup+1 로 올리는 시도는 panel
//! lazy-create + runModal 내부 setup race 로 효과 없음 (실측). 또 `runModal`
//! 을 우회해 직접 panel 표시 + `runModalForWindow:` 부르는 패턴은 NSAlert 의
//! 내부 setup (panel 위치 / NSPanel default 버튼 hide / suppression off) 을
//! 통째 우회 → panel 깨짐 (실측).
//!
//! 결국 가장 안전한 우회: **alert 띄우는 동안 우리 NSWindow level 을 normal
//! (0) 로 낮추고 `runModal` 끝나면 popup (101) 복구**. alert 의 modal level
//! (8) 이 normal (0) 보다 높아 자연 위에 표시. NSAlert 내부 setup 모두 그대로.
//! 결합 (host window 알아야 함) 비용은 있지만 panel 시각이 표준.

const std = @import("std");
const objc = @import("macos_objc.zig");
const dialog = @import("dialog.zig");

var nsapp_ready: bool = false;
/// 우리 NSWindow (popup level) — alert 띄우는 동안만 normal level 로 낮춰야
/// alert 가 가려지지 않음. host 가 init 후 등록.
var host_window: objc.id = null;

/// host run() 의 NSApp setActivationPolicy 후 한 번 호출. 그 이후 dialog 가
/// NSAlert path 사용.
pub fn markNSAppReady() void {
    nsapp_ready = true;
}

/// host 의 NSWindow 등록. alert 띄우는 동안 popup → normal 로 낮춰서 alert 가
/// 그 위로 자연 표시되게.
pub fn setHostWindow(window: objc.id) void {
    host_window = window;
}

pub fn show(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    if (nsapp_ready) {
        showNSAlert(severity, title, message);
    } else {
        showOsascript(severity, title, message);
    }
}

/// NSAlert.runModal — 표준 path 그대로. NSAlert 내부 setup (panel 위치 중앙
/// 정렬 / NSPanel default 버튼 hide / suppression button off) 모두 보존.
/// 가시성은 `runModal` 호출 *직전* 우리 NSWindow level 을 normal 로 낮추고
/// runModal 종료 후 popup 복구하는 우회로 처리 (헤더 주석 참고).
fn showNSAlert(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    const NSAlert = objc.getClass("NSAlert");
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const init_obj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);

    const alert_alloc = alloc(NSAlert, objc.sel("alloc")) orelse return;
    const alert = init_obj(alert_alloc, objc.sel("init")) orelse return;

    const setText = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setText(alert, objc.sel("setMessageText:"), nsStringFromSlice(title));
    setText(alert, objc.sel("setInformativeText:"), nsStringFromSlice(message));

    const addBtn = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.id);
    _ = addBtn(alert, objc.sel("addButtonWithTitle:"), nsStringFromSlice("OK"));

    // NSAlertStyle: Warning=0, Informational=1, Critical=2.
    const setStyle = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) void);
    setStyle(alert, objc.sel("setAlertStyle:"), switch (severity) {
        .info => @as(c_long, 1),
        .err => @as(c_long, 2),
    });

    // 우리 popup-level 윈도우 level 을 잠깐 normal 로 낮춰 alert (modal level=8)
    // 이 그 위에 자연 표시. runModal 끝나면 popup 복구.
    const NSPopUpMenuWindowLevel: c_int = 101;
    const NSNormalWindowLevel: c_int = 0;
    const setLevel = objc.objcSend(fn (objc.id, objc.SEL, c_int) callconv(.c) void);

    if (host_window != null) setLevel(host_window, objc.sel("setLevel:"), NSNormalWindowLevel);
    defer if (host_window != null) setLevel(host_window, objc.sel("setLevel:"), NSPopUpMenuWindowLevel);

    const runModal = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_long);
    _ = runModal(alert, objc.sel("runModal"));
}

const NSAlertRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
const NSAlertRange = extern struct { location: usize, length: usize };

/// About 다이얼로그 NSTextView 의 delegate — selection 변경 시 즉시
/// selected text 를 clipboard 로 (#122 의 selection auto-copy 패턴과 일관).
/// NSTextView 의 cmd+c 가 NSAlert modal 안에서 firstResponder 라우팅 안
/// 되는 문제도 같이 회피.
fn aboutTextDidChangeSelection(_: objc.id, _: objc.SEL, notification: objc.id) callconv(.c) void {
    if (notification == null) return;
    const get_obj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const tv = get_obj(notification, objc.sel("object"));
    if (tv == null) return;

    const get_range = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) NSAlertRange);
    const range = get_range(tv, objc.sel("selectedRange"));
    if (range.length == 0) return; // 빈 selection 이면 clipboard 안 건드림.

    const get_str = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const full = get_str(tv, objc.sel("string"));
    if (full == null) return;
    const substr = objc.objcSend(fn (objc.id, objc.SEL, NSAlertRange) callconv(.c) objc.id);
    const sel = substr(full, objc.sel("substringWithRange:"), range);
    if (sel == null) return;

    const NSPasteboard = objc.getClass("NSPasteboard");
    const pb_get = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const pb = pb_get(NSPasteboard, objc.sel("generalPasteboard"));
    if (pb == null) return;
    const clear = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_long);
    _ = clear(pb, objc.sel("clearContents"));
    const set_str = objc.objcSend(fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) bool);
    const ns_type = objc.nsString("public.utf8-plain-text");
    _ = set_str(pb, objc.sel("setString:forType:"), sel, ns_type);
}

var about_delegate_class: ?objc.Class = null;
var about_delegate_instance: objc.id = null;

fn registerAboutDelegate() ?objc.id {
    if (about_delegate_instance != null) return about_delegate_instance;
    if (about_delegate_class == null) {
        const NSObject = objc.getClass("NSObject");
        const cls = objc.objc_allocateClassPair(NSObject, "TildazAboutDelegate", 0) orelse return null;
        if (!objc.class_addMethod(cls, objc.sel("textViewDidChangeSelection:"), @ptrCast(&aboutTextDidChangeSelection), "v@:@")) return null;
        objc.objc_registerClassPair(cls);
        about_delegate_class = cls;
    }
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const init_obj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const inst = init_obj(alloc(about_delegate_class.?, objc.sel("alloc")) orelse return null, objc.sel("init")) orelse return null;
    about_delegate_instance = inst;
    return inst;
}

/// About 전용 다이얼로그 — informativeText 대신 accessoryView 로 NSTextView
/// 를 붙인다. 이유: NSAlert 의 NSTextField (informativeText) 는
/// `setSelectable:YES` 만 줘도 cmd+c (copy:) 가 firstResponder 라우팅 안 돼
/// OK 버튼으로 흘러 클립보드 복사 안 됨. NSTextView 는 자체적으로 copy:
/// 처리 + firstResponder 정상 동작 + monospace 로 path 가독성 좋음.
pub fn showAboutAlert(title: []const u8, body: []const u8) void {
    if (!nsapp_ready) {
        showOsascript(.info, title, body);
        return;
    }

    const NSAlert = objc.getClass("NSAlert");
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const init_obj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);

    const alert_alloc = alloc(NSAlert, objc.sel("alloc")) orelse return;
    const alert = init_obj(alert_alloc, objc.sel("init")) orelse return;

    const setText = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setText(alert, objc.sel("setMessageText:"), nsStringFromSlice(title));

    const setStyle = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) void);
    setStyle(alert, objc.sel("setAlertStyle:"), 1); // Informational

    const addBtn = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.id);
    _ = addBtn(alert, objc.sel("addButtonWithTitle:"), nsStringFromSlice("OK"));

    // accessoryView: NSTextView. width 580 / height 110 — exe / config / log
    // 절대 경로 한 줄 다 들어감. selectable + editable=NO + monospace.
    const NSTextView = objc.getClass("NSTextView");
    const tv_alloc = alloc(NSTextView, objc.sel("alloc")) orelse return;
    const initWithFrame = objc.objcSend(fn (objc.id, objc.SEL, NSAlertRect) callconv(.c) objc.id);
    const tv = initWithFrame(tv_alloc, objc.sel("initWithFrame:"), .{ .x = 0, .y = 0, .w = 580, .h = 130 }) orelse return;

    const setBool = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    setBool(tv, objc.sel("setEditable:"), false);
    setBool(tv, objc.sel("setSelectable:"), true);
    setBool(tv, objc.sel("setDrawsBackground:"), false);
    setBool(tv, objc.sel("setRichText:"), false);

    const NSFont = objc.getClass("NSFont");
    const fixedFont = objc.objcSend(fn (objc.Class, objc.SEL, f64) callconv(.c) objc.id);
    const font = fixedFont(NSFont, objc.sel("userFixedPitchFontOfSize:"), 12.0);
    if (font != null) {
        const setFont = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
        setFont(tv, objc.sel("setFont:"), font);
    }

    const setStr = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setStr(tv, objc.sel("setString:"), nsStringFromSlice(body));

    // selection 자동 copy — #122 의 터미널 selection finish auto-copy 와
    // 일관. NSAlert modal 안에서 cmd+c 라우팅 안 되는 문제도 회피.
    if (registerAboutDelegate()) |delegate| {
        const setDelegate = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
        setDelegate(tv, objc.sel("setDelegate:"), delegate);
    }

    const setAccessory = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setAccessory(alert, objc.sel("setAccessoryView:"), tv);

    // host popup level → normal (NSAlert 가 위에 표시되도록), 끝나면 복구.
    const NSPopUpMenuWindowLevel: c_int = 101;
    const NSNormalWindowLevel: c_int = 0;
    const setLevel = objc.objcSend(fn (objc.id, objc.SEL, c_int) callconv(.c) void);
    if (host_window != null) setLevel(host_window, objc.sel("setLevel:"), NSNormalWindowLevel);
    defer if (host_window != null) setLevel(host_window, objc.sel("setLevel:"), NSPopUpMenuWindowLevel);

    const runModal = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_long);
    _ = runModal(alert, objc.sel("runModal"));
}

/// AppleScript fallback — NSApp 무관, config 에러 같이 부트스트랩 실패 시.
fn showOsascript(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    var script_buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&script_buf);
    const w = fbs.writer();

    w.writeAll("display dialog \"") catch return;
    appendEscaped(w, message) catch return;
    w.writeAll("\" buttons {\"OK\"} default button \"OK\" with icon ") catch return;
    w.writeAll(switch (severity) {
        .info => "note",
        .err => "stop",
    }) catch return;
    w.writeAll(" with title \"") catch return;
    appendEscaped(w, title) catch return;
    w.writeAll("\"") catch return;

    const script = fbs.getWritten();

    var child = std.process.Child.init(
        &.{ "/usr/bin/osascript", "-e", script },
        std.heap.page_allocator,
    );
    _ = child.spawnAndWait() catch {};
}

fn appendEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
}

/// `[]const u8` slice → NSString (UTF-8). stack buffer 에 복사 + null terminate
/// 후 stringWithUTF8String: — NSString 이 자기 복사 만드므로 함수 return 후
/// 안전. 8KB 한도 (긴 메시지엔 truncate).
fn nsStringFromSlice(s: []const u8) objc.id {
    var buf: [8192]u8 = undefined;
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    const NSString = objc.getClass("NSString");
    const stringWithUTF8 = objc.objcSend(fn (objc.Class, objc.SEL, [*:0]const u8) callconv(.c) objc.id);
    return stringWithUTF8(NSString, objc.sel("stringWithUTF8String:"), @ptrCast(&buf));
}
