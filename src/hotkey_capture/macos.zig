const std = @import("std");
const objc = @import("../macos_objc.zig");

pub const begin_notification_name = "me.ensky0.tildaz.hotkey-capture-begin";
pub const end_notification_name = "me.ensky0.tildaz.hotkey-capture-end";

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
