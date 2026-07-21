//! KDE Plasma KGlobalAccel D-Bus integration.
//!
//! instance/action identity, Qt key conversion, conflict diagnosis/takeover,
//! persistent numbered identity cleanup을 portal lifecycle과 분리한다. direct
//! registration과 Component signal client도 이 모듈에 둔다.
//!
//! Official interfaces:
//! - https://github.com/KDE/kglobalaccel/blob/master/src/org.kde.KGlobalAccel.xml
//! - https://github.com/KDE/kglobalaccel/blob/master/src/org.kde.kglobalaccel.Component.xml

const std = @import("std");
const instance_context = @import("../../instance_context.zig");
const instance_identity = @import("instance_identity.zig");
const log = @import("../../log.zig");
const dialog = @import("../../dialog.zig");
const messages = @import("../../messages.zig");
const dbus = @import("dbus.zig");
const hotkey_format = @import("hotkey_format.zig");

const destination: [*:0]const u8 = "org.kde.kglobalaccel";
const root_path: [*:0]const u8 = "/kglobalaccel";
const root_interface: [*:0]const u8 = "org.kde.KGlobalAccel";
const component_interface: [*:0]const u8 = "org.kde.kglobalaccel.Component";
const component_pressed: [*:0]const u8 = "globalShortcutPressed";
const dbus_interface: [*:0]const u8 = "org.freedesktop.DBus";
const dbus_name_owner_changed: [*:0]const u8 = "NameOwnerChanged";
const method_call_timeout_ms: c_int = 25_000;
const qkeysequence_slots: usize = 4;

var component_buf: [32]u8 = undefined;
pub fn component() [*:0]const u8 {
    return (instance_identity.appId(&component_buf, instance_context.requireWorkerIndex()) catch unreachable).ptr;
}

var action_buf: [32]u8 = undefined;
pub fn action() [*:0]const u8 {
    return (instance_identity.shortcutId(&action_buf, instance_context.requireWorkerIndex()) catch unreachable).ptr;
}

var component_display_buf: [32]u8 = undefined;
pub fn componentDisplay() [*:0]const u8 {
    return (instance_identity.displayName(&component_display_buf, instance_context.requireWorkerIndex()) catch unreachable).ptr;
}

var action_display_buf: [64]u8 = undefined;
pub fn actionDisplay() [*:0]const u8 {
    return (instance_identity.shortcutDescription(&action_display_buf, instance_context.requireWorkerIndex()) catch unreachable).ptr;
}

pub const set_shortcut_flag_set_present: u32 = 2;
pub const set_shortcut_flag_no_autoloading: u32 = 4;
pub const set_shortcut_flags: u32 = set_shortcut_flag_set_present | set_shortcut_flag_no_autoloading;

fn actionId() [4][*:0]const u8 {
    return .{ component(), action(), componentDisplay(), actionDisplay() };
}

fn appendStringArray(api: *const dbus.Api, iter: *dbus.DBusMessageIter, values: []const [*:0]const u8) !void {
    var array: dbus.DBusMessageIter = .{};
    if (api.iter_open_container(iter, dbus.dbus_type_array, "s", &array) == 0) return error.KGlobalAccelAppendFailed;
    for (values) |value| {
        var ptr: [*:0]const u8 = value;
        if (api.iter_append_basic(&array, dbus.dbus_type_string, @ptrCast(&ptr)) == 0) return error.KGlobalAccelAppendFailed;
    }
    if (api.iter_close_container(iter, &array) == 0) return error.KGlobalAccelAppendFailed;
}

fn unregisterShortcut(bus: *dbus.SessionBus, component_name: [*:0]const u8, action_name: [*:0]const u8) !void {
    const call = bus.api.message_new_method_call(destination, root_path, root_interface, "unregister") orelse return error.KGlobalAccelMessageAllocFailed;
    defer bus.api.message_unref(call);

    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);
    var component_var: [*:0]const u8 = component_name;
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&component_var)) == 0) return error.KGlobalAccelAppendFailed;
    var action_var: [*:0]const u8 = action_name;
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&action_var)) == 0) return error.KGlobalAccelAppendFailed;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);
    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const msg = if (err.message) |value| std.mem.span(value) else "(no message)";
            log.appendLine("kglobalaccel", "kglobalaccel unregister failed: {s}", .{msg});
        }
        return error.KGlobalAccelMethodCallFailed;
    };
    defer bus.api.message_unref(reply);
    log.appendLineVerbose("kglobalaccel", "kglobalaccel unregister succeeded — component={s} action={s}", .{ std.mem.span(component_name), std.mem.span(action_name) });
}

pub fn syncNumberedIdentities(allocator: std.mem.Allocator, indices: []const u32) void {
    const desktop = std.process.getEnvVarOwned(allocator, "XDG_CURRENT_DESKTOP") catch return;
    defer allocator.free(desktop);
    if (!isKdeDesktopValue(desktop)) return;

    var bus = dbus.SessionBus.connect() catch |err| {
        log.appendLineVerbose("kglobalaccel", "KDE numbered identity query skipped: {s}", .{@errorName(err)});
        return;
    };
    defer bus.deinit();

    const paths = allComponentPaths(allocator, &bus) catch |err| {
        log.appendLineVerbose("kglobalaccel", "KDE component enumeration skipped: {s}", .{@errorName(err)});
        return;
    };
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    var kept: usize = 0;
    var removed: usize = 0;
    for (paths) |path| {
        const unique_name = componentUniqueName(allocator, &bus, path) catch continue;
        defer allocator.free(unique_name);
        const index = numberedComponentIndex(unique_name) orelse continue;
        if (containsInstanceIndex(indices, index)) {
            kept += 1;
            continue;
        }

        const component_z = allocator.dupeZ(u8, unique_name) catch continue;
        defer allocator.free(component_z);
        var stale_action_buf: [32]u8 = undefined;
        const stale_action = std.fmt.bufPrintZ(&stale_action_buf, "toggle-{d}", .{index}) catch continue;
        unregisterShortcut(&bus, component_z.ptr, stale_action.ptr) catch |err| {
            log.appendLineVerbose("kglobalaccel", "stale KDE action cleanup skipped for instance {}: {s}", .{ index, @errorName(err) });
            continue;
        };
        removed += 1;
    }
    log.appendLine("kglobalaccel", "KDE numbered hotkeys synchronized desired={} kept={} removed={}", .{ indices.len, kept, removed });
}

fn allComponentPaths(allocator: std.mem.Allocator, bus: *dbus.SessionBus) ![][]u8 {
    const call = bus.api.message_new_method_call(destination, root_path, root_interface, "allComponents") orelse return error.KGlobalAccelMessageAllocFailed;
    defer bus.api.message_unref(call);

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);
    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse return error.KGlobalAccelMethodCallFailed;
    defer bus.api.message_unref(reply);

    var reply_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_init(reply, &reply_iter) == 0 or bus.api.iter_get_arg_type(&reply_iter) != dbus.dbus_type_array) return error.KGlobalAccelReplyBadType;
    var array_iter: dbus.DBusMessageIter = .{};
    bus.api.iter_recurse(&reply_iter, &array_iter);

    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    while (bus.api.iter_get_arg_type(&array_iter) != dbus.dbus_type_invalid) {
        if (bus.api.iter_get_arg_type(&array_iter) != dbus.dbus_type_object_path) return error.KGlobalAccelReplyBadType;
        var path_c: ?[*:0]const u8 = null;
        bus.api.iter_get_basic(&array_iter, @ptrCast(&path_c));
        if (path_c) |path| try paths.append(allocator, try allocator.dupe(u8, std.mem.span(path)));
        if (bus.api.iter_next(&array_iter) == 0) break;
    }
    return paths.toOwnedSlice(allocator);
}

fn componentUniqueName(allocator: std.mem.Allocator, bus: *dbus.SessionBus, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const call = bus.api.message_new_method_call(destination, path_z.ptr, "org.freedesktop.DBus.Properties", "Get") orelse return error.KGlobalAccelMessageAllocFailed;
    defer bus.api.message_unref(call);

    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);
    var interface_name: [*:0]const u8 = "org.kde.kglobalaccel.Component";
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&interface_name)) == 0) return error.KGlobalAccelAppendFailed;
    var property_name: [*:0]const u8 = "uniqueName";
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&property_name)) == 0) return error.KGlobalAccelAppendFailed;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);
    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse return error.KGlobalAccelMethodCallFailed;
    defer bus.api.message_unref(reply);

    var reply_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_init(reply, &reply_iter) == 0 or bus.api.iter_get_arg_type(&reply_iter) != dbus.dbus_type_variant) return error.KGlobalAccelReplyBadType;
    var value_iter: dbus.DBusMessageIter = .{};
    bus.api.iter_recurse(&reply_iter, &value_iter);
    if (bus.api.iter_get_arg_type(&value_iter) != dbus.dbus_type_string) return error.KGlobalAccelReplyBadType;
    var value_c: ?[*:0]const u8 = null;
    bus.api.iter_get_basic(&value_iter, @ptrCast(&value_c));
    return allocator.dupe(u8, if (value_c) |value| std.mem.span(value) else "");
}

fn numberedComponentIndex(component_name: []const u8) ?u32 {
    const prefix = "tildaz.instance";
    if (!std.mem.startsWith(u8, component_name, prefix)) return null;
    const number = component_name[prefix.len..];
    if (number.len == 0 or (number.len > 1 and number[0] == '0')) return null;
    return std.fmt.parseInt(u32, number, 10) catch null;
}

fn containsInstanceIndex(indices: []const u32, needle: u32) bool {
    for (indices) |index| if (index == needle) return true;
    return false;
}

pub fn cleanupLegacyIdentity(allocator: std.mem.Allocator, bus: *dbus.SessionBus) void {
    const desktop = std.process.getEnvVarOwned(allocator, "XDG_CURRENT_DESKTOP") catch return;
    defer allocator.free(desktop);
    if (!isKdeDesktopValue(desktop)) return;

    const legacy_component: [*:0]const u8 = "tildaz";
    if (instance_context.requireWorkerIndex() == 0) {
        unregisterShortcut(bus, legacy_component, "toggle") catch |err| {
            log.appendLineVerbose("kglobalaccel", "legacy KDE action cleanup skipped: {s}", .{@errorName(err)});
        };
    }
    var legacy_action_buf: [32]u8 = undefined;
    const legacy_action = std.fmt.bufPrintZ(&legacy_action_buf, "toggle-{d}", .{instance_context.requireWorkerIndex()}) catch return;
    unregisterShortcut(bus, legacy_component, legacy_action.ptr) catch |err| {
        log.appendLineVerbose("kglobalaccel", "legacy numbered KDE action cleanup skipped: {s}", .{@errorName(err)});
    };
}

pub fn qtKey(keysym: u32, modifiers: u32) i32 {
    var key: i32 = 0;
    if ((modifiers & 0x4) != 0) key |= 0x02000000;
    if ((modifiers & 0x2) != 0) key |= 0x04000000;
    if ((modifiers & 0x1) != 0) key |= 0x08000000;
    if ((modifiers & 0x8) != 0) key |= 0x10000000;

    const key_code: i32 = switch (keysym) {
        0xffbe => 0x01000030,
        0xffbf => 0x01000031,
        0xffc0 => 0x01000032,
        0xffc1 => 0x01000033,
        0xffc2 => 0x01000034,
        0xffc3 => 0x01000035,
        0xffc4 => 0x01000036,
        0xffc5 => 0x01000037,
        0xffc6 => 0x01000038,
        0xffc7 => 0x01000039,
        0xffc8 => 0x0100003a,
        0xffc9 => 0x0100003b,
        0xff09 => 0x01000001,
        0xff0d => 0x01000004,
        0xff1b => 0x01000000,
        0x0020 => 0x20,
        0x0060 => 0x60,
        '0'...'9' => @intCast(keysym),
        'a'...'z' => @intCast(keysym - 0x20),
        else => 0,
    };
    return key | key_code;
}

pub fn queryToggleShortcut(bus: *dbus.SessionBus) ?i32 {
    const call = bus.api.message_new_method_call(destination, root_path, root_interface, "shortcut") orelse return null;
    defer bus.api.message_unref(call);

    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);
    const action_id = actionId();
    appendStringArray(&bus.api, &iter, &action_id) catch return null;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);
    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const msg = if (err.message) |value| std.mem.span(value) else "(no message)";
            log.appendLine("kglobalaccel", "kglobalaccel shortcut query failed: {s}", .{msg});
        }
        return null;
    };
    defer bus.api.message_unref(reply);

    var reply_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_init(reply, &reply_iter) == 0 or bus.api.iter_get_arg_type(&reply_iter) != dbus.dbus_type_array) return null;
    var keys: dbus.DBusMessageIter = .{};
    bus.api.iter_recurse(&reply_iter, &keys);
    if (bus.api.iter_get_arg_type(&keys) != dbus.dbus_type_int32) return null;
    var qt_key: i32 = 0;
    bus.api.iter_get_basic(&keys, @ptrCast(&qt_key));
    return qt_key;
}

const OwnerActionId = struct {
    component: []u8,
    action: []u8,
    display_component: []u8,
    display_action: []u8,

    fn deinit(self: *OwnerActionId, allocator: std.mem.Allocator) void {
        allocator.free(self.component);
        allocator.free(self.action);
        allocator.free(self.display_component);
        allocator.free(self.display_action);
    }
};

fn queryOwnerForKey(allocator: std.mem.Allocator, bus: *dbus.SessionBus, qt_key: i32) ?OwnerActionId {
    const call = bus.api.message_new_method_call(destination, root_path, root_interface, "action") orelse return null;
    defer bus.api.message_unref(call);
    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);
    var key = qt_key;
    if (bus.api.iter_append_basic(&iter, dbus.dbus_type_int32, @ptrCast(&key)) == 0) return null;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);
    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const msg = if (err.message) |value| std.mem.span(value) else "(no message)";
            log.appendLine("kglobalaccel", "kglobalaccel action query failed: {s}", .{msg});
        }
        return null;
    };
    defer bus.api.message_unref(reply);

    var reply_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_init(reply, &reply_iter) == 0 or bus.api.iter_get_arg_type(&reply_iter) != dbus.dbus_type_array) return null;
    var array: dbus.DBusMessageIter = .{};
    bus.api.iter_recurse(&reply_iter, &array);

    var values: [4][]u8 = .{ &.{}, &.{}, &.{}, &.{} };
    var count: usize = 0;
    while (count < values.len and bus.api.iter_get_arg_type(&array) == dbus.dbus_type_string) : (count += 1) {
        var raw: [*:0]const u8 = undefined;
        bus.api.iter_get_basic(&array, @ptrCast(&raw));
        values[count] = allocator.dupe(u8, std.mem.span(raw)) catch {
            for (values[0..count]) |value| allocator.free(value);
            return null;
        };
        _ = bus.api.iter_next(&array);
    }
    if (count != values.len or values[0].len == 0) {
        for (values[0..count]) |value| allocator.free(value);
        return null;
    }
    return .{
        .component = values[0],
        .action = values[1],
        .display_component = values[2],
        .display_action = values[3],
    };
}

const KeySequences = struct {
    items: [][]i32,

    fn deinit(self: *KeySequences, allocator: std.mem.Allocator) void {
        for (self.items) |sequence| allocator.free(sequence);
        allocator.free(self.items);
    }
};

fn queryKeySequencesForAction(allocator: std.mem.Allocator, bus: *dbus.SessionBus, action_id: []const []const u8) ?KeySequences {
    const call = bus.api.message_new_method_call(destination, root_path, root_interface, "shortcutKeys") orelse return null;
    defer bus.api.message_unref(call);

    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);
    var array: dbus.DBusMessageIter = .{};
    if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "s", &array) == 0) return null;
    var buffers: [4][128]u8 = undefined;
    for (action_id, 0..) |value, index| {
        if (index >= buffers.len or value.len + 1 > buffers[index].len) return null;
        @memcpy(buffers[index][0..value.len], value);
        buffers[index][value.len] = 0;
        var ptr: [*:0]const u8 = @ptrCast(&buffers[index]);
        if (bus.api.iter_append_basic(&array, dbus.dbus_type_string, @ptrCast(&ptr)) == 0) return null;
    }
    if (bus.api.iter_close_container(&iter, &array) == 0) return null;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);
    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const msg = if (err.message) |value| std.mem.span(value) else "(no message)";
            log.appendLine("kglobalaccel", "kglobalaccel shortcutKeys(action) query failed: {s}", .{msg});
        }
        return null;
    };
    defer bus.api.message_unref(reply);

    var reply_iter: dbus.DBusMessageIter = .{};
    if (bus.api.iter_init(reply, &reply_iter) == 0 or bus.api.iter_get_arg_type(&reply_iter) != dbus.dbus_type_array) return null;
    var entries: dbus.DBusMessageIter = .{};
    bus.api.iter_recurse(&reply_iter, &entries);
    var sequences: std.ArrayList([]i32) = .empty;
    defer {
        for (sequences.items) |sequence| allocator.free(sequence);
        sequences.deinit(allocator);
    }
    while (bus.api.iter_get_arg_type(&entries) != dbus.dbus_type_invalid) {
        if (bus.api.iter_get_arg_type(&entries) != dbus.dbus_type_struct) return null;
        var sequence_struct: dbus.DBusMessageIter = .{};
        bus.api.iter_recurse(&entries, &sequence_struct);
        if (bus.api.iter_get_arg_type(&sequence_struct) != dbus.dbus_type_array) return null;
        var keys: dbus.DBusMessageIter = .{};
        bus.api.iter_recurse(&sequence_struct, &keys);
        var sequence: std.ArrayList(i32) = .empty;
        defer sequence.deinit(allocator);
        while (bus.api.iter_get_arg_type(&keys) != dbus.dbus_type_invalid) {
            if (bus.api.iter_get_arg_type(&keys) != dbus.dbus_type_int32) return null;
            var key: i32 = 0;
            bus.api.iter_get_basic(&keys, @ptrCast(&key));
            sequence.append(allocator, key) catch return null;
            if (bus.api.iter_next(&keys) == 0) break;
        }
        // KDE의 QKeySequence D-Bus operator는 count와 무관하게 정확히 4개
        // int를 직렬화하고, 역직렬화도 4개를 무조건 읽는다.
        if (sequence.items.len != qkeysequence_slots) return null;
        const owned = sequence.toOwnedSlice(allocator) catch return null;
        sequences.append(allocator, owned) catch {
            allocator.free(owned);
            return null;
        };
        if (bus.api.iter_next(&entries) == 0) break;
    }
    return .{ .items = sequences.toOwnedSlice(allocator) catch return null };
}

fn setForeignShortcut(bus: *dbus.SessionBus, action_id: []const [*:0]const u8, keys: []const i32) !void {
    const call = bus.api.message_new_method_call(destination, root_path, root_interface, "setForeignShortcut") orelse return error.KGlobalAccelMessageAllocFailed;
    defer bus.api.message_unref(call);
    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);
    try appendStringArray(&bus.api, &iter, action_id);
    var key_array: dbus.DBusMessageIter = .{};
    if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "i", &key_array) == 0) return error.KGlobalAccelAppendFailed;
    for (keys) |value| {
        var key = value;
        if (bus.api.iter_append_basic(&key_array, dbus.dbus_type_int32, @ptrCast(&key)) == 0) return error.KGlobalAccelAppendFailed;
    }
    if (bus.api.iter_close_container(&iter, &key_array) == 0) return error.KGlobalAccelAppendFailed;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);
    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse {
        if (bus.api.error_is_set(&err) != 0) {
            const msg = if (err.message) |value| std.mem.span(value) else "(no message)";
            log.appendLine("kglobalaccel", "kglobalaccel setForeignShortcut failed: {s}", .{msg});
        }
        return error.KGlobalAccelMethodCallFailed;
    };
    defer bus.api.message_unref(reply);
}

fn setForeignShortcutKeys(bus: *dbus.SessionBus, action_id: []const [*:0]const u8, sequences: []const []const i32) !void {
    const call = bus.api.message_new_method_call(destination, root_path, root_interface, "setForeignShortcutKeys") orelse return error.KGlobalAccelMessageAllocFailed;
    defer bus.api.message_unref(call);
    var iter: dbus.DBusMessageIter = .{};
    bus.api.iter_init_append(call, &iter);
    try appendStringArray(&bus.api, &iter, action_id);
    var outer: dbus.DBusMessageIter = .{};
    if (bus.api.iter_open_container(&iter, dbus.dbus_type_array, "(ai)", &outer) == 0) return error.KGlobalAccelAppendFailed;
    for (sequences) |sequence_values| {
        if (sequence_values.len != qkeysequence_slots) return error.KGlobalAccelInvalidKeySequence;
        var sequence: dbus.DBusMessageIter = .{};
        if (bus.api.iter_open_container(&outer, dbus.dbus_type_struct, null, &sequence) == 0) return error.KGlobalAccelAppendFailed;
        var keys: dbus.DBusMessageIter = .{};
        if (bus.api.iter_open_container(&sequence, dbus.dbus_type_array, "i", &keys) == 0) return error.KGlobalAccelAppendFailed;
        for (sequence_values) |value| {
            var key = value;
            if (bus.api.iter_append_basic(&keys, dbus.dbus_type_int32, @ptrCast(&key)) == 0) return error.KGlobalAccelAppendFailed;
        }
        if (bus.api.iter_close_container(&sequence, &keys) == 0) return error.KGlobalAccelAppendFailed;
        if (bus.api.iter_close_container(&outer, &sequence) == 0) return error.KGlobalAccelAppendFailed;
    }
    if (bus.api.iter_close_container(&iter, &outer) == 0) return error.KGlobalAccelAppendFailed;

    var err: dbus.DBusError = .{};
    bus.api.error_init(&err);
    defer bus.api.error_free(&err);
    const reply = bus.api.send_with_reply_and_block(bus.conn, call, method_call_timeout_ms, &err) orelse return error.KGlobalAccelMethodCallFailed;
    bus.api.message_unref(reply);
}

fn setToggleShortcut(bus: *dbus.SessionBus, qt_key: i32) !void {
    const action_id = actionId();
    const keys = [_]i32{qt_key};
    try setForeignShortcut(bus, &action_id, &keys);
    log.appendLineVerbose("kglobalaccel", "kglobalaccel setForeignShortcut(tildaz) succeeded — qt_key=0x{x}", .{@as(u32, @bitCast(qt_key))});
}

fn takeoverConflict(allocator: std.mem.Allocator, bus: *dbus.SessionBus, owner: *const OwnerActionId, our_qt_key: i32) !void {
    const owner_id = [_][]const u8{ owner.component, owner.action, owner.display_component, owner.display_action };
    var owner_sequences = queryKeySequencesForAction(allocator, bus, &owner_id) orelse {
        log.appendLine("kglobalaccel", "takeover: owner '{s}' keys query null — skip", .{owner.component});
        return error.KGlobalAccelReplyBadType;
    };
    defer owner_sequences.deinit(allocator);

    var filtered: std.ArrayList([]const i32) = .empty;
    defer filtered.deinit(allocator);
    for (owner_sequences.items) |sequence| {
        if (isExactSingleKey(sequence, our_qt_key)) continue;
        try filtered.append(allocator, sequence);
    }
    if (filtered.items.len == owner_sequences.items.len) {
        log.appendLine("kglobalaccel", "takeover: owner '{s}' keys missing our_qt_key=0x{x} — skipped", .{ owner.component, @as(u32, @bitCast(our_qt_key)) });
        return error.KGlobalAccelShortcutOwnerMismatch;
    }

    var buffers: [4][128]u8 = undefined;
    var sentinels: [4][*:0]const u8 = undefined;
    inline for (.{ owner.component, owner.action, owner.display_component, owner.display_action }, 0..) |value, index| {
        if (value.len + 1 > buffers[index].len) return error.KGlobalAccelAppendFailed;
        @memcpy(buffers[index][0..value.len], value);
        buffers[index][value.len] = 0;
        sentinels[index] = @ptrCast(&buffers[index]);
    }
    try setForeignShortcutKeys(bus, &sentinels, filtered.items);
    log.appendLineVerbose("kglobalaccel", "takeover: from '{s}/{s}' reclaimed qt_key=0x{x} (remaining keys = {})", .{
        owner.component,
        owner.action,
        @as(u32, @bitCast(our_qt_key)),
        filtered.items.len,
    });
}

fn isExactSingleKey(sequence: []const i32, key: i32) bool {
    return sequence.len == qkeysequence_slots and
        sequence[0] == key and
        sequence[1] == 0 and
        sequence[2] == 0 and
        sequence[3] == 0;
}

pub const PressedCallback = *const fn (user_data: ?*anyopaque, timestamp: i64) void;

/// KDE Plasma 전용 direct KGlobalAccel client. filter user_data가 가리키므로 caller가
/// heap에서 stable address로 보관해야 한다. `create`가 이 규칙까지 책임진다.
pub const Client = struct {
    allocator: std.mem.Allocator,
    api: *const dbus.Api,
    conn: *dbus.DBusConnection,
    callback: PressedCallback,
    user_data: ?*anyopaque,
    owner_match_rule: [:0]u8,
    component_match_rule: ?[:0]u8 = null,
    component_path: ?[]u8 = null,
    is_registered: bool = false,
    owner_restart_pending: bool = false,
    filter_installed: bool = false,
    owner_match_installed: bool = false,
    component_match_installed: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        bus: *dbus.SessionBus,
        keysym: u32,
        modifiers: u32,
        callback: PressedCallback,
        user_data: ?*anyopaque,
    ) !*Client {
        const owner_rule = try allocator.dupeZ(
            u8,
            "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.kde.kglobalaccel'",
        );
        errdefer allocator.free(owner_rule);

        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .api = &bus.api,
            .conn = bus.conn,
            .callback = callback,
            .user_data = user_data,
            .owner_match_rule = owner_rule,
        };

        if (bus.api.add_filter(bus.conn, signalFilter, self, null) == 0) {
            return error.KGlobalAccelAddFilterFailed;
        }
        self.filter_installed = true;
        errdefer self.removeFilterAndMatches();

        try self.addMatch(owner_rule, "NameOwnerChanged");
        self.owner_match_installed = true;

        self.register(keysym, modifiers) catch |err| {
            self.setInactiveNoAutostart();
            return err;
        };
        return self;
    }

    pub fn deinit(self: *Client) void {
        // 정상 종료에서는 daemon의 영속 설정을 지우지 않고 현재 process action만
        // inactive로 만든다. daemon이 이미 죽었을 때 종료가 새 daemon을 띄우지
        // 않도록 method message의 auto-start를 명시적으로 끈다.
        self.setInactiveNoAutostart();
        self.removeFilterAndMatches();
        if (self.component_path) |path| self.allocator.free(path);
        if (self.component_match_rule) |rule| self.allocator.free(rule);
        self.allocator.free(self.owner_match_rule);
    }

    pub fn registered(self: *const Client) bool {
        return self.is_registered;
    }

    /// NameOwnerChanged filter는 D-Bus dispatch 안에서 이 flag만 세운다. 실제
    /// synchronous method call과 match 교체는 main loop가 callback 밖에서 수행한다.
    pub fn drainOwnerRestart(self: *Client, keysym: u32, modifiers: u32) void {
        if (!self.owner_restart_pending) return;
        self.owner_restart_pending = false;
        self.register(keysym, modifiers) catch |err| {
            self.is_registered = false;
            log.appendLine("kglobalaccel", "daemon restart re-registration failed: {s}", .{@errorName(err)});
            return;
        };
        log.appendLine("kglobalaccel", "daemon restart re-registration completed", .{});
    }

    fn register(self: *Client, keysym: u32, modifiers: u32) !void {
        self.is_registered = false;
        const qt_key = qtKey(keysym, modifiers);
        if (qt_key == 0) return error.KGlobalAccelUnsupportedKey;

        try callActionIdVoid(self.api, self.conn, "doRegister", true);
        const new_path = try getComponentPath(self.allocator, self.api, self.conn);
        var new_path_owned = true;
        errdefer if (new_path_owned) self.allocator.free(new_path);

        // daemon 재시작 뒤 component object path가 바뀔 수 있다. 새 path의 Pressed
        // match를 먼저 설치하고 난 뒤에만 setShortcutKeys로 shortcut을 활성화한다.
        self.removeComponentMatch();
        if (self.component_path) |old_path| self.allocator.free(old_path);
        self.component_path = null;
        if (self.component_match_rule) |old_rule| self.allocator.free(old_rule);
        self.component_match_rule = null;

        const new_rule = try std.fmt.allocPrintSentinel(
            self.allocator,
            "type='signal',interface='{s}',member='{s}',path='{s}'",
            .{ std.mem.span(component_interface), std.mem.span(component_pressed), new_path },
            0,
        );
        var new_rule_owned = true;
        errdefer if (new_rule_owned) self.allocator.free(new_rule);
        try self.addMatch(new_rule, "globalShortcutPressed");
        self.component_match_installed = true;
        self.component_path = new_path;
        self.component_match_rule = new_rule;
        new_path_owned = false;
        new_rule_owned = false;
        errdefer {
            self.removeComponentMatch();
            self.allocator.free(self.component_path.?);
            self.allocator.free(self.component_match_rule.?);
            self.component_path = null;
            self.component_match_rule = null;
        }

        var display_buf: [64]u8 = undefined;
        const display = hotkey_format.displayString(&display_buf, keysym, modifiers);
        claimKey(self.allocator, self.api, self.conn, qt_key, display) catch |err| {
            self.setInactiveNoAutostart();
            return err;
        };
        try setShortcutKeys(self.api, self.conn, qt_key);
        try verifyOwner(self.allocator, self.api, self.conn, qt_key);
        self.is_registered = true;
        log.appendLine("kglobalaccel", "direct hotkey registered component={s} action={s} qt_key=0x{x}", .{
            std.mem.span(component()),
            std.mem.span(action()),
            @as(u32, @bitCast(qt_key)),
        });
    }

    fn addMatch(self: *Client, rule: [:0]const u8, label: []const u8) !void {
        var err: dbus.DBusError = .{};
        self.api.error_init(&err);
        defer self.api.error_free(&err);
        self.api.add_match(self.conn, rule.ptr, &err);
        if (self.api.error_is_set(&err) != 0) {
            const message = if (err.message) |value| std.mem.span(value) else "(no message)";
            log.appendLine("kglobalaccel", "{s} add_match failed: {s}", .{ label, message });
            return error.KGlobalAccelAddMatchFailed;
        }
    }

    fn removeComponentMatch(self: *Client) void {
        if (!self.component_match_installed) return;
        const rule = self.component_match_rule orelse return;
        removeMatch(self.api, self.conn, rule);
        self.component_match_installed = false;
    }

    fn removeFilterAndMatches(self: *Client) void {
        self.removeComponentMatch();
        if (self.owner_match_installed) {
            removeMatch(self.api, self.conn, self.owner_match_rule);
            self.owner_match_installed = false;
        }
        if (self.filter_installed) {
            self.api.remove_filter(self.conn, signalFilter, self);
            self.filter_installed = false;
        }
    }

    fn setInactiveNoAutostart(self: *Client) void {
        callActionIdVoid(self.api, self.conn, "setInactive", false) catch |err| {
            log.appendLineVerbose("kglobalaccel", "setInactive skipped: {s}", .{@errorName(err)});
        };
        self.is_registered = false;
    }
};

fn removeMatch(api: *const dbus.Api, conn: *dbus.DBusConnection, rule: [:0]const u8) void {
    var err: dbus.DBusError = .{};
    api.error_init(&err);
    api.remove_match(conn, rule.ptr, &err);
    api.error_free(&err);
}

fn callActionIdVoid(api: *const dbus.Api, conn: *dbus.DBusConnection, method: [*:0]const u8, auto_start: bool) !void {
    const call = api.message_new_method_call(destination, root_path, root_interface, method) orelse return error.KGlobalAccelMessageAllocFailed;
    defer api.message_unref(call);
    api.message_set_auto_start(call, @intFromBool(auto_start));

    var iter: dbus.DBusMessageIter = .{};
    api.iter_init_append(call, &iter);
    const action_id = actionId();
    try appendStringArray(api, &iter, &action_id);
    try sendVoidCall(api, conn, call, method);
}

fn sendVoidCall(api: *const dbus.Api, conn: *dbus.DBusConnection, call: *dbus.DBusMessage, method: [*:0]const u8) !void {
    var err: dbus.DBusError = .{};
    api.error_init(&err);
    defer api.error_free(&err);
    const reply = api.send_with_reply_and_block(conn, call, method_call_timeout_ms, &err) orelse {
        if (api.error_is_set(&err) != 0) {
            const message = if (err.message) |value| std.mem.span(value) else "(no message)";
            log.appendLine("kglobalaccel", "{s} failed: {s}", .{ std.mem.span(method), message });
        }
        return error.KGlobalAccelMethodCallFailed;
    };
    api.message_unref(reply);
}

fn getComponentPath(allocator: std.mem.Allocator, api: *const dbus.Api, conn: *dbus.DBusConnection) ![]u8 {
    const call = api.message_new_method_call(destination, root_path, root_interface, "getComponent") orelse return error.KGlobalAccelMessageAllocFailed;
    defer api.message_unref(call);
    var iter: dbus.DBusMessageIter = .{};
    api.iter_init_append(call, &iter);
    var component_name: [*:0]const u8 = component();
    if (api.iter_append_basic(&iter, dbus.dbus_type_string, @ptrCast(&component_name)) == 0) return error.KGlobalAccelAppendFailed;

    var err: dbus.DBusError = .{};
    api.error_init(&err);
    defer api.error_free(&err);
    const reply = api.send_with_reply_and_block(conn, call, method_call_timeout_ms, &err) orelse return error.KGlobalAccelMethodCallFailed;
    defer api.message_unref(reply);
    var reply_iter: dbus.DBusMessageIter = .{};
    if (api.iter_init(reply, &reply_iter) == 0 or api.iter_get_arg_type(&reply_iter) != dbus.dbus_type_object_path) return error.KGlobalAccelReplyBadType;
    var path_c: ?[*:0]const u8 = null;
    api.iter_get_basic(&reply_iter, @ptrCast(&path_c));
    const path = if (path_c) |value| std.mem.span(value) else return error.KGlobalAccelReplyBadType;
    if (path.len == 0) return error.KGlobalAccelReplyBadType;
    return allocator.dupe(u8, path);
}

fn claimKey(allocator: std.mem.Allocator, api: *const dbus.Api, conn: *dbus.DBusConnection, qt_key: i32, key_display: []const u8) !void {
    var bus_view = dbus.SessionBus{ .api = api.*, .conn = conn, .unique_name = "" };
    var owner_opt = queryOwnerForKey(allocator, &bus_view, qt_key);
    defer if (owner_opt) |*owner| owner.deinit(allocator);
    const owner = owner_opt orelse return;
    if (std.mem.eql(u8, owner.component, std.mem.span(component())) and
        std.mem.eql(u8, owner.action, std.mem.span(action()))) return;

    var message_buf: [512]u8 = undefined;
    const confirm_message = std.fmt.bufPrint(&message_buf, messages.hotkey_takeover_format, .{
        key_display,
        owner.display_component,
        owner.display_action,
    }) catch return error.KGlobalAccelDialogFormatFailed;
    if (!dialog.showConfirm(messages.hotkey_takeover_title, confirm_message)) {
        log.appendLine("kglobalaccel", "takeover declined — owner={s}/{s} retained", .{ owner.component, owner.action });
        var declined_buf: [256]u8 = undefined;
        const declined_message = std.fmt.bufPrint(&declined_buf, messages.hotkey_takeover_declined_format, .{
            key_display,
            owner.display_component,
        }) catch messages.hotkey_takeover_declined_fallback_msg;
        dialog.showInfo(messages.hotkey_takeover_declined_title, declined_message);
        return error.KGlobalAccelTakeoverDeclined;
    }

    try takeoverConflict(allocator, &bus_view, &owner, qt_key);
}

fn setShortcutKeys(api: *const dbus.Api, conn: *dbus.DBusConnection, qt_key: i32) !void {
    const call = api.message_new_method_call(destination, root_path, root_interface, "setShortcutKeys") orelse return error.KGlobalAccelMessageAllocFailed;
    defer api.message_unref(call);
    var iter: dbus.DBusMessageIter = .{};
    api.iter_init_append(call, &iter);
    const action_id = actionId();
    try appendStringArray(api, &iter, &action_id);

    var sequences: dbus.DBusMessageIter = .{};
    if (api.iter_open_container(&iter, dbus.dbus_type_array, "(ai)", &sequences) == 0) return error.KGlobalAccelAppendFailed;
    var sequence: dbus.DBusMessageIter = .{};
    if (api.iter_open_container(&sequences, dbus.dbus_type_struct, null, &sequence) == 0) return error.KGlobalAccelAppendFailed;
    var keys: dbus.DBusMessageIter = .{};
    if (api.iter_open_container(&sequence, dbus.dbus_type_array, "i", &keys) == 0) return error.KGlobalAccelAppendFailed;
    var sequence_values = [_]i32{ qt_key, 0, 0, 0 };
    for (&sequence_values) |*key| {
        if (api.iter_append_basic(&keys, dbus.dbus_type_int32, @ptrCast(key)) == 0) return error.KGlobalAccelAppendFailed;
    }
    if (api.iter_close_container(&sequence, &keys) == 0) return error.KGlobalAccelAppendFailed;
    if (api.iter_close_container(&sequences, &sequence) == 0) return error.KGlobalAccelAppendFailed;
    if (api.iter_close_container(&iter, &sequences) == 0) return error.KGlobalAccelAppendFailed;
    var flags: u32 = set_shortcut_flags;
    if (api.iter_append_basic(&iter, dbus.dbus_type_uint32, @ptrCast(&flags)) == 0) return error.KGlobalAccelAppendFailed;

    var err: dbus.DBusError = .{};
    api.error_init(&err);
    defer api.error_free(&err);
    const reply = api.send_with_reply_and_block(conn, call, method_call_timeout_ms, &err) orelse {
        if (api.error_is_set(&err) != 0) {
            const message = if (err.message) |value| std.mem.span(value) else "(no message)";
            log.appendLine("kglobalaccel", "setShortcutKeys failed: {s}", .{message});
        }
        return error.KGlobalAccelMethodCallFailed;
    };
    defer api.message_unref(reply);
    if (!replyHasSingleKey(api, reply, qt_key)) return error.KGlobalAccelReturnedShortcutMismatch;
}

fn replyHasSingleKey(api: *const dbus.Api, reply: *dbus.DBusMessage, expected: i32) bool {
    var outer: dbus.DBusMessageIter = .{};
    if (api.iter_init(reply, &outer) == 0 or api.iter_get_arg_type(&outer) != dbus.dbus_type_array) return false;
    var entries: dbus.DBusMessageIter = .{};
    api.iter_recurse(&outer, &entries);
    if (api.iter_get_arg_type(&entries) != dbus.dbus_type_struct) return false;
    var sequence: dbus.DBusMessageIter = .{};
    api.iter_recurse(&entries, &sequence);
    if (api.iter_get_arg_type(&sequence) != dbus.dbus_type_array) return false;
    var keys: dbus.DBusMessageIter = .{};
    api.iter_recurse(&sequence, &keys);
    var actual: [qkeysequence_slots]i32 = @splat(0);
    for (&actual, 0..) |*value, index| {
        if (api.iter_get_arg_type(&keys) != dbus.dbus_type_int32) return false;
        api.iter_get_basic(&keys, @ptrCast(value));
        const has_next = api.iter_next(&keys) != 0;
        if (index + 1 < actual.len and !has_next) return false;
        if (index + 1 == actual.len and has_next) return false;
    }
    if (!isExactSingleKey(&actual, expected)) return false;
    return api.iter_next(&entries) == 0;
}

fn verifyOwner(allocator: std.mem.Allocator, api: *const dbus.Api, conn: *dbus.DBusConnection, qt_key: i32) !void {
    var bus_view = dbus.SessionBus{ .api = api.*, .conn = conn, .unique_name = "" };
    var owner = queryOwnerForKey(allocator, &bus_view, qt_key) orelse return error.KGlobalAccelOwnerVerificationFailed;
    defer owner.deinit(allocator);
    if (!std.mem.eql(u8, owner.component, std.mem.span(component())) or
        !std.mem.eql(u8, owner.action, std.mem.span(action()))) return error.KGlobalAccelOwnerVerificationFailed;
}

fn signalFilter(conn: *dbus.DBusConnection, message: *dbus.DBusMessage, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = conn;
    const self: *Client = @ptrCast(@alignCast(user_data.?));
    if (self.api.message_is_signal(message, component_interface, component_pressed) != 0) {
        const path_c = self.api.message_get_path(message) orelse return dbus.dbus_handler_result_not_yet_handled;
        const expected_path = self.component_path orelse return dbus.dbus_handler_result_not_yet_handled;
        if (!std.mem.eql(u8, std.mem.span(path_c), expected_path)) return dbus.dbus_handler_result_not_yet_handled;

        var iter: dbus.DBusMessageIter = .{};
        if (self.api.iter_init(message, &iter) == 0 or self.api.iter_get_arg_type(&iter) != dbus.dbus_type_string) return dbus.dbus_handler_result_handled;
        var component_c: ?[*:0]const u8 = null;
        self.api.iter_get_basic(&iter, @ptrCast(&component_c));
        _ = self.api.iter_next(&iter);
        if (self.api.iter_get_arg_type(&iter) != dbus.dbus_type_string) return dbus.dbus_handler_result_handled;
        var action_c: ?[*:0]const u8 = null;
        self.api.iter_get_basic(&iter, @ptrCast(&action_c));
        const component_name = if (component_c) |value| std.mem.span(value) else "";
        const action_name = if (action_c) |value| std.mem.span(value) else "";
        if (!std.mem.eql(u8, component_name, std.mem.span(component())) or
            !std.mem.eql(u8, action_name, std.mem.span(action()))) return dbus.dbus_handler_result_handled;
        _ = self.api.iter_next(&iter);
        var timestamp: i64 = 0;
        if (self.api.iter_get_arg_type(&iter) == dbus.dbus_type_int64) self.api.iter_get_basic(&iter, @ptrCast(&timestamp));
        self.callback(self.user_data, timestamp);
        return dbus.dbus_handler_result_handled;
    }

    if (self.api.message_is_signal(message, dbus_interface, dbus_name_owner_changed) != 0) {
        var iter: dbus.DBusMessageIter = .{};
        if (self.api.iter_init(message, &iter) == 0) return dbus.dbus_handler_result_not_yet_handled;
        var name_c: ?[*:0]const u8 = null;
        if (self.api.iter_get_arg_type(&iter) != dbus.dbus_type_string) return dbus.dbus_handler_result_not_yet_handled;
        self.api.iter_get_basic(&iter, @ptrCast(&name_c));
        if (!std.mem.eql(u8, if (name_c) |value| std.mem.span(value) else "", std.mem.span(destination))) return dbus.dbus_handler_result_not_yet_handled;
        _ = self.api.iter_next(&iter); // old owner
        _ = self.api.iter_next(&iter); // new owner
        if (self.api.iter_get_arg_type(&iter) != dbus.dbus_type_string) return dbus.dbus_handler_result_handled;
        var new_owner_c: ?[*:0]const u8 = null;
        self.api.iter_get_basic(&iter, @ptrCast(&new_owner_c));
        const new_owner = if (new_owner_c) |value| std.mem.span(value) else "";
        self.is_registered = false;
        if (new_owner.len != 0) self.owner_restart_pending = true;
        return dbus.dbus_handler_result_handled;
    }
    return dbus.dbus_handler_result_not_yet_handled;
}

pub fn tryAutoApply(
    allocator: std.mem.Allocator,
    bus: *dbus.SessionBus,
    keysym: u32,
    modifiers: u32,
    preferred_display: []const u8,
    actual: []const u8,
) void {
    const qt_key = qtKey(keysym, modifiers);
    var owner_opt = queryOwnerForKey(allocator, bus, qt_key);
    defer if (owner_opt) |*owner| owner.deinit(allocator);

    const ours = if (owner_opt) |owner|
        std.mem.eql(u8, owner.component, std.mem.span(component())) and
            std.mem.eql(u8, owner.action, std.mem.span(action()))
    else
        false;

    if (owner_opt) |owner| {
        if (!ours) {
            log.appendLine("kglobalaccel", "secondary conflict detected — owner={s}/{s} (display: {s} / {s}) qt_key=0x{x}", .{
                owner.component,
                owner.action,
                owner.display_component,
                owner.display_action,
                @as(u32, @bitCast(qt_key)),
            });
            var message_buf: [512]u8 = undefined;
            const confirm_message = std.fmt.bufPrint(&message_buf, messages.hotkey_takeover_format, .{
                preferred_display,
                owner.display_component,
                owner.display_action,
            }) catch {
                showMismatchPersistsDialog(allocator, preferred_display, actual);
                return;
            };
            if (!dialog.showConfirm(messages.hotkey_takeover_title, confirm_message)) {
                log.appendLine("kglobalaccel", "takeover declined (Cancel) — existing binding retained", .{});
                var declined_buf: [256]u8 = undefined;
                const declined_message = std.fmt.bufPrint(&declined_buf, messages.hotkey_takeover_declined_format, .{
                    preferred_display,
                    owner.display_component,
                }) catch {
                    dialog.showInfo(messages.hotkey_takeover_declined_title, messages.hotkey_takeover_declined_fallback_msg);
                    return;
                };
                dialog.showInfo(messages.hotkey_takeover_declined_title, declined_message);
                return;
            }
            takeoverConflict(allocator, bus, &owner, qt_key) catch |err| {
                log.appendLine("kglobalaccel", "takeover D-Bus call failed ({s}) — fallback dialog", .{@errorName(err)});
                showMismatchPersistsDialog(allocator, preferred_display, actual);
                return;
            };
        }
    }

    setToggleShortcut(bus, qt_key) catch |err| {
        log.appendLine("kglobalaccel", "KDE setForeignShortcut(tildaz) failed ({s}) — fallback dialog", .{@errorName(err)});
        showMismatchPersistsDialog(allocator, preferred_display, actual);
        return;
    };
    if (queryToggleShortcut(bus)) |stored| {
        if (stored != qt_key) {
            log.appendLine("kglobalaccel", "KDE post-set verification failed — stored=0x{x} expected=0x{x}", .{
                @as(u32, @bitCast(stored)),
                @as(u32, @bitCast(qt_key)),
            });
            showMismatchPersistsDialog(allocator, preferred_display, actual);
            return;
        }
    }
    log.appendLine("kglobalaccel", "hotkey updated (KDE D-Bus): \"{s}\" → {s}", .{ actual, preferred_display });
    showHotkeyUpdatedDialog(allocator, actual, preferred_display);
}

pub fn isKdeDesktopValue(value: []const u8) bool {
    var tokens = std.mem.tokenizeScalar(u8, value, ':');
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "KDE")) return true;
    }
    return false;
}

pub fn isCurrentDesktop() bool {
    const value = std.posix.getenv("XDG_CURRENT_DESKTOP") orelse return false;
    return isKdeDesktopValue(value);
}

pub fn showHotkeyUpdatedDialog(allocator: std.mem.Allocator, was: []const u8, now: []const u8) void {
    var buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, messages.hotkey_updated_format, .{ was, now }) catch {
        dialog.showInfo(messages.hotkey_updated_title, messages.hotkey_updated_fallback_msg);
        return;
    };
    dialog.showInfo(messages.hotkey_updated_title, message);
    _ = allocator;
}

pub fn showMismatchPersistsDialog(allocator: std.mem.Allocator, preferred: []const u8, actual: []const u8) void {
    var buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, messages.hotkey_mismatch_persists_format, .{ preferred, actual }) catch {
        dialog.showInfo(messages.hotkey_mismatch_persists_title, messages.hotkey_mismatch_persists_fallback_msg);
        return;
    };
    dialog.showInfo(messages.hotkey_mismatch_persists_title, message);
    _ = allocator;
}

test "numbered KDE component identity is parsed strictly" {
    try std.testing.expectEqual(@as(?u32, 0), numberedComponentIndex("tildaz.instance0"));
    try std.testing.expectEqual(@as(?u32, 42), numberedComponentIndex("tildaz.instance42"));
    try std.testing.expect(numberedComponentIndex("tildaz.instance") == null);
    try std.testing.expect(numberedComponentIndex("tildaz.instance01") == null);
    try std.testing.expect(numberedComponentIndex("tildaz.instance2.extra") == null);
    try std.testing.expect(numberedComponentIndex("other.instance2") == null);
}

test "KDE desktop token is exact and case insensitive" {
    try std.testing.expect(isKdeDesktopValue("KDE"));
    try std.testing.expect(isKdeDesktopValue("KDE:Plasma"));
    try std.testing.expect(isKdeDesktopValue("kde"));
    try std.testing.expect(!isKdeDesktopValue("KDESomething"));
    try std.testing.expect(!isKdeDesktopValue("Cinnamon"));
}

test "XKB to Qt key conversion keeps function offsets and modifiers" {
    try std.testing.expectEqual(@as(i32, 0x01000030), qtKey(0xffbe, 0));
    try std.testing.expectEqual(@as(i32, 0x01000035), qtKey(0xffc3, 0));
    try std.testing.expectEqual(@as(i32, 0x01000036), qtKey(0xffc4, 0));
    try std.testing.expectEqual(@as(i32, 0x0100003b), qtKey(0xffc9, 0));
    try std.testing.expectEqual(@as(i32, 0x16000054), qtKey('t', 0x2 | 0x4 | 0x8));
    try std.testing.expectEqual(@as(i32, 0x20), qtKey(' ', 0));
    try std.testing.expectEqual(@as(i32, 0x60), qtKey('`', 0));
}

test "conflict takeover removes only an exact one-chord key sequence" {
    const target: i32 = 0x01000030;
    try std.testing.expect(isExactSingleKey(&.{ target, 0, 0, 0 }, target));
    try std.testing.expect(!isExactSingleKey(&.{ target, 0x01000031, 0, 0 }, target));
    try std.testing.expect(!isExactSingleKey(&.{ 0x01000031, 0, 0, 0 }, target));
    try std.testing.expect(!isExactSingleKey(&.{target}, target));
    try std.testing.expect(!isExactSingleKey(&.{}, target));
}
