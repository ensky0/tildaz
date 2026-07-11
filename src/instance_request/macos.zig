const objc = @import("../macos_objc.zig");

pub const notification_name = "me.ensky0.tildaz.new-instance";

pub fn send() !void {
    const Center = objc.getClass("NSDistributedNotificationCenter");
    const get = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const center = get(Center, objc.sel("defaultCenter")) orelse return error.NotificationCenterUnavailable;
    const post = objc.objcSend(fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) void);
    post(center, objc.sel("postNotificationName:object:"), objc.nsString(notification_name), null);
}
