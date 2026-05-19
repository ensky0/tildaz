//! Runtime libdbus-1 wrapper for XDG Desktop Portal integration.
//!
//! L9 의 portal `GlobalShortcuts` 사용을 위한 session bus client. wayland 의
//! libxkbcommon / FreeType 처럼 runtime dlopen — macOS-hosted Linux cross build
//! 가 dbus headers / link 없이 통과 + Linux runtime 에선 거의 모든 distro
//! (Alpine / musl 포함) 의 `libdbus-1.so.3` 으로 동작 (systemd 비의존).
//!
//! L9-α scope: session bus connect + unique_name. L9-β-1: message build /
//! parse + filter + match + sync method call + read_write_dispatch loop —
//! portal `CreateSession` 등 method 호출 인프라.
//!
//! libdbus API 출처: https://dbus.freedesktop.org/doc/api/html/

const std = @import("std");
const log = @import("../../log.zig");

pub const DBusConnection = opaque {};
pub const DBusMessage = opaque {};

/// `DBusError` C struct 의 Zig ABI 미러. C 정의 (`dbus/dbus-types.h`):
///   const char *name;          // offset 0  (8 bytes)
///   const char *message;       // offset 8  (8 bytes)
///   unsigned int dummy1..5:1;  // offset 16 (= 5 bits + padding → 4 bytes)
///   void *padding1;            // offset 24 (8 bytes, alignment 8)
/// total 32 bytes on 64-bit. bit-field 들은 우리 코드가 직접 안 읽음 — `flags`
/// 한 묶음으로 잡고 dbus 측이 알아서 비트 set.
pub const DBusError = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    flags: u32 = 0,
    padding1: ?*anyopaque = null,
};

/// `DBusMessageIter` 의 stack-allocated buffer. libdbus 가 정확한 sizeof 를
/// public header 에 안 공개해서 (`dbus/dbus-message.h` 의 정의가 internal
/// struct 멤버 dummy 들 사용), 우리는 충분히 큰 opaque buffer 로 잡음. 64-bit
/// Linux 에서 실제 sizeof ≈ 56 bytes — 80 으로 margin 확보. alignment 8 (첫
/// 멤버가 void*).
pub const DBusMessageIter = extern struct {
    bytes: [80]u8 align(8) = @splat(0),
};

/// `DBusBusType::DBUS_BUS_SESSION` (= 0). xdg-desktop-portal 은 session bus
/// 에 등록됨.
const dbus_bus_type_session: c_int = 0;

/// libdbus type codes — `dbus/dbus-protocol.h` 의 `DBUS_TYPE_*` 매크로. ASCII
/// 문자 값 그대로 (예: `DBUS_TYPE_STRING = 's' = 115`).
pub const dbus_type_invalid: c_int = 0;
pub const dbus_type_string: c_int = 's';
pub const dbus_type_uint32: c_int = 'u';
pub const dbus_type_object_path: c_int = 'o';
pub const dbus_type_array: c_int = 'a';
pub const dbus_type_variant: c_int = 'v';
pub const dbus_type_dict_entry: c_int = 'e';
pub const dbus_type_struct: c_int = 'r';

/// `DBUS_HANDLER_RESULT_*` enum — filter / object handler 가 반환. HANDLED =
/// "이 message 처리 끝, 다음 filter 안 부름". NOT_YET_HANDLED = "다른 filter
/// 도 보여줘".
pub const dbus_handler_result_handled: c_int = 0;
pub const dbus_handler_result_not_yet_handled: c_int = 1;

/// `DBusHandleMessageFunction` — `dbus_connection_add_filter` 의 callback.
/// HANDLED 또는 NOT_YET_HANDLED 반환.
pub const DBusHandleMessageFunction = *const fn (
    conn: *DBusConnection,
    msg: *DBusMessage,
    user_data: ?*anyopaque,
) callconv(.c) c_int;

const DBusBusGetPrivate = *const fn (type_: c_int, err: ?*DBusError) callconv(.c) ?*DBusConnection;
const DBusBusGetUniqueName = *const fn (conn: *DBusConnection) callconv(.c) ?[*:0]const u8;
const DBusConnectionClose = *const fn (conn: *DBusConnection) callconv(.c) void;
const DBusConnectionUnref = *const fn (conn: *DBusConnection) callconv(.c) void;
const DBusErrorInit = *const fn (err: *DBusError) callconv(.c) void;
const DBusErrorFree = *const fn (err: *DBusError) callconv(.c) void;
const DBusErrorIsSet = *const fn (err: *const DBusError) callconv(.c) c_int;

const DBusMessageNewMethodCall = *const fn (
    destination: [*:0]const u8,
    path: [*:0]const u8,
    iface: [*:0]const u8,
    member: [*:0]const u8,
) callconv(.c) ?*DBusMessage;
const DBusMessageUnref = *const fn (msg: *DBusMessage) callconv(.c) void;
const DBusMessageIsSignal = *const fn (
    msg: *DBusMessage,
    iface: [*:0]const u8,
    member: [*:0]const u8,
) callconv(.c) c_int;
const DBusMessageGetPath = *const fn (msg: *DBusMessage) callconv(.c) ?[*:0]const u8;

const DBusMessageIterInitAppend = *const fn (msg: *DBusMessage, iter: *DBusMessageIter) callconv(.c) void;
const DBusMessageIterOpenContainer = *const fn (
    iter: *DBusMessageIter,
    type_: c_int,
    contents: ?[*:0]const u8,
    sub: *DBusMessageIter,
) callconv(.c) c_int;
const DBusMessageIterCloseContainer = *const fn (iter: *DBusMessageIter, sub: *DBusMessageIter) callconv(.c) c_int;
const DBusMessageIterAppendBasic = *const fn (
    iter: *DBusMessageIter,
    type_: c_int,
    value: *const anyopaque,
) callconv(.c) c_int;

const DBusMessageIterInit = *const fn (msg: *DBusMessage, iter: *DBusMessageIter) callconv(.c) c_int;
const DBusMessageIterGetArgType = *const fn (iter: *DBusMessageIter) callconv(.c) c_int;
const DBusMessageIterGetBasic = *const fn (iter: *DBusMessageIter, value: *anyopaque) callconv(.c) void;
const DBusMessageIterRecurse = *const fn (iter: *DBusMessageIter, sub: *DBusMessageIter) callconv(.c) void;
const DBusMessageIterNext = *const fn (iter: *DBusMessageIter) callconv(.c) c_int;

const DBusConnectionSendWithReplyAndBlock = *const fn (
    conn: *DBusConnection,
    msg: *DBusMessage,
    timeout_ms: c_int,
    err: ?*DBusError,
) callconv(.c) ?*DBusMessage;
const DBusConnectionAddFilter = *const fn (
    conn: *DBusConnection,
    function: DBusHandleMessageFunction,
    user_data: ?*anyopaque,
    free_data: ?*const fn (data: ?*anyopaque) callconv(.c) void,
) callconv(.c) c_int;
const DBusConnectionRemoveFilter = *const fn (
    conn: *DBusConnection,
    function: DBusHandleMessageFunction,
    user_data: ?*anyopaque,
) callconv(.c) void;
const DBusBusAddMatch = *const fn (conn: *DBusConnection, rule: [*:0]const u8, err: ?*DBusError) callconv(.c) void;
const DBusBusRemoveMatch = *const fn (conn: *DBusConnection, rule: [*:0]const u8, err: ?*DBusError) callconv(.c) void;
const DBusConnectionReadWriteDispatch = *const fn (conn: *DBusConnection, timeout_ms: c_int) callconv(.c) c_int;

pub const Api = struct {
    handle: *anyopaque,
    bus_get_private: DBusBusGetPrivate,
    bus_get_unique_name: DBusBusGetUniqueName,
    connection_close: DBusConnectionClose,
    connection_unref: DBusConnectionUnref,
    error_init: DBusErrorInit,
    error_free: DBusErrorFree,
    error_is_set: DBusErrorIsSet,
    message_new_method_call: DBusMessageNewMethodCall,
    message_unref: DBusMessageUnref,
    message_is_signal: DBusMessageIsSignal,
    message_get_path: DBusMessageGetPath,
    iter_init_append: DBusMessageIterInitAppend,
    iter_open_container: DBusMessageIterOpenContainer,
    iter_close_container: DBusMessageIterCloseContainer,
    iter_append_basic: DBusMessageIterAppendBasic,
    iter_init: DBusMessageIterInit,
    iter_get_arg_type: DBusMessageIterGetArgType,
    iter_get_basic: DBusMessageIterGetBasic,
    iter_recurse: DBusMessageIterRecurse,
    iter_next: DBusMessageIterNext,
    send_with_reply_and_block: DBusConnectionSendWithReplyAndBlock,
    add_filter: DBusConnectionAddFilter,
    remove_filter: DBusConnectionRemoveFilter,
    add_match: DBusBusAddMatch,
    remove_match: DBusBusRemoveMatch,
    read_write_dispatch: DBusConnectionReadWriteDispatch,

    fn load() !Api {
        const handle = std.c.dlopen("libdbus-1.so.3", .{ .LAZY = true }) orelse return error.DBusLibraryMissing;
        errdefer _ = std.c.dlclose(handle);

        return .{
            .handle = handle,
            .bus_get_private = lookupSymbol(handle, DBusBusGetPrivate, "dbus_bus_get_private"),
            .bus_get_unique_name = lookupSymbol(handle, DBusBusGetUniqueName, "dbus_bus_get_unique_name"),
            .connection_close = lookupSymbol(handle, DBusConnectionClose, "dbus_connection_close"),
            .connection_unref = lookupSymbol(handle, DBusConnectionUnref, "dbus_connection_unref"),
            .error_init = lookupSymbol(handle, DBusErrorInit, "dbus_error_init"),
            .error_free = lookupSymbol(handle, DBusErrorFree, "dbus_error_free"),
            .error_is_set = lookupSymbol(handle, DBusErrorIsSet, "dbus_error_is_set"),
            .message_new_method_call = lookupSymbol(handle, DBusMessageNewMethodCall, "dbus_message_new_method_call"),
            .message_unref = lookupSymbol(handle, DBusMessageUnref, "dbus_message_unref"),
            .message_is_signal = lookupSymbol(handle, DBusMessageIsSignal, "dbus_message_is_signal"),
            .message_get_path = lookupSymbol(handle, DBusMessageGetPath, "dbus_message_get_path"),
            .iter_init_append = lookupSymbol(handle, DBusMessageIterInitAppend, "dbus_message_iter_init_append"),
            .iter_open_container = lookupSymbol(handle, DBusMessageIterOpenContainer, "dbus_message_iter_open_container"),
            .iter_close_container = lookupSymbol(handle, DBusMessageIterCloseContainer, "dbus_message_iter_close_container"),
            .iter_append_basic = lookupSymbol(handle, DBusMessageIterAppendBasic, "dbus_message_iter_append_basic"),
            .iter_init = lookupSymbol(handle, DBusMessageIterInit, "dbus_message_iter_init"),
            .iter_get_arg_type = lookupSymbol(handle, DBusMessageIterGetArgType, "dbus_message_iter_get_arg_type"),
            .iter_get_basic = lookupSymbol(handle, DBusMessageIterGetBasic, "dbus_message_iter_get_basic"),
            .iter_recurse = lookupSymbol(handle, DBusMessageIterRecurse, "dbus_message_iter_recurse"),
            .iter_next = lookupSymbol(handle, DBusMessageIterNext, "dbus_message_iter_next"),
            .send_with_reply_and_block = lookupSymbol(handle, DBusConnectionSendWithReplyAndBlock, "dbus_connection_send_with_reply_and_block"),
            .add_filter = lookupSymbol(handle, DBusConnectionAddFilter, "dbus_connection_add_filter"),
            .remove_filter = lookupSymbol(handle, DBusConnectionRemoveFilter, "dbus_connection_remove_filter"),
            .add_match = lookupSymbol(handle, DBusBusAddMatch, "dbus_bus_add_match"),
            .remove_match = lookupSymbol(handle, DBusBusRemoveMatch, "dbus_bus_remove_match"),
            .read_write_dispatch = lookupSymbol(handle, DBusConnectionReadWriteDispatch, "dbus_connection_read_write_dispatch"),
        };
    }

    fn deinit(self: *Api) void {
        _ = std.c.dlclose(self.handle);
    }
};

/// dlsym 결과를 함수 ptr 로 cast. 모든 libdbus symbol 은 같은 라이브러리의
/// 공개 API 라 lookup 실패는 라이브러리 corruption — fatal panic. 우리는
/// 라이브러리 버전 / 호환성 확인 안 함 (libdbus 1.x ABI 안정성에 의존).
fn lookupSymbol(handle: *anyopaque, comptime T: type, name: [*:0]const u8) T {
    const symbol = std.c.dlsym(handle, name) orelse std.debug.panic("libdbus missing symbol: {s}", .{name});
    return @ptrCast(@alignCast(symbol));
}

/// session bus 연결 + unique_name 로그 + cleanup 책임. method call / signal
/// subscribe API 는 portal.zig 가 `api` field 통해 사용.
pub const SessionBus = struct {
    api: Api,
    conn: *DBusConnection,
    unique_name: []const u8,

    pub fn connect() !SessionBus {
        const api = try Api.load();
        var api_mut = api;
        errdefer api_mut.deinit();

        var err: DBusError = .{};
        api.error_init(&err);
        defer api.error_free(&err);

        const conn = api.bus_get_private(dbus_bus_type_session, &err) orelse {
            if (api.error_is_set(&err) != 0) {
                const msg = if (err.message) |m| std.mem.span(m) else "(no message)";
                log.appendLine("dbus", "dbus_bus_get_private failed: {s}", .{msg});
            }
            return error.DBusConnectFailed;
        };
        errdefer {
            api.connection_close(conn);
            api.connection_unref(conn);
        }

        const name_c = api.bus_get_unique_name(conn) orelse return error.DBusUniqueNameFailed;
        const unique_name = std.mem.span(name_c);

        log.appendLine("dbus", "session bus connected unique_name={s}", .{unique_name});

        return .{
            .api = api,
            .conn = conn,
            .unique_name = unique_name,
        };
    }

    pub fn deinit(self: *SessionBus) void {
        self.api.connection_close(self.conn);
        self.api.connection_unref(self.conn);
        self.api.deinit();
    }
};
