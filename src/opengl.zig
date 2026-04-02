// OpenGL 1.1 and WGL bindings for Windows
// All functions are from opengl32.dll or gdi32.dll — no extension loading needed.

const BOOL = @import("std").os.windows.BOOL;

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

pub const HDC = ?*anyopaque;
pub const HGLRC = ?*anyopaque;

// --- Constants ---
pub const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;
pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_RGBA: GLint = 0x1908;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;
pub const GL_QUADS: GLenum = 0x0007;
pub const GL_BLEND: GLenum = 0x0BE2;
pub const GL_SRC_ALPHA: GLenum = 0x0302;
pub const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
pub const GL_NEAREST: GLint = 0x2600;
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_CLAMP: GLint = 0x2900;
pub const GL_PROJECTION: GLenum = 0x1701;
pub const GL_MODELVIEW: GLenum = 0x1700;

// --- OpenGL 1.1 functions (opengl32.dll) ---
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
pub extern "opengl32" fn glDeleteTextures(GLsizei, [*]const GLuint) callconv(.c) void;
pub extern "opengl32" fn glBegin(GLenum) callconv(.c) void;
pub extern "opengl32" fn glEnd() callconv(.c) void;
pub extern "opengl32" fn glVertex2f(GLfloat, GLfloat) callconv(.c) void;
pub extern "opengl32" fn glTexCoord2f(GLfloat, GLfloat) callconv(.c) void;
pub extern "opengl32" fn glColor3f(GLfloat, GLfloat, GLfloat) callconv(.c) void;
pub extern "opengl32" fn glColor4f(GLfloat, GLfloat, GLfloat, GLfloat) callconv(.c) void;

// --- WGL functions (opengl32.dll) ---
pub extern "opengl32" fn wglCreateContext(HDC) callconv(.c) HGLRC;
pub extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.c) BOOL;
pub extern "opengl32" fn wglMakeCurrent(HDC, HGLRC) callconv(.c) BOOL;

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
