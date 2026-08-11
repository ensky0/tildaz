//! Linux desktop hotkey 표기 공통 helper.
//!
//! GNOME/Cinnamon GSettings, sway, KGlobalAccel이 같은 XKB keysym을
//! 서로 다른 외부 형식으로 보낼 때 key 이름과 사용자 표시 문자열을 한 곳에서
//! 공유한다. 등록 backend의 수명주기와 무관한 순수 formatting 책임만 둔다.

const std = @import("std");
const runtime = @import("../../runtime.zig");
const config_mod = @import("../../config.zig");
const log = @import("../../log.zig");

/// xkb keysym → GTK/XKB accelerator key 이름. Latin/숫자는 ASCII 한 글자,
/// function/special key는 `F1`, `space`, `Return` 등의 표준 이름을 쓴다.
pub fn gtkName(keysym: u32) []const u8 {
    return config_mod.linuxKeysymName(keysym) orelse blk: {
        log.appendLine("hotkey", "gtkName: unmapped keysym=0x{x} — config.linuxKeysymFromName out of sync? 'F1' fallback (#208)", .{keysym});
        break :blk "F1";
    };
}

/// xkb keysym + modifier → KDE 친화 사용자 표시 (`Meta+A`,
/// `Ctrl+Shift+T`, `Ctrl+\``, `Alt+F12`). backend 송신 형식이 아니라 dialog와
/// log에만 사용한다.
pub fn displayString(buf: []u8, keysym: u32, modifiers: u32) []const u8 {
    var fbs = std.Io.fixedBufferStream(buf);
    const w = fbs.writer();
    if ((modifiers & 0x2) != 0) w.writeAll("Ctrl+") catch {};
    if ((modifiers & 0x4) != 0) w.writeAll("Shift+") catch {};
    if ((modifiers & 0x1) != 0) w.writeAll("Alt+") catch {};
    if ((modifiers & 0x8) != 0) w.writeAll("Meta+") catch {};
    const word: ?[]const u8 = switch (keysym) {
        0xffbe => "F1",
        0xffbf => "F2",
        0xffc0 => "F3",
        0xffc1 => "F4",
        0xffc2 => "F5",
        0xffc3 => "F6",
        0xffc4 => "F7",
        0xffc5 => "F8",
        0xffc6 => "F9",
        0xffc7 => "F10",
        0xffc8 => "F11",
        0xffc9 => "F12",
        0xff09 => "Tab",
        0xff0d => "Return",
        0xff1b => "Escape",
        0x0020 => "Space",
        else => null,
    };
    if (word) |s| {
        w.writeAll(s) catch {};
    } else if (keysym >= 'a' and keysym <= 'z') {
        const c: u8 = @intCast(keysym - 0x20);
        w.writeAll(&[1]u8{c}) catch {};
    } else if (keysym >= 0x20 and keysym <= 0x7e) {
        const c: u8 = @intCast(keysym);
        w.writeAll(&[1]u8{c}) catch {};
    } else {
        w.writeAll("?") catch {};
    }
    return fbs.getWritten();
}

test "Linux hotkey display string keeps Qt-friendly names" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("F1", displayString(&buf, 0xffbe, 0));
    try std.testing.expectEqualStrings("Ctrl+Shift+T", displayString(&buf, 't', 0x2 | 0x4));
    try std.testing.expectEqualStrings("Meta+`", displayString(&buf, '`', 0x8));
    try std.testing.expectEqualStrings("Alt+F12", displayString(&buf, 0xffc9, 0x1));
}
