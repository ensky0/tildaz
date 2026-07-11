const std = @import("std");
const window = @import("../window.zig");

extern "user32" fn FindWindowW([*:0]const u16, [*:0]const u16) callconv(.c) ?*anyopaque;
extern "user32" fn PostMessageW(?*anyopaque, c_uint, usize, isize) callconv(.c) c_int;

pub fn send() !void {
    const hwnd = FindWindowW(
        std.unicode.utf8ToUtf16LeStringLiteral("TildaZWindow"),
        std.unicode.utf8ToUtf16LeStringLiteral("TildaZ-0"),
    ) orelse return error.CoordinatorNotRunning;
    if (PostMessageW(hwnd, window.WM_NEW_INSTANCE_REQUEST, 0, 0) == 0) return error.RequestSendFailed;
}
