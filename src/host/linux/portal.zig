//! XDG Desktop Portal `GlobalShortcuts` client (L9).
//!
//! Wayland 의 보안 모델 상 client 가 자체적으로 global hotkey 등록 불가 (다른
//! app focus 시에도 도달하는 keyboard event = cross-client 가로채기는 protocol
//! 자체에 없음 — 의도적). 대신 compositor 가 portal 을 통해 shortcut service
//! 제공: tildaz → portal `GlobalShortcuts.CreateSession` + `BindShortcuts` →
//! compositor 가 hotkey routing → `Activated` signal 로 tildaz 에 알림.
//!
//! 모든 portal method 는 **Request object pattern**:
//!   1. Client → portal: method call (예: `CreateSession(options)`)
//!   2. portal → Client: 즉시 method reply 로 Request object path 반환
//!   3. portal 가 user / compositor 와 interaction (필요 시)
//!   4. portal → Client: `org.freedesktop.portal.Request.Response` signal
//!      (response code + result dict)
//!
//! L9-β-1 scope: `CreateSession` 한 단계만. session_handle 보관. shortcut
//! 등록 (`BindShortcuts`) 은 L9-β-2, signal subscribe + toggle 은 L9-γ / δ.
//!
//! spec 출처: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html
//! / Request pattern https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html

const std = @import("std");
const log = @import("../../log.zig");
const dbus = @import("dbus.zig");

const portal_destination: [*:0]const u8 = "org.freedesktop.portal.Desktop";
const portal_path: [*:0]const u8 = "/org/freedesktop/portal/desktop";
const interface_global_shortcuts: [*:0]const u8 = "org.freedesktop.portal.GlobalShortcuts";
const interface_request: [*:0]const u8 = "org.freedesktop.portal.Request";
const member_response: [*:0]const u8 = "Response";
const member_create_session: [*:0]const u8 = "CreateSession";

/// Request handle / session handle 의 token (path 의 마지막 segment). 우리가
/// 고정 — tildaz process 안에선 동시에 portal session 한 개만 운영. 다른
/// instance 와 conflict 시 portal 가 임의 token 으로 override 가능 (spec).
const handle_token: [*:0]const u8 = "tildaz_handle";
const session_handle_token: [*:0]const u8 = "tildaz_session";

/// portal Response signal 의 응답 code (spec):
///   0 = success
///   1 = user cancelled (예: permission dialog 거절)
///   2 = other (portal 내부 fail 등)
const response_code_success: u32 = 0;

/// `read_write_dispatch` 의 한 iteration timeout (ms). signal 도착 빨라야 응답
/// 빠름. 전체 wait 의 상한은 `create_session_total_timeout_ms` 별도.
const dispatch_iter_timeout_ms: c_int = 100;
const create_session_total_timeout_ms: i64 = 30_000;
const method_call_timeout_ms: c_int = 25_000;

/// `org.freedesktop.portal.GlobalShortcuts.CreateSession` 호출 결과. 이후
/// `BindShortcuts` (L9-β-2) 가 `session_handle` 사용.
pub const GlobalShortcutsSession = struct {
    session_handle: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GlobalShortcutsSession) void {
        self.allocator.free(self.session_handle);
    }
};

/// Sender 의 D-Bus unique name (예: `:1.93`) 을 portal Request / Session
/// object path 의 segment 로 변환. spec — `:` 제거 + `.` → `_`. 결과: "1_93".
fn sanitizeSenderForPath(allocator: std.mem.Allocator, sender: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    for (sender) |c| {
        if (c == ':') continue;
        try buf.append(allocator, if (c == '.') '_' else c);
    }
    return buf.toOwnedSlice(allocator);
}

/// filter callback 의 userdata. Response signal 이 도착해 `done = true` 가
/// 되면 polling loop 가 빠짐.
const ResponseWaitState = struct {
    api: *const dbus.Api,
    expected_request_path: []const u8,
    allocator: std.mem.Allocator,
    response_code: u32 = std.math.maxInt(u32),
    session_handle: ?[]u8 = null,
    done: bool = false,
};

/// `dbus_connection_add_filter` callback — 들어오는 모든 message 가 통과.
/// portal Response signal 중 우리 request handle 의 것만 매칭, 나머지는
/// NOT_YET_HANDLED 로 통과시켜 다른 filter 도 볼 수 있게.
fn responseFilter(conn: *dbus.DBusConnection, msg: *dbus.DBusMessage, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = conn;
    const state: *ResponseWaitState = @ptrCast(@alignCast(user_data.?));
    const api = state.api;

    if (api.message_is_signal(msg, interface_request, member_response) == 0) {
        return dbus.dbus_handler_result_not_yet_handled;
    }
    const path_c = api.message_get_path(msg) orelse return dbus.dbus_handler_result_not_yet_handled;
    const path = std.mem.span(path_c);
    if (!std.mem.eql(u8, path, state.expected_request_path)) {
        return dbus.dbus_handler_result_not_yet_handled;
    }

    parseResponseBody(state, msg);
    state.done = true;
    return dbus.dbus_handler_result_handled;
}

/// Response signal body 의 `(u response_code, a{sv} results)` 를 읽어 state 채움.
/// `session_handle` key 의 string / object_path variant 만 우리가 관심.
fn parseResponseBody(state: *ResponseWaitState, msg: *dbus.DBusMessage) void {
    const api = state.api;
    var iter: dbus.DBusMessageIter = .{};
    if (api.iter_init(msg, &iter) == 0) return;

    if (api.iter_get_arg_type(&iter) != dbus.dbus_type_uint32) return;
    var code: u32 = 0;
    api.iter_get_basic(&iter, @ptrCast(&code));
    state.response_code = code;

    _ = api.iter_next(&iter);
    if (api.iter_get_arg_type(&iter) != dbus.dbus_type_array) return;

    var arr_iter: dbus.DBusMessageIter = .{};
    api.iter_recurse(&iter, &arr_iter);
    while (api.iter_get_arg_type(&arr_iter) == dbus.dbus_type_dict_entry) {
        var entry_iter: dbus.DBusMessageIter = .{};
        api.iter_recurse(&arr_iter, &entry_iter);
        if (api.iter_get_arg_type(&entry_iter) == dbus.dbus_type_string) {
            var key_c: ?[*:0]const u8 = null;
            api.iter_get_basic(&entry_iter, @ptrCast(&key_c));
            _ = api.iter_next(&entry_iter);
            if (key_c) |k| {
                const key = std.mem.span(k);
                if (std.mem.eql(u8, key, "session_handle") and api.iter_get_arg_type(&entry_iter) == dbus.dbus_type_variant) {
                    var var_iter: dbus.DBusMessageIter = .{};
                    api.iter_recurse(&entry_iter, &var_iter);
                    const val_type = api.iter_get_arg_type(&var_iter);
                    if (val_type == dbus.dbus_type_string or val_type == dbus.dbus_type_object_path) {
                        var val_c: ?[*:0]const u8 = null;
                        api.iter_get_basic(&var_iter, @ptrCast(&val_c));
                        if (val_c) |v| {
                            const v_slice = std.mem.span(v);
                            state.session_handle = state.allocator.dupe(u8, v_slice) catch null;
                        }
                    }
                }
            }
        }
        _ = api.iter_next(&arr_iter);
    }
}

/// portal `CreateSession` 호출 → Response signal wait → `session_handle` 반환.
/// 한 번에 전체 흐름 sync 처리 (startup 시점만 호출, main loop 진입 전).
pub fn createGlobalShortcutsSession(
    allocator: std.mem.Allocator,
    bus: *dbus.SessionBus,
) !GlobalShortcutsSession {
    const sender_segment = try sanitizeSenderForPath(allocator, bus.unique_name);
    defer allocator.free(sender_segment);

    const expected_request_path = try std.fmt.allocPrint(allocator, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{
        sender_segment, std.mem.span(handle_token),
    });
    defer allocator.free(expected_request_path);

    const match_rule = try std.fmt.allocPrintSentinel(allocator, "type='signal',interface='{s}',member='{s}',path='{s}'", .{
        std.mem.span(interface_request), std.mem.span(member_response), expected_request_path,
    }, 0);
    defer allocator.free(match_rule);

    var state = ResponseWaitState{
        .api = &bus.api,
        .expected_request_path = expected_request_path,
        .allocator = allocator,
    };

    if (bus.api.add_filter(bus.conn, responseFilter, &state, null) == 0) return error.PortalAddFilterFailed;
    defer bus.api.remove_filter(bus.conn, responseFilter, &state);

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);

    bus.api.add_match(bus.conn, match_rule.ptr, &err);
    if (bus.api.error_is_set(&err) != 0) {
        const msg = if (err.message) |m| std.mem.span(m) else "(no message)";
        log.appendLine("portal", "add_match failed: {s}", .{msg});
        return error.PortalAddMatchFailed;
    }
    defer {
        var err2: dbus.DBusError = .{};
        bus.api.error_init(&err2);
        bus.api.remove_match(bus.conn, match_rule.ptr, &err2);
        bus.api.error_free(&err2);
    }

    // build CreateSession method call:
    //   a{sv} options — session_handle_token / handle_token 두 entry.
    const call = bus.api.message_new_method_call(
        portal_destination,
        portal_path,
        interface_global_shortcuts,
        member_create_session,
    ) orelse return error.PortalMessageAllocFailed;
    defer bus.api.message_unref(call);

    {
        var iter: dbus.DBusMessageIter = .{};
        bus.api.iter_init_append(call, &iter);
        var arr_iter: dbus.DBusMessageIter = .{};
        if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "{sv}", &arr_iter) == 0) return error.PortalAppendFailed;
        try appendStringVariantEntry(&bus.api, &arr_iter, "session_handle_token", session_handle_token);
        try appendStringVariantEntry(&bus.api, &arr_iter, "handle_token", handle_token);
        if (bus.api.iter_close_container(&iter, &arr_iter) == 0) return error.PortalAppendFailed;
    }

    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const m = if (err.message) |x| std.mem.span(x) else "(no message)";
            log.appendLine("portal", "CreateSession method call failed: {s}", .{m});
        }
        return error.PortalMethodCallFailed;
    };
    defer bus.api.message_unref(reply);

    // method reply 의 첫 arg = Request object path. expected 와 일치 확인.
    {
        var reply_iter: dbus.DBusMessageIter = .{};
        if (bus.api.iter_init(reply, &reply_iter) == 0) return error.PortalReplyMissingArgs;
        if (bus.api.iter_get_arg_type(&reply_iter) != dbus.dbus_type_object_path) return error.PortalReplyBadType;
        var got_c: ?[*:0]const u8 = null;
        bus.api.iter_get_basic(&reply_iter, @ptrCast(&got_c));
        const got_path = if (got_c) |g| std.mem.span(g) else "";
        if (!std.mem.eql(u8, got_path, expected_request_path)) {
            log.appendLine("portal", "CreateSession request path mismatch — expected={s} got={s}", .{ expected_request_path, got_path });
            return error.PortalRequestPathMismatch;
        }
    }

    // polling loop — Response signal 받을 때까지 read_write_dispatch.
    const start_ms = std.time.milliTimestamp();
    while (!state.done) {
        if (bus.api.read_write_dispatch(bus.conn, dispatch_iter_timeout_ms) == 0) {
            log.appendLine("portal", "connection disconnected during CreateSession wait", .{});
            return error.PortalConnectionLost;
        }
        if (std.time.milliTimestamp() - start_ms > create_session_total_timeout_ms) {
            log.appendLine("portal", "CreateSession Response signal timeout", .{});
            return error.PortalResponseTimeout;
        }
    }

    if (state.response_code != response_code_success) {
        log.appendLine("portal", "CreateSession response code={d} (1=user cancel, 2=other)", .{state.response_code});
        return error.PortalCreateSessionDenied;
    }
    const handle = state.session_handle orelse {
        log.appendLine("portal", "CreateSession response missing session_handle", .{});
        return error.PortalSessionHandleMissing;
    };

    log.appendLine("portal", "GlobalShortcuts session created handle={s}", .{handle});

    return .{
        .session_handle = handle,
        .allocator = allocator,
    };
}

/// `a{sv}` 배열 안에 한 entry (`{sv}` = string key + variant value) 추가. portal
/// CreateSession options 가 모두 string variant 라 helper 로 묶음.
fn appendStringVariantEntry(
    api: *const dbus.Api,
    arr_iter: *dbus.DBusMessageIter,
    key: [*:0]const u8,
    value: [*:0]const u8,
) !void {
    var entry_iter: dbus.DBusMessageIter = .{};
    if (api.iter_open_container(arr_iter, dbus.dbus_type_dict_entry, null, &entry_iter) == 0) return error.PortalAppendFailed;
    var key_var: [*:0]const u8 = key;
    if (api.iter_append_basic(&entry_iter, dbus.dbus_type_string, @ptrCast(&key_var)) == 0) return error.PortalAppendFailed;
    var var_iter: dbus.DBusMessageIter = .{};
    if (api.iter_open_container(&entry_iter, dbus.dbus_type_variant, "s", &var_iter) == 0) return error.PortalAppendFailed;
    var value_var: [*:0]const u8 = value;
    if (api.iter_append_basic(&var_iter, dbus.dbus_type_string, @ptrCast(&value_var)) == 0) return error.PortalAppendFailed;
    if (api.iter_close_container(&entry_iter, &var_iter) == 0) return error.PortalAppendFailed;
    if (api.iter_close_container(arr_iter, &entry_iter) == 0) return error.PortalAppendFailed;
}
