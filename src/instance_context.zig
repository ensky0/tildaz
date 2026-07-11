const std = @import("std");

var worker_index: ?u32 = null;

pub fn setWorkerIndex(index: u32) void {
    worker_index = index;
}

pub fn workerIndex() ?u32 {
    return worker_index;
}

pub fn requireWorkerIndex() u32 {
    return worker_index orelse @panic("TildaZ worker index is not set");
}

test "worker index context" {
    const previous = worker_index;
    defer worker_index = previous;

    setWorkerIndex(7);
    try std.testing.expectEqual(@as(?u32, 7), workerIndex());
    try std.testing.expectEqual(@as(u32, 7), requireWorkerIndex());
}
