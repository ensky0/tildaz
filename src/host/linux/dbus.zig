//! Runtime libdbus-1 wrapper for XDG Desktop Portal integration.
//!
//! L9 의 portal `GlobalShortcuts` 사용을 위한 session bus client. wayland 의
//! libxkbcommon / FreeType 처럼 runtime dlopen — macOS-hosted Linux cross build
//! 가 dbus headers / link 없이 통과 + Linux runtime 에선 거의 모든 distro
//! (Alpine / musl 포함) 의 `libdbus-1.so.3` 으로 동작 (systemd 비의존).
//!
//! L9-α scope — session bus connect + unique_name 조회 + cleanup. method call /
//! signal subscribe / event loop 통합은 L9-β 부터 (CreateSession / BindShortcuts).
//!
//! libdbus API 출처: https://dbus.freedesktop.org/doc/api/html/group__DBusBus.html
//! / https://dbus.freedesktop.org/doc/api/html/group__DBusConnection.html

const std = @import("std");
const log = @import("../../log.zig");

const DBusConnection = opaque {};

/// `DBusError` C struct 의 Zig ABI 미러. C 정의 (`dbus/dbus-types.h`):
///   const char *name;          // offset 0  (8 bytes)
///   const char *message;       // offset 8  (8 bytes)
///   unsigned int dummy1..5:1;  // offset 16 (= 5 bits + padding → 4 bytes)
///   void *padding1;            // offset 24 (8 bytes, alignment 8)
/// total 32 bytes on 64-bit. bit-field 들은 우리 코드가 직접 안 읽음 — `flags`
/// 한 묶음으로 잡고 dbus 측이 알아서 비트 set.
const DBusError = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    flags: u32 = 0,
    padding1: ?*anyopaque = null,
};

/// `DBusBusType` enum 의 정수값. SESSION = 0 (xdg-desktop-portal 전용),
/// SYSTEM = 1, STARTER = 2.
const dbus_bus_type_session: c_int = 0;

const DBusBusGetPrivate = *const fn (type_: c_int, err: ?*DBusError) callconv(.c) ?*DBusConnection;
const DBusBusGetUniqueName = *const fn (conn: *DBusConnection) callconv(.c) ?[*:0]const u8;
const DBusConnectionClose = *const fn (conn: *DBusConnection) callconv(.c) void;
const DBusConnectionUnref = *const fn (conn: *DBusConnection) callconv(.c) void;
const DBusErrorInit = *const fn (err: *DBusError) callconv(.c) void;
const DBusErrorFree = *const fn (err: *DBusError) callconv(.c) void;
const DBusErrorIsSet = *const fn (err: *const DBusError) callconv(.c) c_int;

const Api = struct {
    handle: *anyopaque,
    bus_get_private: DBusBusGetPrivate,
    bus_get_unique_name: DBusBusGetUniqueName,
    connection_close: DBusConnectionClose,
    connection_unref: DBusConnectionUnref,
    error_init: DBusErrorInit,
    error_free: DBusErrorFree,
    error_is_set: DBusErrorIsSet,

    fn load() !Api {
        const handle = std.c.dlopen("libdbus-1.so.3", .{ .LAZY = true }) orelse return error.DBusLibraryMissing;
        errdefer _ = std.c.dlclose(handle);

        return .{
            .handle = handle,
            .bus_get_private = lookup(handle, DBusBusGetPrivate, "dbus_bus_get_private") orelse return error.DBusSymbolMissing,
            .bus_get_unique_name = lookup(handle, DBusBusGetUniqueName, "dbus_bus_get_unique_name") orelse return error.DBusSymbolMissing,
            .connection_close = lookup(handle, DBusConnectionClose, "dbus_connection_close") orelse return error.DBusSymbolMissing,
            .connection_unref = lookup(handle, DBusConnectionUnref, "dbus_connection_unref") orelse return error.DBusSymbolMissing,
            .error_init = lookup(handle, DBusErrorInit, "dbus_error_init") orelse return error.DBusSymbolMissing,
            .error_free = lookup(handle, DBusErrorFree, "dbus_error_free") orelse return error.DBusSymbolMissing,
            .error_is_set = lookup(handle, DBusErrorIsSet, "dbus_error_is_set") orelse return error.DBusSymbolMissing,
        };
    }

    fn deinit(self: *Api) void {
        _ = std.c.dlclose(self.handle);
    }
};

fn lookup(handle: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
    const symbol = std.c.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(symbol));
}

/// session bus 연결 + unique_name 로그 + cleanup 책임. L9-α 는 이게 끝 —
/// method call / signal 은 L9-β 부터 이 struct 위에 build. `dbus_bus_get_private`
/// 사용 (shared `dbus_bus_get` 와 달리 우리가 close / unref 책임) — terminal
/// 종료 시 깔끔하게 disconnect.
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
