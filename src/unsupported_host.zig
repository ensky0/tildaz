const std = @import("std");

pub fn showPanic(msg: []const u8, addr: usize) noreturn {
    std.debug.print("panic: {s}\nreturn address: 0x{x}\n", .{ msg, addr });
    std.process.exit(1);
}

pub fn showFatalRunError(err: anyerror) void {
    std.debug.print("TildaZ 실행 host가 아직 이 플랫폼을 지원하지 않습니다: {s}\n", .{@errorName(err)});
}

pub fn run() !void {
    return error.UnsupportedPlatform;
}
