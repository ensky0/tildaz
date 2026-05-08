const std = @import("std");

pub fn showPanic(msg: []const u8, addr: usize) noreturn {
    std.debug.print("panic: {s}\nreturn address: 0x{x}\n", .{ msg, addr });
    std.process.exit(1);
}

pub fn showFatalRunError(err: anyerror) void {
    std.debug.print("TildaZ failed to start.\n\nError: {s}\n", .{@errorName(err)});
}

pub fn run() !void {
    return error.UnsupportedPlatform;
}
