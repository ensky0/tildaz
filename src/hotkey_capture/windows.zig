const std = @import("std");
const window = @import("../window.zig");

const HWND = ?*anyopaque;
const UINT = c_uint;
const SMTO_ABORTIFHUNG: UINT = 0x0002;

extern "user32" fn FindWindowW([*:0]const u16, [*:0]const u16) callconv(.c) HWND;
extern "user32" fn SendMessageTimeoutW(HWND, UINT, usize, isize, UINT, UINT, ?*usize) callconv(.c) usize;

pub const Session = struct {
    indices: []const u32,
    active: bool = true,

    pub fn deinit(self: *Session) void {
        if (!self.active) return;
        broadcast(self.indices, window.WM_HOTKEY_CAPTURE_END) catch {};
        self.active = false;
    }
};

pub fn begin(indices: []const u32) !Session {
    broadcast(indices, window.WM_HOTKEY_CAPTURE_BEGIN) catch |err| {
        broadcast(indices, window.WM_HOTKEY_CAPTURE_END) catch {};
        return err;
    };
    return .{ .indices = indices };
}

fn broadcast(indices: []const u32, message: UINT) !void {
    for (indices) |index| {
        var title_utf8: [32]u8 = undefined;
        const title = @import("../instances.zig").windowTitle(&title_utf8, index) catch return error.InvalidInstanceTitle;
        var title_utf16: [32]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_utf16, title) catch return error.InvalidInstanceTitle;
        title_utf16[title_len] = 0;
        const hwnd = FindWindowW(
            std.unicode.utf8ToUtf16LeStringLiteral(@import("../instances.zig").window_class_name),
            @ptrCast(title_utf16[0..title_len :0]),
        ) orelse continue;
        var result: usize = 0;
        if (SendMessageTimeoutW(hwnd, message, 0, 0, SMTO_ABORTIFHUNG, 1000, &result) == 0 or result == 0)
            return error.HotkeyCaptureSyncFailed;
    }
}
