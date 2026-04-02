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
    biCompression: DWORD = 0,
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
const ANTIALIASED_QUALITY: DWORD = 4;
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

pub const GlyphInfo = struct {
    uv: GlyphUV,
    cell_count: u8, // 1 = narrow, 2 = wide
};

const ATLAS_SIZE: u32 = 2048;

pub const FontAtlas = struct {
    texture_id: gl.GLuint = 0,
    cell_width: u32,
    cell_height: u32,

    // Dynamic glyph cache
    glyph_map: std.AutoHashMap(u21, GlyphInfo),
    fallback_glyph: GlyphInfo = undefined,

    // Packing cursor
    pack_x: u32 = 0,
    pack_y: u32 = 0,

    // Persistent GDI resources for on-demand rasterization
    scratch_dc: HDC = null,
    scratch_bmp: HBITMAP = null,
    scratch_bits: ?[*]BYTE = null,
    scratch_font: HFONT = null,
    scratch_old_bmp: HGDIOBJ = null,
    scratch_old_font: HGDIOBJ = null,
    scratch_width: u32 = 0, // 2 * cell_width
    black_brush: HBRUSH = null,

    pub fn init(alloc: std.mem.Allocator, font_family: [*:0]const WCHAR, font_height: c_int, cell_w: u32, cell_h: u32) !FontAtlas {
        var self = FontAtlas{
            .cell_width = cell_w,
            .cell_height = cell_h,
            .glyph_map = std.AutoHashMap(u21, GlyphInfo).init(alloc),
            .scratch_width = 2 * cell_w,
        };
        errdefer self.glyph_map.deinit();

        // Create scratch DIB for individual glyph rasterization (wide = 2 * cell_w)
        var bmi = BITMAPINFO{
            .bmiHeader = .{
                .biWidth = @intCast(self.scratch_width),
                .biHeight = -@as(LONG, @intCast(cell_h)), // top-down
                .biBitCount = 32,
            },
        };

        self.scratch_bmp = CreateDIBSection(null, &bmi, DIB_RGB_COLORS, &self.scratch_bits, null, 0);
        if (self.scratch_bmp == null) return error.CreateDIBSectionFailed;
        errdefer _ = DeleteObject(self.scratch_bmp);

        self.scratch_dc = CreateCompatibleDC(null);
        if (self.scratch_dc == null) return error.CreateDCFailed;
        errdefer _ = DeleteDC(self.scratch_dc);

        self.scratch_old_bmp = SelectObject(self.scratch_dc, self.scratch_bmp);

        // Create font with grayscale antialiasing
        self.scratch_font = CreateFontW(
            font_height, 0, 0, 0, FW_NORMAL, 0, 0, 0,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            ANTIALIASED_QUALITY, FIXED_PITCH | FF_MODERN,
            font_family,
        );
        if (self.scratch_font == null) return error.CreateFontFailed;
        errdefer _ = DeleteObject(self.scratch_font);

        self.scratch_old_font = SelectObject(self.scratch_dc, self.scratch_font);

        _ = SetBkMode(self.scratch_dc, TRANSPARENT);
        _ = SetTextColor(self.scratch_dc, rgb(255, 255, 255));

        self.black_brush = CreateSolidBrush(rgb(0, 0, 0));

        // Create empty GL texture (2048x2048)
        gl.glGenTextures(1, @ptrCast(&self.texture_id));
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.texture_id);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP);
        gl.glTexImage2D(
            gl.GL_TEXTURE_2D,
            0,
            gl.GL_RGBA,
            ATLAS_SIZE,
            ATLAS_SIZE,
            0,
            @intCast(gl.GL_RGBA),
            gl.GL_UNSIGNED_BYTE,
            null, // empty texture
        );

        // Pre-render fallback '?' glyph
        self.fallback_glyph = self.renderGlyph('?', false) orelse GlyphInfo{
            .uv = .{ .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0 },
            .cell_count = 1,
        };

        return self;
    }

    pub fn deinit(self: *FontAtlas) void {
        if (self.texture_id != 0) {
            gl.glDeleteTextures(1, @ptrCast(&self.texture_id));
            self.texture_id = 0;
        }
        // Restore and free GDI resources
        if (self.scratch_dc != null) {
            if (self.scratch_old_font != null) _ = SelectObject(self.scratch_dc, self.scratch_old_font);
            if (self.scratch_old_bmp != null) _ = SelectObject(self.scratch_dc, self.scratch_old_bmp);
            _ = DeleteDC(self.scratch_dc);
        }
        if (self.scratch_font != null) _ = DeleteObject(self.scratch_font);
        if (self.scratch_bmp != null) _ = DeleteObject(self.scratch_bmp);
        if (self.black_brush != null) _ = DeleteObject(self.black_brush);
        self.glyph_map.deinit();
    }

    /// Get or render a glyph. Returns GlyphInfo with UV coordinates and cell count.
    pub fn getOrRenderGlyph(self: *FontAtlas, codepoint: u21, is_wide: bool) GlyphInfo {
        if (self.glyph_map.get(codepoint)) |info| return info;
        return self.renderGlyph(codepoint, is_wide) orelse self.fallback_glyph;
    }

    /// Backward-compatible getUV for tab bar (always narrow)
    pub fn getUV(self: *FontAtlas, codepoint: u21) GlyphUV {
        return self.getOrRenderGlyph(codepoint, false).uv;
    }

    fn renderGlyph(self: *FontAtlas, codepoint: u21, is_wide: bool) ?GlyphInfo {
        const cell_w = self.cell_width;
        const cell_h = self.cell_height;
        const glyph_width: u32 = if (is_wide) 2 * cell_w else cell_w;

        // Check packing space
        if (self.pack_x + glyph_width > ATLAS_SIZE) {
            self.pack_x = 0;
            self.pack_y += cell_h;
        }
        if (self.pack_y + cell_h > ATLAS_SIZE) {
            return null; // atlas full
        }

        // Clear scratch DIB region
        const clear_rect = RECT{
            .left = 0,
            .top = 0,
            .right = @intCast(glyph_width),
            .bottom = @intCast(cell_h),
        };
        _ = FillRect(self.scratch_dc, &clear_rect, self.black_brush);

        // Encode codepoint as UTF-16
        var wchar_buf: [2]WCHAR = undefined;
        var wchar_len: c_int = undefined;
        if (codepoint <= 0xFFFF) {
            wchar_buf[0] = @intCast(codepoint);
            wchar_len = 1;
        } else {
            // Surrogate pair for U+10000+
            const cp = codepoint - 0x10000;
            wchar_buf[0] = @intCast(0xD800 + (cp >> 10));
            wchar_buf[1] = @intCast(0xDC00 + (cp & 0x3FF));
            wchar_len = 2;
        }

        // Render glyph via GDI
        _ = TextOutW(self.scratch_dc, 0, 0, &wchar_buf, wchar_len);

        // Convert BGRA → white+alpha in scratch buffer
        const bits = self.scratch_bits orelse return null;
        const stride = self.scratch_width * 4;
        var row_idx: u32 = 0;
        while (row_idx < cell_h) : (row_idx += 1) {
            var col_idx: u32 = 0;
            while (col_idx < glyph_width) : (col_idx += 1) {
                const idx = row_idx * stride + col_idx * 4;
                const b = bits[idx];
                const g = bits[idx + 1];
                const r = bits[idx + 2];
                const alpha = @max(r, @max(g, b));
                bits[idx] = 255;
                bits[idx + 1] = 255;
                bits[idx + 2] = 255;
                bits[idx + 3] = alpha;
            }
        }

        // Upload to GL texture via glTexSubImage2D
        // We need to upload row-by-row or use a contiguous buffer.
        // Since scratch_width may be wider than glyph_width, we upload the exact region.
        // glTexSubImage2D reads from contiguous memory with the given width,
        // but our scratch DIB has stride = scratch_width. For narrow glyphs (glyph_width < scratch_width),
        // we need to account for the stride.
        if (glyph_width == self.scratch_width) {
            // Full width of scratch, upload directly
            gl.glBindTexture(gl.GL_TEXTURE_2D, self.texture_id);
            gl.glTexSubImage2D(
                gl.GL_TEXTURE_2D,
                0,
                @intCast(self.pack_x),
                @intCast(self.pack_y),
                @intCast(glyph_width),
                @intCast(cell_h),
                @intCast(gl.GL_RGBA),
                gl.GL_UNSIGNED_BYTE,
                @ptrCast(bits),
            );
        } else {
            // Upload row by row for narrow glyphs (scratch is wider than glyph)
            gl.glBindTexture(gl.GL_TEXTURE_2D, self.texture_id);
            var y: u32 = 0;
            while (y < cell_h) : (y += 1) {
                const row_ptr: [*]const BYTE = bits + y * stride;
                gl.glTexSubImage2D(
                    gl.GL_TEXTURE_2D,
                    0,
                    @intCast(self.pack_x),
                    @intCast(self.pack_y + y),
                    @intCast(glyph_width),
                    1,
                    @intCast(gl.GL_RGBA),
                    gl.GL_UNSIGNED_BYTE,
                    @ptrCast(row_ptr),
                );
            }
        }

        // Compute UV coordinates
        const atlas_f: f32 = @floatFromInt(ATLAS_SIZE);
        const info = GlyphInfo{
            .uv = .{
                .u0 = @as(f32, @floatFromInt(self.pack_x)) / atlas_f,
                .v0 = @as(f32, @floatFromInt(self.pack_y)) / atlas_f,
                .u1 = @as(f32, @floatFromInt(self.pack_x + glyph_width)) / atlas_f,
                .v1 = @as(f32, @floatFromInt(self.pack_y + cell_h)) / atlas_f,
            },
            .cell_count = if (is_wide) 2 else 1,
        };

        self.glyph_map.put(codepoint, info) catch {};
        self.pack_x += glyph_width;

        return info;
    }
};
