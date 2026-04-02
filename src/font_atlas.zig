const std = @import("std");
const gl = @import("opengl.zig");

const BOOL = std.os.windows.BOOL;
const DWORD = std.os.windows.DWORD;
const BYTE = std.os.windows.BYTE;
const WCHAR = u16;
const LONG = c_long;
const HDC = ?*anyopaque;
const HBITMAP = ?*anyopaque;
const HGDIOBJ = ?*anyopaque;
const HFONT = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const COLORREF = DWORD;

const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: LONG = 0,
    biHeight: LONG = 0,
    biPlanes: u16 = 1,
    biBitCount: u16 = 0,
    biCompression: DWORD = 0, // BI_RGB
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: LONG = 0,
    biYPelsPerMeter: LONG = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]DWORD = .{0},
};

const DIB_RGB_COLORS: c_uint = 0;
const TRANSPARENT: c_int = 1;
const CLEARTYPE_QUALITY: DWORD = 5;
const FW_NORMAL: c_int = 400;
const DEFAULT_CHARSET: DWORD = 1;
const OUT_DEFAULT_PRECIS: DWORD = 0;
const CLIP_DEFAULT_PRECIS: DWORD = 0;
const FIXED_PITCH: DWORD = 1;
const FF_MODERN: DWORD = 0x30;

extern "gdi32" fn CreateCompatibleDC(HDC) callconv(.c) HDC;
extern "gdi32" fn DeleteDC(HDC) callconv(.c) BOOL;
extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.c) HGDIOBJ;
extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.c) BOOL;
extern "gdi32" fn CreateDIBSection(HDC, *const BITMAPINFO, c_uint, *?[*]BYTE, ?*anyopaque, DWORD) callconv(.c) HBITMAP;
extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(.c) COLORREF;
extern "gdi32" fn SetBkMode(HDC, c_int) callconv(.c) c_int;
extern "gdi32" fn TextOutW(HDC, c_int, c_int, [*]const WCHAR, c_int) callconv(.c) BOOL;
extern "gdi32" fn CreateSolidBrush(COLORREF) callconv(.c) HBRUSH;
extern "gdi32" fn FillRect(HDC, *const RECT, HBRUSH) callconv(.c) c_int;
extern "gdi32" fn CreateFontW(c_int, c_int, c_int, c_int, c_int, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, [*:0]const WCHAR) callconv(.c) HFONT;

fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}

pub const GlyphUV = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

const GLYPH_COUNT = 95; // ASCII 32..126
const COLS_PER_ROW = 16;
const GLYPH_ROWS = (GLYPH_COUNT + COLS_PER_ROW - 1) / COLS_PER_ROW; // 6

pub const FontAtlas = struct {
    texture_id: gl.GLuint = 0,
    atlas_width: u32,
    atlas_height: u32,
    cell_width: u32,
    cell_height: u32,
    glyph_uvs: [GLYPH_COUNT]GlyphUV = undefined,

    pub fn init(font_family: [*:0]const WCHAR, font_height: c_int, cell_w: u32, cell_h: u32) !FontAtlas {
        var self = FontAtlas{
            .atlas_width = COLS_PER_ROW * cell_w,
            .atlas_height = GLYPH_ROWS * cell_h,
            .cell_width = cell_w,
            .cell_height = cell_h,
        };

        const aw: f32 = @floatFromInt(self.atlas_width);
        const ah: f32 = @floatFromInt(self.atlas_height);

        // Create GDI DIB section for rasterizing glyphs
        var bmi = BITMAPINFO{
            .bmiHeader = .{
                .biWidth = @intCast(self.atlas_width),
                .biHeight = -@as(LONG, @intCast(self.atlas_height)), // top-down
                .biBitCount = 32,
            },
        };

        var bits_ptr: ?[*]BYTE = null;
        const hbmp = CreateDIBSection(null, &bmi, DIB_RGB_COLORS, &bits_ptr, null, 0);
        if (hbmp == null) return error.CreateDIBSectionFailed;
        defer _ = DeleteObject(hbmp);

        const dc = CreateCompatibleDC(null);
        if (dc == null) return error.CreateDCFailed;
        defer _ = DeleteDC(dc);

        const old_bmp = SelectObject(dc, hbmp);
        defer _ = SelectObject(dc, old_bmp);

        // Create font with grayscale antialiasing (not ClearType — avoids color fringes in atlas)
        const atlas_font = CreateFontW(
            font_height, 0, 0, 0, FW_NORMAL, 0, 0, 0,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, FIXED_PITCH | FF_MODERN,
            font_family,
        );
        if (atlas_font == null) return error.CreateFontFailed;
        defer _ = DeleteObject(atlas_font);

        const old_font = SelectObject(dc, atlas_font);
        defer _ = SelectObject(dc, old_font);

        // Fill background black
        const fill_rect = RECT{
            .left = 0,
            .top = 0,
            .right = @intCast(self.atlas_width),
            .bottom = @intCast(self.atlas_height),
        };
        const black_brush = CreateSolidBrush(rgb(0, 0, 0));
        _ = FillRect(dc, &fill_rect, black_brush);
        _ = DeleteObject(black_brush);

        _ = SetBkMode(dc, TRANSPARENT);
        _ = SetTextColor(dc, rgb(255, 255, 255));

        // Render each ASCII glyph
        for (0..GLYPH_COUNT) |i| {
            const c: u16 = @intCast(i + 32);
            const col: u32 = @intCast(i % COLS_PER_ROW);
            const row: u32 = @intCast(i / COLS_PER_ROW);
            const x: c_int = @intCast(col * cell_w);
            const y: c_int = @intCast(row * cell_h);

            var wchar: [1]WCHAR = .{c};
            _ = TextOutW(dc, x, y, &wchar, 1);

            // Compute UV coordinates
            const fx: f32 = @floatFromInt(col * cell_w);
            const fy: f32 = @floatFromInt(row * cell_h);
            const fw: f32 = @floatFromInt(cell_w);
            const fh: f32 = @floatFromInt(cell_h);
            self.glyph_uvs[i] = .{
                .u0 = fx / aw,
                .v0 = fy / ah,
                .u1 = (fx + fw) / aw,
                .v1 = (fy + fh) / ah,
            };
        }

        // Convert BGRA → RGBA and compute alpha from ClearType subpixels
        // ClearType renders separate R/G/B coverage. We use max(R,G,B) as
        // the alpha to preserve sharpness while avoiding color fringes.
        const pixel_data: [*]BYTE = bits_ptr.?;
        const total_bytes = self.atlas_width * self.atlas_height * 4;
        var idx: usize = 0;
        while (idx < total_bytes) : (idx += 4) {
            const b = pixel_data[idx];
            const g = pixel_data[idx + 1];
            const r = pixel_data[idx + 2];
            const alpha = @max(r, @max(g, b));
            pixel_data[idx] = 255; // R (white — tinted by glColor at render time)
            pixel_data[idx + 1] = 255; // G
            pixel_data[idx + 2] = 255; // B
            pixel_data[idx + 3] = alpha; // A = max coverage
        }

        // Upload as GL texture
        gl.glGenTextures(1, @ptrCast(&self.texture_id));
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.texture_id);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP);
        gl.glTexImage2D(
            gl.GL_TEXTURE_2D,
            0,
            gl.GL_RGBA,
            @intCast(self.atlas_width),
            @intCast(self.atlas_height),
            0,
            @intCast(gl.GL_RGBA),
            gl.GL_UNSIGNED_BYTE,
            @ptrCast(pixel_data),
        );

        return self;
    }

    pub fn deinit(self: *FontAtlas) void {
        if (self.texture_id != 0) {
            gl.glDeleteTextures(1, @ptrCast(&self.texture_id));
            self.texture_id = 0;
        }
    }

    pub fn getUV(self: *const FontAtlas, codepoint: u21) GlyphUV {
        if (codepoint >= 32 and codepoint <= 126) {
            return self.glyph_uvs[codepoint - 32];
        }
        // Fallback: '?' glyph
        return self.glyph_uvs['?' - 32];
    }
};
