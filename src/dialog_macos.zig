//! macOS 의 dialog 구현 — `osascript` 의 `display dialog`. NSApp 부트스트랩
//! 무관 동기 modal 이라 config 에러처럼 NSApp init 전 호출도 OK. NSAlert 직접
//! 호출은 NSApp activate 이후라야 자연스러워서 일관성을 위해 osascript 통일.
//!
//! `dialog.zig` 에서 comptime 으로 select.

const std = @import("std");
const dialog = @import("dialog.zig");

pub fn show(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    // AppleScript 의 큰따옴표 / 백슬래시 escape 후 script 조립.
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
