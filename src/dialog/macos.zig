//! macOS 의 dialog 구현 — 두 path:
//!
//! 1. **NSAlert** (NSApp init 후): native TildaZ icon/modal/button은 유지하고,
//!    18pt title + orange separator + 15pt read-only NSTextView accessoryView를
//!    모든 정상 info/error/confirm/About/prompt에 사용한다. 화면을 넘을 때만
//!    본문 NSScrollView에 세로 scroller가 나타난다.
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
const config = @import("../config.zig");
const objc = @import("../macos_objc.zig");
const dialog = @import("../dialog.zig");
const log = @import("../log.zig");
const messages = @import("../messages.zig");
const ui_metrics = @import("../ui_metrics.zig");

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

const NSPopUpMenuWindowLevel: c_int = 101;
const NSNormalWindowLevel: c_int = 0;

/// host window 를 popup → normal 로 잠깐 낮춰 modal alert 가 그 위에 표시되게.
/// caller 의 `runModal` 끝나면 popup 복구. host_window 가 null 이면 no-op.
fn lowerHostLevel() void {
    if (host_window == null) return;
    const setLevel = objc.objcSend(fn (objc.id, objc.SEL, c_int) callconv(.c) void);
    setLevel(host_window, objc.sel("setLevel:"), NSNormalWindowLevel);
}
fn restoreHostLevel() void {
    if (host_window == null) return;
    const setLevel = objc.objcSend(fn (objc.id, objc.SEL, c_int) callconv(.c) void);
    setLevel(host_window, objc.sel("setLevel:"), NSPopUpMenuWindowLevel);
}

fn sharedApp() objc.id {
    const NSApplication = objc.getClass("NSApplication");
    const shared = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    return shared(NSApplication, objc.sel("sharedApplication"));
}

/// #249 — 단일 버튼(OK 하나) alert 의 키보드 닫기. NSAlert 의 기본 동작만으론 두 가지가
/// 빠진다:
///   1. Esc: NSAlert 는 제목이 "Cancel" 인 버튼에만 Esc(`\x1b`)를 자동 부여하고 OK
///      하나짜리엔 안 묶는다([NSAlert.buttons]).
///   2. Enter: 보통 기본 버튼(OK)이 Return 을 받지만, About 처럼 selectable NSTextView
///      accessoryView 가 있으면 그 text view 가 first responder 라 Return 을 먼저 먹어
///      Enter 를 두 번 눌러야 닫힌다(NSButton 은 Full Keyboard Access 가 꺼져 있으면
///      first responder 가 안 돼 makeFirstResponder 로도 못 돌린다).
/// 그래서 runModal 동안 NSEvent local key monitor 를 달아 Esc(53)·Return(36)·키패드
/// Enter(76)를 *first responder 와 무관하게* 직접 가로채 `stopModalWithCode:` 로 닫는다.
/// 단일 버튼 alert 은 어느 키든 결과가 "닫기" 하나라 stopModal 로 충분(반환값 무시).
/// alert window 를 안 건드려 위치 race 없음. runModal 종료 후 removeMonitor: 로 해제.
///
/// [NSAlert.buttons]: https://developer.apple.com/documentation/appkit/nsalert/1532992-buttons
///
/// ObjC block 을 Zig 에서 직접 구성한다. captures 없는 *global* block 이라 isa 는
/// `_NSConcreteGlobalBlock`, flags 는 `BLOCK_IS_GLOBAL`. addLocalMonitor 내부의
/// Block_copy 는 global block 을 그대로 돌려주므로 정적 인스턴스로 안전하다.
const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};
const DismissMonitorBlock = extern struct {
    isa: ?*const anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const fn (*DismissMonitorBlock, objc.id) callconv(.c) objc.id,
    descriptor: *const BlockDescriptor,
};
extern const _NSConcreteGlobalBlock: anyopaque;
const BLOCK_IS_GLOBAL: c_int = 1 << 28;
const NSEventMaskKeyDown: u64 = 1 << 10;
const kVK_Return: u16 = 36;
const kVK_Escape: u16 = 53;
const kVK_KeypadEnter: u16 = 76;

/// local monitor block 의 invoke — 닫기 키(Esc/Return/키패드 Enter)면 modal 종료 + 이벤트
/// 삼킴(null 반환), 아니면 그대로 통과(event 반환).
fn dismissMonitorInvoke(_: *DismissMonitorBlock, event: objc.id) callconv(.c) objc.id {
    if (event == null) return event;
    const keyCodeOf = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) u16);
    const code = keyCodeOf(event, objc.sel("keyCode"));
    if (code == kVK_Escape or code == kVK_Return or code == kVK_KeypadEnter) {
        const app = sharedApp();
        if (app != null) {
            const stopModal = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) void);
            stopModal(app, objc.sel("stopModalWithCode:"), 0);
        }
        return null;
    }
    return event;
}

var dismiss_block_descriptor: BlockDescriptor = .{ .reserved = 0, .size = @sizeOf(DismissMonitorBlock) };
var dismiss_block: DismissMonitorBlock = .{
    .isa = null, // 런타임에 _NSConcreteGlobalBlock 로 설정 (extern 주소는 comptime 불가).
    .flags = BLOCK_IS_GLOBAL,
    .reserved = 0,
    .invoke = &dismissMonitorInvoke,
    .descriptor = &dismiss_block_descriptor,
};

/// runModal 동안만 닫기 키를 가로채는 local monitor 등록. 반환값은 removeDismissMonitor 로 해제.
fn addDismissMonitor() objc.id {
    dismiss_block.isa = &_NSConcreteGlobalBlock;
    const NSEvent = objc.getClass("NSEvent");
    const add = objc.objcSend(fn (objc.Class, objc.SEL, u64, *DismissMonitorBlock) callconv(.c) objc.id);
    return add(NSEvent, objc.sel("addLocalMonitorForEventsMatchingMask:handler:"), NSEventMaskKeyDown, &dismiss_block);
}
fn removeDismissMonitor(monitor: objc.id) void {
    if (monitor == null) return;
    const NSEvent = objc.getClass("NSEvent");
    const rm = objc.objcSend(fn (objc.Class, objc.SEL, objc.id) callconv(.c) void);
    rm(NSEvent, objc.sel("removeMonitor:"), monitor);
}

var prompt_field: objc.id = null;
var prompt_status: objc.id = null;
var prompt_alert: objc.id = null;
var prompt_capture_buf: [64]u8 = undefined;
var prompt_capture_len: usize = 0;
var prompt_validator: ?dialog.HotkeyValidator = null;

fn updatePromptValidation() bool {
    if (prompt_capture_len == 0) {
        setPromptCreateEnabled(prompt_alert, false);
        setPromptStatusText("");
        return false;
    }
    const result = if (prompt_validator) |validator|
        validator.validate(prompt_capture_buf[0..prompt_capture_len])
    else
        dialog.HotkeyValidation.check_failed;
    const available = switch (result) {
        .available => true,
        else => false,
    };
    setPromptCreateEnabled(prompt_alert, available);
    var status_buf: [256]u8 = undefined;
    const status = dialog.hotkeyValidationMessage(&status_buf, result);
    setPromptStatusText(status);
    return available;
}

fn promptMonitorInvoke(_: *DismissMonitorBlock, event: objc.id) callconv(.c) objc.id {
    if (event == null) return null;
    const keyCodeOf = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) u16);
    const keycode = keyCodeOf(event, objc.sel("keyCode"));
    const app = sharedApp();
    if (keycode == kVK_Escape) {
        if (app != null) {
            const stopModal = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) void);
            stopModal(app, objc.sel("stopModalWithCode:"), 1001);
        }
        return null;
    }
    if (keycode == kVK_Return or keycode == kVK_KeypadEnter) {
        if (updatePromptValidation() and app != null) {
            const stopModal = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) void);
            stopModal(app, objc.sel("stopModalWithCode:"), 1000);
        }
        return null;
    }
    if (keycode == 51) { // kVK_Delete
        prompt_capture_len = 0;
        setPromptFieldText("");
        _ = updatePromptValidation();
        return null;
    }

    const flagsOf = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_ulong);
    const flags = flagsOf(event, objc.sel("modifierFlags"));
    var modifiers: u32 = 0;
    if ((flags & (1 << 19)) != 0) modifiers |= config.CAPTURE_MOD_ALT;
    if ((flags & (1 << 18)) != 0) modifiers |= config.CAPTURE_MOD_CTRL;
    if ((flags & (1 << 17)) != 0) modifiers |= config.CAPTURE_MOD_SHIFT;
    if ((flags & (1 << 20)) != 0) modifiers |= config.CAPTURE_MOD_PRIMARY;
    if (config.capturedHotkeyText(&prompt_capture_buf, keycode, modifiers)) |captured| {
        prompt_capture_len = captured.len;
        setPromptFieldText(captured);
        _ = updatePromptValidation();
    }
    return null;
}

var prompt_monitor_descriptor: BlockDescriptor = .{ .reserved = 0, .size = @sizeOf(DismissMonitorBlock) };
var prompt_monitor_block: DismissMonitorBlock = .{
    .isa = null,
    .flags = BLOCK_IS_GLOBAL,
    .reserved = 0,
    .invoke = &promptMonitorInvoke,
    .descriptor = &prompt_monitor_descriptor,
};

fn addPromptMonitor() objc.id {
    prompt_monitor_block.isa = &_NSConcreteGlobalBlock;
    const NSEvent = objc.getClass("NSEvent");
    const add = objc.objcSend(fn (objc.Class, objc.SEL, u64, *DismissMonitorBlock) callconv(.c) objc.id);
    return add(NSEvent, objc.sel("addLocalMonitorForEventsMatchingMask:handler:"), NSEventMaskKeyDown, &prompt_monitor_block);
}

fn setPromptFieldText(text: []const u8) void {
    if (prompt_field == null) return;
    const set = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    set(prompt_field, objc.sel("setStringValue:"), nsStringFromSlice(text));
}

fn setPromptStatusText(text: []const u8) void {
    if (prompt_status == null) return;
    const set = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    set(prompt_status, objc.sel("setStringValue:"), nsStringFromSlice(text));
    const redraw = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    redraw(prompt_status, objc.sel("setNeedsDisplay:"), true);
}

/// #249 — alert 가 key window 가 아니면 강제로 key 로 승격한다(이미 key 면 no-op).
/// 키보드는 *key window* 로만 가는데, 키 입력에 두 갈래가 있다:
///   - Esc: 우리 local monitor 가 앱 이벤트 스트림에서 가로채 key window 와 *무관* 하게 동작.
///   - Enter: NSAlert 기본 버튼(OK/Quit)의 Return 응답이라 alert 가 *key 여야만* 동작.
/// 그래서 alert 가 key 가 아니면 "Esc 는 되는데 Enter 만 안 되는" 증상이 난다. alert 가
/// key 가 못 되는 경우: ① startup 권한창(앱이 백그라운드 launch 직후라 active 아님) ②
/// 앱이 어떤 이유로 frontmost 를 놓친 상태. 단순 `activateIgnoringOtherApps:` 는 background
/// 앱에서 거부되므로, 창을 직접 앞으로 내미는 makeKeyAndOrderFront 로 활성화한다 — 이게
/// background accessory 앱의 *정당한* 활성화 경로라 앱이 active 가 되고 alert 가 key 가
/// 된다(이어서 activate 도 호출해 frontmost 확정). `runModal` *전* 이 아니라 modal 루프
/// (`NSModalPanelRunLoopMode`) 안 = 중앙배치 *후* 라 위치 race 도 없다.
fn dialogForceKeyFn(_: objc.id, _: objc.SEL, alert: objc.id) callconv(.c) void {
    if (alert == null) return;
    const getWin = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const w = getWin(alert, objc.sel("window")) orelse return;
    const isKey = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) bool);
    if (isKey(w, objc.sel("isKeyWindow"))) return; // 이미 key — 런타임 정상 경로는 무변경.
    const mkf = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    mkf(w, objc.sel("makeKeyAndOrderFront:"), null);
    const app = sharedApp();
    if (app != null) {
        const act = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
        act(app, objc.sel("activateIgnoringOtherApps:"), true);
    }
}
var force_key_instance: objc.id = null;
/// `dialogForceKeyFn` 을 modal 루프 안에서 실행되도록 예약(중앙배치 후). 0 / 0.1s 두 시점에
/// idempotent 하게 — 비동기 activate 가 한 번에 적용 안 될 때 대비(이미 key 면 둘 다 no-op).
fn scheduleForceKey(alert: objc.id) void {
    if (force_key_instance == null) {
        const NSObject = objc.getClass("NSObject");
        const cls = objc.objc_allocateClassPair(NSObject, "TildazDialogKeyer", 0) orelse return;
        _ = objc.class_addMethod(cls, objc.sel("forceKey:"), @ptrCast(&dialogForceKeyFn), "v@:@");
        objc.objc_registerClassPair(cls);
        const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
        const init_obj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
        force_key_instance = init_obj(alloc(cls, objc.sel("alloc")) orelse return, objc.sel("init"));
    }
    const NSArray = objc.getClass("NSArray");
    const arrayWith = objc.objcSend(fn (objc.Class, objc.SEL, objc.id) callconv(.c) objc.id);
    const modes = arrayWith(NSArray, objc.sel("arrayWithObject:"), objc.nsString("NSModalPanelRunLoopMode"));
    const perform = objc.objcSend(fn (objc.id, objc.SEL, objc.SEL, objc.id, f64, objc.id) callconv(.c) void);
    const delays = [_]f64{ 0.0, 0.1 };
    for (delays) |d| {
        perform(force_key_instance, objc.sel("performSelector:withObject:afterDelay:inModes:"), objc.sel("forceKey:"), alert, d, modes);
    }
}
/// runModal 종료 후 아직 안 fire 한 forceKey 예약을 취소 — 다음 다이얼로그(다른 alert)로
/// stale 참조가 새지 않게.
fn cancelForceKey() void {
    if (force_key_instance == null) return;
    const NSObject = objc.getClass("NSObject");
    const cancel = objc.objcSend(fn (objc.Class, objc.SEL, objc.id) callconv(.c) void);
    cancel(NSObject, objc.sel("cancelPreviousPerformRequestsWithTarget:"), force_key_instance);
}

/// 새 NSAlert 인스턴스 (alloc + init). null 반환은 caller 가 fail-soft 로 무시.
fn newAlert() ?objc.id {
    const NSAlert = objc.getClass("NSAlert");
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const init_obj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const a = alloc(NSAlert, objc.sel("alloc")) orelse return null;
    const alert = init_obj(a, objc.sel("init")) orelse return null;

    // 모든 안내·오류·확인·prompt·About이 system severity icon 대신 bundle의
    // TildaZ icon을 사용한다. 각 entry가 모두 newAlert()를 거치므로 단일 지점.
    setAlertIcon(alert, applicationIcon());
    return alert;
}

fn applicationIcon() objc.id {
    const app = sharedApp();
    if (app == null) return null;
    const getIcon = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    return getIcon(app, objc.sel("applicationIconImage"));
}

fn setAlertIcon(alert: objc.id, icon: objc.id) void {
    const setIcon = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setIcon(alert, objc.sel("setIcon:"), icon);
}

/// NSAlert 의 `setMessageText:`. nil-safe.
fn setMessage(alert: objc.id, text: []const u8) void {
    const setText = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setText(alert, objc.sel("setMessageText:"), nsStringFromSlice(text));
}

/// NSAlert 의 `setInformativeText:`. nil-safe.
fn setInformative(alert: objc.id, text: []const u8) void {
    const setText = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setText(alert, objc.sel("setInformativeText:"), nsStringFromSlice(text));
}

/// NSAlert 의 `addButtonWithTitle:` — 추가 순서대로 cmd+1, cmd+2... 단축키 + 첫
/// 버튼이 default. 반환된 NSButton 은 우리가 retain 안 함 (alert 가 lifetime 관리).
fn addButton(alert: objc.id, title: []const u8) void {
    const add = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.id);
    _ = add(alert, objc.sel("addButtonWithTitle:"), nsStringFromSlice(title));
}

/// NSAlertStyle: Warning=0, Informational=1, Critical=2.
fn setStyle(alert: objc.id, style: c_long) void {
    const set = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) void);
    set(alert, objc.sel("setAlertStyle:"), style);
}

fn alertStyleFor(severity: dialog.Severity) c_long {
    return switch (severity) {
        .info => 1,
        .err => 2,
    };
}

/// host window level 을 잠깐 normal 로 낮춰 alert 가 위에 표시되게 한 뒤 `runModal`
/// 호출. 끝나면 popup level 로 복구. 결과 modal response 반환.
///
/// 포커스(alert 가 key window 가 되는 것)는 `scheduleForceKey` 한 곳이 책임진다 — accessory
/// 앱은 active 가 아니면 alert 가 key 가 못 돼 키보드를 못 받기 때문(#249).
/// `keyboard_dismiss` 가 true 면 runModal 동안 닫기 키(Esc/Enter) local monitor 를 단다 —
/// 단일 버튼(OK 하나) alert 전용. 확인창은 두 버튼의 의미가 달라(Quit/Cancel) monitor 를
/// 안 쓰고 기본 버튼 Return + Cancel 버튼 Esc keyEquivalent 로 처리하므로 false.
fn runModalOverHost(alert: objc.id, keyboard_dismiss: bool) c_long {
    lowerHostLevel();
    defer restoreHostLevel();
    // #249 — alert 가 key 가 아니면(권한창 등) 키보드를 못 받으므로 modal 루프 안에서 key 로
    // 승격. 이미 key 인 런타임 다이얼로그는 dialogForceKeyFn 이 no-op.
    scheduleForceKey(alert);
    defer cancelForceKey();
    const monitor: objc.id = if (keyboard_dismiss) addDismissMonitor() else null;
    defer if (keyboard_dismiss) removeDismissMonitor(monitor);
    const runModal = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) c_long);
    return runModal(alert, objc.sel("runModal"));
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
    const alert = newAlert() orelse return;
    setMessage(alert, title);
    addButton(alert, messages.button_ok);
    setStyle(alert, alertStyleFor(severity));
    _ = attachBrandedContent(alert, title, message);
    _ = runModalOverHost(alert, true);
}

const NSAlertRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
const NSAlertSize = extern struct { w: f64, h: f64 };
const NSAlertRange = extern struct { location: usize, length: usize };

const BrandedHeaderGeometry = struct {
    separator_y: f64,
    separator_h: f64,
    title_y: f64,
    title_h: f64,
    total_h: f64,
};

fn brandedHeaderGeometry(body_top: f64) BrandedHeaderGeometry {
    const separator_h: f64 = @floatFromInt(ui_metrics.DIALOG_SEPARATOR_THICKNESS_PT);
    const separator_row_h: f64 = @floatFromInt(ui_metrics.DIALOG_BODY_FONT_PT + 8);
    const title_h: f64 = @floatFromInt(ui_metrics.DIALOG_TITLE_FONT_PT + 8);
    const separator_y = body_top + (separator_row_h - separator_h) / 2.0;
    const title_y = body_top + separator_row_h;
    return .{
        .separator_y = separator_y,
        .separator_h = separator_h,
        .title_y = title_y,
        .title_h = title_h,
        .total_h = title_y + title_h,
    };
}

test "macOS branded dialog header uses common logical point metrics" {
    const header = brandedHeaderGeometry(100.0);
    try std.testing.expectEqual(@as(f64, 2.0), header.separator_h);
    try std.testing.expect(header.separator_y >= 100.0);
    try std.testing.expect(header.separator_y + header.separator_h <= header.title_y);
    try std.testing.expectEqual(@as(f64, 26.0), header.title_h);
    try std.testing.expectEqual(header.title_y + header.title_h, header.total_h);
}

fn dialogTextNaturalSize(tv: objc.id, layout_manager: objc.id, text_container: objc.id, minimum: NSAlertSize) NSAlertSize {
    if (layout_manager == null or text_container == null) return minimum;
    const ensureLayout = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    ensureLayout(layout_manager, objc.sel("ensureLayoutForTextContainer:"), text_container);
    const usedRect = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) NSAlertRect);
    const used = usedRect(layout_manager, objc.sel("usedRectForTextContainer:"), text_container);
    const getSize = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) NSAlertSize);
    const inset = getSize(tv, objc.sel("textContainerInset"));
    return .{
        .w = @max(minimum.w, @ceil(used.w + inset.w * 2.0)),
        .h = @max(minimum.h, @ceil(used.h + inset.h * 2.0)),
    };
}

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

const DialogBodyView = struct {
    view: objc.id,
    width: f64,
    height: f64,
};

/// 모든 정상 다이얼로그의 본문 NSScrollView + NSTextView. `reserved_h`는
/// branded header와 prompt input/status처럼 accessoryView 안에 고정할 높이다.
/// 짧은 본문은 자연 높이를 사용하고 scroller가 숨으며, 화면을 넘을 때만 본문
/// viewport가 줄어든다. NSTextView라 read-only selection/copy도 모든 길이에서 같다.
fn makeDialogBody(alert: objc.id, body: []const u8, reserved_h: f64, minimum_w: f64) ?DialogBodyView {
    // accessoryView: 세로 NSScrollView + NSTextView. 평소에는 본문 자연 높이,
    // 화면 가용 높이를 넘을 때만 AppKit scroller가 나타난다.
    const getScreen = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    var screen: objc.id = if (host_window != null) getScreen(host_window, objc.sel("screen")) else null;
    if (screen == null) {
        const NSScreen = objc.getClass("NSScreen");
        const mainScreen = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
        screen = mainScreen(NSScreen, objc.sel("mainScreen"));
    }
    const visible_frame = if (screen != null) blk: {
        const getRect = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) NSAlertRect);
        break :blk getRect(screen, objc.sel("visibleFrame"));
    } else NSAlertRect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    const max_accessory_w = @max(1.0, @min(580.0, visible_frame.w - 96.0));
    const min_accessory_w = @min(minimum_w, max_accessory_w);
    var accessory_w = max_accessory_w;

    // 제목·icon·button을 배치한 NSAlert의 실제 base 높이를 먼저 재고, visible
    // screen에서 그 높이와 prompt 고정 영역, 16pt 상하 여백을 뺀 나머지를 본문
    // 상한으로 쓴다. 화면 비율 상수로 일찍 자르지 않아 큰 화면에서는 자연 높이를
    // 더 많이 보존한다.
    const layoutAlert = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) void);
    layoutAlert(alert, objc.sel("layout"));
    const getObjForWindow = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const alert_window = getObjForWindow(alert, objc.sel("window")) orelse return null;
    const getRect = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) NSAlertRect);
    const base_alert_h = getRect(alert_window, objc.sel("frame")).h;
    const max_accessory_h = @max(32.0, visible_frame.h - base_alert_h - reserved_h - 32.0);

    const NSScrollView = objc.getClass("NSScrollView");
    const NSTextView = objc.getClass("NSTextView");
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const scroll_alloc = alloc(NSScrollView, objc.sel("alloc")) orelse return null;
    const tv_alloc = alloc(NSTextView, objc.sel("alloc")) orelse return null;
    const initWithFrame = objc.objcSend(fn (objc.id, objc.SEL, NSAlertRect) callconv(.c) objc.id);
    const initial_body_h: f64 = @floatFromInt(ui_metrics.DIALOG_BODY_FONT_PT + 8);
    const scroll_owned = initWithFrame(scroll_alloc, objc.sel("initWithFrame:"), .{ .x = 0, .y = 0, .w = accessory_w, .h = initial_body_h }) orelse return null;
    const autorelease = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const scroll = autorelease(scroll_owned, objc.sel("autorelease"));

    const setBool = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    setBool(scroll, objc.sel("setHasVerticalScroller:"), true);
    setBool(scroll, objc.sel("setHasHorizontalScroller:"), false);
    setBool(scroll, objc.sel("setAutohidesScrollers:"), true);
    setBool(scroll, objc.sel("setDrawsBackground:"), false);
    const setBorder = objc.objcSend(fn (objc.id, objc.SEL, usize) callconv(.c) void);
    setBorder(scroll, objc.sel("setBorderType:"), 0); // NSNoBorder

    const getSize = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) NSAlertSize);
    const initial_content = getSize(scroll, objc.sel("contentSize"));
    const tv_owned = initWithFrame(tv_alloc, objc.sel("initWithFrame:"), .{ .x = 0, .y = 0, .w = initial_content.w, .h = initial_content.h }) orelse return null;
    const tv = autorelease(tv_owned, objc.sel("autorelease"));

    setBool(tv, objc.sel("setEditable:"), false);
    setBool(tv, objc.sel("setSelectable:"), true);
    setBool(tv, objc.sel("setDrawsBackground:"), false);
    setBool(tv, objc.sel("setRichText:"), false);
    setBool(tv, objc.sel("setVerticallyResizable:"), true);
    setBool(tv, objc.sel("setHorizontallyResizable:"), false);

    const setSize = objc.objcSend(fn (objc.id, objc.SEL, NSAlertSize) callconv(.c) void);
    setSize(tv, objc.sel("setMinSize:"), .{ .w = 0, .h = initial_content.h });
    setSize(tv, objc.sel("setMaxSize:"), .{ .w = 10_000_000, .h = 10_000_000 });
    const setMask = objc.objcSend(fn (objc.id, objc.SEL, usize) callconv(.c) void);
    setMask(tv, objc.sel("setAutoresizingMask:"), 2); // NSViewWidthSizable

    const getObj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const text_container = getObj(tv, objc.sel("textContainer"));
    if (text_container != null) {
        setSize(text_container, objc.sel("setContainerSize:"), .{ .w = initial_content.w, .h = 10_000_000 });
        setBool(text_container, objc.sel("setWidthTracksTextView:"), true);
    }

    const NSFont = objc.getClass("NSFont");
    const fixedFont = objc.objcSend(fn (objc.Class, objc.SEL, f64) callconv(.c) objc.id);
    const font = fixedFont(NSFont, objc.sel("userFixedPitchFontOfSize:"), @floatFromInt(ui_metrics.DIALOG_BODY_FONT_PT));
    if (font != null) {
        const setFont = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
        setFont(tv, objc.sel("setFont:"), font);
    }

    const setStr = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setStr(tv, objc.sel("setString:"), nsStringFromSlice(body));

    const layout_manager = getObj(tv, objc.sel("layoutManager"));
    const setDocument = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setDocument(scroll, objc.sel("setDocumentView:"), tv);

    // 최대 폭에서 먼저 layout해 실제 longest rendered line 폭을 얻은 뒤 공통
    // 최소/최대 폭으로 clamp한다. 짧은 문구가 항상 580pt로 벌어지지 않고, 긴
    // path는 화면 경계까지 넓힌 뒤 세로 wrap/scroll 계산으로 넘어간다.
    const first_natural = dialogTextNaturalSize(
        tv,
        layout_manager,
        text_container,
        .{ .w = min_accessory_w, .h = initial_content.h },
    );
    accessory_w = @min(max_accessory_w, @max(min_accessory_w, first_natural.w + 4.0));

    // scroller가 나타나면 document 가용 폭이 줄고 wrap 행이 늘 수 있다. AppKit이
    // 실제로 준 contentSize로 폭/높이를 다시 재는 pass를 반복해 마지막 줄까지
    // document frame에 포함한다. 짧은 본문은 첫 자연 높이에 수렴해 scroller가 숨는다.
    var natural_h = first_natural.h;
    var pass: u8 = 0;
    while (pass < 3) : (pass += 1) {
        const viewport_h = if (pass == 0) max_accessory_h else @min(natural_h, max_accessory_h);
        setSize(scroll, objc.sel("setFrameSize:"), .{ .w = accessory_w, .h = viewport_h });
        const content = getSize(scroll, objc.sel("contentSize"));
        setSize(tv, objc.sel("setFrameSize:"), .{ .w = content.w, .h = @max(natural_h, content.h) });
        if (text_container != null) {
            setSize(text_container, objc.sel("setContainerSize:"), .{ .w = content.w, .h = 10_000_000 });
        }
        natural_h = dialogTextNaturalSize(
            tv,
            layout_manager,
            text_container,
            .{ .w = min_accessory_w, .h = initial_content.h },
        ).h;
    }
    const accessory_h = @min(natural_h, max_accessory_h);
    setSize(scroll, objc.sel("setFrameSize:"), .{ .w = accessory_w, .h = accessory_h });
    const final_content = getSize(scroll, objc.sel("contentSize"));
    setSize(tv, objc.sel("setFrameSize:"), .{ .w = final_content.w, .h = @max(natural_h, final_content.h) });
    if (text_container != null) {
        setSize(text_container, objc.sel("setContainerSize:"), .{ .w = final_content.w, .h = 10_000_000 });
    }

    // selection 자동 copy — #122 의 터미널 selection finish auto-copy 와
    // 일관. NSAlert modal 안에서 cmd+c 라우팅 안 되는 문제도 회피.
    if (registerAboutDelegate()) |delegate| {
        const setDelegate = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
        setDelegate(tv, objc.sel("setDelegate:"), delegate);
    }

    return .{ .view = scroll, .width = accessory_w, .height = accessory_h };
}

const BrandedContent = struct {
    view: objc.id,
    width: f64,
    height: f64,
};

fn restoreNativeAlertContent(alert: objc.id, title: []const u8, body: []const u8) void {
    setAlertIcon(alert, applicationIcon());
    setMessage(alert, title);
    setInformative(alert, body);
}

/// NSAlert의 modal panel과 native button은 유지하고 content만 공통 visual
/// language로 구성한다. AppKit 좌표는 logical point라 backing scale 변환은 OS가 한다.
fn makeBrandedContent(alert: objc.id, title: []const u8, body: []const u8, reserved_bottom_h: f64, minimum_w: f64) ?BrandedContent {
    const icon = applicationIcon();
    if (icon == null) return null;

    // NSAlert.icon=nil은 icon 숨김이 아니라 app icon 복원이다(Apple 공식 문서).
    // 빈 image dummy 없이 native TildaZ icon을 유지하고 message/informative 영역만
    // 비워 제목/font/separator/body를 accessory hierarchy에서 한 번만 표시한다.
    setAlertIcon(alert, icon);
    setMessage(alert, "");
    setInformative(alert, "");

    const header_at_zero = brandedHeaderGeometry(0.0);
    const body_view = makeDialogBody(alert, body, header_at_zero.total_h + reserved_bottom_h, minimum_w) orelse return null;
    const body_y = reserved_bottom_h;
    const header = brandedHeaderGeometry(body_y + body_view.height);
    const content_w = body_view.width;

    const NSView = objc.getClass("NSView");
    const NSTextField = objc.getClass("NSTextField");
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const initWithFrame = objc.objcSend(fn (objc.id, objc.SEL, NSAlertRect) callconv(.c) objc.id);
    const autorelease = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);

    const container_owned = initWithFrame(alloc(NSView, objc.sel("alloc")) orelse return null, objc.sel("initWithFrame:"), .{ .x = 0, .y = 0, .w = content_w, .h = header.total_h }) orelse return null;
    const container = autorelease(container_owned, objc.sel("autorelease"));

    const title_owned = initWithFrame(alloc(NSTextField, objc.sel("alloc")) orelse return null, objc.sel("initWithFrame:"), .{
        .x = 0,
        .y = header.title_y,
        .w = content_w,
        .h = header.title_h,
    }) orelse return null;
    const title_view = autorelease(title_owned, objc.sel("autorelease"));
    const setBool = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    setBool(title_view, objc.sel("setEditable:"), false);
    setBool(title_view, objc.sel("setSelectable:"), false);
    setBool(title_view, objc.sel("setBezeled:"), false);
    setBool(title_view, objc.sel("setDrawsBackground:"), false);
    setBool(title_view, objc.sel("setUsesSingleLineMode:"), true);
    const setString = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setString(title_view, objc.sel("setStringValue:"), nsStringFromSlice(title));
    const NSFont = objc.getClass("NSFont");
    const systemFont = objc.objcSend(fn (objc.Class, objc.SEL, f64) callconv(.c) objc.id);
    const title_font = systemFont(NSFont, objc.sel("systemFontOfSize:"), @floatFromInt(ui_metrics.DIALOG_TITLE_FONT_PT));
    if (title_font != null) {
        const setFont = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
        setFont(title_view, objc.sel("setFont:"), title_font);
    }

    const separator_owned = initWithFrame(alloc(NSView, objc.sel("alloc")) orelse return null, objc.sel("initWithFrame:"), .{
        .x = 0,
        .y = header.separator_y,
        .w = content_w,
        .h = header.separator_h,
    }) orelse return null;
    const separator = autorelease(separator_owned, objc.sel("autorelease"));
    setBool(separator, objc.sel("setWantsLayer:"), true);
    const getObj = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const layer = getObj(separator, objc.sel("layer"));
    if (layer == null) return null;
    const color = ui_metrics.DIALOG_SEPARATOR_COLOR;
    const NSColor = objc.getClass("NSColor");
    const makeColor = objc.objcSend(fn (objc.Class, objc.SEL, f64, f64, f64, f64) callconv(.c) objc.id);
    const orange = makeColor(
        NSColor,
        objc.sel("colorWithSRGBRed:green:blue:alpha:"),
        @as(f64, @floatFromInt(color.r)) / 255.0,
        @as(f64, @floatFromInt(color.g)) / 255.0,
        @as(f64, @floatFromInt(color.b)) / 255.0,
        1.0,
    );
    if (orange == null) return null;
    const cg_color = getObj(orange, objc.sel("CGColor"));
    if (cg_color == null) return null;
    const setColor = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setColor(layer, objc.sel("setBackgroundColor:"), cg_color);

    const setOrigin = objc.objcSend(fn (objc.id, objc.SEL, NSAlertSize) callconv(.c) void);
    setOrigin(body_view.view, objc.sel("setFrameOrigin:"), .{ .w = 0, .h = body_y });
    const addSubview = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    addSubview(container, objc.sel("addSubview:"), body_view.view);
    addSubview(container, objc.sel("addSubview:"), separator);
    addSubview(container, objc.sel("addSubview:"), title_view);

    const getWindow = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    if (getWindow(alert, objc.sel("window"))) |window| {
        setString(window, objc.sel("setTitle:"), nsStringFromSlice(title));
    }
    return .{ .view = container, .width = content_w, .height = header.total_h };
}

fn attachBrandedContent(alert: objc.id, title: []const u8, body: []const u8) bool {
    const content = makeBrandedContent(alert, title, body, 0, 320.0) orelse {
        restoreNativeAlertContent(alert, title, body);
        return false;
    };
    const setAccessory = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setAccessory(alert, objc.sel("setAccessoryView:"), content.view);
    return true;
}

fn showAboutText(title: []const u8, body: []const u8) bool {
    if (!nsapp_ready) return false;
    const alert = newAlert() orelse return false;
    setMessage(alert, title);
    setStyle(alert, alertStyleFor(.info));
    addButton(alert, messages.button_ok);
    _ = attachBrandedContent(alert, title, body);

    // #249 — NSTextView 가 first responder 라 Enter 를 먹던 문제는 runModalOverHost 의
    // dismiss monitor 가 Enter 를 직접 가로채 해결(keyboard_dismiss=true).
    _ = runModalOverHost(alert, true);
    return true;
}

pub fn showAboutAlert(title: []const u8, body: []const u8) void {
    if (!showAboutText(title, body)) show(.info, title, body);
}

/// fatal도 같은 branded NSAlert content를 사용하고, 화면을 넘을 때만 본문을
/// scroll해 전체 경로와 마지막 줄을 보존한다 (#316, #237).
pub fn showFatal(title: []const u8, body: []const u8) void {
    show(.err, title, body);
}

/// OK / Cancel 두 버튼의 확인 다이얼로그. #250 — 표준 매핑: Enter=Quit, Esc=Cancel.
/// NSAlert 의 첫 추가 버튼 = 기본(Return) + 맨 오른쪽이라 Quit 을 먼저 → Enter=Quit
/// (NSAlertFirstButtonReturn=1000). Esc=Cancel 은 NSAlert 가 자동 부여하지 않으므로
/// 두 번째 버튼(Cancel)에 Esc keyEquivalent 를 명시. 반환: Quit → true.
pub fn showConfirm(title: []const u8, message: []const u8) bool {
    // #282 C6 — bootstrap(NSApp 미준비) 단계에도 조용히 false 반환하지 않고
    // `show` 와 동일하게 osascript 로 실제 2-버튼 confirm 을 띄운다 (Windows
    // MessageBoxW / Linux overlay 처럼 backend 미가용에도 안내 후 사용자 선택).
    if (!nsapp_ready) return confirmOsascript(title, message);

    const alert = newAlert() orelse {
        log.userFacing("dialog", "NSAlert 생성 실패 — confirm 을 osascript 로 대체");
        return confirmOsascript(title, message);
    };
    setMessage(alert, title);
    setStyle(alert, 1); // Informational
    addButton(alert, messages.button_ok);
    addButton(alert, messages.button_cancel);
    setButtonEsc(alert, 1); // Cancel(두 번째 버튼) → Esc.
    _ = attachBrandedContent(alert, title, message);

    const result = runModalOverHost(alert, false);
    // NSAlertFirstButtonReturn = 1000 (= Quit, 첫 추가 버튼 = 기본).
    return result == 1000;
}

/// osascript 2-버튼 confirm — OK → true, Cancel/닫기 → false (#282 C6).
/// `display dialog` 는 Cancel 시 exit code 1 (user canceled -128), OK 시 0.
fn confirmOsascript(title: []const u8, message: []const u8) bool {
    const allocator = std.heap.page_allocator;
    var script_buf: std.ArrayList(u8) = .empty;
    defer script_buf.deinit(allocator);
    const w = script_buf.writer(allocator);
    w.writeAll("display dialog \"") catch return false;
    appendEscaped(w, message) catch return false;
    w.writeAll("\" buttons {\"Cancel\", \"OK\"} default button \"OK\" cancel button \"Cancel\"") catch return false;
    if (!(appendBundleIconClause(w) catch return false)) {
        log.appendLine("dialog", "bundle AppIcon.icns unavailable — osascript confirm without icon", .{});
    }
    w.writeAll(" with title \"") catch return false;
    appendEscaped(w, title) catch return false;
    w.writeAll("\"") catch return false;
    const script = script_buf.items;

    var child = std.process.Child.init(
        &.{ "/usr/bin/osascript", "-e", script },
        allocator,
    );
    const term = child.spawnAndWait() catch {
        log.userFacing("dialog", "osascript confirm 실행 실패 — Cancel 로 처리");
        return false;
    };
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

pub fn promptHotkey(allocator: std.mem.Allocator, title: []const u8, message: []const u8, validator: dialog.HotkeyValidator) ?[]u8 {
    // #282 C6 — hotkey 캡처는 키 이벤트 modal 이라 osascript 로 대체 불가.
    // backend 미가용 시 조용히 null 대신 안내 로그 후 null (호출부가 기존
    // hotkey 유지 등 안전 처리).
    if (!nsapp_ready) {
        log.userFacing("dialog", "hotkey 캡처 dialog 를 아직 열 수 없음 (NSApp 미준비) — 변경 취소");
        return null;
    }
    const alert = newAlert() orelse {
        log.userFacing("dialog", "hotkey 캡처 dialog 생성 실패 — 변경 취소");
        return null;
    };
    setMessage(alert, title);
    setStyle(alert, 1);
    addButton(alert, messages.button_create);
    addButton(alert, messages.button_cancel);
    setButtonEsc(alert, 1);

    const prompt_controls_h = 52.0;
    const prompt_body_gap = 16.0;
    const branded = makeBrandedContent(alert, title, message, prompt_controls_h + prompt_body_gap, 360.0) orelse {
        restoreNativeAlertContent(alert, title, message);
        return null;
    };
    const container_w = branded.width;

    const NSTextField = objc.getClass("NSTextField");
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const field_alloc = alloc(NSTextField, objc.sel("alloc")) orelse return null;
    const status_alloc = alloc(NSTextField, objc.sel("alloc")) orelse return null;
    const initWithFrame = objc.objcSend(fn (objc.id, objc.SEL, NSAlertRect) callconv(.c) objc.id);
    const field = initWithFrame(field_alloc, objc.sel("initWithFrame:"), .{ .x = 0, .y = 26, .w = container_w, .h = 26 }) orelse return null;
    const status = initWithFrame(status_alloc, objc.sel("initWithFrame:"), .{ .x = 0, .y = 0, .w = container_w, .h = 22 }) orelse return null;
    const setBool = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    for ([_]objc.id{ field, status }) |label| {
        setBool(label, objc.sel("setEditable:"), false);
        setBool(label, objc.sel("setSelectable:"), false);
        setBool(label, objc.sel("setBezeled:"), false);
        setBool(label, objc.sel("setDrawsBackground:"), false);
    }
    const setAlignment = objc.objcSend(fn (objc.id, objc.SEL, c_long) callconv(.c) void);
    setAlignment(field, objc.sel("setAlignment:"), 1); // NSTextAlignmentCenter
    setAlignment(status, objc.sel("setAlignment:"), 1);
    const NSColor = objc.getClass("NSColor");
    const getColor = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const red = getColor(NSColor, objc.sel("systemRedColor"));
    if (red != null) {
        const setColor = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
        setColor(status, objc.sel("setTextColor:"), red);
    }
    const addSubview = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    addSubview(branded.view, objc.sel("addSubview:"), field);
    addSubview(branded.view, objc.sel("addSubview:"), status);
    const setAccessory = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    setAccessory(alert, objc.sel("setAccessoryView:"), branded.view);
    prompt_field = field;
    prompt_status = status;
    prompt_alert = alert;
    prompt_capture_len = 0;
    prompt_validator = validator;
    defer prompt_validator = null;
    setPromptCreateEnabled(alert, false);

    const monitor = addPromptMonitor();
    defer removeDismissMonitor(monitor);
    defer {
        prompt_field = null;
        prompt_status = null;
        prompt_alert = null;
    }
    while (true) {
        const result = runModalOverHost(alert, false);
        if (result != 1000) return null;
        if (updatePromptValidation()) return allocator.dupe(u8, prompt_capture_buf[0..prompt_capture_len]) catch null;
    }
}

fn setPromptCreateEnabled(alert: objc.id, enabled: bool) void {
    if (alert == null) return;
    const get_buttons = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const buttons = get_buttons(alert, objc.sel("buttons")) orelse return;
    const obj_at = objc.objcSend(fn (objc.id, objc.SEL, u64) callconv(.c) objc.id);
    const button = obj_at(buttons, objc.sel("objectAtIndex:"), 0) orelse return;
    const setEnabled = objc.objcSend(fn (objc.id, objc.SEL, bool) callconv(.c) void);
    setEnabled(button, objc.sel("setEnabled:"), enabled);
}

/// NSAlert.buttons[index] 의 keyEquivalent 를 Esc(`\x1b`)로 설정. NSAlert 가 Cancel
/// 버튼에 Esc 를 자동 부여하지 않으므로 명시 (#250).
fn setButtonEsc(alert: objc.id, index: u64) void {
    const get_buttons = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    const buttons = get_buttons(alert, objc.sel("buttons")) orelse return;
    const obj_at = objc.objcSend(fn (objc.id, objc.SEL, u64) callconv(.c) objc.id);
    const btn = obj_at(buttons, objc.sel("objectAtIndex:"), index) orelse return;
    const set_keyeq = objc.objcSend(fn (objc.id, objc.SEL, objc.id) callconv(.c) void);
    set_keyeq(btn, objc.sel("setKeyEquivalent:"), objc.nsString("\x1b"));
}

/// AppleScript fallback — NSApp 무관, config 에러 같이 부트스트랩 실패 시.
fn showOsascript(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    _ = severity;
    const allocator = std.heap.page_allocator;
    var script_buf: std.ArrayList(u8) = .empty;
    defer script_buf.deinit(allocator);
    const w = script_buf.writer(allocator);

    w.writeAll("display dialog \"") catch return;
    appendEscaped(w, message) catch return;
    w.writeAll("\" buttons {\"OK\"} default button \"OK\"") catch return;
    if (!(appendBundleIconClause(w) catch return)) {
        log.appendLine("dialog", "bundle AppIcon.icns unavailable — osascript alert without icon", .{});
    }
    w.writeAll(" with title \"") catch return;
    appendEscaped(w, title) catch return;
    w.writeAll("\"") catch return;

    const script = script_buf.items;

    var child = std.process.Child.init(
        &.{ "/usr/bin/osascript", "-e", script },
        allocator,
    );
    _ = child.spawnAndWait() catch {};
}

/// signed app bundle의 AppIcon.icns 절대경로. osascript fallback도 NSAlert와
/// 같은 TildaZ icon을 쓰기 위해 NSBundle의 실제 resource lookup을 사용한다.
fn bundleIconPath() ?[]const u8 {
    const NSBundle = objc.getClass("NSBundle");
    const getBundle = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const bundle = getBundle(NSBundle, objc.sel("mainBundle")) orelse return null;
    const getPath = objc.objcSend(fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) objc.id);
    const path = getPath(bundle, objc.sel("pathForResource:ofType:"), objc.nsString("AppIcon"), objc.nsString("icns"));
    if (path == null) return null;
    const getLen = objc.objcSend(fn (objc.id, objc.SEL, usize) callconv(.c) usize);
    const len = getLen(path, objc.sel("lengthOfBytesUsingEncoding:"), 4); // NSUTF8StringEncoding
    if (len == 0) return null;
    const getUtf8 = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) [*:0]const u8);
    const utf8 = getUtf8(path, objc.sel("UTF8String"));
    return utf8[0..len];
}

fn appendBundleIconClause(w: anytype) !bool {
    const path = bundleIconPath() orelse return false;
    try w.writeAll(" with icon POSIX file \"");
    try appendEscaped(w, path);
    try w.writeAll("\"");
    return true;
}

fn appendEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
}

/// `[]const u8` slice → NSString (UTF-8). 길이를 함께 전달하므로 NUL 종료나
/// 고정 stack buffer가 필요 없고, NSString이 전체 byte를 자기 storage로 복사한다.
fn nsStringFromSlice(s: []const u8) objc.id {
    const NSString = objc.getClass("NSString");
    const alloc = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const raw = alloc(NSString, objc.sel("alloc")) orelse return null;
    const initBytes = objc.objcSend(fn (objc.id, objc.SEL, [*]const u8, usize, usize) callconv(.c) objc.id);
    const value = initBytes(raw, objc.sel("initWithBytes:length:encoding:"), s.ptr, s.len, 4) orelse return null; // NSUTF8StringEncoding
    const autorelease = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) objc.id);
    return autorelease(value, objc.sel("autorelease"));
}
