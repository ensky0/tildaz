const std = @import("std");
const objc = @import("../macos_objc.zig");
const app_id = @import("../app_id.zig");

/// 같은 판의 다른 worker 에게만 "hotkey 를 잠깐 멈춰라" 를 알린다. 판 (dev · 릴리즈) 을
/// 가르지 않으면 dev 의 캡처가 릴리즈 hotkey 까지 멈춘다 (#760 — `instance_request` 와 같은 결함).
pub const begin_notification_name = app_id.bundle_id ++ ".hotkey-capture-begin";
pub const end_notification_name = app_id.bundle_id ++ ".hotkey-capture-end";

test "알림 이름은 판마다 갈린다 (#760)" {
    const request = @import("../instance_request/macos.zig");
    for ([_][]const u8{ request.notification_name, begin_notification_name, end_notification_name }) |n| {
        try std.testing.expect(std.mem.startsWith(u8, n, app_id.bundle_id ++ "."));
    }
    if (app_id.is_dev) try std.testing.expectEqualStrings("me.ensky0.tildaz.dev.new-instance", request.notification_name);
}

var suspended = std.atomic.Value(bool).init(false);

pub const Session = struct {
    active: bool = true,

    pub fn deinit(self: *Session) void {
        if (!self.active) return;
        post(end_notification_name) catch {};
        setSuspended(false);
        self.active = false;
    }
};

pub fn begin(_: []const u32) !Session {
    setSuspended(true);
    post(begin_notification_name) catch |err| {
        setSuspended(false);
        return err;
    };
    return .{};
}

pub fn setSuspended(value: bool) void {
    suspended.store(value, .release);
}

pub fn isSuspended() bool {
    return suspended.load(.acquire);
}

fn post(comptime name: [:0]const u8) !void {
    const Center = objc.getClass("NSDistributedNotificationCenter");
    const get = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const center = get(Center, objc.sel("defaultCenter")) orelse return error.NotificationCenterUnavailable;
    const send = objc.objcSend(fn (objc.id, objc.SEL, objc.id, objc.id, objc.id, bool) callconv(.c) void);
    send(
        center,
        objc.sel("postNotificationName:object:userInfo:deliverImmediately:"),
        objc.nsString(name),
        null,
        null,
        true,
    );
}
