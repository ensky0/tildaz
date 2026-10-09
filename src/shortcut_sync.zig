const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("runtime.zig").Runtime;

const impl = switch (builtin.os.tag) {
    .linux => @import("shortcut_sync/linux.zig"),
    else => struct {
        pub fn sync(_: Runtime, _: std.mem.Allocator, _: []const u32) !void {}
        pub fn removeAll(_: Runtime, _: std.mem.Allocator) !void {}
    },
};

pub fn sync(rt: Runtime, allocator: std.mem.Allocator, indices: []const u32) !void {
    try impl.sync(rt, allocator, indices);
}

/// #700 — `tildaz --desktop remove`. 우리 항목을 모두 지운다. `sync` 와 달리 **지금 세션과
/// 무관하게** 파일에 남은 것까지 치운다 — 제거는 다른 데스크톱에서 돌릴 수도 있다.
pub fn removeAll(rt: Runtime, allocator: std.mem.Allocator) !void {
    try impl.removeAll(rt, allocator);
}

test "platform shortcut synchronization helpers" {
    if (builtin.os.tag == .linux) {
        const config = @import("config.zig");
        var buf: [96]u8 = undefined;
        const hotkey = config.Hotkey.fromString("ctrl+shift+f12").?;
        try std.testing.expectEqualStrings("CTRL SHIFT ,F12", try impl.hyprlandAccel(&buf, hotkey));
    }
}
