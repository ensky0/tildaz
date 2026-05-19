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
const member_bind_shortcuts: [*:0]const u8 = "BindShortcuts";
const member_activated: [*:0]const u8 = "Activated";

/// Request handle / session handle 의 token (path 의 마지막 segment). 우리가
/// 고정 — tildaz process 안에선 동시에 portal session 한 개만 운영. 다른
/// instance 와 conflict 시 portal 가 임의 token 으로 override 가능 (spec).
const handle_token: [*:0]const u8 = "tildaz_handle";
const session_handle_token: [*:0]const u8 = "tildaz_session";
const bind_handle_token: [*:0]const u8 = "tildaz_bind";

/// L9-β-2 — 우리가 portal 에 등록하는 유일한 shortcut id. Activated signal 의
/// `shortcut_id` arg 도 이 값으로 들어옴 — L9-γ 에서 매칭 키.
pub const shortcut_id_toggle: [*:0]const u8 = "toggle";
const shortcut_description: [*:0]const u8 = "Show / hide TildaZ";

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
/// BindShortcuts 는 사용자 dialog 응답 기다림 — 첫 등록 시 portal 가 KDE /
/// GNOME UI 띄움, 사용자가 승인 / 거부 / 단축키 변경. 5 분 timeout.
const bind_total_timeout_ms: i64 = 300_000;

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
    log.appendLine("portal", "Response body code={d}, parsing results dict", .{code});
    while (api.iter_get_arg_type(&arr_iter) == dbus.dbus_type_dict_entry) {
        var entry_iter: dbus.DBusMessageIter = .{};
        api.iter_recurse(&arr_iter, &entry_iter);
        if (api.iter_get_arg_type(&entry_iter) == dbus.dbus_type_string) {
            var key_c: ?[*:0]const u8 = null;
            api.iter_get_basic(&entry_iter, @ptrCast(&key_c));
            _ = api.iter_next(&entry_iter);
            if (key_c) |k| {
                const key = std.mem.span(k);
                // L9-γ 진단 trace — Response.results 의 어떤 key 들이 오는지
                // 출력. BindShortcuts response 에 "shortcuts" key 가 있고 그
                // array 가 비어 있으면 KDE portal-kde 가 실제 등록 안 함.
                log.appendLine("portal", "Response key={s} type={c}", .{ key, @as(u8, @intCast(api.iter_get_arg_type(&entry_iter))) });
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
                } else if (std.mem.eql(u8, key, "shortcuts") and api.iter_get_arg_type(&entry_iter) == dbus.dbus_type_variant) {
                    // L9-γ 진단 trace — BindShortcuts response 의 `shortcuts`
                    // variant 안 a(sa{sv}) 풀어서 entry count + 각 entry 의
                    // shortcut id 출력. 빈 array 면 portal-kde 가 KGlobalAccel
                    // 등록 실패 (사용자 dialog 거부 or 충돌).
                    var var_iter: dbus.DBusMessageIter = .{};
                    api.iter_recurse(&entry_iter, &var_iter);
                    if (api.iter_get_arg_type(&var_iter) == dbus.dbus_type_array) {
                        var sc_arr: dbus.DBusMessageIter = .{};
                        api.iter_recurse(&var_iter, &sc_arr);
                        var count: u32 = 0;
                        while (api.iter_get_arg_type(&sc_arr) == dbus.dbus_type_struct) {
                            var st_iter: dbus.DBusMessageIter = .{};
                            api.iter_recurse(&sc_arr, &st_iter);
                            if (api.iter_get_arg_type(&st_iter) == dbus.dbus_type_string) {
                                var sid_c: ?[*:0]const u8 = null;
                                api.iter_get_basic(&st_iter, @ptrCast(&sid_c));
                                const sid = if (sid_c) |s| std.mem.span(s) else "(null)";
                                log.appendLine("portal", "Response shortcuts[{d}] id={s}", .{ count, sid });
                            }
                            count += 1;
                            _ = api.iter_next(&sc_arr);
                        }
                        log.appendLine("portal", "Response shortcuts total={d}", .{count});
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

/// XKB keysym + modifier → portal `preferred_trigger` 의 GTK accelerator 문자열
/// (예: `0xffbe + 0` → `"F1"`, `0xffbe + ctrl` → `"<Control>F1"`).
///
/// L9-β-2 scope — `config.LinuxHotkey.fromString` 이 placeholder 라 (default
/// 만 반환) modifier 는 항상 0, keysym 도 F1..F12 default 범위. 후속 sub-step
/// 에서 `Hotkey.fromString` 정식 구현 + 더 많은 keysym 매핑.
///
/// caller 가 free.
fn keysymToAccelerator(allocator: std.mem.Allocator, keysym: u32, modifiers: u32) ![:0]u8 {
    const name: []const u8 = switch (keysym) {
        // XKB F1..F12 keysyms — `xkbcommon/xkbcommon-keysyms.h` 의 `XKB_KEY_F*`.
        0xffbe => "F1",
        0xffbf => "F2",
        0xffc0 => "F3",
        0xffc1 => "F4",
        0xffc2 => "F5",
        0xffc3 => "F6",
        0xffc4 => "F7",
        0xffc5 => "F8",
        0xffc6 => "F9",
        0xffc7 => "F10",
        0xffc8 => "F11",
        0xffc9 => "F12",
        else => "F1",
    };
    // modifier 매핑은 후속 — 현재 LinuxHotkey.fromString 이 modifier=0 만 줌.
    _ = modifiers;
    return allocator.dupeZ(u8, name);
}

/// portal `GlobalShortcuts.BindShortcuts` 호출 — 단일 "toggle" shortcut 등록.
/// 첫 호출 시 portal 가 KDE / GNOME UI dialog 띄움 → 사용자 승인 / 거부 / 단축키
/// 변경. 이후엔 cached (compositor 측). 흐름은 `createGlobalShortcutsSession`
/// 와 동등 — Request handle path 계산 → match rule + filter install → method
/// call → reply (Request path) → Response signal wait. timeout 만 더 김 (5 min).
pub fn bindToggleShortcut(
    allocator: std.mem.Allocator,
    bus: *dbus.SessionBus,
    session_handle: []const u8,
    hotkey_keysym: u32,
    hotkey_modifiers: u32,
) !void {
    const sender_segment = try sanitizeSenderForPath(allocator, bus.unique_name);
    defer allocator.free(sender_segment);

    const expected_request_path = try std.fmt.allocPrint(allocator, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{
        sender_segment, std.mem.span(bind_handle_token),
    });
    defer allocator.free(expected_request_path);

    const match_rule = try std.fmt.allocPrintSentinel(allocator, "type='signal',interface='{s}',member='{s}',path='{s}'", .{
        std.mem.span(interface_request), std.mem.span(member_response), expected_request_path,
    }, 0);
    defer allocator.free(match_rule);

    const session_handle_z = try allocator.dupeZ(u8, session_handle);
    defer allocator.free(session_handle_z);

    const accelerator = try keysymToAccelerator(allocator, hotkey_keysym, hotkey_modifiers);
    defer allocator.free(accelerator);

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
        log.appendLine("portal", "BindShortcuts add_match failed: {s}", .{msg});
        return error.PortalAddMatchFailed;
    }
    defer {
        var err2: dbus.DBusError = .{};
        bus.api.error_init(&err2);
        bus.api.remove_match(bus.conn, match_rule.ptr, &err2);
        bus.api.error_free(&err2);
    }

    // build BindShortcuts method call. args:
    //   o session_handle
    //   a(sa{sv}) shortcuts — list of (id, attrs). 우리는 1 entry.
    //   s parent_window — layer-shell 은 toplevel 아니라 빈 string.
    //   a{sv} options — handle_token 만.
    const call = bus.api.message_new_method_call(
        portal_destination,
        portal_path,
        interface_global_shortcuts,
        member_bind_shortcuts,
    ) orelse return error.PortalMessageAllocFailed;
    defer bus.api.message_unref(call);

    {
        var iter: dbus.DBusMessageIter = .{};
        bus.api.iter_init_append(call, &iter);

        // arg 1: o session_handle.
        var session_var: [*:0]const u8 = session_handle_z.ptr;
        if (bus.api.iter_append_basic(&iter, dbus.dbus_type_object_path, @ptrCast(&session_var)) == 0) return error.PortalAppendFailed;

        // arg 2: a(sa{sv}) shortcuts.
        var arr_iter: dbus.DBusMessageIter = .{};
        if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "(sa{sv})", &arr_iter) == 0) return error.PortalAppendFailed;
        {
            var struct_iter: dbus.DBusMessageIter = .{};
            if (bus.api.iter_open_container(&arr_iter, dbus.dbus_type_struct, null, &struct_iter) == 0) return error.PortalAppendFailed;
            var id_var: [*:0]const u8 = shortcut_id_toggle;
            if (bus.api.iter_append_basic(&struct_iter, dbus.dbus_type_string, @ptrCast(&id_var)) == 0) return error.PortalAppendFailed;
            var attrs_iter: dbus.DBusMessageIter = .{};
            if (bus.api.iter_open_container(&struct_iter, dbus.dbus_type_array, "{sv}", &attrs_iter) == 0) return error.PortalAppendFailed;
            try appendStringVariantEntry(&bus.api, &attrs_iter, "description", shortcut_description);
            const accel_ptr: [*:0]const u8 = accelerator.ptr;
            try appendStringVariantEntry(&bus.api, &attrs_iter, "preferred_trigger", accel_ptr);
            if (bus.api.iter_close_container(&struct_iter, &attrs_iter) == 0) return error.PortalAppendFailed;
            if (bus.api.iter_close_container(&arr_iter, &struct_iter) == 0) return error.PortalAppendFailed;
        }
        if (bus.api.iter_close_container(&iter, &arr_iter) == 0) return error.PortalAppendFailed;

        // arg 3: s parent_window — 빈 string (layer-shell 은 xdg toplevel 없음).
        var parent_var: [*:0]const u8 = "";
        if (bus.api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&parent_var)) == 0) return error.PortalAppendFailed;

        // arg 4: a{sv} options — handle_token.
        var opt_iter: dbus.DBusMessageIter = .{};
        if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "{sv}", &opt_iter) == 0) return error.PortalAppendFailed;
        try appendStringVariantEntry(&bus.api, &opt_iter, "handle_token", bind_handle_token);
        if (bus.api.iter_close_container(&iter, &opt_iter) == 0) return error.PortalAppendFailed;
    }

    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const m = if (err.message) |x| std.mem.span(x) else "(no message)";
            log.appendLine("portal", "BindShortcuts method call failed: {s}", .{m});
        }
        return error.PortalMethodCallFailed;
    };
    defer bus.api.message_unref(reply);

    {
        var reply_iter: dbus.DBusMessageIter = .{};
        if (bus.api.iter_init(reply, &reply_iter) == 0) return error.PortalReplyMissingArgs;
        if (bus.api.iter_get_arg_type(&reply_iter) != dbus.dbus_type_object_path) return error.PortalReplyBadType;
        var got_c: ?[*:0]const u8 = null;
        bus.api.iter_get_basic(&reply_iter, @ptrCast(&got_c));
        const got_path = if (got_c) |g| std.mem.span(g) else "";
        if (!std.mem.eql(u8, got_path, expected_request_path)) {
            log.appendLine("portal", "BindShortcuts request path mismatch — expected={s} got={s}", .{ expected_request_path, got_path });
            return error.PortalRequestPathMismatch;
        }
    }

    log.appendLine("portal", "BindShortcuts request sent preferred_trigger={s} — waiting for user approval (up to 5 min)", .{accelerator});

    const start_ms = std.time.milliTimestamp();
    while (!state.done) {
        if (bus.api.read_write_dispatch(bus.conn, dispatch_iter_timeout_ms) == 0) {
            log.appendLine("portal", "connection disconnected during BindShortcuts wait", .{});
            return error.PortalConnectionLost;
        }
        if (std.time.milliTimestamp() - start_ms > bind_total_timeout_ms) {
            log.appendLine("portal", "BindShortcuts Response signal timeout", .{});
            return error.PortalResponseTimeout;
        }
    }

    if (state.response_code != response_code_success) {
        log.appendLine("portal", "BindShortcuts response code={d} (1=user cancel)", .{state.response_code});
        return error.PortalBindDenied;
    }

    log.appendLine("portal", "shortcut bound id={s}", .{std.mem.span(shortcut_id_toggle)});
}

/// L9-γ — `Activated` signal 도착 시 호출되는 user callback. portal 가
/// signal payload 파싱 후 `shortcut_id` (예: "toggle") 와 `timestamp` 를
/// 그대로 전달. caller 가 user_data 로 자기 context (`*Client` 등) 를 받음.
pub const ActivatedCallback = *const fn (user_data: ?*anyopaque, shortcut_id: []const u8, timestamp: u64) void;

/// L9-γ — portal `GlobalShortcuts.Activated` signal subscription. heap 으로
/// 할당해야 함 — `add_filter` 의 user_data 가 stable address 를 요구하고
/// filter 가 이 struct 의 field (api / session_handle / callback) 를 매
/// signal 마다 읽음. deinit 이 remove_match / remove_filter / dupe 해 둔
/// strings free. caller (wayland_minimal) 가 deinit 후 `allocator.destroy`.
pub const ActivatedSubscription = struct {
    allocator: std.mem.Allocator,
    api: *const dbus.Api,
    conn: *dbus.DBusConnection,
    match_rule: [:0]u8,
    session_handle: []u8,
    callback: ActivatedCallback,
    user_data: ?*anyopaque,

    pub fn deinit(self: *ActivatedSubscription) void {
        var err: dbus.DBusError = .{};
        self.api.error_init(&err);
        self.api.remove_match(self.conn, self.match_rule.ptr, &err);
        self.api.error_free(&err);
        self.api.remove_filter(self.conn, activatedFilter, self);
        self.allocator.free(self.match_rule);
        self.allocator.free(self.session_handle);
    }
};

/// `dbus_connection_add_filter` callback — `org.freedesktop.portal.GlobalShortcuts.Activated`
/// signal 인지 확인하고 payload 파싱. signal args (spec):
///   o session_handle, s shortcut_id, t timestamp, a{sv} options
/// session 이 우리 session 이 아니면 NOT_YET_HANDLED — 다른 filter / 다른
/// subscription 도 볼 수 있게.
fn activatedFilter(conn: *dbus.DBusConnection, msg: *dbus.DBusMessage, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = conn;
    const sub: *ActivatedSubscription = @ptrCast(@alignCast(user_data.?));
    const api = sub.api;

    // L9-γ 진단 trace — 들어오는 모든 message 의 type / interface / member
    // 출력. signal 도착 자체가 안 되는 건지, 도착하는데 매칭 실패인지 분기.
    const iface_c = api.message_get_interface(msg);
    const member_c = api.message_get_member(msg);
    const msg_type = api.message_get_type(msg);
    const iface = if (iface_c) |i| std.mem.span(i) else "(null)";
    const member = if (member_c) |m| std.mem.span(m) else "(null)";
    log.appendLine("portal", "filter msg type={d} iface={s} member={s}", .{ msg_type, iface, member });

    if (api.message_is_signal(msg, interface_global_shortcuts, member_activated) == 0) {
        return dbus.dbus_handler_result_not_yet_handled;
    }
    log.appendLine("portal", "filter Activated signal matched, parsing payload", .{});

    var iter: dbus.DBusMessageIter = .{};
    if (api.iter_init(msg, &iter) == 0) return dbus.dbus_handler_result_not_yet_handled;

    // arg 0: o session_handle — 다른 client 의 session signal 은 무시.
    if (api.iter_get_arg_type(&iter) != dbus.dbus_type_object_path) {
        return dbus.dbus_handler_result_not_yet_handled;
    }
    var session_c: ?[*:0]const u8 = null;
    api.iter_get_basic(&iter, @ptrCast(&session_c));
    const session_path = if (session_c) |s| std.mem.span(s) else "";
    if (!std.mem.eql(u8, session_path, sub.session_handle)) {
        return dbus.dbus_handler_result_not_yet_handled;
    }

    // arg 1: s shortcut_id.
    _ = api.iter_next(&iter);
    if (api.iter_get_arg_type(&iter) != dbus.dbus_type_string) {
        return dbus.dbus_handler_result_handled;
    }
    var sid_c: ?[*:0]const u8 = null;
    api.iter_get_basic(&iter, @ptrCast(&sid_c));
    const shortcut_id = if (sid_c) |s| std.mem.span(s) else "";

    // arg 2: t timestamp (compositor 의 input event time, 단위는 ms 가
    // 일반적이지만 spec 상 opaque). 0 가능 — compositor 가 안 채울 수도.
    _ = api.iter_next(&iter);
    var timestamp: u64 = 0;
    if (api.iter_get_arg_type(&iter) == dbus.dbus_type_uint64) {
        api.iter_get_basic(&iter, @ptrCast(&timestamp));
    }

    sub.callback(sub.user_data, shortcut_id, timestamp);
    return dbus.dbus_handler_result_handled;
}

/// L9-γ — `Activated` signal subscribe. portal `BindShortcuts` 가 성공한 후
/// 곧바로 호출 — compositor 가 hotkey 누름마다 이 signal 보냄. 반환된
/// subscription 은 main loop 종료 시 `deinit` + `destroy` 로 해제.
///
/// session_handle 매칭 — 다른 portal client 의 Activated signal 도 같은
/// session bus 에 흐를 수 있어 (예: 다른 GlobalShortcuts 사용 app), 우리
/// session path 와 일치할 때만 callback 호출. dispatch 자체는 main loop
/// 의 `read_write_dispatch(conn, 0)` 가 매 iteration 처리.
pub fn subscribeActivatedSignal(
    allocator: std.mem.Allocator,
    bus: *dbus.SessionBus,
    session_handle: []const u8,
    callback: ActivatedCallback,
    user_data: ?*anyopaque,
) !*ActivatedSubscription {
    const match_rule = try std.fmt.allocPrintSentinel(allocator, "type='signal',interface='{s}',member='{s}'", .{
        std.mem.span(interface_global_shortcuts), std.mem.span(member_activated),
    }, 0);
    errdefer allocator.free(match_rule);

    const session_copy = try allocator.dupe(u8, session_handle);
    errdefer allocator.free(session_copy);

    const sub = try allocator.create(ActivatedSubscription);
    errdefer allocator.destroy(sub);
    sub.* = .{
        .allocator = allocator,
        .api = &bus.api,
        .conn = bus.conn,
        .match_rule = match_rule,
        .session_handle = session_copy,
        .callback = callback,
        .user_data = user_data,
    };

    if (bus.api.add_filter(bus.conn, activatedFilter, sub, null) == 0) {
        return error.PortalAddFilterFailed;
    }
    errdefer bus.api.remove_filter(bus.conn, activatedFilter, sub);

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);
    bus.api.add_match(bus.conn, match_rule.ptr, &err);
    if (bus.api.error_is_set(&err) != 0) {
        const m = if (err.message) |x| std.mem.span(x) else "(no message)";
        log.appendLine("portal", "Activated add_match failed: {s}", .{m});
        return error.PortalAddMatchFailed;
    }

    log.appendLine("portal", "Activated signal subscribed session={s}", .{session_copy});
    return sub;
}
