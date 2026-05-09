//! Renderer dispatch — 호출처가 platform 별 그래픽스 API (D3D11 / Metal) 를
//! 직접 다루지 않게.
//!
//! 현재 상태: Windows 의 `D3d11Renderer` 만 통합된 인터페이스 (init / deinit /
//! invalidate / rebuildFont / resize / renderTabBar / renderTerminal) 를 노출한다.
//! macOS 의 `MetalRenderer` 는 단일 `renderFrame` 만 노출하고 host 가 직접
//! 호출 — 두 path 의 인터페이스 통일은 별도 이슈에서 진행. 그래서 `renderer.zig`
//! 의 `RendererBackend` 는 Windows 전용이고, macOS host 는 `renderer/macos.zig`
//! 의 MetalRenderer 를 직접 import.

const std = @import("std");
const builtin = @import("builtin");
const ghostty = @import("ghostty-vt");

const D3d11Renderer = if (builtin.os.tag == .windows)
    @import("renderer/windows.zig").D3d11Renderer
else
    struct {};

pub const RendererBackend = switch (builtin.os.tag) {
    .windows => D3d11Renderer,
    else => UnsupportedRendererBackend,
};

pub const RenameState = RendererBackend.RenameState;

const UnsupportedRendererBackend = struct {
    pub const RenameState = struct {
        tab_index: usize,
        text: [*]const u8,
        text_len: usize,
        cursor: usize,
    };

    pub fn init(
        _: std.mem.Allocator,
        _: ?*anyopaque,
        _: []const [*:0]const u16,
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
        _: []const [*:0]const u16,
        _: c_int,
        _: u32,
        _: u32,
    ) !void {
        return error.UnsupportedRendererBackend;
    }

    pub fn renderTabBar(
        _: *UnsupportedRendererBackend,
        _: []const []const u8,
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
