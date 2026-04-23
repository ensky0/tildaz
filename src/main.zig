const std = @import("std");
const windows_host = @import("windows_host.zig");

/// ReleaseFast에서도 crash 원인을 표시하는 panic handler
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    const addr = ret_addr orelse @returnAddress();
    windows_host.showPanic(msg, addr);
}

pub fn main() void {
    windows_host.run() catch |err| windows_host.showFatalRunError(err);
}
