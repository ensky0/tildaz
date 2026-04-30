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
