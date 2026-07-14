const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .linux => @import("host/linux/single_instance.zig"),
    .windows => @import("instance_request/windows.zig"),
    .macos => @import("instance_request/macos.zig"),
    else => @compileError("unsupported platform"),
};

const NoopRequestGate = struct {
    pub fn deinit(_: *NoopRequestGate) void {}
};

/// Windows plain-launch burst의 대표 1개를 고르는 process 간 gate. 다른
/// platform은 기존 request adapter가 자체 event 전달 방식을 유지하므로 no-op.
pub const RequestGate = if (builtin.os.tag == .windows) impl.RequestGate else NoopRequestGate;

pub fn tryAcquireGate() !?RequestGate {
    if (comptime builtin.os.tag == .windows) return impl.tryAcquireGate();
    return .{};
}

pub fn send() !void {
    if (comptime builtin.os.tag == .linux) return impl.sendNewInstanceRequest();
    return impl.send();
}
