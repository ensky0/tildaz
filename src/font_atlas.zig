const std = @import("std");
const gl = @import("opengl.zig");
const dw = @import("directwrite.zig");

const BOOL = std.os.windows.BOOL;
const BYTE = std.os.windows.BYTE;
const WCHAR = u16;
const LONG = c_long;

pub const GlyphUV = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const GlyphInfo = struct {
    uv: GlyphUV,
    cell_count: u8, // 1 = narrow, 2 = wide
    // Pixel offset from cell origin to actual glyph top-left
    offset_x: i8 = 0,
    offset_y: i8 = 0,
    // Actual glyph pixel dimensions (may differ from cell size)
    pixel_w: u8 = 0,
    pixel_h: u8 = 0,
};

const ATLAS_SIZE: u32 = 2048;

pub const FontAtlas = struct {
    texture_id: gl.GLuint = 0,
    cell_width: u32,
    cell_height: u32,

    // Dynamic glyph cache
    glyph_map: std.AutoHashMap(u21, GlyphInfo),
    fallback_glyph: GlyphInfo = undefined,

    // Packing cursor (variable row height for tight glyph bounds)
    pack_x: u32 = 0,
    pack_y: u32 = 0,
    pack_row_h: u32 = 0,

    // Alpha LUT (blend gamma correction from GetAlphaBlendParams)
    alpha_lut: [256]u8 = undefined,

    // DirectWrite rendering params (needed for GetAlphaBlendParams per glyph)
    dw_rendering_params: ?*dw.IDWriteRenderingParams = null,

    // DirectWrite resources
    dw_factory: ?*dw.IDWriteFactory = null,
    dw_factory2: ?*dw.IDWriteFactory2 = null,
    dw_font_collection: ?*dw.IDWriteFontCollection = null,
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
        };

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

        // 6. Get system rendering params (kept alive for GetAlphaBlendParams per glyph)
        {
            var sys_params: ?*dw.IDWriteRenderingParams = null;
            if (factory.?.CreateRenderingParams(&sys_params) >= 0) {
                self.dw_rendering_params = sys_params;
            }
        }

        // Default identity LUT — will be overwritten by first GetAlphaBlendParams call
        for (0..256) |lut_i| {
            self.alpha_lut[lut_i] = @intCast(lut_i);
        }

        // 7. Create number substitution (for MapCharacters callback)
        const locale = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
        var number_sub: ?*dw.IUnknown = null;
        _ = factory.?.CreateNumberSubstitution(dw.DWRITE_NUMBER_SUBSTITUTION_METHOD_NONE, locale, 0, &number_sub);
        self.dw_number_sub = number_sub;

        // 8. Create empty GL texture (2048x2048, RGB for ClearType subpixel data)
        gl.glGenTextures(1, @ptrCast(&self.texture_id));
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.texture_id);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
        gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
        gl.glTexImage2D(
            gl.GL_TEXTURE_2D,
            0,
            gl.GL_RGB,
            ATLAS_SIZE,
            ATLAS_SIZE,
            0,
            @intCast(gl.GL_RGB),
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
        if (self.dw_rendering_params) |rp| _ = rp.Release();
        if (self.dw_font_fallback) |fb| _ = fb.vtable.Release(fb);
        if (self.dw_number_sub) |ns| _ = ns.Release();
        if (self.dw_primary_font_face) |ff| _ = ff.vtable.Release(ff);
        if (self.dw_font_collection) |fc| _ = fc.vtable.Release(fc);
        if (self.dw_factory2) |f2| _ = f2.Release();
        if (self.dw_factory) |f| _ = f.Release();
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

        const factory = self.dw_factory orelse return null;
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

        if (glyph_index == 0) return null;

        // Construct glyph run
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

        // Create glyph run analysis — direct alpha extraction from rasterizer
        var analysis: ?*dw.IDWriteGlyphRunAnalysis = null;
        if (factory.CreateGlyphRunAnalysis(
            &glyph_run,
            1.0, // pixelsPerDip
            null, // no transform
            dw.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
            dw.DWRITE_MEASURING_MODE_NATURAL,
            0.0, // baselineOriginX
            self.dw_ascent_px, // baselineOriginY
            &analysis,
        ) < 0) return null;
        defer _ = analysis.?.Release();

        // Get actual glyph bounds from rasterizer (may extend beyond cell)
        var tex_bounds: dw.RECT = undefined;
        const has_pixels = analysis.?.GetAlphaTextureBounds(dw.DWRITE_TEXTURE_CLEARTYPE_3x1, &tex_bounds) >= 0 and
            tex_bounds.left < tex_bounds.right and tex_bounds.top < tex_bounds.bottom;

        // Get blend parameters from DirectWrite for accurate gamma correction
        var blend_lut: [256]u8 = undefined;
        const ct_level: f32 = 1.0; // Full ClearType subpixel rendering
        if (self.dw_rendering_params) |rp| {
            var blend_gamma: dw.FLOAT = 1.8;
            var blend_enhanced_contrast: dw.FLOAT = 0.5;
            var blend_clear_type_level: dw.FLOAT = 1.0;
            _ = analysis.?.GetAlphaBlendParams(rp, &blend_gamma, &blend_enhanced_contrast, &blend_clear_type_level);

            // Build LUT: enhanced contrast + inverse blend gamma for sRGB blending
            const inv_gamma = 1.0 / blend_gamma;
            for (0..256) |i| {
                var a: f32 = @as(f32, @floatFromInt(i)) / 255.0;
                a = @min(a + a * blend_enhanced_contrast, 1.0);
                a = std.math.pow(f32, a, inv_gamma);
                blend_lut[i] = @intCast(@min(@as(u32, @intFromFloat(a * 255.0 + 0.5)), 255));
            }
        } else {
            for (0..256) |i| blend_lut[i] = @intCast(i);
        }

        // Use actual glyph bounds from DirectWrite — no clipping
        var glyph_w: u32 = 1;
        var glyph_h: u32 = 1;
        var glyph_off_x: i32 = 0;
        var glyph_off_y: i32 = 0;

        if (has_pixels) {
            glyph_w = @intCast(tex_bounds.right - tex_bounds.left);
            glyph_h = @intCast(tex_bounds.bottom - tex_bounds.top);
            glyph_off_x = tex_bounds.left;
            glyph_off_y = tex_bounds.top;
        }

        // Check packing space with actual glyph dimensions
        if (self.pack_x + glyph_w > ATLAS_SIZE) {
            self.pack_x = 0;
            self.pack_y += self.pack_row_h;
            self.pack_row_h = 0;
        }
        if (self.pack_y + glyph_h > ATLAS_SIZE) {
            return null; // atlas full
        }
        if (glyph_h > self.pack_row_h) self.pack_row_h = glyph_h;

        // RGB output buffer — exact glyph size, no wasted space
        var rgb_buf: [3 * 256 * 256]u8 = undefined;
        const rgb_size = 3 * glyph_w * glyph_h;
        @memset(rgb_buf[0..rgb_size], 0);

        if (has_pixels) {
            const ct_buf_size: u32 = rgb_size; // ClearType 3x1 = same as RGB
            var ct_buf: [3 * 256 * 256]u8 = undefined;
            if (ct_buf_size <= ct_buf.len) {
                if (analysis.?.CreateAlphaTexture(
                    dw.DWRITE_TEXTURE_CLEARTYPE_3x1,
                    &tex_bounds,
                    &ct_buf,
                    ct_buf_size,
                ) >= 0) {
                    // Apply enhanced contrast LUT, then mix ClearType with grayscale
                    var i: u32 = 0;
                    while (i + 2 < rgb_size) : (i += 3) {
                        const r = blend_lut[ct_buf[i]];
                        const g = blend_lut[ct_buf[i + 1]];
                        const b = blend_lut[ct_buf[i + 2]];
                        // Grayscale alpha (average of R,G,B)
                        const gray: u8 = @intCast((@as(u16, r) + @as(u16, g) + @as(u16, b)) / 3);
                        // Mix: final = gray * (1 - ct_level) + channel * ct_level
                        const rf: f32 = @as(f32, @floatFromInt(gray)) * (1.0 - ct_level) + @as(f32, @floatFromInt(r)) * ct_level;
                        const gf: f32 = @as(f32, @floatFromInt(gray)) * (1.0 - ct_level) + @as(f32, @floatFromInt(g)) * ct_level;
                        const bf: f32 = @as(f32, @floatFromInt(gray)) * (1.0 - ct_level) + @as(f32, @floatFromInt(b)) * ct_level;
                        rgb_buf[i] = @intFromFloat(@min(rf, 255.0));
                        rgb_buf[i + 1] = @intFromFloat(@min(gf, 255.0));
                        rgb_buf[i + 2] = @intFromFloat(@min(bf, 255.0));
                    }
                }
            }
        }

        // Upload actual glyph pixels to atlas (tight bounds)
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.texture_id);
        gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
        gl.glTexSubImage2D(
            gl.GL_TEXTURE_2D,
            0,
            @intCast(self.pack_x),
            @intCast(self.pack_y),
            @intCast(glyph_w),
            @intCast(glyph_h),
            @intCast(gl.GL_RGB),
            gl.GL_UNSIGNED_BYTE,
            @ptrCast(&rgb_buf),
        );

        // UV and offset info for renderer
        const atlas_f: f32 = @floatFromInt(ATLAS_SIZE);
        const info = GlyphInfo{
            .uv = .{
                .u0 = @as(f32, @floatFromInt(self.pack_x)) / atlas_f,
                .v0 = @as(f32, @floatFromInt(self.pack_y)) / atlas_f,
                .u1 = @as(f32, @floatFromInt(self.pack_x + glyph_w)) / atlas_f,
                .v1 = @as(f32, @floatFromInt(self.pack_y + glyph_h)) / atlas_f,
            },
            .cell_count = if (is_wide) 2 else 1,
            .offset_x = @intCast(std.math.clamp(glyph_off_x, -128, 127)),
            .offset_y = @intCast(std.math.clamp(glyph_off_y, -128, 127)),
            .pixel_w = @intCast(@min(glyph_w, 255)),
            .pixel_h = @intCast(@min(glyph_h, 255)),
        };

        self.glyph_map.put(codepoint, info) catch {};
        self.pack_x += glyph_w;

        return info;
    }

};
