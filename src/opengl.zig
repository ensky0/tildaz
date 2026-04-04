// OpenGL bindings for Windows
// GL 1.1 functions from opengl32.dll (static), GL 3.3 functions via wglGetProcAddress (runtime).

const std = @import("std");
const BOOL = std.os.windows.BOOL;

// --- Types ---
pub const GLenum = c_uint;
pub const GLint = c_int;
pub const GLuint = c_uint;
pub const GLsizei = c_int;
pub const GLfloat = f32;
pub const GLdouble = f64;
pub const GLclampf = f32;
pub const GLbitfield = c_uint;
pub const GLubyte = u8;
pub const GLboolean = u8;
pub const GLchar = u8;
pub const GLsizeiptr = isize;
pub const GLintptr = isize;

pub const HDC = ?*anyopaque;
pub const HGLRC = ?*anyopaque;
pub const PROC = ?*const fn () callconv(.c) void;

// --- Constants (GL 1.1) ---
pub const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;
pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_RGBA: GLint = 0x1908;
pub const GL_RGB: GLint = 0x1907;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;
pub const GL_QUADS: GLenum = 0x0007;
pub const GL_BLEND: GLenum = 0x0BE2;
pub const GL_SRC_ALPHA: GLenum = 0x0302;
pub const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
pub const GL_ONE: GLenum = 0x0001;
pub const GL_ZERO: GLenum = 0x0000;
pub const GL_NEAREST: GLint = 0x2600;
pub const GL_LINEAR: GLint = 0x2601;
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_CLAMP: GLint = 0x2900;
pub const GL_CLAMP_TO_EDGE: GLint = 0x812F;

// Texture environment
pub const GL_TEXTURE_ENV: GLenum = 0x2300;
pub const GL_TEXTURE_ENV_MODE: GLenum = 0x2200;
pub const GL_TEXTURE_ENV_COLOR: GLenum = 0x2201;
pub const GL_MODULATE: GLint = 0x2100;
pub const GL_PROJECTION: GLenum = 0x1701;
pub const GL_MODELVIEW: GLenum = 0x1700;
pub const GL_TRIANGLES: GLenum = 0x0004;

// --- Constants (GL 2.0+ shaders) ---
pub const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
pub const GL_VERTEX_SHADER: GLenum = 0x8B31;
pub const GL_COMPILE_STATUS: GLenum = 0x8B81;
pub const GL_LINK_STATUS: GLenum = 0x8B82;
pub const GL_INFO_LOG_LENGTH: GLenum = 0x8B84;

// --- Constants (GL 1.5+ buffers) ---
pub const GL_ARRAY_BUFFER: GLenum = 0x8892;
pub const GL_ELEMENT_ARRAY_BUFFER: GLenum = 0x8893;
pub const GL_STATIC_DRAW: GLenum = 0x88E4;
pub const GL_DYNAMIC_DRAW: GLenum = 0x88E8;
pub const GL_STREAM_DRAW: GLenum = 0x88E0;

// --- Constants (GL 3.0+ sRGB) ---
pub const GL_FRAMEBUFFER_SRGB: GLenum = 0x8DB9;

// --- Constants (GL 3.0+ unpack) ---
pub const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;

// --- Constants (GL types) ---
pub const GL_FLOAT: GLenum = 0x1406;
pub const GL_FALSE: GLboolean = 0;
pub const GL_TRUE: GLboolean = 1;

// --- WGL context creation attribs ---
pub const WGL_CONTEXT_MAJOR_VERSION_ARB: c_int = 0x2091;
pub const WGL_CONTEXT_MINOR_VERSION_ARB: c_int = 0x2092;
pub const WGL_CONTEXT_PROFILE_MASK_ARB: c_int = 0x9126;
pub const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: c_int = 0x00000001;

// --- OpenGL 1.1 functions (opengl32.dll, static link) ---
pub extern "opengl32" fn glClearColor(GLclampf, GLclampf, GLclampf, GLclampf) callconv(.c) void;
pub extern "opengl32" fn glClear(GLbitfield) callconv(.c) void;
pub extern "opengl32" fn glEnable(GLenum) callconv(.c) void;
pub extern "opengl32" fn glDisable(GLenum) callconv(.c) void;
pub extern "opengl32" fn glBlendFunc(GLenum, GLenum) callconv(.c) void;
pub extern "opengl32" fn glViewport(GLint, GLint, GLsizei, GLsizei) callconv(.c) void;
pub extern "opengl32" fn glMatrixMode(GLenum) callconv(.c) void;
pub extern "opengl32" fn glLoadIdentity() callconv(.c) void;
pub extern "opengl32" fn glOrtho(GLdouble, GLdouble, GLdouble, GLdouble, GLdouble, GLdouble) callconv(.c) void;
pub extern "opengl32" fn glGenTextures(GLsizei, [*]GLuint) callconv(.c) void;
pub extern "opengl32" fn glBindTexture(GLenum, GLuint) callconv(.c) void;
pub extern "opengl32" fn glTexImage2D(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(.c) void;
pub extern "opengl32" fn glTexParameteri(GLenum, GLenum, GLint) callconv(.c) void;
pub extern "opengl32" fn glTexEnvi(GLenum, GLenum, GLint) callconv(.c) void;
pub extern "opengl32" fn glTexEnvfv(GLenum, GLenum, [*]const GLfloat) callconv(.c) void;
pub extern "opengl32" fn glDeleteTextures(GLsizei, [*]const GLuint) callconv(.c) void;
pub extern "opengl32" fn glTexSubImage2D(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*const anyopaque) callconv(.c) void;
pub extern "opengl32" fn glPixelStorei(GLenum, GLint) callconv(.c) void;
pub extern "opengl32" fn glGetError() callconv(.c) GLenum;
pub extern "opengl32" fn glGetString(GLenum) callconv(.c) ?[*:0]const GLubyte;
// Legacy immediate mode (kept for tab bar until ported)
pub extern "opengl32" fn glBegin(GLenum) callconv(.c) void;
pub extern "opengl32" fn glEnd() callconv(.c) void;
pub extern "opengl32" fn glVertex2f(GLfloat, GLfloat) callconv(.c) void;
pub extern "opengl32" fn glTexCoord2f(GLfloat, GLfloat) callconv(.c) void;
pub extern "opengl32" fn glColor3f(GLfloat, GLfloat, GLfloat) callconv(.c) void;
pub extern "opengl32" fn glColor4f(GLfloat, GLfloat, GLfloat, GLfloat) callconv(.c) void;

// --- WGL functions (opengl32.dll, static link) ---
pub extern "opengl32" fn wglCreateContext(HDC) callconv(.c) HGLRC;
pub extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.c) BOOL;
pub extern "opengl32" fn wglMakeCurrent(HDC, HGLRC) callconv(.c) BOOL;
pub extern "opengl32" fn wglGetProcAddress([*:0]const u8) callconv(.c) PROC;

// --- GDI pixel format functions (gdi32.dll) ---
pub extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.c) c_int;
pub extern "gdi32" fn SetPixelFormat(HDC, c_int, *const PIXELFORMATDESCRIPTOR) callconv(.c) BOOL;
pub extern "gdi32" fn SwapBuffers(HDC) callconv(.c) BOOL;

// --- PIXELFORMATDESCRIPTOR ---
pub const PFD_DRAW_TO_WINDOW: u32 = 0x00000004;
pub const PFD_SUPPORT_OPENGL: u32 = 0x00000020;
pub const PFD_DOUBLEBUFFER: u32 = 0x00000001;
pub const PFD_TYPE_RGBA: u8 = 0;
pub const PFD_MAIN_PLANE: u8 = 0;

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: u32 = 0,
    iPixelType: u8 = 0,
    cColorBits: u8 = 0,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: u32 = 0,
    dwVisibleMask: u32 = 0,
    dwDamageMask: u32 = 0,
};

// ============================================================================
// GL 3.3 runtime-loaded functions
// ============================================================================

pub const GlFuncs = struct {
    // Shaders
    createShader: *const fn (GLenum) callconv(.c) GLuint = undefined,
    shaderSource: *const fn (GLuint, GLsizei, [*]const [*:0]const GLchar, ?[*]const GLint) callconv(.c) void = undefined,
    compileShader: *const fn (GLuint) callconv(.c) void = undefined,
    getShaderiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void = undefined,
    getShaderInfoLog: *const fn (GLuint, GLsizei, ?*GLsizei, [*]GLchar) callconv(.c) void = undefined,
    deleteShader: *const fn (GLuint) callconv(.c) void = undefined,

    // Programs
    createProgram: *const fn () callconv(.c) GLuint = undefined,
    attachShader: *const fn (GLuint, GLuint) callconv(.c) void = undefined,
    linkProgram: *const fn (GLuint) callconv(.c) void = undefined,
    getProgramiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void = undefined,
    getProgramInfoLog: *const fn (GLuint, GLsizei, ?*GLsizei, [*]GLchar) callconv(.c) void = undefined,
    useProgram: *const fn (GLuint) callconv(.c) void = undefined,
    deleteProgram: *const fn (GLuint) callconv(.c) void = undefined,

    // Uniforms
    getUniformLocation: *const fn (GLuint, [*:0]const GLchar) callconv(.c) GLint = undefined,
    uniform1i: *const fn (GLint, GLint) callconv(.c) void = undefined,
    uniform2f: *const fn (GLint, GLfloat, GLfloat) callconv(.c) void = undefined,
    uniformMatrix4fv: *const fn (GLint, GLsizei, GLboolean, [*]const GLfloat) callconv(.c) void = undefined,

    // VAO
    genVertexArrays: *const fn (GLsizei, [*]GLuint) callconv(.c) void = undefined,
    bindVertexArray: *const fn (GLuint) callconv(.c) void = undefined,
    deleteVertexArrays: *const fn (GLsizei, [*]const GLuint) callconv(.c) void = undefined,

    // VBO
    genBuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void = undefined,
    bindBuffer: *const fn (GLenum, GLuint) callconv(.c) void = undefined,
    bufferData: *const fn (GLenum, GLsizeiptr, ?*const anyopaque, GLenum) callconv(.c) void = undefined,
    bufferSubData: *const fn (GLenum, GLintptr, GLsizeiptr, *const anyopaque) callconv(.c) void = undefined,
    deleteBuffers: *const fn (GLsizei, [*]const GLuint) callconv(.c) void = undefined,

    // Vertex attribs
    vertexAttribPointer: *const fn (GLuint, GLint, GLenum, GLboolean, GLsizei, ?*const anyopaque) callconv(.c) void = undefined,
    enableVertexAttribArray: *const fn (GLuint) callconv(.c) void = undefined,

    // Draw
    drawArrays: *const fn (GLenum, GLint, GLsizei) callconv(.c) void = undefined,

    // Active texture
    activeTexture: *const fn (GLenum) callconv(.c) void = undefined,

    pub fn load() !GlFuncs {
        var f: GlFuncs = .{};
        inline for (@typeInfo(GlFuncs).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "load")) continue;
            const name = comptime glName(field.name);
            const ptr = wglGetProcAddress(name) orelse return error.GlFuncNotFound;
            @field(f, field.name) = @ptrCast(ptr);
        }
        return f;
    }

    fn glName(comptime zig_name: []const u8) [*:0]const u8 {
        // Convert camelCase field name to GL function name with "gl" prefix
        // e.g. "createShader" -> "glCreateShader"
        comptime {
            const upper = [_]u8{zig_name[0] - 32};
            const full = "gl" ++ upper ++ zig_name[1..];
            return full ++ [_:0]u8{0};
        }
    }
};

/// wglCreateContextAttribsARB function type
pub const WglCreateContextAttribsARB = *const fn (HDC, HGLRC, ?[*]const c_int) callconv(.c) HGLRC;

/// Load wglCreateContextAttribsARB from the current GL context
pub fn loadWglCreateContextAttribsARB() ?WglCreateContextAttribsARB {
    const ptr = wglGetProcAddress("wglCreateContextAttribsARB") orelse return null;
    return @ptrCast(ptr);
}

// ============================================================================
// Shader compile/link helpers
// ============================================================================

pub fn compileShaderSource(f: *const GlFuncs, shader_type: GLenum, source: [*:0]const GLchar) !GLuint {
    const shader = f.createShader(shader_type);
    if (shader == 0) return error.ShaderCreateFailed;
    const sources = [_][*:0]const GLchar{source};
    f.shaderSource(shader, 1, &sources, null);
    f.compileShader(shader);
    var status: GLint = 0;
    f.getShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == 0) {
        var buf: [512]GLchar = undefined;
        f.getShaderInfoLog(shader, 512, null, &buf);
        std.log.err("Shader compile error: {s}", .{@as([*:0]const u8, @ptrCast(&buf))});
        f.deleteShader(shader);
        return error.ShaderCompileFailed;
    }
    return shader;
}

pub fn linkShaderProgram(f: *const GlFuncs, vert: GLuint, frag: GLuint) !GLuint {
    const program = f.createProgram();
    if (program == 0) return error.ProgramCreateFailed;
    f.attachShader(program, vert);
    f.attachShader(program, frag);
    f.linkProgram(program);
    var status: GLint = 0;
    f.getProgramiv(program, GL_LINK_STATUS, &status);
    if (status == 0) {
        var buf: [512]GLchar = undefined;
        f.getProgramInfoLog(program, 512, null, &buf);
        std.log.err("Program link error: {s}", .{@as([*:0]const u8, @ptrCast(&buf))});
        f.deleteProgram(program);
        return error.ProgramLinkFailed;
    }
    return program;
}
