//! Runtime libEGL / libGLESv2 wrapper — GPU 렌더 경로 ([#277](https://github.com/ensky0/tildaz/issues/277)).
//!
//! `libgbm` / `libfreetype` 과 같은 dlopen 패턴이다. 없으면 GPU 경로를 쓰지 않고
//! software `wl_shm` 으로 돈다 — 하드 링크 의존을 늘리지 않는다는 원칙 그대로다
//! (`ARCHITECTURE.md`).
//!
//! **window surface 를 만들지 않는다.** 우리 Wayland client 는 libwayland 를 쓰지
//! 않는 raw wire client 라 `wl_egl_window` 에 넘길 proxy 가 없다. 대신 GBM 으로
//! 할당한 dma-buf 를 `EGL_EXT_image_dma_buf_import` 로 가져와 FBO 의 color
//! attachment 로 쓴다 — surfaceless context (`EGL_KHR_surfaceless_context`) +
//! config 없는 context (`EGL_KHR_no_config_context`) 조합.

const std = @import("std");
const gbm = @import("gbm.zig");

pub const EGL_NONE: i32 = 0x3038;
pub const PLATFORM_GBM_KHR: u32 = 0x31D7;
pub const OPENGL_ES_API: u32 = 0x30A0;
pub const CONTEXT_MAJOR_VERSION: i32 = 0x3098;
pub const VENDOR: i32 = 0x3053;
pub const LINUX_DMA_BUF_EXT: u32 = 0x3270;
pub const WIDTH: i32 = 0x3057;
pub const HEIGHT: i32 = 0x3056;
pub const LINUX_DRM_FOURCC_EXT: i32 = 0x3271;
pub const DMA_BUF_PLANE0_FD_EXT: i32 = 0x3272;
pub const DMA_BUF_PLANE0_OFFSET_EXT: i32 = 0x3273;
pub const DMA_BUF_PLANE0_PITCH_EXT: i32 = 0x3274;
pub const DMA_BUF_PLANE0_MODIFIER_LO_EXT: i32 = 0x3443;
pub const DMA_BUF_PLANE0_MODIFIER_HI_EXT: i32 = 0x3444;

pub const GL_TEXTURE_2D: u32 = 0x0DE1;
pub const GL_FRAMEBUFFER: u32 = 0x8D40;
pub const GL_COLOR_ATTACHMENT0: u32 = 0x8CE0;
pub const GL_FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
pub const GL_COLOR_BUFFER_BIT: u32 = 0x4000;
pub const GL_TEXTURE_MIN_FILTER: u32 = 0x2801;
pub const GL_TEXTURE_MAG_FILTER: u32 = 0x2800;
pub const GL_NEAREST: i32 = 0x2600;
pub const GL_RENDERER: u32 = 0x1F01;
pub const GL_VERSION: u32 = 0x1F02;

pub const GL_VERTEX_SHADER: u32 = 0x8B31;
pub const GL_FRAGMENT_SHADER: u32 = 0x8B30;
pub const GL_COMPILE_STATUS: u32 = 0x8B81;
pub const GL_LINK_STATUS: u32 = 0x8B82;
pub const GL_ARRAY_BUFFER: u32 = 0x8892;
pub const GL_STREAM_DRAW: u32 = 0x88E0;
pub const GL_FLOAT: u32 = 0x1406;
pub const GL_TRIANGLES: u32 = 0x0004;
pub const GL_BLEND: u32 = 0x0BE2;

// 텍스처 — GLES2 코어 포맷만 쓴다. `GL_R8` 은 GLES3 이상이라 쓰지 않는다:
// grayscale 글리프는 `GL_ALPHA` (1 byte, 셰이더에서 `.a` 로 읽는다), 컬러 emoji 는
// `GL_RGBA` (FreeType 의 BGRA premultiplied 를 업로드 시 R/B 만 바꿔 넣는다 —
// GLES2 에는 `GL_BGRA` 가 없다).
pub const GL_ALPHA: i32 = 0x1906;
pub const GL_RGBA: i32 = 0x1908;
pub const GL_UNSIGNED_BYTE: u32 = 0x1401;
pub const GL_TEXTURE0: u32 = 0x84C0;
pub const GL_UNPACK_ALIGNMENT: u32 = 0x0CF5;
pub const GL_CLAMP_TO_EDGE: i32 = 0x812F;
pub const GL_TEXTURE_WRAP_S: u32 = 0x2802;
pub const GL_TEXTURE_WRAP_T: u32 = 0x2803;

// 블렌딩 — 셰이더가 **premultiplied** 색을 내보내므로 `ONE / ONE_MINUS_SRC_ALPHA`.
// 프레임버퍼가 비-sRGB 라 gamma space 에서 섞이고, 그게 software 경로의
// `blendPixel` (역시 gamma space 직선 블렌드) 과 같은 결과를 준다.
pub const GL_ONE: u32 = 1;
pub const GL_ONE_MINUS_SRC_ALPHA: u32 = 0x0303;

const EglGetProcAddress = *const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque;
const EglGetPlatformDisplay = *const fn (platform: u32, native: ?*anyopaque, attrs: ?[*]const isize) callconv(.c) ?*anyopaque;
const EglInitialize = *const fn (dpy: ?*anyopaque, major: ?*i32, minor: ?*i32) callconv(.c) c_uint;
const EglTerminate = *const fn (dpy: ?*anyopaque) callconv(.c) c_uint;
const EglBindApi = *const fn (api: u32) callconv(.c) c_uint;
const EglCreateContext = *const fn (dpy: ?*anyopaque, config: ?*anyopaque, share: ?*anyopaque, attrs: [*]const i32) callconv(.c) ?*anyopaque;
const EglDestroyContext = *const fn (dpy: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) c_uint;
const EglMakeCurrent = *const fn (dpy: ?*anyopaque, draw: ?*anyopaque, read: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) c_uint;
const EglQueryString = *const fn (dpy: ?*anyopaque, name: i32) callconv(.c) ?[*:0]const u8;
const EglGetError = *const fn () callconv(.c) i32;
const EglCreateImageKhr = *const fn (dpy: ?*anyopaque, ctx: ?*anyopaque, target: u32, buffer: ?*anyopaque, attrs: [*]const i32) callconv(.c) ?*anyopaque;
const EglDestroyImageKhr = *const fn (dpy: ?*anyopaque, image: ?*anyopaque) callconv(.c) c_uint;

const GlImageTargetTexture2DOes = *const fn (target: u32, image: ?*anyopaque) callconv(.c) void;
const GlGenTextures = *const fn (n: i32, out: [*]u32) callconv(.c) void;
const GlDeleteTextures = *const fn (n: i32, items: [*]const u32) callconv(.c) void;
const GlBindTexture = *const fn (target: u32, tex: u32) callconv(.c) void;
const GlTexParameteri = *const fn (target: u32, pname: u32, param: i32) callconv(.c) void;
const GlGenFramebuffers = *const fn (n: i32, out: [*]u32) callconv(.c) void;
const GlDeleteFramebuffers = *const fn (n: i32, items: [*]const u32) callconv(.c) void;
const GlBindFramebuffer = *const fn (target: u32, fb: u32) callconv(.c) void;
const GlFramebufferTexture2D = *const fn (target: u32, attachment: u32, textarget: u32, tex: u32, level: i32) callconv(.c) void;
const GlCheckFramebufferStatus = *const fn (target: u32) callconv(.c) u32;
const GlViewport = *const fn (x: i32, y: i32, w: i32, h: i32) callconv(.c) void;
const GlClearColor = *const fn (r: f32, g: f32, b: f32, a: f32) callconv(.c) void;
const GlClear = *const fn (mask: u32) callconv(.c) void;
const GlFlush = *const fn () callconv(.c) void;
const GlFinish = *const fn () callconv(.c) void;
const GlGetString = *const fn (name: u32) callconv(.c) ?[*:0]const u8;
const GlGetError = *const fn () callconv(.c) u32;

const GlCreateShader = *const fn (kind: u32) callconv(.c) u32;
const GlShaderSource = *const fn (shader: u32, count: i32, strings: [*]const [*:0]const u8, lengths: ?[*]const i32) callconv(.c) void;
const GlCompileShader = *const fn (shader: u32) callconv(.c) void;
const GlGetShaderiv = *const fn (shader: u32, pname: u32, out: *i32) callconv(.c) void;
const GlGetShaderInfoLog = *const fn (shader: u32, max: i32, len: ?*i32, out: [*]u8) callconv(.c) void;
const GlDeleteShader = *const fn (shader: u32) callconv(.c) void;
const GlCreateProgram = *const fn () callconv(.c) u32;
const GlAttachShader = *const fn (program: u32, shader: u32) callconv(.c) void;
const GlLinkProgram = *const fn (program: u32) callconv(.c) void;
const GlGetProgramiv = *const fn (program: u32, pname: u32, out: *i32) callconv(.c) void;
const GlGetProgramInfoLog = *const fn (program: u32, max: i32, len: ?*i32, out: [*]u8) callconv(.c) void;
const GlDeleteProgram = *const fn (program: u32) callconv(.c) void;
const GlUseProgram = *const fn (program: u32) callconv(.c) void;
const GlGetUniformLocation = *const fn (program: u32, name: [*:0]const u8) callconv(.c) i32;
const GlUniform2f = *const fn (location: i32, x: f32, y: f32) callconv(.c) void;
const GlBindAttribLocation = *const fn (program: u32, index: u32, name: [*:0]const u8) callconv(.c) void;
const GlGenBuffers = *const fn (n: i32, out: [*]u32) callconv(.c) void;
const GlDeleteBuffers = *const fn (n: i32, items: [*]const u32) callconv(.c) void;
const GlBindBuffer = *const fn (target: u32, buffer: u32) callconv(.c) void;
const GlBufferData = *const fn (target: u32, size: isize, data: ?*const anyopaque, usage: u32) callconv(.c) void;
const GlEnableVertexAttribArray = *const fn (index: u32) callconv(.c) void;
const GlVertexAttribPointer = *const fn (index: u32, size: i32, kind: u32, normalized: u8, stride: i32, offset: ?*const anyopaque) callconv(.c) void;
const GlDrawArrays = *const fn (mode: u32, first: i32, count: i32) callconv(.c) void;
const GlDisable = *const fn (cap: u32) callconv(.c) void;
const GlTexImage2D = *const fn (target: u32, level: i32, internal: i32, w: i32, h: i32, border: i32, format: u32, kind: u32, pixels: ?*const anyopaque) callconv(.c) void;
const GlTexSubImage2D = *const fn (target: u32, level: i32, x: i32, y: i32, w: i32, h: i32, format: u32, kind: u32, pixels: ?*const anyopaque) callconv(.c) void;
const GlPixelStorei = *const fn (pname: u32, param: i32) callconv(.c) void;
const GlActiveTexture = *const fn (unit: u32) callconv(.c) void;
const GlUniform1i = *const fn (location: i32, value: i32) callconv(.c) void;
const GlBlendFunc = *const fn (src: u32, dst: u32) callconv(.c) void;

pub const Api = struct {
    egl_handle: *anyopaque,
    gles_handle: *anyopaque,

    getProcAddress: EglGetProcAddress,
    getPlatformDisplay: EglGetPlatformDisplay,
    initialize: EglInitialize,
    terminate: EglTerminate,
    bindApi: EglBindApi,
    createContext: EglCreateContext,
    destroyContext: EglDestroyContext,
    makeCurrent: EglMakeCurrent,
    queryString: EglQueryString,
    getError: EglGetError,
    createImage: EglCreateImageKhr,
    destroyImage: EglDestroyImageKhr,

    imageTargetTexture2D: GlImageTargetTexture2DOes,
    genTextures: GlGenTextures,
    deleteTextures: GlDeleteTextures,
    bindTexture: GlBindTexture,
    texParameteri: GlTexParameteri,
    genFramebuffers: GlGenFramebuffers,
    deleteFramebuffers: GlDeleteFramebuffers,
    bindFramebuffer: GlBindFramebuffer,
    framebufferTexture2D: GlFramebufferTexture2D,
    checkFramebufferStatus: GlCheckFramebufferStatus,
    viewport: GlViewport,
    clearColor: GlClearColor,
    clear: GlClear,
    flush: GlFlush,
    finish: GlFinish,
    getString: GlGetString,
    glGetError: GlGetError,

    createShader: GlCreateShader,
    shaderSource: GlShaderSource,
    compileShader: GlCompileShader,
    getShaderiv: GlGetShaderiv,
    getShaderInfoLog: GlGetShaderInfoLog,
    deleteShader: GlDeleteShader,
    createProgram: GlCreateProgram,
    attachShader: GlAttachShader,
    linkProgram: GlLinkProgram,
    getProgramiv: GlGetProgramiv,
    getProgramInfoLog: GlGetProgramInfoLog,
    deleteProgram: GlDeleteProgram,
    useProgram: GlUseProgram,
    getUniformLocation: GlGetUniformLocation,
    uniform2f: GlUniform2f,
    bindAttribLocation: GlBindAttribLocation,
    genBuffers: GlGenBuffers,
    deleteBuffers: GlDeleteBuffers,
    bindBuffer: GlBindBuffer,
    bufferData: GlBufferData,
    enableVertexAttribArray: GlEnableVertexAttribArray,
    vertexAttribPointer: GlVertexAttribPointer,
    drawArrays: GlDrawArrays,
    disable: GlDisable,
    texImage2D: GlTexImage2D,
    texSubImage2D: GlTexSubImage2D,
    pixelStorei: GlPixelStorei,
    activeTexture: GlActiveTexture,
    uniform1i: GlUniform1i,
    blendFunc: GlBlendFunc,

    pub fn load() !Api {
        const egl_handle = std.c.dlopen("libEGL.so.1", .{ .LAZY = true }) orelse return error.EglLibraryMissing;
        errdefer _ = std.c.dlclose(egl_handle);
        const gles_handle = std.c.dlopen("libGLESv2.so.2", .{ .LAZY = true }) orelse return error.GlesLibraryMissing;
        errdefer _ = std.c.dlclose(gles_handle);

        const get_proc = lookup(egl_handle, EglGetProcAddress, "eglGetProcAddress") orelse return error.EglSymbolMissing;
        // 확장 진입점은 eglGetProcAddress 로 얻는다 — libglvnd 경유 시 라이브러리에
        // 직접 심볼이 없을 수 있다.
        const create_image = get_proc("eglCreateImageKHR") orelse return error.EglImageExtensionMissing;
        const destroy_image = get_proc("eglDestroyImageKHR") orelse return error.EglImageExtensionMissing;
        const image_target = get_proc("glEGLImageTargetTexture2DOES") orelse return error.GlImageExtensionMissing;

        return .{
            .egl_handle = egl_handle,
            .gles_handle = gles_handle,
            .getProcAddress = get_proc,
            .getPlatformDisplay = lookup(egl_handle, EglGetPlatformDisplay, "eglGetPlatformDisplay") orelse return error.EglSymbolMissing,
            .initialize = lookup(egl_handle, EglInitialize, "eglInitialize") orelse return error.EglSymbolMissing,
            .terminate = lookup(egl_handle, EglTerminate, "eglTerminate") orelse return error.EglSymbolMissing,
            .bindApi = lookup(egl_handle, EglBindApi, "eglBindAPI") orelse return error.EglSymbolMissing,
            .createContext = lookup(egl_handle, EglCreateContext, "eglCreateContext") orelse return error.EglSymbolMissing,
            .destroyContext = lookup(egl_handle, EglDestroyContext, "eglDestroyContext") orelse return error.EglSymbolMissing,
            .makeCurrent = lookup(egl_handle, EglMakeCurrent, "eglMakeCurrent") orelse return error.EglSymbolMissing,
            .queryString = lookup(egl_handle, EglQueryString, "eglQueryString") orelse return error.EglSymbolMissing,
            .getError = lookup(egl_handle, EglGetError, "eglGetError") orelse return error.EglSymbolMissing,
            // `eglGetProcAddress` 는 `*anyopaque` (정렬 1) 를 돌려주는데 함수
            // 포인터는 aarch64 에서 정렬 4 다. `@alignCast` 없이 캐스팅하면
            // x86_64 에서만 컴파일된다 (`zig build check` 의 aarch64 타겟이 잡음).
            .createImage = @ptrCast(@alignCast(create_image)),
            .destroyImage = @ptrCast(@alignCast(destroy_image)),
            .imageTargetTexture2D = @ptrCast(@alignCast(image_target)),
            .genTextures = lookup(gles_handle, GlGenTextures, "glGenTextures") orelse return error.GlSymbolMissing,
            .deleteTextures = lookup(gles_handle, GlDeleteTextures, "glDeleteTextures") orelse return error.GlSymbolMissing,
            .bindTexture = lookup(gles_handle, GlBindTexture, "glBindTexture") orelse return error.GlSymbolMissing,
            .texParameteri = lookup(gles_handle, GlTexParameteri, "glTexParameteri") orelse return error.GlSymbolMissing,
            .genFramebuffers = lookup(gles_handle, GlGenFramebuffers, "glGenFramebuffers") orelse return error.GlSymbolMissing,
            .deleteFramebuffers = lookup(gles_handle, GlDeleteFramebuffers, "glDeleteFramebuffers") orelse return error.GlSymbolMissing,
            .bindFramebuffer = lookup(gles_handle, GlBindFramebuffer, "glBindFramebuffer") orelse return error.GlSymbolMissing,
            .framebufferTexture2D = lookup(gles_handle, GlFramebufferTexture2D, "glFramebufferTexture2D") orelse return error.GlSymbolMissing,
            .checkFramebufferStatus = lookup(gles_handle, GlCheckFramebufferStatus, "glCheckFramebufferStatus") orelse return error.GlSymbolMissing,
            .viewport = lookup(gles_handle, GlViewport, "glViewport") orelse return error.GlSymbolMissing,
            .clearColor = lookup(gles_handle, GlClearColor, "glClearColor") orelse return error.GlSymbolMissing,
            .clear = lookup(gles_handle, GlClear, "glClear") orelse return error.GlSymbolMissing,
            .flush = lookup(gles_handle, GlFlush, "glFlush") orelse return error.GlSymbolMissing,
            .finish = lookup(gles_handle, GlFinish, "glFinish") orelse return error.GlSymbolMissing,
            .getString = lookup(gles_handle, GlGetString, "glGetString") orelse return error.GlSymbolMissing,
            .glGetError = lookup(gles_handle, GlGetError, "glGetError") orelse return error.GlSymbolMissing,
            .createShader = lookup(gles_handle, GlCreateShader, "glCreateShader") orelse return error.GlSymbolMissing,
            .shaderSource = lookup(gles_handle, GlShaderSource, "glShaderSource") orelse return error.GlSymbolMissing,
            .compileShader = lookup(gles_handle, GlCompileShader, "glCompileShader") orelse return error.GlSymbolMissing,
            .getShaderiv = lookup(gles_handle, GlGetShaderiv, "glGetShaderiv") orelse return error.GlSymbolMissing,
            .getShaderInfoLog = lookup(gles_handle, GlGetShaderInfoLog, "glGetShaderInfoLog") orelse return error.GlSymbolMissing,
            .deleteShader = lookup(gles_handle, GlDeleteShader, "glDeleteShader") orelse return error.GlSymbolMissing,
            .createProgram = lookup(gles_handle, GlCreateProgram, "glCreateProgram") orelse return error.GlSymbolMissing,
            .attachShader = lookup(gles_handle, GlAttachShader, "glAttachShader") orelse return error.GlSymbolMissing,
            .linkProgram = lookup(gles_handle, GlLinkProgram, "glLinkProgram") orelse return error.GlSymbolMissing,
            .getProgramiv = lookup(gles_handle, GlGetProgramiv, "glGetProgramiv") orelse return error.GlSymbolMissing,
            .getProgramInfoLog = lookup(gles_handle, GlGetProgramInfoLog, "glGetProgramInfoLog") orelse return error.GlSymbolMissing,
            .deleteProgram = lookup(gles_handle, GlDeleteProgram, "glDeleteProgram") orelse return error.GlSymbolMissing,
            .useProgram = lookup(gles_handle, GlUseProgram, "glUseProgram") orelse return error.GlSymbolMissing,
            .getUniformLocation = lookup(gles_handle, GlGetUniformLocation, "glGetUniformLocation") orelse return error.GlSymbolMissing,
            .uniform2f = lookup(gles_handle, GlUniform2f, "glUniform2f") orelse return error.GlSymbolMissing,
            .bindAttribLocation = lookup(gles_handle, GlBindAttribLocation, "glBindAttribLocation") orelse return error.GlSymbolMissing,
            .genBuffers = lookup(gles_handle, GlGenBuffers, "glGenBuffers") orelse return error.GlSymbolMissing,
            .deleteBuffers = lookup(gles_handle, GlDeleteBuffers, "glDeleteBuffers") orelse return error.GlSymbolMissing,
            .bindBuffer = lookup(gles_handle, GlBindBuffer, "glBindBuffer") orelse return error.GlSymbolMissing,
            .bufferData = lookup(gles_handle, GlBufferData, "glBufferData") orelse return error.GlSymbolMissing,
            .enableVertexAttribArray = lookup(gles_handle, GlEnableVertexAttribArray, "glEnableVertexAttribArray") orelse return error.GlSymbolMissing,
            .vertexAttribPointer = lookup(gles_handle, GlVertexAttribPointer, "glVertexAttribPointer") orelse return error.GlSymbolMissing,
            .drawArrays = lookup(gles_handle, GlDrawArrays, "glDrawArrays") orelse return error.GlSymbolMissing,
            .disable = lookup(gles_handle, GlDisable, "glDisable") orelse return error.GlSymbolMissing,
            .texImage2D = lookup(gles_handle, GlTexImage2D, "glTexImage2D") orelse return error.GlSymbolMissing,
            .texSubImage2D = lookup(gles_handle, GlTexSubImage2D, "glTexSubImage2D") orelse return error.GlSymbolMissing,
            .pixelStorei = lookup(gles_handle, GlPixelStorei, "glPixelStorei") orelse return error.GlSymbolMissing,
            .activeTexture = lookup(gles_handle, GlActiveTexture, "glActiveTexture") orelse return error.GlSymbolMissing,
            .uniform1i = lookup(gles_handle, GlUniform1i, "glUniform1i") orelse return error.GlSymbolMissing,
            .blendFunc = lookup(gles_handle, GlBlendFunc, "glBlendFunc") orelse return error.GlSymbolMissing,
        };
    }

    pub fn deinit(self: *Api) void {
        _ = std.c.dlclose(self.gles_handle);
        _ = std.c.dlclose(self.egl_handle);
    }
};

fn lookup(handle: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
    const symbol = std.c.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(symbol));
}

/// 초기화된 EGL display + surfaceless GLES context 한 벌.
pub const Context = struct {
    api: Api,
    display: *anyopaque,
    context: *anyopaque,

    /// GBM device 위에 surfaceless GLES2 context 를 만든다. 실패는 전부 null —
    /// 호출처가 software 경로로 떨어진다.
    pub fn create(device: *anyopaque) ?Context {
        var api = Api.load() catch return null;
        errdefer api.deinit();

        const display = api.getPlatformDisplay(PLATFORM_GBM_KHR, device, null) orelse {
            api.deinit();
            return null;
        };
        var major: i32 = 0;
        var minor: i32 = 0;
        if (api.initialize(display, &major, &minor) == 0) {
            api.deinit();
            return null;
        }
        if (api.bindApi(OPENGL_ES_API) == 0) {
            _ = api.terminate(display);
            api.deinit();
            return null;
        }
        // config 없이 만든다 (`EGL_KHR_no_config_context`) — FBO 에만 그리므로
        // window surface 용 config 가 의미 없다.
        const attrs = [_]i32{ CONTEXT_MAJOR_VERSION, 2, EGL_NONE };
        const context = api.createContext(display, null, null, &attrs) orelse {
            _ = api.terminate(display);
            api.deinit();
            return null;
        };
        if (api.makeCurrent(display, null, null, context) == 0) {
            _ = api.destroyContext(display, context);
            _ = api.terminate(display);
            api.deinit();
            return null;
        }
        return .{ .api = api, .display = display, .context = context };
    }

    pub fn deinit(self: *Context) void {
        _ = self.api.makeCurrent(self.display, null, null, null);
        _ = self.api.destroyContext(self.display, self.context);
        _ = self.api.terminate(self.display);
        self.api.deinit();
    }

    pub fn rendererName(self: *const Context) []const u8 {
        return span(self.api.getString(GL_RENDERER));
    }

    pub fn versionName(self: *const Context) []const u8 {
        return span(self.api.getString(GL_VERSION));
    }

    /// dma-buf 를 EGLImage 로 가져와 texture 에 붙이고 FBO 의 color attachment 로
    /// 만든다. 성공하면 `Target`, 아니면 null.
    ///
    /// **modifier 마다 되고 안 되고가 갈린다.** AMD 실측에서 DCC(압축) modifier 는
    /// 할당은 되지만 이 import 가 `EGL_BAD_MATCH` 로 실패했다. 그래서 호출처는
    /// 후보를 순회하며 되는 것을 고른다 (`negotiate`).
    pub fn importAsTarget(self: *const Context, fd: std.posix.fd_t, bo: gbm.Bo) ?Target {
        const attrs = [_]i32{
            WIDTH,                          @intCast(bo.width),
            HEIGHT,                         @intCast(bo.height),
            LINUX_DRM_FOURCC_EXT,           @bitCast(gbm.FORMAT_ARGB8888),
            DMA_BUF_PLANE0_FD_EXT,          fd,
            DMA_BUF_PLANE0_OFFSET_EXT,      @intCast(bo.offset),
            DMA_BUF_PLANE0_PITCH_EXT,       @intCast(bo.stride),
            DMA_BUF_PLANE0_MODIFIER_LO_EXT, @bitCast(@as(u32, @truncate(bo.modifier & 0xffff_ffff))),
            DMA_BUF_PLANE0_MODIFIER_HI_EXT, @bitCast(@as(u32, @truncate(bo.modifier >> 32))),
            EGL_NONE,
        };
        const image = self.api.createImage(self.display, null, LINUX_DMA_BUF_EXT, null, &attrs) orelse return null;

        var texture: u32 = 0;
        self.api.genTextures(1, @ptrCast(&texture));
        self.api.bindTexture(GL_TEXTURE_2D, texture);
        self.api.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        self.api.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        self.api.imageTargetTexture2D(GL_TEXTURE_2D, image);

        var framebuffer: u32 = 0;
        self.api.genFramebuffers(1, @ptrCast(&framebuffer));
        self.api.bindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        self.api.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
        if (self.api.checkFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            self.api.deleteFramebuffers(1, @ptrCast(&framebuffer));
            self.api.deleteTextures(1, @ptrCast(&texture));
            _ = self.api.destroyImage(self.display, image);
            return null;
        }
        return .{ .image = image, .texture = texture, .framebuffer = framebuffer };
    }

    pub fn destroyTarget(self: *const Context, target: Target) void {
        var fb = target.framebuffer;
        var tex = target.texture;
        self.api.deleteFramebuffers(1, @ptrCast(&fb));
        self.api.deleteTextures(1, @ptrCast(&tex));
        _ = self.api.destroyImage(self.display, target.image);
    }
};

/// dma-buf 하나에 대응하는 GL 렌더 타깃.
pub const Target = struct {
    image: *anyopaque,
    texture: u32,
    framebuffer: u32,
};

fn span(p: ?[*:0]const u8) []const u8 {
    return if (p) |s| std.mem.span(s) else "(unknown)";
}
