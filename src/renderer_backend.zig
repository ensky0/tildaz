const std = @import("std");
const builtin = @import("builtin");
const ghostty = @import("ghostty-vt");

const D3d11Renderer = if (builtin.os.tag == .windows)
    @import("d3d11_renderer.zig").D3d11Renderer
else
    struct {};

pub const RendererBackend = switch (builtin.os.tag) {
    .windows => D3d11Renderer,
    else => UnsupportedRendererBackend,
};

pub const TabTitle = RendererBackend.TabTitle;
pub const RenameState = RendererBackend.RenameState;

const UnsupportedRendererBackend = struct {
    pub const TabTitle = struct { ptr: [*]const u8, len: usize };
    pub const RenameState = struct {
        tab_index: usize,
        text: [*]const u8,
        text_len: usize,
        cursor: usize,
    };

    pub fn init(
        _: std.mem.Allocator,
        _: ?*anyopaque,
        _: [*:0]const u16,
        _: c_int,
        _: u32,
        _: u32,
        _: ?[3]u8,
    ) !UnsupportedRendererBackend {
        return error.UnsupportedRendererBackend;
    }

    pub fn deinit(_: *UnsupportedRendererBackend) void {}

    pub fn invalidate(_: *UnsupportedRendererBackend) void {}

    pub fn resize(_: *UnsupportedRendererBackend, _: u32, _: u32) void {}

    pub fn rebuildFont(
        _: *UnsupportedRendererBackend,
        _: ?*anyopaque,
        _: [*:0]const u16,
        _: c_int,
        _: u32,
        _: u32,
    ) !void {
        return error.UnsupportedRendererBackend;
    }

    pub fn renderTabBar(
        _: *UnsupportedRendererBackend,
        _: []const UnsupportedRendererBackend.TabTitle,
        _: usize,
        _: c_int,
        _: c_int,
        _: c_int,
        _: c_int,
        _: c_int,
        _: c_int,
        _: ?usize,
        _: c_int,
        _: ?UnsupportedRendererBackend.RenameState,
    ) void {}

    pub fn renderTerminal(
        _: *UnsupportedRendererBackend,
        _: *ghostty.Terminal,
        _: c_int,
        _: c_int,
        _: c_int,
        _: c_int,
        _: c_int,
        _: c_int,
        _: c_int,
        _: c_int,
    ) void {}
};
