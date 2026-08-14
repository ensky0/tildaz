const std = @import("std");
const run_options = @import("../run_options.zig");
const Runtime = @import("../runtime.zig").Runtime;

pub fn showPanic(msg: []const u8, addr: usize, _: ?*std.builtin.StackTrace) noreturn {
    std.debug.print("panic: {s}\nreturn address: 0x{x}\n", .{ msg, addr });
    std.process.exit(1);
}

pub fn showFatalRunError(err: anyerror) void {
    std.debug.print("TildaZ failed to start.\n\nError: {s}\n", .{@errorName(err)});
}

pub fn run(rt: Runtime, opts: run_options.RunOptions) !void {
    _ = rt;
    // 이 platform 은 애초에 실행되지 않는다 — 측정 옵션도 의미가 없다 (#382).
    _ = opts;
    return error.UnsupportedPlatform;
}
