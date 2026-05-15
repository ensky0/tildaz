//! Runtime libxkbcommon wrapper for the direct Wayland backend.
//!
//! Wayland delivers keyboard keymaps as XKB text. Loading libxkbcommon at
//! runtime keeps macOS-hosted Linux cross builds from needing Linux headers or a
//! Linux linker setup, while still using the standard Wayland keyboard path on
//! real Linux desktops.

const std = @import("std");
const log = @import("../../log.zig");

const xkb_context = opaque {};
const xkb_keymap = opaque {};
const xkb_state = opaque {};

const XKB_CONTEXT_NO_FLAGS: c_uint = 0;
const XKB_KEYMAP_FORMAT_TEXT_V1: c_uint = 1;
const XKB_KEYMAP_COMPILE_NO_FLAGS: c_uint = 0;

const XkbContextNew = *const fn (flags: c_uint) callconv(.c) ?*xkb_context;
const XkbContextUnref = *const fn (context: ?*xkb_context) callconv(.c) void;
const XkbKeymapNewFromString = *const fn (
    context: *xkb_context,
    string: [*:0]const u8,
    format: c_uint,
    flags: c_uint,
) callconv(.c) ?*xkb_keymap;
const XkbKeymapUnref = *const fn (keymap: ?*xkb_keymap) callconv(.c) void;
const XkbStateNew = *const fn (keymap: *xkb_keymap) callconv(.c) ?*xkb_state;
const XkbStateUnref = *const fn (state: ?*xkb_state) callconv(.c) void;
const XkbStateUpdateMask = *const fn (
    state: *xkb_state,
    depressed_mods: c_uint,
    latched_mods: c_uint,
    locked_mods: c_uint,
    depressed_layout: c_uint,
    latched_layout: c_uint,
    locked_layout: c_uint,
) callconv(.c) c_uint;
const XkbStateKeyGetUtf8 = *const fn (
    state: *xkb_state,
    key: c_uint,
    buffer: [*]u8,
    size: usize,
) callconv(.c) c_int;
const XkbStateKeyGetOneSym = *const fn (state: *xkb_state, key: c_uint) callconv(.c) c_uint;
const XkbStateModNameIsActive = *const fn (
    state: *xkb_state,
    name: [*:0]const u8,
    component: c_uint,
) callconv(.c) c_int;

// libxkbcommon `enum xkb_state_component`. MODS_EFFECTIVE = (1 << 3).
// 처음에 (1 << 7) = LAYOUT_EFFECTIVE 로 잘못 적어 mod_name_is_active 가
// modifier component 를 안 보고 항상 0 반환 → 단축키 분기 fail (1차 시연 발견).
const XKB_STATE_MODS_EFFECTIVE: c_uint = 0x0008;

const Api = struct {
    handle: *anyopaque,
    context_new: XkbContextNew,
    context_unref: XkbContextUnref,
    keymap_new_from_string: XkbKeymapNewFromString,
    keymap_unref: XkbKeymapUnref,
    state_new: XkbStateNew,
    state_unref: XkbStateUnref,
    state_update_mask: XkbStateUpdateMask,
    state_key_get_utf8: XkbStateKeyGetUtf8,
    state_key_get_one_sym: XkbStateKeyGetOneSym,
    state_mod_name_is_active: XkbStateModNameIsActive,

    fn load() !Api {
        const handle = std.c.dlopen("libxkbcommon.so.0", .{ .LAZY = true }) orelse return error.XkbLibraryMissing;
        errdefer _ = std.c.dlclose(handle);

        return .{
            .handle = handle,
            .context_new = lookup(handle, XkbContextNew, "xkb_context_new") orelse return error.XkbSymbolMissing,
            .context_unref = lookup(handle, XkbContextUnref, "xkb_context_unref") orelse return error.XkbSymbolMissing,
            .keymap_new_from_string = lookup(handle, XkbKeymapNewFromString, "xkb_keymap_new_from_string") orelse return error.XkbSymbolMissing,
            .keymap_unref = lookup(handle, XkbKeymapUnref, "xkb_keymap_unref") orelse return error.XkbSymbolMissing,
            .state_new = lookup(handle, XkbStateNew, "xkb_state_new") orelse return error.XkbSymbolMissing,
            .state_unref = lookup(handle, XkbStateUnref, "xkb_state_unref") orelse return error.XkbSymbolMissing,
            .state_update_mask = lookup(handle, XkbStateUpdateMask, "xkb_state_update_mask") orelse return error.XkbSymbolMissing,
            .state_key_get_utf8 = lookup(handle, XkbStateKeyGetUtf8, "xkb_state_key_get_utf8") orelse return error.XkbSymbolMissing,
            .state_key_get_one_sym = lookup(handle, XkbStateKeyGetOneSym, "xkb_state_key_get_one_sym") orelse return error.XkbSymbolMissing,
            .state_mod_name_is_active = lookup(handle, XkbStateModNameIsActive, "xkb_state_mod_name_is_active") orelse return error.XkbSymbolMissing,
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

pub const Keyboard = struct {
    api: ?Api = null,
    context: ?*xkb_context = null,
    keymap: ?*xkb_keymap = null,
    state: ?*xkb_state = null,

    pub fn deinit(self: *Keyboard) void {
        self.clearKeymap();
        if (self.api) |*api| {
            if (self.context) |context| {
                api.context_unref(context);
                self.context = null;
            }
            api.deinit();
            self.api = null;
        }
    }

    pub fn setKeymap(self: *Keyboard, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.ensureApi();
        const api = &self.api.?;

        if (self.context == null) {
            self.context = api.context_new(XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContextCreateFailed;
        }

        const keymap_text = try allocator.dupeZ(u8, text);
        defer allocator.free(keymap_text);

        const keymap = api.keymap_new_from_string(
            self.context.?,
            keymap_text.ptr,
            XKB_KEYMAP_FORMAT_TEXT_V1,
            XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.XkbKeymapCreateFailed;
        errdefer api.keymap_unref(keymap);

        const state = api.state_new(keymap) orelse return error.XkbStateCreateFailed;
        errdefer api.state_unref(state);

        self.clearKeymap();
        self.keymap = keymap;
        self.state = state;
    }

    pub fn updateMask(
        self: *Keyboard,
        depressed_mods: u32,
        latched_mods: u32,
        locked_mods: u32,
        group: u32,
    ) void {
        const api = if (self.api) |*api| api else return;
        const state = self.state orelse return;
        _ = api.state_update_mask(
            state,
            @intCast(depressed_mods),
            @intCast(latched_mods),
            @intCast(locked_mods),
            0,
            0,
            @intCast(group),
        );
    }

    pub fn oneSym(self: *Keyboard, key: u32) ?u32 {
        const api = if (self.api) |*api| api else return null;
        const state = self.state orelse return null;
        return api.state_key_get_one_sym(state, @intCast(key));
    }

    pub fn utf8(self: *Keyboard, key: u32, buf: []u8) []const u8 {
        if (buf.len == 0) return "";
        const api = if (self.api) |*api| api else return "";
        const state = self.state orelse return "";
        const n = api.state_key_get_utf8(state, @intCast(key), buf.ptr, buf.len);
        if (n <= 0) return "";
        const wanted: usize = @intCast(n);
        if (wanted >= buf.len) return "";
        return buf[0..wanted];
    }

    pub fn ctrlActive(self: *Keyboard) bool {
        return self.modActive("Control");
    }

    pub fn shiftActive(self: *Keyboard) bool {
        return self.modActive("Shift");
    }

    fn modActive(self: *Keyboard, comptime name: [:0]const u8) bool {
        const api = if (self.api) |*api| api else return false;
        const state = self.state orelse return false;
        return api.state_mod_name_is_active(state, name.ptr, XKB_STATE_MODS_EFFECTIVE) > 0;
    }

    fn ensureApi(self: *Keyboard) !void {
        if (self.api != null) return;
        self.api = Api.load() catch |err| {
            log.appendLine("wayland", "libxkbcommon load failed: {s}", .{@errorName(err)});
            return error.XkbUnavailable;
        };
    }

    fn clearKeymap(self: *Keyboard) void {
        if (self.api) |*api| {
            if (self.state) |state| {
                api.state_unref(state);
                self.state = null;
            }
            if (self.keymap) |keymap| {
                api.keymap_unref(keymap);
                self.keymap = null;
            }
        }
    }
};
