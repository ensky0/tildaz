const std = @import("std");
const builtin = @import("builtin");

const platform = switch (builtin.os.tag) {
    .windows => @import("windows/main.zig"),
    .macos => @import("macos/main.zig"),
    else => @compileError("unsupported OS: " ++ @tagName(builtin.os.tag)),
};

pub const main = platform.main;

/// Custom panic handler for Windows (shows MessageBox).
/// On other platforms, this decl is not present → Zig uses default handler.
pub const panic = if (builtin.os.tag == .windows)
    std.debug.FullPanic(struct {
        fn panic(msg: []const u8, ret_addr: ?usize) noreturn {
            @import("windows/main.zig").panic(msg, @errorReturnTrace(), ret_addr);
        }
    }.panic)
else
    std.debug.FullPanic(std.debug.defaultPanic);
