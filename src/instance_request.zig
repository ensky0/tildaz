const builtin = @import("builtin");
const Runtime = @import("runtime.zig").Runtime;

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

pub fn tryAcquireGate(rt: Runtime) !?RequestGate {
    // gate 는 Windows 에서만 실체가 있고 다른 platform 은 no-op 이라 `rt` 를 쓰지 않는다 —
    // 시그니처만 세 platform 공통으로 둔다.
    _ = rt;
    if (comptime builtin.os.tag == .windows) return impl.tryAcquireGate();
    return .{};
}

pub fn send(rt: Runtime) !void {
    // `rt` 를 쓰는 것은 Linux 경로뿐이다. comptime 분기 **안**에서 버려야 다른 platform
    // 에서만 discard 가 살아 있고, Linux 빌드에서 "pointless discard" 가 되지 않는다.
    if (comptime builtin.os.tag == .linux) {
        return impl.sendNewInstanceRequest(rt);
    } else {
        _ = rt;
        return impl.send();
    }
}
