//! Linux GPU 렌더 경로 진단 도구 ([#277](https://github.com/ensky0/tildaz/issues/277)).
//!
//! tildaz 본체 빌드에 들어가지 않는 독립 측정 도구다 (`dist/macos/color-capture.m`
//! 와 같은 위치의 물건). 어떤 배포판 / 데스크톱 / GPU 드라이버에서든 **GPU 경로가
//! 성립하는지**를 한 번에 판정해서, 결과를 이슈에 그대로 붙일 수 있는 형태로 출력한다.
//!
//! 검사하는 것 — tildaz 가 실행 시점에 확인할 항목과 같은 순서다:
//!   1. `libgbm` / `libEGL` / `libGLESv2` 를 dlopen 할 수 있는가
//!   2. DRM render node 를 열고 GBM device 를 만들 수 있는가
//!   3. compositor 가 `zwp_linux_dmabuf_v1` 을 노출하는가 (버전 / ARGB8888 modifier)
//!   4. GBM 으로 dma-buf 를 할당할 수 있는가 (LINEAR / tiled)
//!   5. 그 dma-buf 로 `wl_buffer` 를 만들 수 있는가 (`created` vs `failed`)
//!   6. CPU 로 그린 dma-buf 가 화면에 표시되는가
//!   7. `EGL_EXT_image_dma_buf_import` → FBO 로 GLES 가 같은 dma-buf 에 그릴 수 있는가
//!   8. GPU 로 그린 dma-buf 가 화면에 표시되는가
//!
//! 하나라도 실패하면 tildaz 는 기존 software `wl_shm` 경로로 동작한다 (영구 fallback).
//! 즉 이 도구가 FAIL 을 내도 앱이 안 되는 게 아니라 **GPU 경로를 안 쓴다**는 뜻이다.
//!
//! 빌드 / 실행 (`-lc` 필수 — 빼면 dlopen 대신 Zig 자체 ELF 로더가 잡혀 죽는다):
//! ```sh
//! zig build-exe dist/linux/dmabuf-probe.zig -O ReleaseSafe -lc
//! ./dmabuf-probe
//! ```
//!
//! 창이 약 5 초간 떴다 사라진다. 두 단계로 그린다 — 먼저 CPU 로 4 분면, 이어서
//! GPU 로 같은 4 분면. **두 번째 단계는 CPU 로 마젠타를 가득 칠한 뒤 GPU 로 덮어쓴다**
//! — 화면에 마젠타가 남으면 GPU 가 그 버퍼에 못 쓴 것이다 (눈으로 바로 판정 가능).
//!
//! 종료 코드: 0 = GPU 경로 성립, 1 = 성립하지 않음 (fallback 필요).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

// ----------------------------------------------------------------- wire 기본
//
// libwayland 를 쓰지 않는다 — tildaz 의 Linux host 자체가 raw wire client 라
// (`src/host/linux/wayland_minimal.zig`), 진단도 같은 방식이어야 같은 것을
//검사하는 게 된다. framing / SCM_RIGHTS 구현은 그 파일에서 가져왔다.

const display_id: u32 = 1;
const registry_id: u32 = 2;

const Cmsghdr = extern struct {
    len: usize,
    level: c_int,
    type: c_int,
};

fn align4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

fn cmsgAlign(n: usize) usize {
    const a = @sizeOf(usize);
    const mask: usize = a - 1;
    return (n + mask) & ~mask;
}

fn cmsgLen(payload_len: usize) usize {
    return cmsgAlign(@sizeOf(Cmsghdr)) + payload_len;
}

fn cmsgSpace(payload_len: usize) usize {
    return cmsgAlign(@sizeOf(Cmsghdr)) + cmsgAlign(payload_len);
}

fn readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .little);
}

fn readI32(bytes: *const [4]u8) i32 {
    return @bitCast(readU32(bytes));
}

fn writeU32(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, .little);
}

const Msg = struct {
    buf: [512]u8 = undefined,
    len: usize = 8,
    id: u32,
    opcode: u16,

    fn init(id: u32, opcode: u16) Msg {
        return .{ .id = id, .opcode = opcode };
    }

    fn putU32(self: *Msg, value: u32) !void {
        if (self.len + 4 > self.buf.len) return error.MessageTooLarge;
        writeU32(self.buf[self.len..][0..4], value);
        self.len += 4;
    }

    fn putI32(self: *Msg, value: i32) !void {
        try self.putU32(@bitCast(value));
    }

    fn putString(self: *Msg, value: []const u8) !void {
        const wire_len = value.len + 1;
        const padded = align4(wire_len);
        if (self.len + 4 + padded > self.buf.len) return error.MessageTooLarge;
        try self.putU32(@intCast(wire_len));
        @memcpy(self.buf[self.len..][0..value.len], value);
        self.buf[self.len + value.len] = 0;
        @memset(self.buf[self.len + wire_len .. self.len + padded], 0);
        self.len += padded;
    }

    fn finish(self: *Msg) []const u8 {
        writeU32(self.buf[0..4], self.id);
        const word = (@as(u32, @intCast(self.len)) << 16) | self.opcode;
        writeU32(self.buf[4..8], word);
        return self.buf[0..self.len];
    }

    fn send(self: *Msg, stream: std.net.Stream) !void {
        try stream.writeAll(self.finish());
    }

    fn sendWithFd(self: *Msg, stream: std.net.Stream, fd: posix.fd_t) !void {
        const bytes = self.finish();
        var iov = [_]posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};

        const fd_payload_size = @sizeOf(c_int);
        const control_len = cmsgLen(fd_payload_size);
        var control: [cmsgSpace(fd_payload_size)]u8 align(@alignOf(Cmsghdr)) = @splat(0);
        const hdr: *Cmsghdr = @ptrCast(@alignCast(&control));
        hdr.* = .{
            .len = control_len,
            .level = linux.SOL.SOCKET,
            .type = 1, // SCM_RIGHTS
        };
        const fd_i32: c_int = fd;
        const data_offset = cmsgAlign(@sizeOf(Cmsghdr));
        @memcpy(control[data_offset..][0..fd_payload_size], std.mem.asBytes(&fd_i32));

        const msg = posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = iov[0..].ptr,
            .iovlen = iov.len,
            .control = control[0..].ptr,
            .controllen = control_len,
            .flags = 0,
        };
        const sent = try posix.sendmsg(stream.handle, &msg, 0);
        if (sent != bytes.len) return error.ShortFdWrite;
    }
};

// -------------------------------------------------------------------- gbm

fn fourcc(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c) << 16) | (@as(u32, d) << 24);
}

const GBM_FORMAT_ARGB8888 = fourcc('A', 'R', '2', '4');

// /usr/include/gbm.h — enum gbm_bo_flags / gbm_bo_transfer_flags.
// `GBM_BO_USE_WRITE` 는 쓰지 않는다 — 헤더 계약상 `gbm_bo_write` 전용이고
// CURSOR 외 조합은 보장되지 않으며, 실측에서 render node 에 NULL 을 돌려줬다.
const GBM_BO_USE_RENDERING: u32 = 1 << 2;
const GBM_BO_USE_LINEAR: u32 = 1 << 4;
const GBM_BO_TRANSFER_WRITE: u32 = 1 << 1;

const DRM_FORMAT_MOD_LINEAR: u64 = 0;
const DRM_FORMAT_MOD_INVALID: u64 = 0x00ffffffffffffff;

const Gbm = struct {
    create_device: *const fn (fd: c_int) callconv(.c) ?*anyopaque,
    bo_create: *const fn (dev: ?*anyopaque, w: u32, h: u32, format: u32, flags: u32) callconv(.c) ?*anyopaque,
    bo_create_with_modifiers: *const fn (dev: ?*anyopaque, w: u32, h: u32, format: u32, mods: [*]const u64, count: c_uint) callconv(.c) ?*anyopaque,
    bo_map: *const fn (bo: ?*anyopaque, x: u32, y: u32, w: u32, h: u32, flags: u32, stride: *u32, map_data: *?*anyopaque) callconv(.c) ?*anyopaque,
    bo_unmap: *const fn (bo: ?*anyopaque, map_data: ?*anyopaque) callconv(.c) void,
    bo_get_fd: *const fn (bo: ?*anyopaque) callconv(.c) c_int,
    bo_get_stride: *const fn (bo: ?*anyopaque) callconv(.c) u32,
    bo_get_offset: *const fn (bo: ?*anyopaque, plane: c_int) callconv(.c) u32,
    bo_get_modifier: *const fn (bo: ?*anyopaque) callconv(.c) u64,
    bo_get_plane_count: *const fn (bo: ?*anyopaque) callconv(.c) c_int,
    bo_destroy: *const fn (bo: ?*anyopaque) callconv(.c) void,
    device_destroy: *const fn (dev: ?*anyopaque) callconv(.c) void,

    fn load() !Gbm {
        var lib = try std.DynLib.open("libgbm.so.1");
        return .{
            .create_device = lib.lookup(@FieldType(Gbm, "create_device"), "gbm_create_device") orelse return error.MissingSymbol,
            .bo_create = lib.lookup(@FieldType(Gbm, "bo_create"), "gbm_bo_create") orelse return error.MissingSymbol,
            .bo_create_with_modifiers = lib.lookup(@FieldType(Gbm, "bo_create_with_modifiers"), "gbm_bo_create_with_modifiers") orelse return error.MissingSymbol,
            .bo_map = lib.lookup(@FieldType(Gbm, "bo_map"), "gbm_bo_map") orelse return error.MissingSymbol,
            .bo_unmap = lib.lookup(@FieldType(Gbm, "bo_unmap"), "gbm_bo_unmap") orelse return error.MissingSymbol,
            .bo_get_fd = lib.lookup(@FieldType(Gbm, "bo_get_fd"), "gbm_bo_get_fd") orelse return error.MissingSymbol,
            .bo_get_stride = lib.lookup(@FieldType(Gbm, "bo_get_stride"), "gbm_bo_get_stride") orelse return error.MissingSymbol,
            .bo_get_offset = lib.lookup(@FieldType(Gbm, "bo_get_offset"), "gbm_bo_get_offset") orelse return error.MissingSymbol,
            .bo_get_modifier = lib.lookup(@FieldType(Gbm, "bo_get_modifier"), "gbm_bo_get_modifier") orelse return error.MissingSymbol,
            .bo_get_plane_count = lib.lookup(@FieldType(Gbm, "bo_get_plane_count"), "gbm_bo_get_plane_count") orelse return error.MissingSymbol,
            .bo_destroy = lib.lookup(@FieldType(Gbm, "bo_destroy"), "gbm_bo_destroy") orelse return error.MissingSymbol,
            .device_destroy = lib.lookup(@FieldType(Gbm, "device_destroy"), "gbm_device_destroy") orelse return error.MissingSymbol,
        };
    }
};

// --------------------------------------------------------------- EGL / GLES

const EGL_NONE: i32 = 0x3038;
const EGL_PLATFORM_GBM_KHR: u32 = 0x31D7;
const EGL_OPENGL_ES_API: u32 = 0x30A0;
const EGL_CONTEXT_MAJOR_VERSION: i32 = 0x3098;
const EGL_VENDOR: i32 = 0x3053;
const EGL_EXTENSIONS: i32 = 0x3055;
const EGL_LINUX_DMA_BUF_EXT: u32 = 0x3270;
const EGL_WIDTH: i32 = 0x3057;
const EGL_HEIGHT: i32 = 0x3056;
const EGL_LINUX_DRM_FOURCC_EXT: i32 = 0x3271;
const EGL_DMA_BUF_PLANE0_FD_EXT: i32 = 0x3272;
const EGL_DMA_BUF_PLANE0_OFFSET_EXT: i32 = 0x3273;
const EGL_DMA_BUF_PLANE0_PITCH_EXT: i32 = 0x3274;
const EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT: i32 = 0x3443;
const EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT: i32 = 0x3444;

const GL_TEXTURE_2D: u32 = 0x0DE1;
const GL_FRAMEBUFFER: u32 = 0x8D40;
const GL_COLOR_ATTACHMENT0: u32 = 0x8CE0;
const GL_FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
const GL_COLOR_BUFFER_BIT: u32 = 0x4000;
const GL_SCISSOR_TEST: u32 = 0x0C11;
const GL_TEXTURE_MIN_FILTER: u32 = 0x2801;
const GL_TEXTURE_MAG_FILTER: u32 = 0x2800;
const GL_NEAREST: i32 = 0x2600;
const GL_RENDERER: u32 = 0x1F01;
const GL_VERSION: u32 = 0x1F02;

const Egl = struct {
    getProcAddress: *const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque,
    getPlatformDisplay: *const fn (platform: u32, native: ?*anyopaque, attrs: ?[*]const isize) callconv(.c) ?*anyopaque,
    initialize: *const fn (dpy: ?*anyopaque, major: ?*i32, minor: ?*i32) callconv(.c) c_uint,
    bindAPI: *const fn (api: u32) callconv(.c) c_uint,
    createContext: *const fn (dpy: ?*anyopaque, config: ?*anyopaque, share: ?*anyopaque, attrs: [*]const i32) callconv(.c) ?*anyopaque,
    makeCurrent: *const fn (dpy: ?*anyopaque, draw: ?*anyopaque, read: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) c_uint,
    queryString: *const fn (dpy: ?*anyopaque, name: i32) callconv(.c) ?[*:0]const u8,
    getError: *const fn () callconv(.c) i32,
    createImageKHR: *const fn (dpy: ?*anyopaque, ctx: ?*anyopaque, target: u32, buffer: ?*anyopaque, attrs: [*]const i32) callconv(.c) ?*anyopaque,
    destroyImageKHR: *const fn (dpy: ?*anyopaque, image: ?*anyopaque) callconv(.c) c_uint,

    imageTargetTexture2DOES: *const fn (target: u32, image: ?*anyopaque) callconv(.c) void,
    genTextures: *const fn (n: i32, out: [*]u32) callconv(.c) void,
    bindTexture: *const fn (target: u32, tex: u32) callconv(.c) void,
    texParameteri: *const fn (target: u32, pname: u32, param: i32) callconv(.c) void,
    genFramebuffers: *const fn (n: i32, out: [*]u32) callconv(.c) void,
    bindFramebuffer: *const fn (target: u32, fb: u32) callconv(.c) void,
    framebufferTexture2D: *const fn (target: u32, attachment: u32, textarget: u32, tex: u32, level: i32) callconv(.c) void,
    checkFramebufferStatus: *const fn (target: u32) callconv(.c) u32,
    clearColor: *const fn (r: f32, g: f32, b: f32, a: f32) callconv(.c) void,
    clear: *const fn (mask: u32) callconv(.c) void,
    enable: *const fn (cap: u32) callconv(.c) void,
    scissor: *const fn (x: i32, y: i32, w: i32, h: i32) callconv(.c) void,
    viewport: *const fn (x: i32, y: i32, w: i32, h: i32) callconv(.c) void,
    flush: *const fn () callconv(.c) void,
    getString: *const fn (name: u32) callconv(.c) ?[*:0]const u8,
    glGetError: *const fn () callconv(.c) u32,

    fn load() !Egl {
        var lib = try std.DynLib.open("libEGL.so.1");
        var gles = try std.DynLib.open("libGLESv2.so.2");

        const gpa_fn = lib.lookup(@FieldType(Egl, "getProcAddress"), "eglGetProcAddress") orelse return error.MissingSymbol;
        // 확장 진입점은 eglGetProcAddress 로 얻는다 — glvnd 경유 시 libEGL 에
        // 직접 심볼이 없을 수 있다.
        const create_image = gpa_fn("eglCreateImageKHR") orelse return error.NoEglCreateImageKHR;
        const destroy_image = gpa_fn("eglDestroyImageKHR") orelse return error.NoEglDestroyImageKHR;
        const img_target = gpa_fn("glEGLImageTargetTexture2DOES") orelse return error.NoImageTargetTexture2DOES;

        return .{
            .getProcAddress = gpa_fn,
            .getPlatformDisplay = lib.lookup(@FieldType(Egl, "getPlatformDisplay"), "eglGetPlatformDisplay") orelse return error.MissingSymbol,
            .initialize = lib.lookup(@FieldType(Egl, "initialize"), "eglInitialize") orelse return error.MissingSymbol,
            .bindAPI = lib.lookup(@FieldType(Egl, "bindAPI"), "eglBindAPI") orelse return error.MissingSymbol,
            .createContext = lib.lookup(@FieldType(Egl, "createContext"), "eglCreateContext") orelse return error.MissingSymbol,
            .makeCurrent = lib.lookup(@FieldType(Egl, "makeCurrent"), "eglMakeCurrent") orelse return error.MissingSymbol,
            .queryString = lib.lookup(@FieldType(Egl, "queryString"), "eglQueryString") orelse return error.MissingSymbol,
            .getError = lib.lookup(@FieldType(Egl, "getError"), "eglGetError") orelse return error.MissingSymbol,
            .createImageKHR = @ptrCast(create_image),
            .destroyImageKHR = @ptrCast(destroy_image),
            .imageTargetTexture2DOES = @ptrCast(img_target),
            .genTextures = gles.lookup(@FieldType(Egl, "genTextures"), "glGenTextures") orelse return error.MissingSymbol,
            .bindTexture = gles.lookup(@FieldType(Egl, "bindTexture"), "glBindTexture") orelse return error.MissingSymbol,
            .texParameteri = gles.lookup(@FieldType(Egl, "texParameteri"), "glTexParameteri") orelse return error.MissingSymbol,
            .genFramebuffers = gles.lookup(@FieldType(Egl, "genFramebuffers"), "glGenFramebuffers") orelse return error.MissingSymbol,
            .bindFramebuffer = gles.lookup(@FieldType(Egl, "bindFramebuffer"), "glBindFramebuffer") orelse return error.MissingSymbol,
            .framebufferTexture2D = gles.lookup(@FieldType(Egl, "framebufferTexture2D"), "glFramebufferTexture2D") orelse return error.MissingSymbol,
            .checkFramebufferStatus = gles.lookup(@FieldType(Egl, "checkFramebufferStatus"), "glCheckFramebufferStatus") orelse return error.MissingSymbol,
            .clearColor = gles.lookup(@FieldType(Egl, "clearColor"), "glClearColor") orelse return error.MissingSymbol,
            .clear = gles.lookup(@FieldType(Egl, "clear"), "glClear") orelse return error.MissingSymbol,
            .enable = gles.lookup(@FieldType(Egl, "enable"), "glEnable") orelse return error.MissingSymbol,
            .scissor = gles.lookup(@FieldType(Egl, "scissor"), "glScissor") orelse return error.MissingSymbol,
            .viewport = gles.lookup(@FieldType(Egl, "viewport"), "glViewport") orelse return error.MissingSymbol,
            .flush = gles.lookup(@FieldType(Egl, "flush"), "glFlush") orelse return error.MissingSymbol,
            .getString = gles.lookup(@FieldType(Egl, "getString"), "glGetString") orelse return error.MissingSymbol,
            .glGetError = gles.lookup(@FieldType(Egl, "glGetError"), "glGetError") orelse return error.MissingSymbol,
        };
    }
};

fn cstr(p: ?[*:0]const u8) []const u8 {
    return if (p) |s| std.mem.span(s) else "(null)";
}

// ------------------------------------------------------------------- 판정 결과

const Report = struct {
    // 환경
    desktop: []const u8 = "(unset)",
    dmabuf_version: u32 = 0,
    argb_modifier_count: usize = 0,
    linear_supported: bool = false,
    render_node: []const u8 = "",
    egl_vendor: []const u8 = "(미확인)",
    gl_renderer: []const u8 = "(미확인)",
    gl_version: []const u8 = "(미확인)",

    // 단계별 판정
    gbm_loaded: bool = false,
    gbm_device: bool = false,
    bo_linear: bool = false,
    bo_tiled: bool = false,
    bo_map: bool = false,
    cpu_buffer_created: bool = false,
    cpu_frame_shown: bool = false,
    egl_loaded: bool = false,
    egl_display: bool = false,
    egl_context: bool = false,
    egl_image_import: bool = false,
    gl_fbo_complete: bool = false,
    gl_buffer_created: bool = false,
    gl_frame_shown: bool = false,
    protocol_error: bool = false,
    failure_note: []const u8 = "",

    // compositor 가 공표한 modifier 로 시도한 결과 (LINEAR 가 없는 환경 —
    // 실측된 예: NVIDIA + KWin — 에서 GPU 경로가 가능한지 가리는 항목이다).
    neg_attempted: bool = false,
    neg_modifier: u64 = DRM_FORMAT_MOD_INVALID,
    neg_allocated: bool = false,
    neg_image_import: bool = false,
    neg_fbo_complete: bool = false,
    neg_buffer_created: bool = false,
    neg_frame_shown: bool = false,

    /// 현재 구현(S1: CPU 가 dma-buf 에 그린다)이 이 환경에서 동작하는가.
    fn s1Viable(self: *const Report) bool {
        return self.gbm_device and self.bo_linear and self.bo_map and
            self.cpu_buffer_created and self.cpu_frame_shown and !self.protocol_error;
    }

    /// GLES 렌더러(S2)가 이 환경에서 동작할 수 있는가. LINEAR 든 compositor 가
    /// 공표한 modifier 든 **하나라도** 끝까지 가면 가능하다.
    fn s2Viable(self: *const Report) bool {
        const via_linear = self.gl_fbo_complete and self.gl_buffer_created and self.gl_frame_shown;
        const via_negotiated = self.neg_fbo_complete and self.neg_buffer_created and self.neg_frame_shown;
        return (via_linear or via_negotiated) and !self.protocol_error;
    }
};

fn mark(ok: bool) []const u8 {
    return if (ok) "PASS" else "FAIL";
}

// -------------------------------------------------------------------- 상태

const max_mods = 128;

const State = struct {
    stream: std.net.Stream,
    next_id: u32 = registry_id + 1,
    in: [64 * 1024]u8 = undefined,
    in_len: usize = 0,

    compositor_name: u32 = 0,
    compositor_ver: u32 = 0,
    wm_base_name: u32 = 0,
    wm_base_ver: u32 = 0,
    dmabuf_name: u32 = 0,
    dmabuf_ver: u32 = 0,

    compositor_id: u32 = 0,
    wm_base_id: u32 = 0,
    dmabuf_id: u32 = 0,
    surface_id: u32 = 0,
    xdg_surface_id: u32 = 0,
    toplevel_id: u32 = 0,
    sync_id: u32 = 0,
    frame_id: u32 = 0,

    /// 현재 대기 중인 params 와 그 결과. 두 단계(CPU / GL)에서 재사용한다.
    params_id: u32 = 0,
    params_result: enum { pending, created, failed } = .pending,
    last_buffer_id: u32 = 0,

    sync_done: bool = false,
    xdg_configured: bool = false,
    cfg_w: i32 = 0,
    cfg_h: i32 = 0,
    frame_done: bool = false,
    closed: bool = false,
    got_error: bool = false,

    argb_mods: [max_mods]u64 = undefined,
    argb_mod_count: usize = 0,

    fn allocId(self: *State) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn sendArgs(self: *State, id: u32, opcode: u16, args: []const u32) !void {
        var m = Msg.init(id, opcode);
        for (args) |a| try m.putU32(a);
        try m.send(self.stream);
    }

    fn sendNoArgs(self: *State, id: u32, opcode: u16) !void {
        var m = Msg.init(id, opcode);
        try m.send(self.stream);
    }

    fn roundtrip(self: *State) !void {
        self.sync_id = self.allocId();
        self.sync_done = false;
        try self.sendArgs(display_id, 0, &.{self.sync_id});
        while (!self.sync_done) try self.readAndDispatch();
    }

    fn readAndDispatch(self: *State) !void {
        if (self.in_len == self.in.len) return error.ReadBufferFull;
        const n = try self.stream.read(self.in[self.in_len..]);
        if (n == 0) return error.ConnectionClosed;
        self.in_len += n;
        try self.dispatchBuffered();
    }

    fn dispatchBuffered(self: *State) !void {
        var offset: usize = 0;
        while (self.in_len - offset >= 8) {
            const id = readU32(self.in[offset..][0..4]);
            const word = readU32(self.in[offset + 4 ..][0..4]);
            const size: usize = @intCast(word >> 16);
            const opcode: u16 = @truncate(word & 0xffff);
            if (size < 8) return error.BadMessage;
            if (self.in_len - offset < size) break;
            try self.handleEvent(id, opcode, self.in[offset + 8 .. offset + size]);
            offset += size;
        }
        const rem = self.in_len - offset;
        if (rem > 0 and offset > 0) std.mem.copyForwards(u8, self.in[0..rem], self.in[offset..self.in_len]);
        self.in_len = rem;
    }

    fn handleEvent(self: *State, id: u32, opcode: u16, payload: []const u8) !void {
        if (id == display_id and opcode == 0) {
            if (payload.len >= 12) {
                const obj = readU32(payload[0..4]);
                const code = readU32(payload[4..8]);
                const str_len: usize = @intCast(readU32(payload[8..12]));
                const end = @min(12 + str_len, payload.len);
                std.debug.print("  wl_display.error object={d} code={d} msg={s}\n", .{ obj, code, payload[12..end] });
            }
            self.got_error = true;
            return;
        }
        if (id == display_id and opcode == 1) return; // delete_id

        if (id == registry_id and opcode == 0) {
            if (payload.len < 8) return;
            const name = readU32(payload[0..4]);
            const str_len: usize = @intCast(readU32(payload[4..8]));
            if (str_len == 0) return;
            const iface_end = 8 + str_len - 1;
            if (iface_end > payload.len) return;
            const iface = payload[8..iface_end];
            const ver_off = 8 + align4(str_len);
            if (ver_off + 4 > payload.len) return;
            const ver = readU32(payload[ver_off..][0..4]);

            if (std.mem.eql(u8, iface, "wl_compositor")) {
                self.compositor_name = name;
                self.compositor_ver = ver;
            } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
                self.wm_base_name = name;
                self.wm_base_ver = ver;
            } else if (std.mem.eql(u8, iface, "zwp_linux_dmabuf_v1")) {
                self.dmabuf_name = name;
                self.dmabuf_ver = ver;
            }
            return;
        }

        if (id == self.sync_id and opcode == 0) {
            self.sync_done = true;
            return;
        }
        if (self.frame_id != 0 and id == self.frame_id and opcode == 0) {
            self.frame_done = true;
            return;
        }

        if (self.wm_base_id != 0 and id == self.wm_base_id and opcode == 0) {
            if (payload.len < 4) return;
            try self.sendArgs(self.wm_base_id, 3, &.{readU32(payload[0..4])}); // pong
            return;
        }
        if (self.xdg_surface_id != 0 and id == self.xdg_surface_id and opcode == 0) {
            if (payload.len < 4) return;
            try self.sendArgs(self.xdg_surface_id, 4, &.{readU32(payload[0..4])}); // ack_configure
            self.xdg_configured = true;
            return;
        }
        if (self.toplevel_id != 0 and id == self.toplevel_id) {
            if (opcode == 0 and payload.len >= 8) {
                const w = readI32(payload[0..4]);
                const h = readI32(payload[4..8]);
                if (w > 0 and h > 0) {
                    self.cfg_w = w;
                    self.cfg_h = h;
                }
            } else if (opcode == 1) {
                self.closed = true;
            }
            return;
        }

        if (self.dmabuf_id != 0 and id == self.dmabuf_id and opcode == 1) {
            if (payload.len < 12) return;
            const format = readU32(payload[0..4]);
            const hi = readU32(payload[4..8]);
            const lo = readU32(payload[8..12]);
            if (format == GBM_FORMAT_ARGB8888 and self.argb_mod_count < max_mods) {
                self.argb_mods[self.argb_mod_count] = (@as(u64, hi) << 32) | @as(u64, lo);
                self.argb_mod_count += 1;
            }
            return;
        }

        if (self.params_id != 0 and id == self.params_id) {
            if (opcode == 0 and payload.len >= 4) {
                self.last_buffer_id = readU32(payload[0..4]);
                self.params_result = .created;
            } else if (opcode == 1) {
                self.params_result = .failed;
            }
            return;
        }
    }

    fn bind(self: *State, name: u32, iface: []const u8, version: u32, new_id: u32) !void {
        var m = Msg.init(registry_id, 0);
        try m.putU32(name);
        try m.putString(iface);
        try m.putU32(version);
        try m.putU32(new_id);
        try m.send(self.stream);
    }

    /// dma-buf 로 `wl_buffer` 를 만든다. `create_immed` 가 아니라 `create` 를 쓴다 —
    /// 거부가 protocol error (앱 종료) 가 아니라 `failed` 이벤트로 와야 fallback 이
    /// 안전하기 때문이다. tildaz 본체도 같은 이유로 이 방식을 쓸 예정이다.
    fn createDmabufBuffer(
        self: *State,
        fd: c_int,
        w: u32,
        h: u32,
        stride: u32,
        offset: u32,
        modifier: u64,
    ) !?u32 {
        self.params_id = self.allocId();
        self.params_result = .pending;
        try self.sendArgs(self.dmabuf_id, 1, &.{self.params_id}); // create_params
        {
            var m = Msg.init(self.params_id, 1); // add
            try m.putU32(0); // plane_idx
            try m.putU32(offset);
            try m.putU32(stride);
            try m.putU32(@truncate(modifier >> 32));
            try m.putU32(@truncate(modifier & 0xffff_ffff));
            try m.sendWithFd(self.stream, fd);
        }
        {
            var m = Msg.init(self.params_id, 2); // create
            try m.putI32(@intCast(w));
            try m.putI32(@intCast(h));
            try m.putU32(GBM_FORMAT_ARGB8888);
            try m.putU32(0); // flags
            try m.send(self.stream);
        }
        while (self.params_result == .pending and !self.got_error) try self.readAndDispatch();
        return if (self.params_result == .created) self.last_buffer_id else null;
    }

    fn presentAndWait(self: *State, buffer_id: u32, w: u32, h: u32, hold_ms: i64) !bool {
        try self.sendArgs(self.surface_id, 1, &.{ buffer_id, 0, 0 }); // attach
        {
            var m = Msg.init(self.surface_id, 9); // damage_buffer
            try m.putI32(0);
            try m.putI32(0);
            try m.putI32(@intCast(w));
            try m.putI32(@intCast(h));
            try m.send(self.stream);
        }
        self.frame_id = self.allocId();
        self.frame_done = false;
        try self.sendArgs(self.surface_id, 3, &.{self.frame_id}); // frame
        try self.sendNoArgs(self.surface_id, 6); // commit

        const start = std.time.milliTimestamp();
        var fds = [_]posix.pollfd{.{ .fd = self.stream.handle, .events = posix.POLL.IN, .revents = 0 }};
        while (std.time.milliTimestamp() - start < hold_ms) {
            const ready = posix.poll(&fds, 50) catch break;
            if (ready > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
                self.readAndDispatch() catch break;
            }
            if (self.got_error or self.closed) break;
        }
        return self.frame_done;
    }
};

// ------------------------------------------------------------------ 기준 패턴

const quad_tl: u32 = 0xFF212326; // 탭바 배경
const quad_tr: u32 = 0xFFF7A41D; // amber
const quad_bl: u32 = 0xFF4F4F54; // 세로 구분선
const quad_br: u32 = 0xFFB4B4B4; // 탭 제목
const magenta: u32 = 0xFFFF00FF;

fn fillSolid(base: [*]u8, w: u32, h: u32, stride: u32, color: u32) void {
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = base + y * stride;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            std.mem.writeInt(u32, (row + x * 4)[0..4], color, .little);
        }
    }
}

fn paintPattern(base: [*]u8, w: u32, h: u32, stride: u32) void {
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = base + y * stride;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const top = y < h / 2;
            const left = x < w / 2;
            var color: u32 = if (top and left) quad_tl else if (top) quad_tr else if (left) quad_bl else quad_br;
            if (x < 24 and y < 24) color = 0xFF000000; // 원점 마커
            std.mem.writeInt(u32, (row + x * 4)[0..4], color, .little);
        }
    }
}

fn clearColorOf(argb: u32) [4]f32 {
    const r: f32 = @floatFromInt((argb >> 16) & 0xff);
    const g: f32 = @floatFromInt((argb >> 8) & 0xff);
    const b: f32 = @floatFromInt(argb & 0xff);
    const a: f32 = @floatFromInt((argb >> 24) & 0xff);
    return .{ r / 255.0, g / 255.0, b / 255.0, a / 255.0 };
}

// ---------------------------------------------------------------------- main

pub fn main() !u8 {
    var report = Report{};
    report.desktop = posix.getenv("XDG_CURRENT_DESKTOP") orelse "(unset)";

    std.debug.print("tildaz Linux GPU 경로 진단 (#277)\n\n", .{});

    // ---- Wayland 연결
    const runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse {
        std.debug.print("XDG_RUNTIME_DIR 이 없다 — Wayland 세션이 아니다.\n", .{});
        return 1;
    };
    const wl_display = posix.getenv("WAYLAND_DISPLAY") orelse "wayland-0";
    var path_buf: [512]u8 = undefined;
    const sock_path: []const u8 = if (std.fs.path.isAbsolute(wl_display))
        wl_display
    else
        try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ runtime_dir, wl_display });

    var state = State{ .stream = std.net.connectUnixSocket(sock_path) catch |err| {
        std.debug.print("Wayland 소켓 연결 실패 ({s}): {s}\n", .{ sock_path, @errorName(err) });
        return 1;
    } };
    defer state.stream.close();

    try state.sendArgs(display_id, 1, &.{registry_id});
    try state.roundtrip();
    if (state.compositor_name == 0 or state.wm_base_name == 0) {
        std.debug.print("wl_compositor / xdg_wm_base 가 없다 — 진단 불가.\n", .{});
        return 1;
    }
    if (state.dmabuf_name == 0) {
        report.failure_note = "compositor 가 zwp_linux_dmabuf_v1 을 노출하지 않는다";
        printReport(&report);
        return 1;
    }
    report.dmabuf_version = state.dmabuf_ver;

    state.compositor_id = state.allocId();
    try state.bind(state.compositor_name, "wl_compositor", @min(state.compositor_ver, 4), state.compositor_id);
    state.wm_base_id = state.allocId();
    try state.bind(state.wm_base_name, "xdg_wm_base", @min(state.wm_base_ver, 2), state.wm_base_id);
    state.dmabuf_id = state.allocId();
    // v3 으로 bind 해 format / modifier 이벤트를 받는다. v4+ 는 그 이벤트가
    // deprecated 라 feedback 을 써야 하는데, 진단 목적에는 v3 이 충분하고
    // 오래된 compositor 까지 같은 코드로 덮인다.
    try state.bind(state.dmabuf_name, "zwp_linux_dmabuf_v1", @min(state.dmabuf_ver, 3), state.dmabuf_id);
    try state.roundtrip();

    report.argb_modifier_count = state.argb_mod_count;
    for (state.argb_mods[0..state.argb_mod_count]) |m| {
        if (m == DRM_FORMAT_MOD_LINEAR) report.linear_supported = true;
    }

    // ---- 창 (전체화면이 아니라 작은 창 — 남의 화면을 덮지 않는다)
    state.surface_id = state.allocId();
    try state.sendArgs(state.compositor_id, 0, &.{state.surface_id});
    state.xdg_surface_id = state.allocId();
    try state.sendArgs(state.wm_base_id, 2, &.{ state.xdg_surface_id, state.surface_id });
    state.toplevel_id = state.allocId();
    try state.sendArgs(state.xdg_surface_id, 1, &.{state.toplevel_id});
    {
        var m = Msg.init(state.toplevel_id, 2); // set_title
        try m.putString("tildaz dmabuf probe (#277)");
        try m.send(state.stream);
    }
    try state.sendNoArgs(state.surface_id, 6); // commit
    while (!state.xdg_configured and !state.got_error) try state.readAndDispatch();
    if (state.got_error) {
        report.protocol_error = true;
        printReport(&report);
        return 1;
    }

    const w: u32 = if (state.cfg_w > 0) @intCast(state.cfg_w) else 720;
    const h: u32 = if (state.cfg_h > 0) @intCast(state.cfg_h) else 480;

    // ---- GBM
    var gbm = Gbm.load() catch |err| {
        report.failure_note = "libgbm.so.1 을 열 수 없다";
        std.debug.print("  ({s})\n", .{@errorName(err)});
        printReport(&report);
        return 1;
    };
    report.gbm_loaded = true;

    const node = "/dev/dri/renderD128";
    report.render_node = node;
    const drm_fd = posix.open(node, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch |err| {
        report.failure_note = "DRM render node 를 열 수 없다 (권한 또는 GPU 없음)";
        std.debug.print("  ({s}: {s})\n", .{ node, @errorName(err) });
        printReport(&report);
        return 1;
    };
    defer posix.close(drm_fd);

    const dev = gbm.create_device(drm_fd) orelse {
        report.failure_note = "gbm_create_device 실패";
        printReport(&report);
        return 1;
    };
    defer gbm.device_destroy(dev);
    report.gbm_device = true;

    // LINEAR — CPU 로 그리려면 필요하고, 명시 modifier 를 얻으려면
    // create_with_modifiers 여야 한다 (gbm_bo_create 는 INVALID 를 돌려준다).
    const linear_mods = [_]u64{DRM_FORMAT_MOD_LINEAR};
    const bo_cpu = gbm.bo_create_with_modifiers(dev, w, h, GBM_FORMAT_ARGB8888, &linear_mods, linear_mods.len);
    if (bo_cpu) |b| {
        report.bo_linear = gbm.bo_get_modifier(b) == DRM_FORMAT_MOD_LINEAR;
    }
    if (gbm.bo_create(dev, w, h, GBM_FORMAT_ARGB8888, GBM_BO_USE_RENDERING)) |tiled| {
        report.bo_tiled = true;
        gbm.bo_destroy(tiled);
    }
    const cpu_bo = bo_cpu orelse {
        report.failure_note = "LINEAR dma-buf 할당 실패";
        printReport(&report);
        return 1;
    };
    defer gbm.bo_destroy(cpu_bo);

    const cpu_stride = gbm.bo_get_stride(cpu_bo);
    const cpu_offset = gbm.bo_get_offset(cpu_bo, 0);
    const cpu_mod = gbm.bo_get_modifier(cpu_bo);

    // ---- 1 단계: CPU 로 그린 dma-buf
    var map_stride: u32 = 0;
    var map_data: ?*anyopaque = null;
    if (gbm.bo_map(cpu_bo, 0, 0, w, h, GBM_BO_TRANSFER_WRITE, &map_stride, &map_data)) |mapped| {
        report.bo_map = true;
        paintPattern(@ptrCast(mapped), w, h, map_stride);
        gbm.bo_unmap(cpu_bo, map_data);
    }

    const cpu_fd = gbm.bo_get_fd(cpu_bo);
    if (cpu_fd >= 0) {
        const buf = try state.createDmabufBuffer(cpu_fd, w, h, cpu_stride, cpu_offset, cpu_mod);
        posix.close(cpu_fd);
        if (buf) |bid| {
            report.cpu_buffer_created = true;
            report.cpu_frame_shown = try state.presentAndWait(bid, w, h, 2000);
        }
    }
    if (state.got_error) report.protocol_error = true;

    // ---- 2 단계: 같은 방식으로 할당한 dma-buf 에 GLES 로 그리기
    //
    // 새 bo 를 쓴다 — 1 단계 버퍼는 compositor 가 아직 들고 있을 수 있어
    // 덮어쓰면 경합이 된다.
    gl_phase: {
        var egl = Egl.load() catch |err| {
            std.debug.print("  EGL 로드 실패: {s}\n", .{@errorName(err)});
            break :gl_phase;
        };
        report.egl_loaded = true;

        const dpy = egl.getPlatformDisplay(EGL_PLATFORM_GBM_KHR, dev, null) orelse break :gl_phase;
        var maj: i32 = 0;
        var min: i32 = 0;
        if (egl.initialize(dpy, &maj, &min) == 0) break :gl_phase;
        report.egl_display = true;
        report.egl_vendor = cstr(egl.queryString(dpy, EGL_VENDOR));

        if (egl.bindAPI(EGL_OPENGL_ES_API) == 0) break :gl_phase;
        const ctx_attrs = [_]i32{ EGL_CONTEXT_MAJOR_VERSION, 2, EGL_NONE };
        // EGL_KHR_no_config_context + EGL_KHR_surfaceless_context — FBO 에만
        // 그리므로 config 도 window surface 도 필요 없다.
        const ctx = egl.createContext(dpy, null, null, &ctx_attrs) orelse break :gl_phase;
        if (egl.makeCurrent(dpy, null, null, ctx) == 0) break :gl_phase;
        report.egl_context = true;
        report.gl_renderer = cstr(egl.getString(GL_RENDERER));
        report.gl_version = cstr(egl.getString(GL_VERSION));

        // 2 단계 — LINEAR 로 시도. CPU 도 접근할 수 있는 modifier 라 S1 이 쓰는 것.
        const lin = try runGlPhase(&state, &gbm, dev, &egl, dpy, &linear_mods, w, h, 2500, true);
        report.egl_image_import = lin.image_import;
        report.gl_fbo_complete = lin.fbo_complete;
        report.gl_buffer_created = lin.buffer_created;
        report.gl_frame_shown = lin.frame_shown;

        // 3 단계 — compositor 가 공표한 modifier 를 **하나씩** 시험한다.
        //
        // 목록 전체를 GBM 에 넘기면 GBM 이 고른 하나만 보게 되는데, 그게 쓸 수
        // 있는 것이라는 보장이 없다 — AMD 실측에서 GBM 은 DCC(압축) modifier 를
        // 골랐고 그건 EGLImage import 가 실패했다. GLES 렌더러가 실제로 쓸 수
        // 있는 modifier 를 찾으려면 후보를 개별로 확인해야 한다.
        //
        // LINEAR 를 아예 공표하지 않는 환경도 실재한다 (NVIDIA + KWin 실측:
        // ARGB8888 modifier 13 종에 LINEAR 없음). 그 환경에서 GPU 경로가
        // 가능한지가 여기서 갈린다.
        if (state.argb_mod_count > 0) {
            report.neg_attempted = true;
            std.debug.print("\nmodifier 후보별 확인 (할당 / import / FBO):\n", .{});
            var winner: ?u64 = null;
            for (state.argb_mods[0..state.argb_mod_count]) |m| {
                const one = [_]u64{m};
                const t = try runGlPhase(&state, &gbm, dev, &egl, dpy, &one, w, h, 0, false);
                std.debug.print("  0x{x:0>16}  {s} / {s} / {s}\n", .{
                    m,
                    if (t.allocated) "할당" else "  X ",
                    if (t.image_import) "import" else "  X   ",
                    if (t.fbo_complete) "FBO" else " X ",
                });
                if (winner == null and t.fbo_complete) winner = m;
            }
            if (winner) |m| {
                const one = [_]u64{m};
                const neg = try runGlPhase(&state, &gbm, dev, &egl, dpy, &one, w, h, 2500, true);
                report.neg_allocated = neg.allocated;
                report.neg_modifier = neg.modifier;
                report.neg_image_import = neg.image_import;
                report.neg_fbo_complete = neg.fbo_complete;
                report.neg_buffer_created = neg.buffer_created;
                report.neg_frame_shown = neg.frame_shown;
            }
        }
    }

    if (state.got_error) report.protocol_error = true;

    printReport(&report);
    return if (report.s1Viable()) 0 else 1;
}

const GlPhaseResult = struct {
    allocated: bool = false,
    modifier: u64 = DRM_FORMAT_MOD_INVALID,
    image_import: bool = false,
    fbo_complete: bool = false,
    buffer_created: bool = false,
    frame_shown: bool = false,
};

/// 주어진 modifier 목록으로 dma-buf 를 할당해 GLES 로 그리고 화면에 올린다.
/// LINEAR 시도와 "compositor 공표 modifier" 시도가 같은 코드를 쓴다 — 두 경로가
/// 갈리면 어느 쪽이 왜 실패했는지 비교할 수 없다.
///
/// 매핑이 되는 modifier 면 CPU 로 마젠타를 먼저 칠한다. 화면에 마젠타가 남으면
/// GPU 가 그 버퍼에 못 썼다는 뜻이라 눈으로도 판정된다 (tiled 는 매핑이 안 될 수
/// 있고, 그때는 이 증명이 생략될 뿐 판정 자체는 유효하다).
fn runGlPhase(
    state: *State,
    gbm: *const Gbm,
    dev: ?*anyopaque,
    egl: *Egl,
    dpy: ?*anyopaque,
    mods: []const u64,
    w: u32,
    h: u32,
    hold_ms: i64,
    present: bool,
) !GlPhaseResult {
    var r = GlPhaseResult{};

    const bo = gbm.bo_create_with_modifiers(dev, w, h, GBM_FORMAT_ARGB8888, mods.ptr, @intCast(mods.len)) orelse return r;
    defer gbm.bo_destroy(bo);
    r.allocated = true;
    r.modifier = gbm.bo_get_modifier(bo);
    const stride = gbm.bo_get_stride(bo);
    const offset = gbm.bo_get_offset(bo, 0);

    var map_stride: u32 = 0;
    var map_data: ?*anyopaque = null;
    if (gbm.bo_map(bo, 0, 0, w, h, GBM_BO_TRANSFER_WRITE, &map_stride, &map_data)) |mapped| {
        fillSolid(@ptrCast(mapped), w, h, map_stride, magenta);
        gbm.bo_unmap(bo, map_data);
    }

    const fd = gbm.bo_get_fd(bo);
    if (fd < 0) return r;

    const img_attrs = [_]i32{
        EGL_WIDTH,                          @intCast(w),
        EGL_HEIGHT,                         @intCast(h),
        EGL_LINUX_DRM_FOURCC_EXT,           @bitCast(GBM_FORMAT_ARGB8888),
        EGL_DMA_BUF_PLANE0_FD_EXT,          fd,
        EGL_DMA_BUF_PLANE0_OFFSET_EXT,      @intCast(offset),
        EGL_DMA_BUF_PLANE0_PITCH_EXT,       @intCast(stride),
        EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, @bitCast(@as(u32, @truncate(r.modifier & 0xffff_ffff))),
        EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, @bitCast(@as(u32, @truncate(r.modifier >> 32))),
        EGL_NONE,
    };
    const image = egl.createImageKHR(dpy, null, EGL_LINUX_DMA_BUF_EXT, null, &img_attrs) orelse {
        std.debug.print("  eglCreateImageKHR 실패 (modifier=0x{x:0>16}) err=0x{x}\n", .{ r.modifier, egl.getError() });
        posix.close(fd);
        return r;
    };
    r.image_import = true;

    var tex: u32 = 0;
    egl.genTextures(1, @ptrCast(&tex));
    egl.bindTexture(GL_TEXTURE_2D, tex);
    egl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    egl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    egl.imageTargetTexture2DOES(GL_TEXTURE_2D, image);

    var fb: u32 = 0;
    egl.genFramebuffers(1, @ptrCast(&fb));
    egl.bindFramebuffer(GL_FRAMEBUFFER, fb);
    egl.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    if (egl.checkFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        std.debug.print("  FBO 불완전 (modifier=0x{x:0>16})\n", .{r.modifier});
        _ = egl.destroyImageKHR(dpy, image);
        posix.close(fd);
        return r;
    }
    r.fbo_complete = true;

    // 좌표 — dma-buf 를 FBO 로 쓰면 GL 의 y=0 행이 메모리 첫 행이고 Wayland 는
    // 그 행을 화면 맨 위에 표시한다. 즉 y-flip 보정을 하지 않는다 (top-down).
    egl.viewport(0, 0, @intCast(w), @intCast(h));
    egl.enable(GL_SCISSOR_TEST);
    const hw: i32 = @intCast(w / 2);
    const hh: i32 = @intCast(h / 2);
    const iw: i32 = @intCast(w);
    const ih: i32 = @intCast(h);
    const quads = [_]struct { x: i32, y: i32, w: i32, h: i32, c: u32 }{
        .{ .x = 0, .y = 0, .w = hw, .h = hh, .c = quad_tl },
        .{ .x = hw, .y = 0, .w = iw - hw, .h = hh, .c = quad_tr },
        .{ .x = 0, .y = hh, .w = hw, .h = ih - hh, .c = quad_bl },
        .{ .x = hw, .y = hh, .w = iw - hw, .h = ih - hh, .c = quad_br },
    };
    for (quads) |q| {
        const c = clearColorOf(q.c);
        egl.scissor(q.x, q.y, q.w, q.h);
        egl.clearColor(c[0], c[1], c[2], c[3]);
        egl.clear(GL_COLOR_BUFFER_BIT);
    }
    egl.scissor(0, 0, 24, 24);
    egl.clearColor(0, 0, 0, 1);
    egl.clear(GL_COLOR_BUFFER_BIT);

    // implicit sync 로 충분한지 보려고 glFinish 대신 glFlush 만 한다.
    egl.flush();

    if (!present) {
        // modifier 후보를 훑는 단계에서는 화면에 올리지 않는다 — 후보마다
        // 2.5 초씩 기다리면 진단이 너무 느려진다.
        posix.close(fd);
        _ = egl.destroyImageKHR(dpy, image);
        return r;
    }

    const buf = try state.createDmabufBuffer(fd, w, h, stride, offset, r.modifier);
    posix.close(fd);
    if (buf) |bid| {
        r.buffer_created = true;
        r.frame_shown = try state.presentAndWait(bid, w, h, hold_ms);
    }
    _ = egl.destroyImageKHR(dpy, image);
    return r;
}

fn printReport(r: *const Report) void {
    std.debug.print(
        \\
        \\================ tildaz #277 GPU 경로 진단 결과 ================
        \\환경
        \\  XDG_CURRENT_DESKTOP : {s}
        \\  render node         : {s}
        \\  EGL vendor          : {s}
        \\  GL renderer         : {s}
        \\  GL version          : {s}
        \\  zwp_linux_dmabuf_v1 : v{d}
        \\  ARGB8888 modifier   : {d} 종 (LINEAR {s})
        \\
        \\단계별
        \\  [{s}] libgbm dlopen
        \\  [{s}] GBM device 생성
        \\  [{s}] LINEAR dma-buf 할당
        \\  [{s}] tiled dma-buf 할당
        \\  [{s}] dma-buf CPU 매핑 (gbm_bo_map)
        \\  [{s}] CPU 버퍼 → wl_buffer 생성
        \\  [{s}] CPU 프레임 표시 (frame callback)
        \\  [{s}] libEGL / libGLESv2 dlopen
        \\  [{s}] EGL display (GBM platform)
        \\  [{s}] surfaceless GLES context
        \\  [{s}] dma-buf → EGLImage import
        \\  [{s}] FBO complete
        \\  [{s}] GPU 버퍼 → wl_buffer 생성
        \\  [{s}] GPU 프레임 표시 (frame callback)
        \\
    , .{
        r.desktop,
        if (r.render_node.len == 0) "(열지 못함)" else r.render_node,
        r.egl_vendor,
        r.gl_renderer,
        r.gl_version,
        r.dmabuf_version,
        r.argb_modifier_count,
        if (r.linear_supported) "지원" else "없음",
        mark(r.gbm_loaded),
        mark(r.gbm_device),
        mark(r.bo_linear),
        mark(r.bo_tiled),
        mark(r.bo_map),
        mark(r.cpu_buffer_created),
        mark(r.cpu_frame_shown),
        mark(r.egl_loaded),
        mark(r.egl_display),
        mark(r.egl_context),
        mark(r.egl_image_import),
        mark(r.gl_fbo_complete),
        mark(r.gl_buffer_created),
        mark(r.gl_frame_shown),
    });

    // 두 번으로 나눠 출력한다 — Zig 의 format 호출은 인자 32 개가 상한이다.
    std.debug.print(
        \\compositor 공표 modifier 로 재시도 (LINEAR 이 없는 환경용)
        \\  선택된 modifier      : 0x{x:0>16}
        \\  [{s}] dma-buf 할당
        \\  [{s}] EGLImage import
        \\  [{s}] FBO complete
        \\  [{s}] wl_buffer 생성
        \\  [{s}] 프레임 표시
        \\
        \\  [{s}] protocol error 없음
        \\
        \\종합
        \\  현재 구현 (CPU 가 dma-buf 에 그림) : {s}
        \\  GLES 렌더러 (계획)                 : {s}
        \\{s}{s}
        \\눈으로 볼 것: 마젠타(자홍)가 남아 있으면 GPU 가 그 버퍼에 쓰지 못한 것이다.
        \\4 분면(어두운 회색 / 주황 / 회색 / 밝은 회색) + 좌상단 검은 사각형이면 정상.
        \\==============================================================
        \\
    , .{
        r.neg_modifier,
        if (r.neg_attempted) mark(r.neg_allocated) else "skip",
        if (r.neg_attempted) mark(r.neg_image_import) else "skip",
        if (r.neg_attempted) mark(r.neg_fbo_complete) else "skip",
        if (r.neg_attempted) mark(r.neg_buffer_created) else "skip",
        if (r.neg_attempted) mark(r.neg_frame_shown) else "skip",
        mark(!r.protocol_error),
        if (r.s1Viable()) "동작함 (GPU 경로 사용)" else "불가 — software wl_shm 으로 동작 (앱은 정상)",
        if (r.s2Viable()) "가능함" else "불가 — 이 환경에서는 software 가 유일한 경로",
        if (r.failure_note.len == 0) "" else "사유: ",
        if (r.failure_note.len == 0) "" else r.failure_note,
    });
}
