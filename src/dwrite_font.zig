// DirectWrite font context — GL/D2D independent.
// Extracted from font_atlas.zig for use with Direct2D renderer.

const std = @import("std");
const dw = @import("directwrite.zig");

const BOOL = std.os.windows.BOOL;
const WCHAR = u16;

/// font.family chain 의 최대 길이. config.MAX_FONT_FAMILIES 와 동등 — 동기화
/// 유지 (cross-module hardcoded 8).
pub const MAX_CHAIN: usize = 8;

pub const GlyphResult = struct {
    face: *dw.IDWriteFontFace,
    index: dw.UINT16,
    owned: bool, // true = caller must Release face
};

/// ZWJ family / VS-16 / skin tone modifier cluster 의 multi-glyph 결과 (#139).
/// Segoe UI Emoji 가 family ZWJ chain 을 single glyph 로 GSUB 합성 못 하면
/// `count > 1` 의 multi-glyph cluster 반환. atlas 가 multi-glyph DrawGlyphRun
/// 으로 한 번에 그려서 single composite glyph 로 cache.
pub const MAX_CLUSTER_GLYPHS: usize = 16;
pub const ClusterResult = struct {
    face: *dw.IDWriteFontFace,
    indices: [MAX_CLUSTER_GLYPHS]dw.UINT16,
    advances: [MAX_CLUSTER_GLYPHS]dw.FLOAT,
    offsets: [MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET,
    count: u8,
    owned: bool,
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
    /// Grapheme cluster shaping (#134) — VS-16 / skin tone modifier / ZWJ
    /// 시퀀스를 OpenType GSUB 로 단일 cluster glyph 로 reduce. macOS 의 CTLine
    /// 동등.
    text_analyzer: ?*dw.IDWriteTextAnalyzer = null,
    /// font.family chain — `[0]` 이 primary (cell metric / MapCharacters 의 base).
    /// chain entry 마다 IDWriteFontFace 보관, resolveGlyph 가 codepoint 별로
    /// 순회해서 글리프 가진 첫 face 반환. 모든 face 는 process 전체 lifetime
    /// 안정 (deinit 까지 Release 안 함) — atlas cache key 가 face 포인터라
    /// 안정성 필수.
    chain_faces: [MAX_CHAIN]?*dw.IDWriteFontFace = .{null} ** MAX_CHAIN,
    chain_count: u8 = 0,
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

    pub fn init(
        alloc: std.mem.Allocator,
        font_chain: []const [*:0]const WCHAR,
        font_height: c_int,
        cell_w: u32,
        cell_h: u32,
    ) !DWriteFontContext {
        if (font_chain.len == 0) return error.EmptyFontChain;
        // 1. Create DWrite factory
        var factory: ?*dw.IDWriteFactory = null;
        if (dw.DWriteCreateFactory(dw.DWRITE_FACTORY_TYPE_SHARED, &dw.IID_IDWriteFactory, @ptrCast(&factory)) < 0)
            return error.DWriteFactoryFailed;
        errdefer _ = factory.?.vtable.Release(factory.?);

        // 2. Get system font collection
        var collection: ?*dw.IDWriteFontCollection = null;
        if (factory.?.GetSystemFontCollection(&collection, 0) < 0) return error.FontCollectionFailed;
        errdefer _ = collection.?.vtable.Release(collection.?);

        // 3. chain entry 마다 face 생성. caller 가 사전 검증 (windows_host 의
        //    isFontAvailable loop) 했지만 race 방지 위해 여기서도 missing 시 error.
        //    중간 실패 시 errdefer 가 이미 만든 faces 모두 release.
        var chain_faces: [MAX_CHAIN]?*dw.IDWriteFontFace = .{null} ** MAX_CHAIN;
        var chain_count: u8 = 0;
        errdefer {
            for (chain_faces[0..chain_count]) |maybe_face| {
                if (maybe_face) |f| _ = f.vtable.Release(f);
            }
        }

        const limit = @min(font_chain.len, MAX_CHAIN);
        for (font_chain[0..limit]) |family_w| {
            var family_index: dw.UINT32 = 0;
            var exists: BOOL = 0;
            if (collection.?.FindFamilyName(family_w, &family_index, &exists) < 0 or exists == 0)
                return error.FontNotFound;

            var family_obj: ?*dw.IDWriteFontFamily = null;
            if (collection.?.GetFontFamily(family_index, &family_obj) < 0) return error.FontFamilyFailed;
            defer _ = family_obj.?.vtable.Release(family_obj.?);

            var dw_font: ?*dw.IDWriteFont = null;
            if (family_obj.?.GetFirstMatchingFont(
                dw.DWRITE_FONT_WEIGHT_NORMAL,
                dw.DWRITE_FONT_STRETCH_NORMAL,
                dw.DWRITE_FONT_STYLE_NORMAL,
                &dw_font,
            ) < 0) return error.FontMatchFailed;
            defer _ = dw_font.?.vtable.Release(dw_font.?);

            var face: ?*dw.IDWriteFontFace = null;
            if (dw_font.?.CreateFontFace(&face) < 0) return error.FontFaceFailed;
            chain_faces[chain_count] = face.?;
            chain_count += 1;
        }

        const primary_face = chain_faces[0].?;
        const primary_family_w = font_chain[0];

        var self = DWriteFontContext{
            .alloc = alloc,
            .factory = factory.?,
            .font_collection = collection.?,
            .chain_faces = chain_faces,
            .chain_count = chain_count,
            .cell_width = cell_w,
            .cell_height = cell_h,
            .glyph_map = std.AutoHashMap(u21, CachedGlyph).init(alloc),
        };

        // Store primary family name for MapCharacters fallback (system 의 fallback
        // chain 이 우리 primary 를 base 로 fallback 결정).
        var i: u32 = 0;
        while (primary_family_w[i] != 0) : (i += 1) {
            if (i >= 63) break;
            self.primary_family_name[i] = primary_family_w[i];
        }
        self.primary_family_name[i] = 0;
        self.primary_family_len = i;

        // 4. Calculate em size from primary font metrics
        var metrics: dw.DWRITE_FONT_METRICS = undefined;
        primary_face.GetMetrics(&metrics);
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

        // 8. Create text analyzer (for grapheme cluster shaping — #134).
        var analyzer: ?*dw.IDWriteTextAnalyzer = null;
        _ = factory.?.CreateTextAnalyzer(&analyzer);
        self.text_analyzer = analyzer;

        return self;
    }

    pub fn deinit(self: *DWriteFontContext) void {
        // Release all MapCharacters-resolved faces retained in the glyph cache.
        // Chain faces never enter the cache (skipped at insert time) so no
        // double-release risk.
        var it = self.glyph_map.valueIterator();
        while (it.next()) |v| {
            _ = v.face.vtable.Release(v.face);
        }
        self.glyph_map.deinit();
        if (self.rendering_params) |rp| _ = rp.Release();
        if (self.font_fallback) |fb| _ = fb.vtable.Release(fb);
        if (self.number_sub) |ns| _ = ns.Release();
        if (self.text_analyzer) |ta| _ = ta.Release();
        for (self.chain_faces[0..self.chain_count]) |maybe_face| {
            if (maybe_face) |f| _ = f.vtable.Release(f);
        }
        _ = self.font_collection.vtable.Release(self.font_collection);
        if (self.factory2) |f2| _ = f2.Release();
        _ = self.factory.Release();
    }

    /// Resolve a codepoint to (font_face, glyph_index). 우선순위:
    ///   1. cache (이전에 resolve 된 결과)
    ///   2. user font.family chain (config 순서대로 — primary → fallback)
    ///   3. system fallback (DirectWrite IDWriteFontFallback.MapCharacters)
    ///
    /// chain face 는 process lifetime 안정 — atlas cache key (face 포인터) 가
    /// 안정적이라 cache miss 시에도 같은 codepoint → 같은 face. system fallback
    /// 으로 resolve 된 face 만 glyph_map 에 cache 해서 pointer 안정성 유지.
    /// `owned` 는 항상 false — context 가 소유.
    pub fn resolveGlyph(self: *DWriteFontContext, codepoint: u21) ?GlyphResult {
        if (self.glyph_map.get(codepoint)) |c| {
            return .{ .face = c.face, .index = c.index, .owned = false };
        }

        const cp32: dw.UINT32 = codepoint;
        var glyph_index: dw.UINT16 = 0;

        // 1. user chain — config.font.family 순서대로. 글리프 가진 첫 face 반환.
        for (self.chain_faces[0..self.chain_count]) |maybe_face| {
            const face = maybe_face orelse continue;
            glyph_index = 0;
            _ = face.GetGlyphIndices(@ptrCast(&cp32), 1, @ptrCast(&glyph_index));
            if (glyph_index != 0) {
                // chain face 는 stable — cache 안 해도 OK (deinit 에서 release).
                return .{ .face = face, .index = glyph_index, .owned = false };
            }
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

    /// Resolve a *grapheme cluster* (multiple codepoints that combine via ZWJ /
    /// VS-16 / skin tone modifier 등) to single shaped glyph. macOS 의
    /// `CTLineCreateWithAttributedString` 동등 — DirectWrite `IDWriteTextAnalyzer.GetGlyphs`
    /// 가 OpenType GSUB 를 적용해 cluster 를 단일 glyph 로 reduce.
    ///
    /// `cps[0]` 은 base codepoint, `cps[1..]` 은 modifier (VS-16 / skin tone /
    /// ZWJ + secondary base 등). chain 순회 → system fallback 순. 첫 face 가
    /// non-zero glyph 를 만들면 그걸 반환.
    pub fn resolveGrapheme(self: *DWriteFontContext, cps: []const u21) ?ClusterResult {
        if (cps.len == 0 or self.text_analyzer == null) return null;

        // UTF-21 codepoint slice → UTF-16 buffer (surrogate pair 처리).
        var u16_buf: [32]WCHAR = undefined;
        var u16_len: dw.UINT32 = 0;
        for (cps) |cp| {
            if (u16_len + 1 >= u16_buf.len) break;
            if (cp <= 0xFFFF) {
                u16_buf[u16_len] = @intCast(cp);
                u16_len += 1;
            } else {
                const off = cp - 0x10000;
                u16_buf[u16_len] = @intCast(0xD800 + (off >> 10));
                u16_buf[u16_len + 1] = @intCast(0xDC00 + (off & 0x3FF));
                u16_len += 2;
            }
        }
        if (u16_len == 0) return null;

        var indices_buf: [MAX_CLUSTER_GLYPHS]u16 = undefined;
        var advances_buf: [MAX_CLUSTER_GLYPHS]dw.FLOAT = undefined;
        var offsets_buf: [MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET = undefined;

        // 1. user chain 순회 — face 별로 cluster shape 시도.
        for (self.chain_faces[0..self.chain_count]) |maybe_face| {
            const face = maybe_face orelse continue;
            const cnt = self.shapeOnFaceMulti(face, &u16_buf, u16_len, &indices_buf, &advances_buf, &offsets_buf);
            if (cnt > 0) {
                return .{ .face = face, .indices = indices_buf, .advances = advances_buf, .offsets = offsets_buf, .count = cnt, .owned = false };
            }
        }

        // 2. system fallback — base codepoint 로 face 찾고 그 face 로 cluster shape.
        if (self.font_fallback) |fallback| {
            var source = dw.SimpleTextAnalysisSource.create(&u16_buf, u16_len, self.number_sub);
            var mapped_length: dw.UINT32 = 0;
            var mapped_font: ?*dw.IDWriteFont = null;
            var scale: dw.FLOAT = 1.0;
            const family_ptr: ?[*:0]const WCHAR = @ptrCast(&self.primary_family_name);
            if (fallback.MapCharacters(
                @ptrCast(&source),
                0,
                u16_len,
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
                    var face_ptr: ?*dw.IDWriteFontFace = null;
                    if (mf.CreateFontFace(&face_ptr) >= 0) {
                        if (face_ptr) |face| {
                            const cnt = self.shapeOnFaceMulti(face, &u16_buf, u16_len, &indices_buf, &advances_buf, &offsets_buf);
                            if (cnt > 0) {
                                return .{ .face = face, .indices = indices_buf, .advances = advances_buf, .offsets = offsets_buf, .count = cnt, .owned = true };
                            }
                            _ = face.vtable.Release(face);
                        }
                    }
                }
            }
        }

        return null;
    }

    /// `face` 로 cluster 를 OpenType shape — single glyph (가장 흔한 path) 또는
    /// multi-glyph cluster (#139, ZWJ family 등 GSUB 미합성). 결과는 indices array
    /// + count. .notdef 만 반환되면 null (다음 face / fallback).
    /// out_indices 는 `[MAX_CLUSTER_GLYPHS]u16`. 리턴 = count (0 = fail).
    fn shapeOnFaceMulti(self: *DWriteFontContext, face: *dw.IDWriteFontFace, text: [*]const WCHAR, text_len: dw.UINT32, out_indices: *[MAX_CLUSTER_GLYPHS]u16, out_advances: *[MAX_CLUSTER_GLYPHS]dw.FLOAT, out_offsets: *[MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET) u8 {
        const analyzer = self.text_analyzer orelse return 0;

        var cluster_map: [32]u16 = undefined;
        var text_props: [32]dw.DWRITE_SHAPING_TEXT_PROPERTIES = undefined;
        var glyph_indices: [64]u16 = undefined;
        var glyph_props: [64]dw.DWRITE_SHAPING_GLYPH_PROPERTIES = undefined;
        var glyph_advances: [64]dw.FLOAT = undefined;
        var glyph_offsets: [64]dw.DWRITE_GLYPH_OFFSET = undefined;
        var actual_count: dw.UINT32 = 0;

        const sa = dw.DWRITE_SCRIPT_ANALYSIS{ .script = 0, .shapes = 0 };
        const locale_name = std.unicode.utf8ToUtf16LeStringLiteral("en-us");

        const hr = analyzer.GetGlyphs(
            text,
            text_len,
            face,
            0, // is_sideways
            0, // is_right_to_left
            &sa,
            locale_name,
            null, // number_substitution
            null, // features
            null,
            0,
            glyph_indices.len,
            &cluster_map,
            &text_props,
            &glyph_indices,
            &glyph_props,
            &actual_count,
        );
        if (hr < 0 or actual_count == 0) return 0;
        // cluster 내 어떤 glyph 가 .notdef 면 face 가 cluster 의 모든 codepoint
        // 를 글리프로 갖지 않음 — fallback (다음 face 또는 system fallback) 으로.
        // 예: Cascadia 가 ZWJ family 받으면 emoji codepoint 가 .notdef → reject,
        // Segoe UI Emoji fallback 으로 cluster 합성 시도.
        const out_count: u8 = @intCast(@min(actual_count, MAX_CLUSTER_GLYPHS));
        var i: u8 = 0;
        while (i < out_count) : (i += 1) {
            if (glyph_indices[i] == 0) return 0; // any .notdef → fail
            out_indices[i] = glyph_indices[i];
        }

        // GetGlyphPlacements 로 advances + offsets 계산 (#139). emoji ZWJ family
        // 는 GSUB 가 single glyph 로 ligation 안 되고 multi-glyph + 각자의
        // advance/offset 으로 visual 결합되도록 design 되어 있음 (예: Segoe UI
        // Emoji 의 family-mwg 는 man[adv=11.2 off=+3.4] + woman[adv=9.3] +
        // girl[adv=0 off=-13.3] 로 left-pulled stack 으로 결합). advances=0 stack
        // 으로 그리면 girl 만 위에 보이고 family 깨짐. WT 동등 path.
        if (analyzer.GetGlyphPlacements(
            text,
            &cluster_map,
            &text_props,
            text_len,
            &glyph_indices,
            &glyph_props,
            actual_count,
            face,
            self.font_em_size,
            0, // is_sideways
            0, // is_right_to_left
            &sa,
            locale_name,
            null,
            null,
            0,
            &glyph_advances,
            &glyph_offsets,
        ) >= 0) {
            i = 0;
            while (i < out_count) : (i += 1) {
                out_advances[i] = glyph_advances[i];
                out_offsets[i] = glyph_offsets[i];
            }
        } else {
            i = 0;
            while (i < out_count) : (i += 1) {
                out_advances[i] = 0;
                out_offsets[i] = .{ .advanceOffset = 0, .ascenderOffset = 0 };
            }
        }

        return out_count;
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
