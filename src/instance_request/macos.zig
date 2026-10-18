const objc = @import("../macos_objc.zig");
const app_id = @import("../app_id.zig");

/// 세션 전체에 퍼지는 이름이라 판 (dev · 릴리즈) 마다 갈라야 한다. 고정 이름이던 동안
/// dev launcher 의 요청을 릴리즈 worker 도 받아 두 판이 같은 자리에 다이얼로그를 띄웠다 (#760).
/// 릴리즈 이름은 예전과 같다.
pub const notification_name = app_id.bundle_id ++ ".new-instance";

pub fn send() !void {
    const Center = objc.getClass("NSDistributedNotificationCenter");
    const get = objc.objcSend(fn (objc.Class, objc.SEL) callconv(.c) objc.id);
    const center = get(Center, objc.sel("defaultCenter")) orelse return error.NotificationCenterUnavailable;
    const post = objc.objcSend(fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) void);
    post(center, objc.sel("postNotificationName:object:"), objc.nsString(notification_name), null);
}
