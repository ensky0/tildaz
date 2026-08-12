const std = @import("std");
const window = @import("../window.zig");
const windows = std.os.windows;

extern "user32" fn FindWindowW([*:0]const u16, [*:0]const u16) callconv(.c) ?*anyopaque;
extern "user32" fn SendMessageW(?*anyopaque, c_uint, usize, isize) callconv(.c) isize;
extern "kernel32" fn CreateMutexW(?*anyopaque, windows.BOOL, [*:0]const u16) callconv(.c) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, windows.DWORD) callconv(.c) windows.DWORD;
extern "kernel32" fn ReleaseMutex(windows.HANDLE) callconv(.c) windows.BOOL;

const WAIT_OBJECT_0: windows.DWORD = 0x00000000;
const WAIT_ABANDONED: windows.DWORD = 0x00000080;
const WAIT_TIMEOUT: windows.DWORD = 0x00000102;

const GateWait = enum { acquired, busy, failed };

fn classifyGateWait(result: windows.DWORD) GateWait {
    return switch (result) {
        WAIT_OBJECT_0, WAIT_ABANDONED => .acquired,
        WAIT_TIMEOUT => .busy,
        else => .failed,
    };
}

pub const RequestGate = struct {
    handle: windows.HANDLE,

    pub fn deinit(self: *RequestGate) void {
        _ = ReleaseMutex(self.handle);
        windows.CloseHandle(self.handle);
    }
};

/// plain launcher가 blocking launcher.lock보다 먼저 경쟁한다. 승자만 config
/// 복구/새-instance 요청을 수행하고, 나머지는 같은 burst로 병합되어 즉시 종료.
pub fn tryAcquireGate() !?RequestGate {
    const handle = CreateMutexW(
        null,
        .FALSE,
        std.unicode.utf8ToUtf16LeStringLiteral("Local\\TildaZ-NewInstanceRequest-v1"),
    ) orelse return error.RequestGateCreateFailed;
    errdefer windows.CloseHandle(handle);

    return switch (classifyGateWait(WaitForSingleObject(handle, 0))) {
        .acquired => .{ .handle = handle },
        .busy => {
            windows.CloseHandle(handle);
            return null;
        },
        .failed => error.RequestGateWaitFailed,
    };
}

pub fn send() !void {
    const instances = @import("../instances.zig");
    const hwnd = FindWindowW(
        std.unicode.utf8ToUtf16LeStringLiteral(instances.window_class_name),
        std.unicode.utf8ToUtf16LeStringLiteral(instances.window_title_prefix ++ "0"),
    ) orelse return error.CoordinatorNotRunning;
    // 동기 반환이 request gate의 정확한 끝 경계다. caller는 launcher.lock을
    // 반드시 먼저 해제해야 한다 — worker 0 handle이 같은 lock을 획득한다.
    if (SendMessageW(hwnd, window.WM_NEW_INSTANCE_REQUEST, 0, 0) == 0)
        return error.RequestSendFailed;
}

test "request gate maps Windows wait results" {
    try std.testing.expectEqual(GateWait.acquired, classifyGateWait(WAIT_OBJECT_0));
    try std.testing.expectEqual(GateWait.acquired, classifyGateWait(WAIT_ABANDONED));
    try std.testing.expectEqual(GateWait.busy, classifyGateWait(WAIT_TIMEOUT));
    try std.testing.expectEqual(GateWait.failed, classifyGateWait(0xFFFFFFFF));
}
