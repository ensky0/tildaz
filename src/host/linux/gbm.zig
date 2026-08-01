//! Runtime libgbm wrapper — GPU 가 쓸 수 있는 buffer (dma-buf) 할당.
//!
//! `libfreetype` / `libxkbcommon` 과 같은 dlopen 패턴이다. Linux 백엔드는 네이티브
//! 의존을 전부 runtime dlopen 으로 두고 glibc 외에 하드 링크를 만들지 않는다
//! (`ARCHITECTURE.md`) — libgbm 도 예외가 아니라서, 없으면 software `wl_shm`
//! 경로로 조용히 떨어진다.
//!
//! #277 — Linux 를 software renderer 에서 GPU 로 옮기는 작업의 할당 계층이다.
//! 우리 Wayland client 는 `libwayland-client` 를 쓰지 않는 raw wire client 라
//! 표준 EGL 경로 (`wl_egl_window`) 를 쓸 수 없다. 대신 여기서 dma-buf 를 할당해
//! `zwp_linux_dmabuf_v1` 로 compositor 에 넘긴다.

const std = @import("std");
const posix = std.posix;

/// DRM fourcc. `wl_shm` 의 format enum (`shm_format_argb8888` = 0) 과 값 체계가
/// **다르다** — 같은 의미의 픽셀 포맷이지만 dmabuf 프로토콜은 fourcc 를 쓴다.
pub const FORMAT_ARGB8888: u32 = fourcc('A', 'R', '2', '4');

pub const MOD_LINEAR: u64 = 0;
pub const MOD_INVALID: u64 = 0x00ffffffffffffff;

fn fourcc(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c) << 16) | (@as(u32, d) << 24);
}

// /usr/include/gbm.h — enum gbm_bo_flags / gbm_bo_transfer_flags.
//
// `GBM_BO_USE_WRITE` 는 쓰지 않는다. 헤더 계약이 *"`gbm_bo_write` 용이고
// `GBM_BO_USE_CURSOR` 와의 조합만 보장, 다른 조합은 동작하지 않을 수 있다"* 이고,
// 실측에서도 render node 할당이 NULL 로 실패했다 (#277). CPU 접근은 `map` 으로 한다.
const USE_RENDERING: u32 = 1 << 2;
const USE_LINEAR: u32 = 1 << 4;
const TRANSFER_WRITE: u32 = 1 << 1;

const GbmCreateDevice = *const fn (fd: c_int) callconv(.c) ?*anyopaque;
const GbmDeviceDestroy = *const fn (dev: ?*anyopaque) callconv(.c) void;
const GbmBoCreateWithModifiers = *const fn (dev: ?*anyopaque, w: u32, h: u32, format: u32, mods: [*]const u64, count: c_uint) callconv(.c) ?*anyopaque;
const GbmBoDestroy = *const fn (bo: ?*anyopaque) callconv(.c) void;
const GbmBoMap = *const fn (bo: ?*anyopaque, x: u32, y: u32, w: u32, h: u32, flags: u32, stride: *u32, map_data: *?*anyopaque) callconv(.c) ?*anyopaque;
const GbmBoUnmap = *const fn (bo: ?*anyopaque, map_data: ?*anyopaque) callconv(.c) void;
const GbmBoGetFd = *const fn (bo: ?*anyopaque) callconv(.c) c_int;
const GbmBoGetStride = *const fn (bo: ?*anyopaque) callconv(.c) u32;
const GbmBoGetOffset = *const fn (bo: ?*anyopaque, plane: c_int) callconv(.c) u32;
const GbmBoGetModifier = *const fn (bo: ?*anyopaque) callconv(.c) u64;
const GbmBoGetPlaneCount = *const fn (bo: ?*anyopaque) callconv(.c) c_int;

/// 할당된 dma-buf 하나. 기하 정보는 할당 직후 한 번 조회해 보관한다 — 매 frame
/// 재조회할 값이 아니고, `zwp_linux_dmabuf_v1.params.add` 가 그대로 요구하는 값이다.
pub const Bo = struct {
    ptr: *anyopaque,
    width: u32,
    height: u32,
    stride: u32,
    offset: u32,
    modifier: u64,
};

/// `map` 결과. `data` 에 그리고 반드시 `unmap` 해야 compositor 가 읽기 전에
/// 쓰기가 보이는 것이 보장된다.
pub const Mapping = struct {
    data: [*]u8,
    stride: u32,
    opaque_handle: ?*anyopaque,
};

pub const Api = struct {
    handle: *anyopaque,
    create_device: GbmCreateDevice,
    device_destroy: GbmDeviceDestroy,
    bo_create_with_modifiers: GbmBoCreateWithModifiers,
    bo_destroy: GbmBoDestroy,
    bo_map: GbmBoMap,
    bo_unmap: GbmBoUnmap,
    bo_get_fd: GbmBoGetFd,
    bo_get_stride: GbmBoGetStride,
    bo_get_offset: GbmBoGetOffset,
    bo_get_modifier: GbmBoGetModifier,
    bo_get_plane_count: GbmBoGetPlaneCount,

    pub fn load() !Api {
        const handle = std.c.dlopen("libgbm.so.1", .{ .LAZY = true }) orelse return error.GbmLibraryMissing;
        errdefer _ = std.c.dlclose(handle);

        return .{
            .handle = handle,
            .create_device = lookup(handle, GbmCreateDevice, "gbm_create_device") orelse return error.GbmSymbolMissing,
            .device_destroy = lookup(handle, GbmDeviceDestroy, "gbm_device_destroy") orelse return error.GbmSymbolMissing,
            .bo_create_with_modifiers = lookup(handle, GbmBoCreateWithModifiers, "gbm_bo_create_with_modifiers") orelse return error.GbmSymbolMissing,
            .bo_destroy = lookup(handle, GbmBoDestroy, "gbm_bo_destroy") orelse return error.GbmSymbolMissing,
            .bo_map = lookup(handle, GbmBoMap, "gbm_bo_map") orelse return error.GbmSymbolMissing,
            .bo_unmap = lookup(handle, GbmBoUnmap, "gbm_bo_unmap") orelse return error.GbmSymbolMissing,
            .bo_get_fd = lookup(handle, GbmBoGetFd, "gbm_bo_get_fd") orelse return error.GbmSymbolMissing,
            .bo_get_stride = lookup(handle, GbmBoGetStride, "gbm_bo_get_stride") orelse return error.GbmSymbolMissing,
            .bo_get_offset = lookup(handle, GbmBoGetOffset, "gbm_bo_get_offset") orelse return error.GbmSymbolMissing,
            .bo_get_modifier = lookup(handle, GbmBoGetModifier, "gbm_bo_get_modifier") orelse return error.GbmSymbolMissing,
            .bo_get_plane_count = lookup(handle, GbmBoGetPlaneCount, "gbm_bo_get_plane_count") orelse return error.GbmSymbolMissing,
        };
    }

    pub fn deinit(self: *Api) void {
        _ = std.c.dlclose(self.handle);
    }

    pub fn createDevice(self: *const Api, fd: posix.fd_t) ?*anyopaque {
        return self.create_device(fd);
    }

    pub fn destroyDevice(self: *const Api, dev: ?*anyopaque) void {
        self.device_destroy(dev);
    }

    /// LINEAR modifier 로 ARGB8888 buffer 를 할당한다.
    ///
    /// `gbm_bo_create` 가 아니라 `gbm_bo_create_with_modifiers` 를 쓰는 이유:
    /// 전자는 `LINEAR` 플래그로 만들어도 `gbm_bo_get_modifier` 가
    /// `DRM_FORMAT_MOD_INVALID` 를 돌려주는데, 그 값을 프로토콜에 넘길 수 없다
    /// (#277 실측). 후자는 요청한 modifier 를 정확히 돌려준다.
    ///
    /// 다중 plane buffer 는 지원하지 않는다 — 우리 포맷은 항상 1 plane 이고,
    /// 그렇지 않게 나오면 이 경로를 쓰지 않는 편이 안전하다.
    pub fn createLinear(self: *const Api, dev: ?*anyopaque, width: u32, height: u32) ?Bo {
        const mods = [_]u64{MOD_LINEAR};
        const ptr = self.bo_create_with_modifiers(dev, width, height, FORMAT_ARGB8888, &mods, mods.len) orelse return null;
        const modifier = self.bo_get_modifier(ptr);
        if (modifier != MOD_LINEAR or self.bo_get_plane_count(ptr) != 1) {
            self.bo_destroy(ptr);
            return null;
        }
        return .{
            .ptr = ptr,
            .width = width,
            .height = height,
            .stride = self.bo_get_stride(ptr),
            .offset = self.bo_get_offset(ptr, 0),
            .modifier = modifier,
        };
    }

    pub fn destroyBo(self: *const Api, bo: Bo) void {
        self.bo_destroy(bo.ptr);
    }

    /// compositor 에 넘길 dma-buf fd. 호출할 때마다 새 fd 를 돌려주므로 (dup),
    /// 송신 후 호출자가 닫는다.
    pub fn exportFd(self: *const Api, bo: Bo) ?posix.fd_t {
        const fd = self.bo_get_fd(bo.ptr);
        if (fd < 0) return null;
        return fd;
    }

    pub fn map(self: *const Api, bo: Bo) ?Mapping {
        var stride: u32 = 0;
        var handle: ?*anyopaque = null;
        const data = self.bo_map(bo.ptr, 0, 0, bo.width, bo.height, TRANSFER_WRITE, &stride, &handle) orelse return null;
        return .{ .data = @ptrCast(data), .stride = stride, .opaque_handle = handle };
    }

    pub fn unmap(self: *const Api, bo: Bo, mapping: Mapping) void {
        self.bo_unmap(bo.ptr, mapping.opaque_handle);
    }
};

fn lookup(handle: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
    const symbol = std.c.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(symbol));
}

/// DRM render node 를 연다. `renderD128` 부터 순서대로 시도한다 — 다중 GPU
/// 환경에서 첫 번째가 우리가 쓸 수 있는 노드가 아닐 수 있다.
///
/// render node 는 KMS 권한 없이 열 수 있는 GPU 접근 경로다 (`card0` 와 달리
/// seat 소유권이 필요 없다). 없거나 권한이 없으면 null — 호출자는 software
/// 경로로 떨어진다.
pub fn openRenderNode() ?posix.fd_t {
    var index: u8 = 128;
    while (index < 136) : (index += 1) {
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/dev/dri/renderD{d}", .{index}) catch continue;
        const fd = posix.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch continue;
        return fd;
    }
    return null;
}

test "fourcc 는 DRM 규약대로 리틀엔디안 바이트 순서다" {
    // 'A','R','2','4' → 0x34325241. drm_fourcc.h 의 ARGB8888 값과 같아야 한다.
    try std.testing.expectEqual(@as(u32, 0x34325241), FORMAT_ARGB8888);
}
