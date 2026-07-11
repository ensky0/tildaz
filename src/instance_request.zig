const builtin = @import("builtin");

pub fn send() !void {
    switch (builtin.os.tag) {
        .linux => try @import("host/linux/single_instance.zig").sendNewInstanceRequest(),
        .windows => try @import("instance_request/windows.zig").send(),
        .macos => try @import("instance_request/macos.zig").send(),
        else => return error.UnsupportedPlatform,
    }
}
