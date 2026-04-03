const std = @import("std");
const gl = @import("opengl.zig");
const dw = @import("directwrite.zig");

const BOOL = std.os.windows.BOOL;
const BYTE = std.os.windows.BYTE;
const WCHAR = u16;
const LONG = c_long;
const HDC = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const COLORREF = u32;

const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

extern "gdi32" fn DeleteObject(?*anyopaque) callconv(.c) BOOL;
extern "gdi32" fn CreateSolidBrush(COLORREF) callconv(.c) HBRUSH;
extern "user32" fn FillRect(HDC, *const RECT, HBRUSH) callconv(.c) c_int;

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

    // GDI resources (used with DirectWrite render target)
    scratch_dc: HDC = null,
    scratch_bits: ?[*]BYTE = null,
    scratch_width: u32 = 0, // 2 * cell_width
    black_brush: HBRUSH = null,

    // Alpha LUT (identity — DirectWrite handles gamma internally)
    alpha_lut: [256]u8 = undefined,

    // DirectWrite resources
    dw_factory: ?*dw.IDWriteFactory = null,
    dw_factory2: ?*dw.IDWriteFactory2 = null,
    dw_font_collection: ?*dw.IDWriteFontCollection = null,
    dw_gdi_interop: ?*dw.IDWriteGdiInterop = null,
    dw_render_target: ?*dw.IDWriteBitmapRenderTarget = null,
    dw_rendering_params: ?*dw.IDWriteRenderingParams = null,
    dw_font_fallback: ?*dw.IDWriteFontFallback = null,
    dw_number_sub: ?*dw.IUnknown = null,
    dw_primary_font_face: ?*dw.IDWriteFontFace = null,
    dw_primary_family_name: [64]WCHAR = undefined,
    dw_primary_family_len: u32 = 0,
    dw_font_em_size: f32 = 0,
    dw_ascent_px: f32 = 0,

    pub fn init(alloc: std.mem.Allocator, font_family: [*:0]const WCHAR, font_height: c_int, cell_w: u32, cell_h: u32) !FontAtlas {
        var self = FontAtlas{
            .cell_width = cell_w,
            .cell_height = cell_h,
            .glyph_map = std.AutoHashMap(u21, GlyphInfo).init(alloc),
            .scratch_width = 2 * cell_w,
        };

        // Identity LUT — DirectWrite rendering params handle gamma
        for (0..256) |i| {
            self.alpha_lut[i] = @intCast(i);
        }
        errdefer self.glyph_map.deinit();

        // --- DirectWrite initialization ---

        // 1. Create DWrite factory
        var factory: ?*dw.IDWriteFactory = null;
        if (dw.DWriteCreateFactory(dw.DWRITE_FACTORY_TYPE_SHARED, &dw.IID_IDWriteFactory, @ptrCast(&factory)) < 0)
            return error.DWriteFactoryFailed;
        self.dw_factory = factory;
        errdefer {
            _ = factory.?.vtable.Release(factory.?);
            self.dw_factory = null;
        }

        // 2. Get system font collection
        var collection: ?*dw.IDWriteFontCollection = null;
        if (factory.?.GetSystemFontCollection(&collection, 0) < 0) return error.FontCollectionFailed;
        self.dw_font_collection = collection;

        // 3. Find and create primary font face
        var family_index: dw.UINT32 = 0;
        var exists: BOOL = 0;
        if (collection.?.FindFamilyName(font_family, &family_index, &exists) < 0 or exists == 0)
            return error.FontNotFound;

        var font_family_obj: ?*dw.IDWriteFontFamily = null;
        if (collection.?.GetFontFamily(family_index, &font_family_obj) < 0) return error.FontFamilyFailed;
        defer _ = font_family_obj.?.vtable.Release(font_family_obj.?);

        var dw_font: ?*dw.IDWriteFont = null;
        if (font_family_obj.?.GetFirstMatchingFont(
            dw.DWRITE_FONT_WEIGHT_NORMAL,
            dw.DWRITE_FONT_STRETCH_NORMAL,
            dw.DWRITE_FONT_STYLE_NORMAL,
            &dw_font,
        ) < 0) return error.FontMatchFailed;
        defer _ = dw_font.?.vtable.Release(dw_font.?);

        var font_face: ?*dw.IDWriteFontFace = null;
        if (dw_font.?.CreateFontFace(&font_face) < 0) return error.FontFaceFailed;
        self.dw_primary_font_face = font_face;

        // Store family name for MapCharacters
        var i: u32 = 0;
        while (font_family[i] != 0) : (i += 1) {
            if (i >= 63) break;
            self.dw_primary_family_name[i] = font_family[i];
        }
        self.dw_primary_family_name[i] = 0;
        self.dw_primary_family_len = i;

        // 4. Calculate em size from font metrics
        // Match GDI cell height: emSize so that ascent+descent fits in abs_height pixels.
        var metrics: dw.DWRITE_FONT_METRICS = undefined;
        font_face.?.GetMetrics(&metrics);
        const du_per_em: f32 = @floatFromInt(metrics.designUnitsPerEm);
        const ascent: f32 = @floatFromInt(metrics.ascent);
        const descent: f32 = @floatFromInt(metrics.descent);
        const abs_height: f32 = @floatFromInt(if (font_height < 0) -font_height else font_height);
        self.dw_font_em_size = abs_height * du_per_em / (ascent + descent);
        self.dw_ascent_px = abs_height * ascent / (ascent + descent);

        // 5. Get IDWriteFactory2 for system font fallback
        var factory2: ?*dw.IDWriteFactory2 = null;
        if (factory.?.QueryInterface(&dw.IID_IDWriteFactory2, @ptrCast(&factory2)) >= 0) {
            self.dw_factory2 = factory2;
            var fallback: ?*dw.IDWriteFontFallback = null;
            if (factory2.?.GetSystemFontFallback(&fallback) >= 0) {
                self.dw_font_fallback = fallback;
            }
        }

        // 6. Create GDI interop + bitmap render target
        var gdi_interop: ?*dw.IDWriteGdiInterop = null;
        if (factory.?.GetGdiInterop(&gdi_interop) < 0) return error.GdiInteropFailed;
        self.dw_gdi_interop = gdi_interop;

        var render_target: ?*dw.IDWriteBitmapRenderTarget = null;
        if (gdi_interop.?.CreateBitmapRenderTarget(null, self.scratch_width, cell_h, &render_target) < 0)
            return error.RenderTargetFailed;
        self.dw_render_target = render_target;

        // 7. Create rendering params (grayscale AA: clearTypeLevel=0)
        var rendering_params: ?*dw.IDWriteRenderingParams = null;
        if (factory.?.CreateCustomRenderingParams(
            1.0, // gamma
            0.0, // enhancedContrast
            0.0, // clearTypeLevel — 0 = grayscale AA
            dw.DWRITE_PIXEL_GEOMETRY_FLAT,
            dw.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
            &rendering_params,
        ) < 0) return error.RenderingParamsFailed;
        self.dw_rendering_params = rendering_params;

        // 8. Create number substitution (for MapCharacters callback)
        const locale = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
        var number_sub: ?*dw.IUnknown = null;
        _ = factory.?.CreateNumberSubstitution(dw.DWRITE_NUMBER_SUBSTITUTION_METHOD_NONE, locale, 0, &number_sub);
        self.dw_number_sub = number_sub;

        // 9. Extract DC and bitmap pointer from render target
        self.scratch_dc = render_target.?.GetMemoryDC();
        if (self.scratch_dc == null) return error.GetMemoryDCFailed;

        // Get bitmap bits from the render target's DC
        const hbmp = dw.GetCurrentObject(self.scratch_dc, dw.OBJ_BITMAP);
        if (hbmp) |bmp_handle| {
            var bmp: dw.BITMAP = undefined;
            if (dw.GetObjectW(bmp_handle, @sizeOf(dw.BITMAP), @ptrCast(&bmp)) > 0) {
                self.scratch_bits = @ptrCast(bmp.bmBits);
            }
        }
        if (self.scratch_bits == null) return error.BitmapBitsFailed;

        self.black_brush = CreateSolidBrush(rgb(0, 0, 0));

        // Create empty GL texture (2048x2048)
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
        // Release DirectWrite COM resources
        if (self.dw_render_target) |rt| _ = rt.vtable.Release(rt);
        if (self.dw_rendering_params) |rp| _ = rp.Release();
        if (self.dw_gdi_interop) |gi| _ = gi.vtable.Release(gi);
        if (self.dw_font_fallback) |fb| _ = fb.vtable.Release(fb);
        if (self.dw_number_sub) |ns| _ = ns.Release();
        if (self.dw_primary_font_face) |ff| _ = ff.vtable.Release(ff);
        if (self.dw_font_collection) |fc| _ = fc.vtable.Release(fc);
        if (self.dw_factory2) |f2| _ = f2.Release();
        if (self.dw_factory) |f| _ = f.Release();
        // scratch_dc is owned by render target — don't DeleteDC
        if (self.black_brush != null) _ = DeleteObject(self.black_brush);
        self.glyph_map.deinit();
    }

    /// No-op: DirectWrite MapCharacters handles system font fallback automatically.
    pub fn addFallbackFont(self: *FontAtlas, family: [*:0]const WCHAR, font_height: c_int) void {
        _ = self;
        _ = family;
        _ = font_height;
    }

    /// Check if a font family is installed on the system via DirectWrite.
    pub fn isFontAvailable(family: [*:0]const WCHAR) bool {
        var factory: ?*dw.IDWriteFactory = null;
        if (dw.DWriteCreateFactory(dw.DWRITE_FACTORY_TYPE_SHARED, &dw.IID_IDWriteFactory, @ptrCast(&factory)) < 0) return false;
        defer _ = factory.?.vtable.Release(factory.?);

        var collection: ?*dw.IDWriteFontCollection = null;
        if (factory.?.GetSystemFontCollection(&collection, 0) < 0) return false;
        defer _ = collection.?.vtable.Release(collection.?);

        var index: dw.UINT32 = 0;
        var exists: std.os.windows.BOOL = 0;
        if (collection.?.FindFamilyName(family, &index, &exists) < 0) return false;
        return exists != 0;
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

        // Clear scratch bitmap region
        const clear_rect = RECT{
            .left = 0,
            .top = 0,
            .right = @intCast(glyph_width),
            .bottom = @intCast(cell_h),
        };
        _ = FillRect(self.scratch_dc, &clear_rect, self.black_brush);

        const render_target = self.dw_render_target orelse return null;
        const rendering_params = self.dw_rendering_params orelse return null;
        const primary_face = self.dw_primary_font_face orelse return null;

        // Get glyph index from primary font
        const cp32: dw.UINT32 = codepoint;
        var glyph_index: dw.UINT16 = 0;
        _ = primary_face.GetGlyphIndices(@ptrCast(&cp32), 1, @ptrCast(&glyph_index));

        var face_to_use: *dw.IDWriteFontFace = primary_face;
        var fallback_face: ?*dw.IDWriteFontFace = null;
        defer {
            if (fallback_face) |ff| _ = ff.vtable.Release(ff);
        }

        // If primary font doesn't have the glyph, use MapCharacters for fallback
        if (glyph_index == 0) {
            if (self.dw_font_fallback) |fallback| {
                // Encode codepoint as UTF-16 for MapCharacters
                var wchar_buf: [2]WCHAR = undefined;
                var wchar_len: dw.UINT32 = undefined;
                if (codepoint <= 0xFFFF) {
                    wchar_buf[0] = @intCast(codepoint);
                    wchar_len = 1;
                } else {
                    const cp = codepoint - 0x10000;
                    wchar_buf[0] = @intCast(0xD800 + (cp >> 10));
                    wchar_buf[1] = @intCast(0xDC00 + (cp & 0x3FF));
                    wchar_len = 2;
                }

                var source = dw.SimpleTextAnalysisSource.create(&wchar_buf, wchar_len, self.dw_number_sub);
                var mapped_length: dw.UINT32 = 0;
                var mapped_font: ?*dw.IDWriteFont = null;
                var scale: dw.FLOAT = 1.0;
                const family_ptr: ?[*:0]const WCHAR = @ptrCast(&self.dw_primary_family_name);

                if (fallback.MapCharacters(
                    @ptrCast(&source),
                    0,
                    wchar_len,
                    self.dw_font_collection,
                    family_ptr,
                    dw.DWRITE_FONT_WEIGHT_NORMAL,
                    dw.DWRITE_FONT_STYLE_NORMAL,
                    dw.DWRITE_FONT_STRETCH_NORMAL,
                    &mapped_length,
                    &mapped_font,
                    &scale,
                ) >= 0) {
                    if (mapped_font) |mf| {
                        defer _ = mf.vtable.Release(mf);
                        var mf_face: ?*dw.IDWriteFontFace = null;
                        if (mf.CreateFontFace(&mf_face) >= 0) {
                            if (mf_face) |face| {
                                _ = face.GetGlyphIndices(@ptrCast(&cp32), 1, @ptrCast(&glyph_index));
                                if (glyph_index != 0) {
                                    fallback_face = face;
                                    face_to_use = face;
                                } else {
                                    _ = face.vtable.Release(face);
                                }
                            }
                        }
                    }
                }
            }
        }

        // If no font has the glyph, return null → shows '?' fallback instead of .notdef box
        if (glyph_index == 0) return null;

        // Construct glyph run and render via DirectWrite
        var glyph_run = dw.DWRITE_GLYPH_RUN{
            .fontFace = face_to_use,
            .fontEmSize = self.dw_font_em_size,
            .glyphCount = 1,
            .glyphIndices = @ptrCast(&glyph_index),
            .glyphAdvances = null,
            .glyphOffsets = null,
            .isSideways = 0,
            .bidiLevel = 0,
        };

        _ = render_target.DrawGlyphRun(
            0.0,
            self.dw_ascent_px,
            dw.DWRITE_MEASURING_MODE_NATURAL,
            &glyph_run,
            rendering_params,
            0x00FFFFFF, // white text
            null,
        );

        const bits = self.scratch_bits orelse return null;
        const stride = self.scratch_width * 4;

        // Convert BGRA → white+alpha in scratch buffer
        var row_idx: u32 = 0;
        while (row_idx < cell_h) : (row_idx += 1) {
            var col_idx: u32 = 0;
            while (col_idx < glyph_width) : (col_idx += 1) {
                const idx = row_idx * stride + col_idx * 4;
                const b = bits[idx];
                const g = bits[idx + 1];
                const r = bits[idx + 2];
                const alpha = self.alpha_lut[@max(r, @max(g, b))];
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
