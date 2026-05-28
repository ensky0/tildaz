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
const dialog = @import("../../dialog.zig");
const messages = @import("../../messages.zig");
const dbus = @import("dbus.zig");

const portal_destination: [*:0]const u8 = "org.freedesktop.portal.Desktop";
const portal_path: [*:0]const u8 = "/org/freedesktop/portal/desktop";
const interface_global_shortcuts: [*:0]const u8 = "org.freedesktop.portal.GlobalShortcuts";
const interface_request: [*:0]const u8 = "org.freedesktop.portal.Request";
const member_response: [*:0]const u8 = "Response";
const member_create_session: [*:0]const u8 = "CreateSession";
const member_bind_shortcuts: [*:0]const u8 = "BindShortcuts";
const member_unbind_shortcuts: [*:0]const u8 = "UnbindShortcuts";
const member_activated: [*:0]const u8 = "Activated";

/// L9-δ — `org.freedesktop.Notifications` D-Bus service (portal 와 별개).
/// KDE / GNOME / sway / Hyprland / Cinnamon 등 거의 모든 desktop 의 notification
/// daemon 이 이 spec 으로 listen. fdo Desktop Notifications spec 출처:
/// https://specifications.freedesktop.org/notification-spec/notification-spec-latest.html
const notifications_destination: [*:0]const u8 = "org.freedesktop.Notifications";
const notifications_path: [*:0]const u8 = "/org/freedesktop/Notifications";
const notifications_interface: [*:0]const u8 = "org.freedesktop.Notifications";
const notifications_member_notify: [*:0]const u8 = "Notify";
const notify_call_timeout_ms: c_int = 2_000;

/// Request handle / session handle 의 token (path 의 마지막 segment). 우리가
/// 고정 — tildaz process 안에선 동시에 portal session 한 개만 운영. 다른
/// instance 와 conflict 시 portal 가 임의 token 으로 override 가능 (spec).
const handle_token: [*:0]const u8 = "tildaz_handle";
const session_handle_token: [*:0]const u8 = "tildaz_session";
const bind_handle_token: [*:0]const u8 = "tildaz_bind";
const unbind_handle_token: [*:0]const u8 = "tildaz_unbind";
const rebind_handle_token: [*:0]const u8 = "tildaz_rebind";

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
    /// L9-δ — BindShortcuts response 의 `shortcuts` array 안 우리 "toggle"
    /// entry 의 `trigger_description` (human-readable, 예: "F1", "Ctrl+F1").
    /// portal-kde 가 사용자 dialog 에서 다른 키로 변경한 경우 우리가 보낸
    /// preferred_trigger 와 다름 — 비교 후 사용자에게 desktop notification.
    /// 일부 portal 구현 (Cinnamon 등) 이 안 채울 가능성 — null / 빈 string 면 skip.
    actual_trigger: ?[]u8 = null,
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
                    // L9-δ — BindShortcuts response 의 `shortcuts` variant 안
                    // a(sa{sv}) 풀어서 각 entry 의 (id, attrs) 확인. id 가
                    // "toggle" 인 entry 의 `trigger_description` 추출 — caller
                    // (`bindToggleShortcut`) 가 preferred_trigger 와 비교 후
                    // 다르면 desktop notification.
                    var var_iter: dbus.DBusMessageIter = .{};
                    api.iter_recurse(&entry_iter, &var_iter);
                    if (api.iter_get_arg_type(&var_iter) == dbus.dbus_type_array) {
                        var sc_arr: dbus.DBusMessageIter = .{};
                        api.iter_recurse(&var_iter, &sc_arr);
                        while (api.iter_get_arg_type(&sc_arr) == dbus.dbus_type_struct) {
                            extractTriggerDescriptionForToggle(state, &sc_arr);
                            _ = api.iter_next(&sc_arr);
                        }
                    }
                }
            }
        }
        _ = api.iter_next(&arr_iter);
    }
}

/// L9-δ — shortcuts array 의 한 struct iterator 에서 (id, attrs) 를 읽어
/// id == "toggle" 이면 attrs 의 `trigger_description` string 을 추출해 state 에
/// dupe 저장. 첫 호출에서 채워지면 이후 호출에선 skip (한 BindShortcuts 호출에
/// shortcut 1 개만 등록하지만, portal 가 여러 entry 반환할 가능성 hedge).
fn extractTriggerDescriptionForToggle(state: *ResponseWaitState, sc_arr: *dbus.DBusMessageIter) void {
    const api = state.api;
    if (state.actual_trigger != null) return;

    var struct_iter: dbus.DBusMessageIter = .{};
    api.iter_recurse(sc_arr, &struct_iter);

    // arg 0: s shortcut_id
    if (api.iter_get_arg_type(&struct_iter) != dbus.dbus_type_string) return;
    var sid_c: ?[*:0]const u8 = null;
    api.iter_get_basic(&struct_iter, @ptrCast(&sid_c));
    const sid = if (sid_c) |s| std.mem.span(s) else return;
    if (!std.mem.eql(u8, sid, std.mem.span(shortcut_id_toggle))) return;

    // arg 1: a{sv} attrs
    _ = api.iter_next(&struct_iter);
    if (api.iter_get_arg_type(&struct_iter) != dbus.dbus_type_array) return;

    var attrs_iter: dbus.DBusMessageIter = .{};
    api.iter_recurse(&struct_iter, &attrs_iter);
    while (api.iter_get_arg_type(&attrs_iter) == dbus.dbus_type_dict_entry) {
        var a_entry: dbus.DBusMessageIter = .{};
        api.iter_recurse(&attrs_iter, &a_entry);
        if (api.iter_get_arg_type(&a_entry) == dbus.dbus_type_string) {
            var ak_c: ?[*:0]const u8 = null;
            api.iter_get_basic(&a_entry, @ptrCast(&ak_c));
            _ = api.iter_next(&a_entry);
            if (ak_c) |ak| {
                const akey = std.mem.span(ak);
                if (std.mem.eql(u8, akey, "trigger_description") and api.iter_get_arg_type(&a_entry) == dbus.dbus_type_variant) {
                    var av_iter: dbus.DBusMessageIter = .{};
                    api.iter_recurse(&a_entry, &av_iter);
                    if (api.iter_get_arg_type(&av_iter) == dbus.dbus_type_string) {
                        var v_c: ?[*:0]const u8 = null;
                        api.iter_get_basic(&av_iter, @ptrCast(&v_c));
                        if (v_c) |v| {
                            state.actual_trigger = state.allocator.dupe(u8, std.mem.span(v)) catch null;
                        }
                    }
                }
            }
        }
        _ = api.iter_next(&attrs_iter);
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

/// XKB keysym + modifier → portal `preferred_trigger` 문자열. portal-kde 의
/// `XdgShortcut::parse` 가 **대문자 modifier 만** (case-sensitive) — 소문자
/// 보내면 parse 실패 → user dialog 의 binding field 가 "없음" 으로 표시
/// (사용자 시연 발견). portal-kde source 정독으로 확정:
/// https://invent.kde.org/plasma/xdg-desktop-portal-kde/-/blob/v6.6.5/src/xdgshortcut.cpp
///
/// 예: `0xffbe + 0` → `"F1"` / `0xffbe + MOD_CTRL` → `"CTRL+F1"` /
/// `0x0020 + MOD_SHIFT | MOD_CTRL` → `"SHIFT+CTRL+space"`.
///
/// modifier 비트 (`config.zig` 의 `LinuxHotkey.MOD_*` 와 일치) → Qt 의 표기:
///   - 0x1 = Alt → `ALT` (Qt::AltModifier)
///   - 0x2 = Ctrl → `CTRL` (Qt::ControlModifier)
///   - 0x4 = Shift → `SHIFT` (Qt::ShiftModifier)
///   - 0x8 = Super (Win key / `cmd` 토큰) → `LOGO` (Qt::MetaModifier)
///
/// caller 가 free.
fn keysymToAccelerator(allocator: std.mem.Allocator, keysym: u32, modifiers: u32) ![:0]u8 {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    // portal-kde 의 XdgShortcut::parse 순서 무관 (HashMap lookup) — 일관된
    // 순서로: SHIFT+CTRL+ALT+LOGO+key.
    if ((modifiers & 0x4) != 0) try w.writeAll("SHIFT+");
    if ((modifiers & 0x2) != 0) try w.writeAll("CTRL+");
    if ((modifiers & 0x1) != 0) try w.writeAll("ALT+");
    if ((modifiers & 0x8) != 0) try w.writeAll("LOGO+");
    try w.writeAll(keysymGtkName(keysym));
    return allocator.dupeZ(u8, fbs.getWritten());
}

/// xkb keysym → GTK accelerator 의 key 이름. `gdk_keyval_name` 표준 표기.
/// Latin / 숫자 는 ASCII 그대로 한 글자. F1..F12 / space / Return / Escape 등은
/// 별 이름. 미지원 키는 `"F1"` fallback (이전 placeholder 와 동등).
/// xkb keysym + modifier → KDE 친화 display 표기 (`Meta+A`, `Ctrl+Shift+T`,
/// `Ctrl+\``, `Alt+F12`). dialog 메시지 + log 에서 사용 — portal-kde 의
/// 응답 표기 (`Shift+F10`) 와 같은 양식.
///
/// modifier prefix (Title case + `+` 분리): `Shift+` / `Ctrl+` / `Alt+` / `Meta+`.
/// key: F1..F12 / `Tab` / `Return` / `Escape` / `Space` 는 단어, Latin letter
/// 는 대문자 (`A`-`Z`), digit 은 그대로, 그 외 symbol 은 literal (`` ` ``, `~`, etc).
fn keysymDisplayString(buf: []u8, keysym: u32, modifiers: u32) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    if ((modifiers & 0x4) != 0) w.writeAll("Shift+") catch {};
    if ((modifiers & 0x2) != 0) w.writeAll("Ctrl+") catch {};
    if ((modifiers & 0x1) != 0) w.writeAll("Alt+") catch {};
    if ((modifiers & 0x8) != 0) w.writeAll("Meta+") catch {};
    const word: ?[]const u8 = switch (keysym) {
        0xffbe => "F1",  0xffbf => "F2",  0xffc0 => "F3",  0xffc1 => "F4",
        0xffc2 => "F5",  0xffc3 => "F6",  0xffc4 => "F7",  0xffc5 => "F8",
        0xffc6 => "F9",  0xffc7 => "F10", 0xffc8 => "F11", 0xffc9 => "F12",
        0xff09 => "Tab",
        0xff0d => "Return",
        0xff1b => "Escape",
        0x0020 => "Space",
        else => null,
    };
    if (word) |s| {
        w.writeAll(s) catch {};
    } else if (keysym >= 'a' and keysym <= 'z') {
        const c: u8 = @intCast(keysym - 0x20); // Latin letter 는 대문자
        w.writeAll(&[1]u8{c}) catch {};
    } else if (keysym >= 0x20 and keysym <= 0x7e) {
        const c: u8 = @intCast(keysym); // digit + symbol literal
        w.writeAll(&[1]u8{c}) catch {};
    } else {
        w.writeAll("?") catch {};
    }
    return fbs.getWritten();
}

fn keysymGtkName(keysym: u32) []const u8 {
    return switch (keysym) {
        // XKB F1..F12 — `xkbcommon/xkbcommon-keysyms.h` 의 `XKB_KEY_F*`.
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
        0xff09 => "Tab",
        0xff0d => "Return",
        0xff1b => "Escape",
        // Latin lowercase a-z / digits 0-9 — keysym 값이 ASCII 와 동일.
        // GTK 의 1-char accelerator (예: `<Ctrl>a`) 그대로 송신. 우리 buffer
        // 가 64 bytes 면 안전.
        'a'...'z', '0'...'9' => single_char_lookup[keysym - 0x0020],
        ' ' => "space",
        '`' => "grave",
        // #208 — `config.linuxKeysymFromName` 의 수용 범위가 이 switch 의
        // 매핑 범위와 1:1. 도달하면 config 검증을 우회한 keysym (개발 중 신규
        // key 추가 시 한쪽만 갱신) → 명시 log + 'F1' fallback (서비스 자체는
        // 유지). silent fallback 막기 위한 defensive layer.
        else => blk: {
            log.appendLine("portal", "keysymGtkName: unmapped keysym=0x{x} — config.linuxKeysymFromName 동기화 누락? 'F1' fallback (#208)", .{keysym});
            break :blk "F1";
        },
    };
}

/// Latin / digit 1-char accelerator 용 정적 string lookup. keysym (= ASCII) -
/// 0x20 으로 indexing. `'a'` (0x61) → index 0x41 의 `"a"`. zig comptime 으로
/// 한 글자 string 들 정적 배열로.
const single_char_lookup: [96][]const u8 = blk: {
    var arr: [96][]const u8 = undefined;
    for (0..96) |i| {
        arr[i] = &[1]u8{@intCast(0x20 + i)};
    }
    break :blk arr;
};

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
    // success / response-code-fail 경로에선 actual_trigger 를 명시 free / defer
    // 로 처리. errdefer 는 그 사이 *예상 외* error return (예: ConnectionLost /
    // Timeout — 이때도 filter callback 이 이미 actual_trigger 채웠을 가능성)
    // 의 leak 만 hedge.
    errdefer if (state.actual_trigger) |t| allocator.free(t);

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
        return error.PortalBindDenied; // actual_trigger leak 은 위 errdefer 가 해제
    }

    log.appendLine("portal", "shortcut bound id={s}", .{std.mem.span(shortcut_id_toggle)});

    // L9-δ — 실제 bound trigger 와 우리가 요청한 preferred_trigger 비교. portal-kde
    // 의 사용자 dialog 에서 다른 키 선택 / KDE settings 에서 사용자가 직접 변경 등
    // 으로 다를 수 있음 — 사용자에게 desktop notification 으로 알림.
    //
    // *왜 yes/no dialog 가 아니고 notification 인가*: Wayland 에는 일반 dialog API
    // 표준이 없음 (kdialog/zenity 는 DE 의존). 그리고 yes 분기에서 config 를 갱신
    // 하면 "프로그램이 config 안 고친다" 정책 위반 — 사용자가 config 를 직접 수정
    // 하도록 *알림만* 띄우는 게 일관 (#198 결정 흐름 — Option Y).
    //
    // 비교는 string-equal. portal trigger_description 의 human-readable 형식 (예:
    // "F1", "Ctrl+F1") 과 우리 keysymToAccelerator 출력 (예: "F1") 의 표기 충돌
    // 가능 — false-positive 가 더 안전 (사용자 인지). 일부 portal (Cinnamon 등)
    // 은 trigger_description 안 채울 수도 — null / 빈 string 이면 skip.
    if (state.actual_trigger) |actual| {
        defer allocator.free(actual);
        // Qt int 비교 (portal 응답의 human-readable 표기 `Ctrl+\`` vs 우리 송신
        // `CTRL+grave` 의 false-positive 회피). KGlobalAccel.shortcut(actionId)
        // 가 현재 store 의 Qt KeySequence packed int 직접 반환 — 우리 의도된
        // qt_key 와 비교 (사용자 시연 진단 #207 — 두 표기가 *같은 binding* 인데
        // string-equal 항상 다름).
        const our_qt_key = xkbToQtKey(hotkey_keysym, hotkey_modifiers);
        const stored_qt_key = kdeQueryToggleShortcut(bus);
        var disp_buf: [64]u8 = undefined;
        const config_display = keysymDisplayString(&disp_buf, hotkey_keysym, hotkey_modifiers);
        if (stored_qt_key) |sk| {
            if (sk == our_qt_key) {
                log.appendLine("portal", "hotkey trigger confirmed ({s} / qt=0x{x}) — portal text=\"{s}\"", .{ config_display, @as(u32, @bitCast(our_qt_key)), actual });
            } else {
                log.appendLine("portal", "hotkey mismatch — config={s} (qt=0x{x}) actual=\"{s}\" stored qt=0x{x}", .{ config_display, @as(u32, @bitCast(our_qt_key)), actual, @as(u32, @bitCast(sk)) });
                try handleHotkeyMismatch(allocator, bus, session_handle, accelerator, actual, hotkey_keysym, hotkey_modifiers);
            }
        } else {
            // KGlobalAccel.shortcut query 가 null (KDE 외 환경 또는 query fail).
            // string-equal fallback.
            if (!std.mem.eql(u8, actual, accelerator)) {
                log.appendLine("portal", "hotkey mismatch (string fallback) — config={s} actual=\"{s}\"", .{ config_display, actual });
                try handleHotkeyMismatch(allocator, bus, session_handle, accelerator, actual, hotkey_keysym, hotkey_modifiers);
            } else {
                log.appendLine("portal", "hotkey trigger confirmed (string) — actual={s}", .{actual});
            }
        }
    }
}

/// #207 — portal `BindShortcuts` 응답의 `actual` 이 우리 config 의 `preferred`
/// 와 다를 때 자동 보정. config 이 source of truth (mac/win 동등). **계층적
/// fallback chain**:
///
///   1차 (cross-DE 정공): XDG portal `UnbindShortcuts` (spec v2 since)
///     → `BindShortcuts` 재시도. 모든 portal impl 가 v2 구현 시 cross-DE 일관.
///
///   2차 (DE-specific): 1차 실패 시 `XDG_CURRENT_DESKTOP` 감지 + DE 의 native
///     global shortcut API 직접:
///       - KDE: `org.kde.kglobalaccel` D-Bus → `unregister(component, "toggle")`
///         → portal `BindShortcuts` 재호출. runtime 즉시 갱신.
///       - GNOME / sway / hyprland: 별 작업 (#207 후속)
///
///   3차 (마지막 fallback): 위 모두 실패 / 미지원 DE 면 `dialog.showInfo` 로
///     수동 변경 안내.
///
/// dialog 는 `dialog.showInfo` (layer-shell overlay, #203 step 3). 시작 시점에
/// 호출 — main loop 진입 후 첫 frame 에 표시됨. fire-and-forget.
fn handleHotkeyMismatch(
    allocator: std.mem.Allocator,
    bus: *dbus.SessionBus,
    session_handle: []const u8,
    preferred: []const u8,
    actual: []const u8,
    keysym: u32,
    modifiers: u32,
) !void {
    // dialog / log 용 KDE 친화 표기 (`Meta+A`). `preferred` 는 portal-kde 의
    // parse format (`LOGO+a`) — 사용자에게 표시하면 혼란 (#207 사용자 발견).
    var display_buf: [64]u8 = undefined;
    const preferred_display = keysymDisplayString(&display_buf, keysym, modifiers);

    // 1차 — XDG portal UnbindShortcuts + 재 BindShortcuts.
    unbindToggleShortcut(allocator, bus, session_handle) catch |e| {
        log.appendLine("portal", "1차 UnbindShortcuts failed: {s} — 2차 DE-specific path 시도", .{@errorName(e)});
        return tryDeSpecificHotkeyFix(allocator, bus, session_handle, preferred, actual, keysym, modifiers);
    };

    rebindToggleShortcut(allocator, bus, session_handle, keysym, modifiers) catch |e| {
        log.appendLine("portal", "1차 rebind BindShortcuts failed: {s} — 2차 DE-specific path 시도", .{@errorName(e)});
        return tryDeSpecificHotkeyFix(allocator, bus, session_handle, preferred, actual, keysym, modifiers);
    };

    // 1차 성공.
    log.appendLine("portal", "hotkey updated (portal): {s} → {s}", .{ actual, preferred_display });
    showHotkeyUpdatedDialog(allocator, actual, preferred_display);
}

/// 2차 — `XDG_CURRENT_DESKTOP` 감지 + DE 의 native API. KDE 만 우선 구현
/// (#207). 다른 DE 는 3차 fallback dialog 로.
fn tryDeSpecificHotkeyFix(
    allocator: std.mem.Allocator,
    bus: *dbus.SessionBus,
    session_handle: []const u8,
    preferred: []const u8,
    actual: []const u8,
    keysym: u32,
    modifiers: u32,
) !void {
    _ = session_handle;
    _ = preferred;

    // dialog / log 용 KDE 친화 표기 (`Meta+A`).
    var display_buf: [64]u8 = undefined;
    const preferred_display = keysymDisplayString(&display_buf, keysym, modifiers);

    const de = detectCurrentDesktop(allocator);
    defer if (de) |s| allocator.free(s);

    if (de) |d| {
        if (containsToken(d, "KDE")) {
            kdeTryAutoApply(allocator, bus, keysym, modifiers, preferred_display, actual);
            return;
        }
        log.appendLine("portal", "2차 DE={s} 미구현 — 3차 fallback", .{d});
    } else {
        log.appendLine("portal", "2차 XDG_CURRENT_DESKTOP 미설정 — 3차 fallback", .{});
    }
    showMismatchPersistsDialog(allocator, preferred_display, actual);
}

/// 2차 KDE-specific path. 충돌 owner 사전 진단 + (있으면) 사용자 confirm
/// dialog 후 takeover. flow:
///
///   1. `action(qt_key)` 로 현재 owner 조회
///   2. owner 없음 또는 tildaz 자체 → 단순 `setForeignShortcut(tildaz)`
///   3. owner = 다른 component → `dialog.showConfirm` (Cancel default)
///      - OK: owner 에서 해당 키만 회수 (`setForeignShortcut(owner, filtered)`)
///            → `setForeignShortcut(tildaz)` → 성공 dialog
///      - Cancel: 기존 binding 유지 → "수동 변경 안내" dialog
fn kdeTryAutoApply(
    allocator: std.mem.Allocator,
    bus: *dbus.SessionBus,
    keysym: u32,
    modifiers: u32,
    preferred_display: []const u8,
    actual: []const u8,
) void {
    const qt_key = xkbToQtKey(keysym, modifiers);

    // 충돌 owner 진단.
    var owner_opt = kdeQueryOwnerForKey(allocator, bus, qt_key);
    defer if (owner_opt) |*o| o.deinit(allocator);

    const is_tildaz_owner = if (owner_opt) |o|
        std.mem.eql(u8, o.component, std.mem.span(kde_component_tildaz)) and
            std.mem.eql(u8, o.action, std.mem.span(kde_action_toggle))
    else
        false;

    if (owner_opt) |owner| {
        if (!is_tildaz_owner) {
            // 다른 component 가 선점 — 사용자 confirm.
            log.appendLine("portal", "2차 충돌 감지 — owner={s}/{s} (display: {s} / {s}) qt_key=0x{x}", .{
                owner.component, owner.action, owner.display_component, owner.display_action,
                @as(u32, @bitCast(qt_key)),
            });
            var msg_buf: [512]u8 = undefined;
            const confirm_msg = std.fmt.bufPrint(&msg_buf, messages.hotkey_takeover_format, .{
                preferred_display, owner.display_component, owner.display_action,
            }) catch {
                showMismatchPersistsDialog(allocator, preferred_display, actual);
                return;
            };
            const ok = dialog.showConfirm(messages.hotkey_takeover_title, confirm_msg);
            if (!ok) {
                log.appendLine("portal", "takeover 거부됨 (Cancel) — 기존 binding 유지", .{});
                var declined_buf: [256]u8 = undefined;
                const dmsg = std.fmt.bufPrint(&declined_buf, messages.hotkey_takeover_declined_format, .{
                    preferred_display, owner.display_component,
                }) catch {
                    dialog.showInfo(messages.hotkey_takeover_declined_title, "Hotkey unchanged.");
                    return;
                };
                dialog.showInfo(messages.hotkey_takeover_declined_title, dmsg);
                return;
            }

            kdeTakeoverConflict(allocator, bus, &owner, qt_key) catch |e| {
                log.appendLine("portal", "takeover D-Bus call 실패 ({s}) — fallback dialog", .{@errorName(e)});
                showMismatchPersistsDialog(allocator, preferred_display, actual);
                return;
            };
        }
    }

    // tildaz 자체 binding set (이미 tildaz owner 였든 / 회수 직후든 동일 path).
    kdeSetToggleShortcut(allocator, bus, qt_key) catch |e| {
        log.appendLine("portal", "KDE setForeignShortcut(tildaz) 실패 ({s}) — fallback dialog", .{@errorName(e)});
        showMismatchPersistsDialog(allocator, preferred_display, actual);
        return;
    };

    // 검증 — 적용 후 query 가 우리 qt_key 와 일치.
    if (kdeQueryToggleShortcut(bus)) |stored| {
        if (stored != qt_key) {
            log.appendLine("portal", "KDE set 후 검증 실패 — stored=0x{x} expected=0x{x}", .{
                @as(u32, @bitCast(stored)), @as(u32, @bitCast(qt_key)),
            });
            showMismatchPersistsDialog(allocator, preferred_display, actual);
            return;
        }
    }

    log.appendLine("portal", "hotkey updated (KDE D-Bus): \"{s}\" → {s}", .{ actual, preferred_display });
    showHotkeyUpdatedDialog(allocator, actual, preferred_display);
}

/// `[tildaz]` group 의 toggle binding — kglobalshortcutsrc 파일 + KGlobalAccel
/// runtime 의 component 이름. *Konsole 부모 cgroup* 으로 잘못 등록된 경우 대비
/// 별 component (`org.kde.konsole`) 도 후속 정리 가능 (현재는 우리 own 만).
const kde_component_tildaz: [*:0]const u8 = "tildaz";
const kde_action_toggle: [*:0]const u8 = "toggle";
const kde_component_display: [*:0]const u8 = "TildaZ";
const kde_action_display: [*:0]const u8 = "Show / hide TildaZ";

/// `org.kde.KGlobalAccel.setShortcut` 의 `flags` argument. KDE source
/// (`src/kglobalaccel.h`) 의 `KGlobalAccel::SetShortcutFlag` enum:
///   - `SetPresent = 2`
///   - `NoAutoloading = 4`
///   - `IsDefault = 8`
///
/// 우리 케이스 = `NoAutoloading | SetPresent = 6` — autoload skip (우리 set
/// 값 그대로) + binding 활성화 마크. 이전 잘못된 값 `1` 은 enum 정의에 없음
/// (no-op 처럼 동작했으나 kglobalshortcutsrc 영구 저장 안 됨 시연 발견 —
/// process 종료 시 [tildaz] group 사라짐).
const kde_set_shortcut_flag_set_present: u32 = 2;
const kde_set_shortcut_flag_no_autoloading: u32 = 4;
const kde_set_shortcut_flags: u32 = kde_set_shortcut_flag_no_autoloading | kde_set_shortcut_flag_set_present;

/// KDE 의 `org.kde.kglobalaccel` D-Bus interface 호출:
///   `unregister(in s componentUnique, in s shortcutUnique, out b arg_0)`
///
/// kglobalshortcutsrc 의 `[<componentUnique>]` group 안 `<shortcutUnique>` line
/// 의 binding 을 *runtime + on-disk* 모두 삭제. 그 후 우리 portal BindShortcuts
/// 가 *처음 등록* path 로 새 trigger 적용 (KDE 가 user dialog 띄울 수 있음).
///
/// 출처: `gdbus introspect --session --dest org.kde.kglobalaccel
///        --object-path /kglobalaccel` (KDE Plasma 6.6.5).
fn kdeUnregisterToggleShortcut(bus: *dbus.SessionBus, component: [*:0]const u8) !void {
    const dest: [*:0]const u8 = "org.kde.kglobalaccel";
    const path: [*:0]const u8 = "/kglobalaccel";
    const iface: [*:0]const u8 = "org.kde.KGlobalAccel";
    const method: [*:0]const u8 = "unregister";

    const call = bus.api.message_new_method_call(dest, path, iface, method) orelse return error.PortalMessageAllocFailed;
    defer bus.api.message_unref(call);

    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);
    var comp_var: [*:0]const u8 = component;
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&comp_var)) == 0) return error.PortalAppendFailed;
    var action_var: [*:0]const u8 = kde_action_toggle;
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&action_var)) == 0) return error.PortalAppendFailed;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);

    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const m = if (err.message) |x| std.mem.span(x) else "(no message)";
            log.appendLine("portal", "kglobalaccel unregister failed: {s}", .{m});
        }
        return error.PortalMethodCallFailed;
    };
    defer bus.api.message_unref(reply);

    // 반환 = bool (성공 여부). false 면 KGlobalAccel 측에서 *해당 binding 없음*
    // (이미 unregister 되었거나 다른 component). 우리 의도 (= 다음 BindShortcuts
    // 가 깨끗한 상태에서 시작) 충족이라 success 처리.
    log.appendLine("portal", "kglobalaccel unregister succeeded — component={s} action={s}", .{ std.mem.span(component), std.mem.span(kde_action_toggle) });
}

/// XKB keysym + modifier → Qt `KeySequence` packed int. `KGlobalAccel.setShortcut`
/// 의 `keys: ai` argument 형식. Qt 의 `Qt::Key_*` (CamelCase 무관) 와 modifier
/// 비트 (`Qt::*Modifier`) 의 OR.
///
/// modifier 매핑 (`config.zig` LinuxHotkey MOD_* → Qt 비트):
///   - MOD_SHIFT (0x4) → Qt::ShiftModifier (0x02000000)
///   - MOD_CTRL  (0x2) → Qt::ControlModifier (0x04000000)
///   - MOD_ALT   (0x1) → Qt::AltModifier (0x08000000)
///   - MOD_SUPER (0x8) → Qt::MetaModifier (0x10000000)
///
/// key code (Qt 의 `qnamespace.h` 의 `Qt::Key` enum):
///   - F1..F12 = 0x01000030..0x0100003B (xkb 0xffbe..0xffc9)
///   - Tab = 0x01000001 (xkb 0xff09)
///   - Return = 0x01000004 (xkb 0xff0d)
///   - Escape = 0x01000000 (xkb 0xff1b)
///   - Space = 0x20 (xkb 0x20, 동일)
///   - QuoteLeft (grave) = 0x60 (xkb 0x60, 동일)
///   - 0-9 = 0x30..0x39 (xkb 동일)
///   - A-Z = 0x41..0x5A (xkb a-z 의 *대문자 변환*)
fn xkbToQtKey(keysym: u32, modifiers: u32) i32 {
    var key: i32 = 0;
    if ((modifiers & 0x4) != 0) key |= 0x02000000; // SHIFT
    if ((modifiers & 0x2) != 0) key |= 0x04000000; // CTRL
    if ((modifiers & 0x1) != 0) key |= 0x08000000; // ALT
    if ((modifiers & 0x8) != 0) key |= 0x10000000; // META (Super)

    const key_code: i32 = switch (keysym) {
        // Qt::Key_F1..F12 = 0x01000030..0x0100003b (consecutive). 이전 F7~F12
        // 가 1 offset 잘못 — 0x01000036 부터 시작해야 (사용자 시연 진단 #207).
        0xffbe => 0x01000030, // F1
        0xffbf => 0x01000031, // F2
        0xffc0 => 0x01000032, // F3
        0xffc1 => 0x01000033, // F4
        0xffc2 => 0x01000034, // F5
        0xffc3 => 0x01000035, // F6
        0xffc4 => 0x01000036, // F7
        0xffc5 => 0x01000037, // F8
        0xffc6 => 0x01000038, // F9
        0xffc7 => 0x01000039, // F10
        0xffc8 => 0x0100003a, // F11
        0xffc9 => 0x0100003b, // F12
        0xff09 => 0x01000001, // Tab
        0xff0d => 0x01000004, // Return
        0xff1b => 0x01000000, // Escape
        0x0020 => 0x20, // Space
        0x0060 => 0x60, // QuoteLeft (grave)
        '0'...'9' => @intCast(keysym), // 동일 (0x30..0x39)
        'a'...'z' => @intCast(keysym - 0x20), // Qt A-Z (0x41..0x5a)
        else => 0,
    };
    return key | key_code;
}

/// `org.kde.KGlobalAccel.shortcut(actionId: as) → ai` — 현재 적용된 keys 의 Qt
/// KeySequence packed int 배열 직접 받음 (machine-readable). portal 응답의
/// human-readable string (`Ctrl+\`` 등) vs 우리 송신 표기 (`CTRL+grave`) 의
/// false-positive 비교 회피.
///
/// 반환:
///   - 적용된 keys 의 첫 Qt int (single shortcut 기준)
///   - null = entry 없음 또는 empty binding
fn kdeQueryToggleShortcut(bus: *dbus.SessionBus) ?i32 {
    const dest: [*:0]const u8 = "org.kde.kglobalaccel";
    const path: [*:0]const u8 = "/kglobalaccel";
    const iface: [*:0]const u8 = "org.kde.KGlobalAccel";
    const method: [*:0]const u8 = "shortcut";

    const call = bus.api.message_new_method_call(dest, path, iface, method) orelse return null;
    defer bus.api.message_unref(call);

    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);
    var arr_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "s", &arr_iter) == 0) return null;
    const action_id = [_][*:0]const u8{
        kde_component_tildaz,
        kde_action_toggle,
        kde_component_display,
        kde_action_display,
    };
    for (action_id) |s| {
        var p: [*:0]const u8 = s;
        if (bus.api.iter_append_basic(&arr_iter, dbus.dbus_type_string, @ptrCast(&p)) == 0) return null;
    }
    if (bus.api.iter_close_container(&iter, &arr_iter) == 0) return null;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);

    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const m = if (err.message) |x| std.mem.span(x) else "(no message)";
            log.appendLine("portal", "kglobalaccel shortcut query failed: {s}", .{m});
        }
        return null;
    };
    defer bus.api.message_unref(reply);

    var reply_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_init(reply, &reply_iter) == 0) return null;
    if (bus.api.iter_get_arg_type(&reply_iter) != dbus.dbus_type_array) return null;
    var keys_arr: dbus.DBusMessageIter = .{};
    bus.api.iter_recurse(&reply_iter, &keys_arr);
    if (bus.api.iter_get_arg_type(&keys_arr) != dbus.dbus_type_int32) return null;
    var qt_key: i32 = 0;
    bus.api.iter_get_basic(&keys_arr, @ptrCast(&qt_key));
    return qt_key;
}

/// KGlobalAccel actionId — 4-string tuple. `[component, action,
/// displayComponent, displayAction]`. action / displayAction 은 사용자
/// 친화 표기 (예: `"활동간 전환"`) — dialog 본문에 직접 노출.
const KdeOwnerActionId = struct {
    component: []u8,
    action: []u8,
    display_component: []u8,
    display_action: []u8,

    fn deinit(self: *KdeOwnerActionId, alloc: std.mem.Allocator) void {
        alloc.free(self.component);
        alloc.free(self.action);
        alloc.free(self.display_component);
        alloc.free(self.display_action);
    }
};

/// `org.kde.KGlobalAccel.action(key: i) → as` — 주어진 Qt KeySequence packed
/// int 를 *현재 소유* 중인 component / action 의 4-string tuple. 비어있으면
/// null (소유자 없음). 충돌 사전 진단 + dialog 본문 (`plasmashell` / `활동간
/// 전환` 등) 용. caller 가 deinit.
fn kdeQueryOwnerForKey(allocator: std.mem.Allocator, bus: *dbus.SessionBus, qt_key: i32) ?KdeOwnerActionId {
    const dest: [*:0]const u8 = "org.kde.kglobalaccel";
    const path: [*:0]const u8 = "/kglobalaccel";
    const iface: [*:0]const u8 = "org.kde.KGlobalAccel";
    const method: [*:0]const u8 = "action";

    const call = bus.api.message_new_method_call(dest, path, iface, method) orelse return null;
    defer bus.api.message_unref(call);

    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);
    var k: i32 = qt_key;
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_int32, @ptrCast(&k)) == 0) return null;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);

    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const m = if (err.message) |x| std.mem.span(x) else "(no message)";
            log.appendLine("portal", "kglobalaccel action query failed: {s}", .{m});
        }
        return null;
    };
    defer bus.api.message_unref(reply);

    var reply_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_init(reply, &reply_iter) == 0) return null;
    if (bus.api.iter_get_arg_type(&reply_iter) != dbus.dbus_type_array) return null;
    var arr_iter: dbus.DBusMessageIter = .{};
    bus.api.iter_recurse(&reply_iter, &arr_iter);

    var strs: [4][]u8 = .{ &.{}, &.{}, &.{}, &.{} };
    var got: [4]bool = .{ false, false, false, false };
    var i: usize = 0;
    while (i < 4 and bus.api.iter_get_arg_type(&arr_iter) == dbus.dbus_type_string) : (i += 1) {
        var raw: [*:0]const u8 = undefined;
        bus.api.iter_get_basic(&arr_iter, @ptrCast(&raw));
        const span = std.mem.span(raw);
        strs[i] = allocator.dupe(u8, span) catch {
            // OOM mid-parse — free 누적분.
            var j: usize = 0;
            while (j < i) : (j += 1) allocator.free(strs[j]);
            return null;
        };
        got[i] = true;
        _ = bus.api.iter_next(&arr_iter);
    }
    if (!(got[0] and got[1] and got[2] and got[3])) {
        // 빈 array 또는 4 미만 — owner 없음 (KGlobalAccel 응답 convention).
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            if (got[j]) allocator.free(strs[j]);
        }
        return null;
    }
    if (strs[0].len == 0) {
        // KGlobalAccel 가 0-length component 로 "owner 없음" 표시 — defensive.
        for (strs) |s| allocator.free(s);
        return null;
    }
    return .{
        .component = strs[0],
        .action = strs[1],
        .display_component = strs[2],
        .display_action = strs[3],
    };
}

/// `org.kde.KGlobalAccel.shortcut(actionId: as) → ai` — 주어진 actionId 의
/// 현재 keys 전체 (multi-binding 가능 — 예: kwin ExposeClass = [Meta+F7, Ctrl+F7]).
/// caller 가 free. null = entry 없음 / query fail.
fn kdeQueryKeysForAction(allocator: std.mem.Allocator, bus: *dbus.SessionBus, action_id: []const []const u8) ?[]i32 {
    const dest: [*:0]const u8 = "org.kde.kglobalaccel";
    const path: [*:0]const u8 = "/kglobalaccel";
    const iface: [*:0]const u8 = "org.kde.KGlobalAccel";
    const method: [*:0]const u8 = "shortcut";

    const call = bus.api.message_new_method_call(dest, path, iface, method) orelse return null;
    defer bus.api.message_unref(call);

    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);
    var arr_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "s", &arr_iter) == 0) return null;
    // action_id 의 각 string 은 D-Bus 에 null-terminated 로 전송 필요.
    // [:0]u8 sentinel-terminated buffer 로 변환 후 ptr 보냄.
    var tmpbuf: [4][128]u8 = undefined;
    for (action_id, 0..) |s, idx| {
        if (idx >= 4) break;
        if (s.len + 1 > tmpbuf[idx].len) return null;
        @memcpy(tmpbuf[idx][0..s.len], s);
        tmpbuf[idx][s.len] = 0;
        var p: [*:0]const u8 = @ptrCast(&tmpbuf[idx]);
        if (bus.api.iter_append_basic(&arr_iter, dbus.dbus_type_string, @ptrCast(&p)) == 0) return null;
    }
    if (bus.api.iter_close_container(&iter, &arr_iter) == 0) return null;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);

    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const m = if (err.message) |x| std.mem.span(x) else "(no message)";
            log.appendLine("portal", "kglobalaccel shortcut(action) query failed: {s}", .{m});
        }
        return null;
    };
    defer bus.api.message_unref(reply);

    var reply_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_init(reply, &reply_iter) == 0) return null;
    if (bus.api.iter_get_arg_type(&reply_iter) != dbus.dbus_type_array) return null;
    var keys_arr: dbus.DBusMessageIter = .{};
    bus.api.iter_recurse(&reply_iter, &keys_arr);

    var list = std.ArrayList(i32){};
    defer list.deinit(allocator);
    while (bus.api.iter_get_arg_type(&keys_arr) == dbus.dbus_type_int32) {
        var qk: i32 = 0;
        bus.api.iter_get_basic(&keys_arr, @ptrCast(&qk));
        list.append(allocator, qk) catch return null;
        _ = bus.api.iter_next(&keys_arr);
    }
    return list.toOwnedSlice(allocator) catch null;
}

/// `org.kde.KGlobalAccel.setForeignShortcut(actionId: as, keys: ai)` (void return)
/// — **외부 (foreign) D-Bus client 가 다른 component 의 binding 직접 set** 의도
/// method. `setShortcut` 은 Qt 내부 client API 라 외부 D-Bus 호출 시 *empty
/// 반환 + 거부* (시연 #207). `setForeignShortcut` 은 외부용 정공.
///
/// `keys` 는 비어있어도 됨 — 해당 actionId 의 binding 전체 회수 의미.
/// kglobalshortcutsrc 파일은 *runtime cache only* — process 재시작 시 reset 가능.
fn kdeSetForeignShortcut(
    bus: *dbus.SessionBus,
    action_id: []const [*:0]const u8,
    keys: []const i32,
) !void {
    const dest: [*:0]const u8 = "org.kde.kglobalaccel";
    const path: [*:0]const u8 = "/kglobalaccel";
    const iface: [*:0]const u8 = "org.kde.KGlobalAccel";
    const method: [*:0]const u8 = "setForeignShortcut";

    const call = bus.api.message_new_method_call(dest, path, iface, method) orelse return error.PortalMessageAllocFailed;
    defer bus.api.message_unref(call);

    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);

    var arr_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "s", &arr_iter) == 0) return error.PortalAppendFailed;
    for (action_id) |s| {
        var p: [*:0]const u8 = s;
        if (bus.api.iter_append_basic(&arr_iter, dbus.dbus_type_string, @ptrCast(&p)) == 0) return error.PortalAppendFailed;
    }
    if (bus.api.iter_close_container(&iter, &arr_iter) == 0) return error.PortalAppendFailed;

    var keys_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "i", &keys_iter) == 0) return error.PortalAppendFailed;
    for (keys) |qk| {
        var k: i32 = qk;
        if (bus.api.iter_append_basic(&keys_iter, dbus.dbus_type_int32, @ptrCast(&k)) == 0) return error.PortalAppendFailed;
    }
    if (bus.api.iter_close_container(&iter, &keys_iter) == 0) return error.PortalAppendFailed;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);

    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const m = if (err.message) |x| std.mem.span(x) else "(no message)";
            log.appendLine("portal", "kglobalaccel setForeignShortcut failed: {s}", .{m});
        }
        return error.PortalMethodCallFailed;
    };
    defer bus.api.message_unref(reply);
}

/// 시연 확정 (#207): tildaz 자체용 setForeignShortcut 의 thin wrapper.
fn kdeSetToggleShortcut(_: std.mem.Allocator, bus: *dbus.SessionBus, qt_key: i32) !void {
    const action_id = [_][*:0]const u8{
        kde_component_tildaz,
        kde_action_toggle,
        kde_component_display,
        kde_action_display,
    };
    const keys = [_]i32{qt_key};
    try kdeSetForeignShortcut(bus, &action_id, &keys);
    log.appendLine("portal", "kglobalaccel setForeignShortcut(tildaz) succeeded — qt_key=0x{x}", .{@as(u32, @bitCast(qt_key))});
}

/// `owner` 의 keys list 에서 `our_qt_key` 만 제거 후 `setForeignShortcut` 으로
/// 갱신. 예: kwin/ExposeClass `[Meta+F7, Ctrl+F7]` 에서 `Ctrl+F7` 빼서
/// `[Meta+F7]` 로 set — `Meta+F7` 은 그대로 사용 가능 (#207 takeover).
///
/// owner 의 keys 가 query 실패 / 비어 있으면 silent return (already cleared).
fn kdeTakeoverConflict(
    allocator: std.mem.Allocator,
    bus: *dbus.SessionBus,
    owner: *const KdeOwnerActionId,
    our_qt_key: i32,
) !void {
    const action_id_slices = [_][]const u8{
        owner.component,
        owner.action,
        owner.display_component,
        owner.display_action,
    };
    const owner_keys = kdeQueryKeysForAction(allocator, bus, &action_id_slices) orelse {
        log.appendLine("portal", "takeover: owner '{s}' keys query null — skip", .{owner.component});
        return;
    };
    defer allocator.free(owner_keys);

    // our_qt_key 제외한 keys 만 남김.
    var filtered = std.ArrayList(i32){};
    defer filtered.deinit(allocator);
    for (owner_keys) |k| {
        if (k != our_qt_key) filtered.append(allocator, k) catch return error.OutOfMemory;
    }
    if (filtered.items.len == owner_keys.len) {
        // owner 가 our_qt_key 안 들고 있음 — KGlobalAccel.action 결과와 불일치.
        // race condition 가능 — skip.
        log.appendLine("portal", "takeover: owner '{s}' 의 keys 에 our_qt_key=0x{x} 없음 — skip", .{ owner.component, @as(u32, @bitCast(our_qt_key)) });
        return;
    }

    // setForeignShortcut 은 D-Bus 송신 시 `[*:0]const u8` 필요. owner 의
    // string 은 sentinel 없는 `[]u8` — sentinel buffer 로 복사.
    var bufs: [4][128]u8 = undefined;
    var owner_actionid_sentinels: [4][*:0]const u8 = undefined;
    inline for (.{ owner.component, owner.action, owner.display_component, owner.display_action }, 0..) |s, idx| {
        if (s.len + 1 > bufs[idx].len) return error.PortalAppendFailed;
        @memcpy(bufs[idx][0..s.len], s);
        bufs[idx][s.len] = 0;
        owner_actionid_sentinels[idx] = @ptrCast(&bufs[idx]);
    }
    try kdeSetForeignShortcut(bus, &owner_actionid_sentinels, filtered.items);
    log.appendLine("portal", "takeover: '{s}/{s}' 에서 qt_key=0x{x} 회수 (남은 keys = {})", .{
        owner.component,
        owner.action,
        @as(u32, @bitCast(our_qt_key)),
        filtered.items.len,
    });
}

/// `XDG_CURRENT_DESKTOP` env — 콜론 (`:`) 으로 다중 토큰 가능 (예: `Unity:GNOME`).
/// caller 가 free.
fn detectCurrentDesktop(allocator: std.mem.Allocator) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, "XDG_CURRENT_DESKTOP") catch null;
}

/// `:` 분리된 다중 토큰 안에 *대소문자 무관* `needle` 있는지.
fn containsToken(haystack: []const u8, needle: []const u8) bool {
    var iter = std.mem.tokenizeScalar(u8, haystack, ':');
    while (iter.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, needle)) return true;
    }
    return false;
}

fn showHotkeyUpdatedDialog(allocator: std.mem.Allocator, was: []const u8, now: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, messages.hotkey_updated_format, .{ was, now }) catch {
        dialog.showInfo(messages.hotkey_updated_title, "System hotkey updated to match config.");
        return;
    };
    dialog.showInfo(messages.hotkey_updated_title, msg);
    _ = allocator;
}

fn showMismatchPersistsDialog(allocator: std.mem.Allocator, preferred: []const u8, actual: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, messages.hotkey_mismatch_persists_format, .{ preferred, actual }) catch {
        dialog.showInfo(messages.hotkey_mismatch_persists_title, "Hotkey mismatch — adjust in your desktop's Global Shortcuts settings.");
        return;
    };
    dialog.showInfo(messages.hotkey_mismatch_persists_title, msg);
    _ = allocator;
}

/// portal `GlobalShortcuts.UnbindShortcuts` (spec v2, since 2). 같은 session 의
/// 기존 binding 제거. spec args:
///   o session_handle
///   as shortcuts (= ["toggle"])
///   a{sv} options (handle_token)
/// → reply: o handle (Request path)
/// → Response signal (u response_code, a{sv} results — empty)
fn unbindToggleShortcut(
    allocator: std.mem.Allocator,
    bus: *dbus.SessionBus,
    session_handle: []const u8,
) !void {
    try callShortcutRequestVerb(allocator, bus, session_handle, .unbind, unbind_handle_token, 0, 0);
}

fn rebindToggleShortcut(
    allocator: std.mem.Allocator,
    bus: *dbus.SessionBus,
    session_handle: []const u8,
    keysym: u32,
    modifiers: u32,
) !void {
    try callShortcutRequestVerb(allocator, bus, session_handle, .bind, rebind_handle_token, keysym, modifiers);
}

const ShortcutVerb = enum { bind, unbind };

/// `BindShortcuts` / `UnbindShortcuts` 공통 호출 helper. 둘 다 Request object
/// pattern (method call → Request path → Response signal) 동일. 차이:
///   - `BindShortcuts`: args = (o, a(sa{sv}), s, a{sv}). shortcuts 는 attrs 있음.
///   - `UnbindShortcuts`: args = (o, as, a{sv}). shortcuts 는 id 만.
fn callShortcutRequestVerb(
    allocator: std.mem.Allocator,
    bus: *dbus.SessionBus,
    session_handle: []const u8,
    verb: ShortcutVerb,
    request_token: [*:0]const u8,
    keysym: u32,
    modifiers: u32,
) !void {
    const sender_segment = try sanitizeSenderForPath(allocator, bus.unique_name);
    defer allocator.free(sender_segment);

    const expected_request_path = try std.fmt.allocPrint(allocator, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{
        sender_segment, std.mem.span(request_token),
    });
    defer allocator.free(expected_request_path);

    const match_rule = try std.fmt.allocPrintSentinel(allocator, "type='signal',interface='{s}',member='{s}',path='{s}'", .{
        std.mem.span(interface_request), std.mem.span(member_response), expected_request_path,
    }, 0);
    defer allocator.free(match_rule);

    const session_handle_z = try allocator.dupeZ(u8, session_handle);
    defer allocator.free(session_handle_z);

    var accelerator_opt: ?[:0]u8 = null;
    defer if (accelerator_opt) |a| allocator.free(a);
    if (verb == .bind) {
        accelerator_opt = try keysymToAccelerator(allocator, keysym, modifiers);
    }

    var state = ResponseWaitState{
        .api = &bus.api,
        .expected_request_path = expected_request_path,
        .allocator = allocator,
    };
    errdefer if (state.actual_trigger) |t| allocator.free(t);

    if (bus.api.add_filter(bus.conn, responseFilter, &state, null) == 0) return error.PortalAddFilterFailed;
    defer bus.api.remove_filter(bus.conn, responseFilter, &state);

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);

    bus.api.add_match(bus.conn, match_rule.ptr, &err);
    if (bus.api.error_is_set(&err) != 0) {
        const msg = if (err.message) |m| std.mem.span(m) else "(no message)";
        log.appendLine("portal", "{s} add_match failed: {s}", .{ @tagName(verb), msg });
        return error.PortalAddMatchFailed;
    }
    defer {
        var err2: dbus.DBusError = .{};
        bus.api.error_init(&err2);
        bus.api.remove_match(bus.conn, match_rule.ptr, &err2);
        bus.api.error_free(&err2);
    }

    const member_str: [*:0]const u8 = if (verb == .bind) member_bind_shortcuts else member_unbind_shortcuts;
    const call = bus.api.message_new_method_call(
        portal_destination,
        portal_path,
        interface_global_shortcuts,
        member_str,
    ) orelse return error.PortalMessageAllocFailed;
    defer bus.api.message_unref(call);

    {
        var iter: dbus.DBusMessageIter = .{};
        bus.api.iter_init_append(call, &iter);

        // arg 1: o session_handle.
        var session_var: [*:0]const u8 = session_handle_z.ptr;
        if (bus.api.iter_append_basic(&iter, dbus.dbus_type_object_path, @ptrCast(&session_var)) == 0) return error.PortalAppendFailed;

        if (verb == .bind) {
            // arg 2: a(sa{sv}) shortcuts — single entry "toggle" + attrs.
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
                const accel_ptr: [*:0]const u8 = accelerator_opt.?.ptr;
                try appendStringVariantEntry(&bus.api, &attrs_iter, "preferred_trigger", accel_ptr);
                if (bus.api.iter_close_container(&struct_iter, &attrs_iter) == 0) return error.PortalAppendFailed;
                if (bus.api.iter_close_container(&arr_iter, &struct_iter) == 0) return error.PortalAppendFailed;
            }
            if (bus.api.iter_close_container(&iter, &arr_iter) == 0) return error.PortalAppendFailed;

            // arg 3: s parent_window.
            var parent_var: [*:0]const u8 = "";
            if (bus.api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&parent_var)) == 0) return error.PortalAppendFailed;
        } else {
            // arg 2: as shortcuts — list of ids ("toggle").
            var arr_iter: dbus.DBusMessageIter = .{};
            if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "s", &arr_iter) == 0) return error.PortalAppendFailed;
            var id_var: [*:0]const u8 = shortcut_id_toggle;
            if (bus.api.iter_append_basic(&arr_iter, dbus.dbus_type_string, @ptrCast(&id_var)) == 0) return error.PortalAppendFailed;
            if (bus.api.iter_close_container(&iter, &arr_iter) == 0) return error.PortalAppendFailed;
        }

        // last arg: a{sv} options — handle_token.
        var opt_iter: dbus.DBusMessageIter = .{};
        if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "{sv}", &opt_iter) == 0) return error.PortalAppendFailed;
        try appendStringVariantEntry(&bus.api, &opt_iter, "handle_token", request_token);
        if (bus.api.iter_close_container(&iter, &opt_iter) == 0) return error.PortalAppendFailed;
    }

    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const m = if (err.message) |x| std.mem.span(x) else "(no message)";
            log.appendLine("portal", "{s} method call failed: {s}", .{ @tagName(verb), m });
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
            log.appendLine("portal", "{s} request path mismatch — expected={s} got={s}", .{ @tagName(verb), expected_request_path, got_path });
            return error.PortalRequestPathMismatch;
        }
    }

    log.appendLine("portal", "{s} request sent — waiting for response", .{@tagName(verb)});

    const start_ms = std.time.milliTimestamp();
    while (!state.done) {
        if (bus.api.read_write_dispatch(bus.conn, dispatch_iter_timeout_ms) == 0) {
            log.appendLine("portal", "connection disconnected during {s} wait", .{@tagName(verb)});
            return error.PortalConnectionLost;
        }
        if (std.time.milliTimestamp() - start_ms > bind_total_timeout_ms) {
            log.appendLine("portal", "{s} Response signal timeout", .{@tagName(verb)});
            return error.PortalResponseTimeout;
        }
    }

    if (state.response_code != response_code_success) {
        log.appendLine("portal", "{s} response code={d}", .{ @tagName(verb), state.response_code });
        return error.PortalRequestFailed;
    }

    log.appendLine("portal", "{s} success", .{@tagName(verb)});

    // bind 의 actual_trigger 확인은 첫 호출 위치에서 (mismatch detect). retry
    // path 에서는 *두 번째 actual* 도 처리해야 — 그러나 retry 도 mismatch 면
    // 사용자에게 mismatch_persists dialog (caller `handleHotkeyMismatch` 가 결정).
    // 여기서 단순 free.
    if (state.actual_trigger) |t| {
        if (verb == .bind and accelerator_opt != null) {
            // retry 의 actual 검사 — accelerator_opt 가 우리 preferred.
            // empty 도 mismatch — setShortcut 직접 set 이 실제 적용 안 됨 가능.
            if (!std.mem.eql(u8, t, accelerator_opt.?)) {
                log.appendLine("portal", "rebind still mismatched — config={s} actual=\"{s}\"", .{ accelerator_opt.?, t });
                allocator.free(t);
                return error.PortalRebindMismatch;
            }
        }
        allocator.free(t);
    }
}

/// L9-δ — `org.freedesktop.Notifications.Notify` D-Bus method call.
/// signature `susssasa{sv}i`:
///   s app_name, u replaces_id, s app_icon, s summary, s body,
///   as actions (empty 가능), a{sv} hints (empty 가능), i expire_timeout
///
/// fire-and-forget — 반환되는 notification id (u32) 무시. notification daemon
/// 부재 (`org.freedesktop.Notifications` service 등록 안 됨) 시 send_with_reply
/// 가 method-call 에러 반환 — caller 에서 log 만 (fatal 아님). spec:
/// https://specifications.freedesktop.org/notification-spec/notification-spec-latest.html
pub fn sendNotification(
    bus: *dbus.SessionBus,
    app_name: [*:0]const u8,
    summary: [*:0]const u8,
    body: [*:0]const u8,
) !void {
    const call = bus.api.message_new_method_call(
        notifications_destination,
        notifications_path,
        notifications_interface,
        notifications_member_notify,
    ) orelse return error.NotifyMessageAllocFailed;
    defer bus.api.message_unref(call);

    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);

    var app_var: [*:0]const u8 = app_name;
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&app_var)) == 0) return error.NotifyAppendFailed;

    var replaces_id: u32 = 0;
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_uint32, @ptrCast(&replaces_id)) == 0) return error.NotifyAppendFailed;

    var icon_var: [*:0]const u8 = "";
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&icon_var)) == 0) return error.NotifyAppendFailed;

    var summary_var: [*:0]const u8 = summary;
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&summary_var)) == 0) return error.NotifyAppendFailed;

    var body_var: [*:0]const u8 = body;
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&body_var)) == 0) return error.NotifyAppendFailed;

    // arg 5: as actions — 빈 array. interactive button 없음 (notification 만).
    var actions_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "s", &actions_iter) == 0) return error.NotifyAppendFailed;
    if (bus.api.iter_close_container(&iter, &actions_iter) == 0) return error.NotifyAppendFailed;

    // arg 6: a{sv} hints — 빈 dict (urgency / category 등 hint 안 줌, 기본).
    var hints_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "{sv}", &hints_iter) == 0) return error.NotifyAppendFailed;
    if (bus.api.iter_close_container(&iter, &hints_iter) == 0) return error.NotifyAppendFailed;

    // arg 7: i expire_timeout (-1 = daemon default; 0 = never; 양수 = ms).
    var timeout: i32 = -1;
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_int32, @ptrCast(&timeout)) == 0) return error.NotifyAppendFailed;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);

    const reply = bus.api.send_with_reply_and_block(bus.conn, call, notify_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const m = if (err.message) |x| std.mem.span(x) else "(no message)";
            log.appendLine("notify", "Notify method call failed: {s}", .{m});
        }
        return error.NotifyCallFailed;
    };
    bus.api.message_unref(reply);
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

    if (api.message_is_signal(msg, interface_global_shortcuts, member_activated) == 0) {
        return dbus.dbus_handler_result_not_yet_handled;
    }

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
