const std = @import("std");
const builtin = @import("builtin");
const host = switch (builtin.os.tag) {
    .windows => @import("windows_host.zig"),
    else => @import("unsupported_host.zig"),
};

/// ReleaseFast에서도 crash 원인을 표시하는 panic handler
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    const addr = ret_addr orelse @returnAddress();
    host.showPanic(msg, addr);
}

pub fn main() void {
    host.run() catch |err| host.showFatalRunError(err);
}
