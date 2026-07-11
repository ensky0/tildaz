const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .linux => @import("shortcut_sync/linux.zig"),
    else => struct {
        pub fn sync(_: std.mem.Allocator, _: []const u32) !void {}
    },
};

pub fn sync(allocator: std.mem.Allocator, indices: []const u32) !void {
    try impl.sync(allocator, indices);
}

test "platform shortcut synchronization helpers" {
    if (builtin.os.tag == .linux) {
        const config = @import("config.zig");
        var buf: [96]u8 = undefined;
        const hotkey = config.Hotkey.fromString("ctrl+shift+f12").?;
        try std.testing.expectEqualStrings("CTRL SHIFT ,F12", try impl.hyprlandAccel(&buf, hotkey));
        try std.testing.expectEqual(@as(?usize, 2), impl.findClosingMapLine("{\n}\n"));
        try std.testing.expectEqual(@as(?usize, null), impl.findClosingMapLine("{}\n"));
    }
}
