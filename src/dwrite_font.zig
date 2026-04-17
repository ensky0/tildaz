// DirectWrite font context — GL/D2D independent.
// Extracted from font_atlas.zig for use with Direct2D renderer.

const std = @import("std");
const dw = @import("directwrite.zig");

const BOOL = std.os.windows.BOOL;
const WCHAR = u16;

pub const GlyphResult = struct {
    face: *dw.IDWriteFontFace,
    index: dw.UINT16,
    owned: bool, // true = caller must Release face
};

const CachedGlyph = struct {
    face: *dw.IDWriteFontFace,
    index: u16,
};

pub const DWriteFontContext = struct {
    alloc: std.mem.Allocator,
    factory: *dw.IDWriteFactory,
    factory2: ?*dw.IDWriteFactory2 = null,
    font_collection: *dw.IDWriteFontCollection,
    font_fallback: ?*dw.IDWriteFontFallback = null,
    primary_font_face: *dw.IDWriteFontFace,
    rendering_params: ?*dw.IDWriteRenderingParams = null,
    number_sub: ?*dw.IUnknown = null,
    primary_family_name: [64]WCHAR = undefined,
    primary_family_len: u32 = 0,
    font_em_size: f32 = 0,
    ascent_px: f32 = 0,
    cell_width: u32,
    cell_height: u32,
    // Caches (codepoint → face/index). Keeps fallback faces alive so atlas
    // cache keys — which use the face pointer — remain stable.
    glyph_map: std.AutoHashMap(u21, CachedGlyph),

    pub fn init(alloc: std.mem.Allocator, font_family: [*:0]const WCHAR, font_height: c_int, cell_w: u32, cell_h: u32) !DWriteFontContext {
        // 1. Create DWrite factory
        var factory: ?*dw.IDWriteFactory = null;
        if (dw.DWriteCreateFactory(dw.DWRITE_FACTORY_TYPE_SHARED, &dw.IID_IDWriteFactory, @ptrCast(&factory)) < 0)
            return error.DWriteFactoryFailed;
        errdefer _ = factory.?.vtable.Release(factory.?);

        // 2. Get system font collection
        var collection: ?*dw.IDWriteFontCollection = null;
        if (factory.?.GetSystemFontCollection(&collection, 0) < 0) return error.FontCollectionFailed;

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

        var self = DWriteFontContext{
            .alloc = alloc,
            .factory = factory.?,
            .font_collection = collection.?,
            .primary_font_face = font_face.?,
            .cell_width = cell_w,
            .cell_height = cell_h,
            .glyph_map = std.AutoHashMap(u21, CachedGlyph).init(alloc),
        };

        // Store family name for MapCharacters
        var i: u32 = 0;
        while (font_family[i] != 0) : (i += 1) {
            if (i >= 63) break;
            self.primary_family_name[i] = font_family[i];
        }
        self.primary_family_name[i] = 0;
        self.primary_family_len = i;

        // 4. Calculate em size from font metrics
        var metrics: dw.DWRITE_FONT_METRICS = undefined;
        font_face.?.GetMetrics(&metrics);
        const du_per_em: f32 = @floatFromInt(metrics.designUnitsPerEm);
        const ascent: f32 = @floatFromInt(metrics.ascent);
        const descent: f32 = @floatFromInt(metrics.descent);
        const abs_height: f32 = @floatFromInt(if (font_height < 0) -font_height else font_height);
        self.font_em_size = abs_height * du_per_em / (ascent + descent);
        self.ascent_px = abs_height * ascent / (ascent + descent);

        // 5. Get IDWriteFactory2 for system font fallback
        var factory2: ?*dw.IDWriteFactory2 = null;
        if (factory.?.QueryInterface(&dw.IID_IDWriteFactory2, @ptrCast(&factory2)) >= 0) {
            self.factory2 = factory2;
            var fallback: ?*dw.IDWriteFontFallback = null;
            if (factory2.?.GetSystemFontFallback(&fallback) >= 0) {
                self.font_fallback = fallback;
            }
        }

        // 6. Get system rendering params
        {
            var sys_params: ?*dw.IDWriteRenderingParams = null;
            if (factory.?.CreateRenderingParams(&sys_params) >= 0) {
                self.rendering_params = sys_params;
            }
        }

        // 7. Create number substitution (for MapCharacters callback)
        const locale = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
        var number_sub: ?*dw.IUnknown = null;
        _ = factory.?.CreateNumberSubstitution(dw.DWRITE_NUMBER_SUBSTITUTION_METHOD_NONE, locale, 0, &number_sub);
        self.number_sub = number_sub;

        return self;
    }

    pub fn deinit(self: *DWriteFontContext) void {
        // Release all fallback faces retained in the glyph cache. Primary face
        // is never stored in the cache, so no double-release risk.
        var it = self.glyph_map.valueIterator();
        while (it.next()) |v| {
            _ = v.face.vtable.Release(v.face);
        }
        self.glyph_map.deinit();
        if (self.rendering_params) |rp| _ = rp.Release();
        if (self.font_fallback) |fb| _ = fb.vtable.Release(fb);
        if (self.number_sub) |ns| _ = ns.Release();
        _ = self.primary_font_face.vtable.Release(self.primary_font_face);
        _ = self.font_collection.vtable.Release(self.font_collection);
        if (self.factory2) |f2| _ = f2.Release();
        _ = self.factory.Release();
    }

    /// Resolve a codepoint to (font_face, glyph_index). Uses system font fallback.
    /// Faces are cached for process lifetime so their pointer addresses remain
    /// stable — the glyph atlas keys on face pointer, so pointer reuse after
    /// Release would cause false cache hits across different fonts.
    /// `owned` is always false; the context retains ownership.
    pub fn resolveGlyph(self: *DWriteFontContext, codepoint: u21) ?GlyphResult {
        if (self.glyph_map.get(codepoint)) |c| {
            return .{ .face = c.face, .index = c.index, .owned = false };
        }

        const cp32: dw.UINT32 = codepoint;
        var glyph_index: dw.UINT16 = 0;
        _ = self.primary_font_face.GetGlyphIndices(@ptrCast(&cp32), 1, @ptrCast(&glyph_index));

        if (glyph_index != 0) {
            // Primary face is stable (never freed), so skip cache to avoid
            // double-Release in deinit.
            return .{ .face = self.primary_font_face, .index = glyph_index, .owned = false };
        }

        // Fallback via MapCharacters
        if (self.font_fallback) |fallback| {
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

            var source = dw.SimpleTextAnalysisSource.create(&wchar_buf, wchar_len, self.number_sub);
            var mapped_length: dw.UINT32 = 0;
            var mapped_font: ?*dw.IDWriteFont = null;
            var scale: dw.FLOAT = 1.0;
            const family_ptr: ?[*:0]const WCHAR = @ptrCast(&self.primary_family_name);

            if (fallback.MapCharacters(
                @ptrCast(&source),
                0,
                wchar_len,
                self.font_collection,
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
                                // Retain the face in the cache; ownership stays with the context.
                                // This keeps the face pointer stable for the atlas cache key.
                                self.glyph_map.put(codepoint, .{ .face = face, .index = glyph_index }) catch {
                                    // On put failure, release to avoid leak and return owned.
                                    return .{ .face = face, .index = glyph_index, .owned = true };
                                };
                                return .{ .face = face, .index = glyph_index, .owned = false };
                            }
                            _ = face.vtable.Release(face);
                        }
                    }
                }
            }
        }

        return null;
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
};
