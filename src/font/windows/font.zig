// DirectWrite font context — GL/D2D independent.
// Extracted from font_atlas.zig for use with Direct2D renderer.

const std = @import("std");
const dw = @import("directwrite.zig");
const font_constants = @import("../constants.zig");
const ligature = @import("../ligature.zig");
const font_spec = @import("../spec.zig");
const log = @import("../../log.zig");
const perf = @import("../../perf.zig");

const BOOL = std.os.windows.BOOL;
const WCHAR = u16;

/// font.family chain 의 최대 길이.
pub const MAX_CHAIN: usize = font_constants.MAX_CHAIN;

// Cross-platform ligature 타입 re-export — caller (renderer/windows.zig) 가
// `font.LigatureMatch` 식으로 그대로 쓸 수 있게.
pub const LigatureGlyph = ligature.LigatureGlyph;
pub const LigatureSpacer = ligature.LigatureSpacer;
pub const LigatureMatch = ligature.LigatureMatch;

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

/// 정공 cell metric — DWrite design metric (ascent/descent/lineGap/advance) 으로
/// 직접 산출. GDI tm 의 rounding / leading 영향 배제. 여기서는 실수 측정값을
/// 그대로 반환하고 호출처가 ratio 까지 적용한 뒤 공통 정책으로 한 번만 ceil 한다.
///
/// font_height_px = 우리가 raster 할 em-size (#148 B-2 후 = 사용자 font.size ×
/// DPI scale). monospace 폰트의 모든 glyph 가 같은 advance 라 '0' 의 advance 를
/// cell_w 로 사용. cell_h = ascent + descent + lineGap (DWrite design 기반).
///
/// 임시 IDWriteFactory 한 번 만들어 측정 후 release. renderer 의 DWriteFontContext
/// 도 자체 factory 를 따로 만듦 (lifetime 분리). DWrite factory 생성은 가벼워서
/// 부담 없음.
pub fn measureCell(
    primary_family_w: [*:0]const WCHAR,
    font_height_px: f32,
) !struct { cell_w: f32, cell_h: f32 } {
    var factory: ?*dw.IDWriteFactory = null;
    if (dw.DWriteCreateFactory(dw.DWRITE_FACTORY_TYPE_SHARED, &dw.IID_IDWriteFactory, @ptrCast(&factory)) < 0)
        return error.DWriteFactoryFailed;
    defer _ = factory.?.vtable.Release(factory.?);

    var collection: ?*dw.IDWriteFontCollection = null;
    if (factory.?.GetSystemFontCollection(&collection, 0) < 0) return error.FontCollectionFailed;
    defer _ = collection.?.vtable.Release(collection.?);

    var family_index: dw.UINT32 = 0;
    var exists: BOOL = 0;
    if (collection.?.FindFamilyName(primary_family_w, &family_index, &exists) < 0 or exists == 0)
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
    defer _ = face.?.vtable.Release(face.?);

    var metrics: dw.DWRITE_FONT_METRICS = undefined;
    face.?.GetMetrics(&metrics);
    const em: f32 = @floatFromInt(metrics.designUnitsPerEm);
    const asc: f32 = @floatFromInt(metrics.ascent);
    const desc: f32 = @floatFromInt(metrics.descent);
    const linegap: f32 = @floatFromInt(metrics.lineGap);

    var glyph_idx: dw.UINT16 = 0;
    const cp: dw.UINT32 = '0';
    if (face.?.GetGlyphIndices(@ptrCast(&cp), 1, @ptrCast(&glyph_idx)) < 0)
        return error.GlyphIndexFailed;

    var glyph_metrics: dw.DWRITE_GLYPH_METRICS = undefined;
    if (face.?.GetDesignGlyphMetrics(@ptrCast(&glyph_idx), 1, @ptrCast(&glyph_metrics), 0) < 0)
        return error.GlyphMetricsFailed;
    const advance: f32 = @floatFromInt(glyph_metrics.advanceWidth);

    const cell_w_px = font_height_px * advance / em;
    const cell_h_px = font_height_px * (asc + desc + linegap) / em;

    return .{
        .cell_w = cell_w_px,
        .cell_h = cell_h_px,
    };
}

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
    /// #375 — bold · italic · bold_italic chain. regular 는 위 `chain_faces` 가
    /// 담당하므로 3 벌만 둔다 (`FaceStyle.index() - 1` 로 색인).
    ///
    /// `GetFirstMatchingFont` 은 **요청과 가장 근접한 face** 를 돌려주므로 (실패하지
    /// 않는다) bold face 가 없는 family 는 자연히 regular 가 들어온다 — "없으면
    /// regular" 를 우리가 따로 판정하지 않아도 된다.
    styled_faces: [font_constants.FaceStyle.count - 1][MAX_CHAIN]?*dw.IDWriteFontFace =
        .{.{null} ** MAX_CHAIN} ** (font_constants.FaceStyle.count - 1),
    chain_count: u8 = 0,
    rendering_params: ?*dw.IDWriteRenderingParams = null,
    number_sub: ?*dw.IUnknown = null,
    primary_family_name: [64]WCHAR = undefined,
    primary_family_len: u32 = 0,
    font_em_size: f32 = 0,
    ascent_px: f32 = 0,
    descent_px: f32 = 0,
    cell_width_px: u32,
    cell_height_px: u32,
    // Caches (codepoint → face/index). Keeps fallback faces alive so atlas
    // cache keys — which use the face pointer — remain stable.
    glyph_map: std.AutoHashMap(u21, CachedGlyph),
    /// pair/triple lookahead cache. 세 backend 공통 key + positive/negative 저장.
    ligature_cache: ligature.Cache,

    pub fn init(
        alloc: std.mem.Allocator,
        font_chain: []const [*:0]const WCHAR,
        spec: font_spec.Spec,
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
        var styled_faces: [font_constants.FaceStyle.count - 1][MAX_CHAIN]?*dw.IDWriteFontFace =
            .{.{null} ** MAX_CHAIN} ** (font_constants.FaceStyle.count - 1);
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

            // #375 — 같은 family 의 변종 face. weight / style 인자만 바꾼다.
            inline for ([_]font_constants.FaceStyle{ .bold, .italic, .bold_italic }) |fs| {
                var styled_font: ?*dw.IDWriteFont = null;
                if (family_obj.?.GetFirstMatchingFont(
                    if (fs.isBold()) dw.DWRITE_FONT_WEIGHT_BOLD else dw.DWRITE_FONT_WEIGHT_NORMAL,
                    dw.DWRITE_FONT_STRETCH_NORMAL,
                    if (fs.isItalic()) dw.DWRITE_FONT_STYLE_ITALIC else dw.DWRITE_FONT_STYLE_NORMAL,
                    &styled_font,
                ) >= 0) {
                    defer _ = styled_font.?.vtable.Release(styled_font.?);
                    var styled_face: ?*dw.IDWriteFontFace = null;
                    if (styled_font.?.CreateFontFace(&styled_face) >= 0) {
                        styled_faces[fs.index() - 1][chain_count] = styled_face.?;
                    }
                }
                // 실패하면 null 로 남고 `chainFor` 가 regular face 로 떨어뜨린다.
            }

            chain_count += 1;
        }

        const primary_face = chain_faces[0].?;
        const primary_family_w = font_chain[0];

        var self = DWriteFontContext{
            .alloc = alloc,
            .factory = factory.?,
            .font_collection = collection.?,
            .chain_faces = chain_faces,
            .styled_faces = styled_faces,
            .chain_count = chain_count,
            .cell_width_px = cell_w,
            .cell_height_px = cell_h,
            .glyph_map = std.AutoHashMap(u21, CachedGlyph).init(alloc),
            .ligature_cache = ligature.Cache.init(alloc),
        };

        // Store primary family name for MapCharacters fallback (system 의 fallback
        // chain 이 우리 primary 를 base 로 fallback 결정).
        // #298 — null-term UTF-16 자체 복사 루프 → std.mem.span (primary_family_w 는
        // [*:0]const WCHAR sentinel 포인터). 최대 63 units + null.
        const fam = std.mem.span(primary_family_w);
        const fam_n = @min(fam.len, self.primary_family_name.len - 1);
        @memcpy(self.primary_family_name[0..fam_n], fam[0..fam_n]);
        self.primary_family_name[fam_n] = 0;
        self.primary_family_len = @intCast(fam_n);

        // 4. Calculate em size from primary font metrics
        var metrics: dw.DWRITE_FONT_METRICS = undefined;
        primary_face.GetMetrics(&metrics);
        const du_per_em: f32 = @floatFromInt(metrics.designUnitsPerEm);
        const ascent: f32 = @floatFromInt(metrics.ascent);
        const abs_height = spec.size_logical;
        // WT BackendD3D 컨벤션 (#148) — em-size = font.size 픽셀 그대로. DWrite
        // native + 일반적인 fontSize 의미와 정합. 이전 식 (`abs_height * em /
        // (asc+desc)`) 은 GDI CreateFontW(positive) 의 cell-height 컨벤션 을
        // DWrite em 으로 환산한 값 — Cascadia 19pt 에서 em=16.4 로 작아져 emoji
        // 가 WT 보다 14% 작게 raster. ascent_px 는 새 em 기준 비례 — `em *
        // ascent / du_per_em`.
        self.font_em_size = abs_height;
        self.ascent_px = abs_height * ascent / du_per_em;
        self.descent_px = abs_height * @as(f32, @floatFromInt(metrics.descent)) / du_per_em;

        // #197 — primary 1줄 lifecycle (cross-platform 동일 형식). path 는 win
        // system font 라 제외. family 는 UTF-16 → UTF-8 변환.
        var fam_buf: [128]u8 = undefined;
        const fam_len = std.unicode.utf16LeToUtf8(&fam_buf, self.primary_family_name[0..self.primary_family_len]) catch 0;
        log.appendLine("font", "primary family={s} cell_w={d} cell_h={d} ascent={d} descent={d}", .{
            fam_buf[0..fam_len],                             self.cell_width_px,                               self.cell_height_px,
            @as(u32, @intFromFloat(@round(self.ascent_px))), @as(u32, @intFromFloat(@round(self.descent_px))),
        });

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
        self.ligature_cache.deinit();
        if (self.rendering_params) |rp| _ = rp.Release();
        if (self.font_fallback) |fb| _ = fb.vtable.Release(fb);
        if (self.number_sub) |ns| _ = ns.Release();
        if (self.text_analyzer) |ta| _ = ta.Release();
        for (self.chain_faces[0..self.chain_count]) |maybe_face| {
            if (maybe_face) |f| _ = f.vtable.Release(f);
        }
        // #375 — 변종 chain. 만들지 못한 칸은 null 이라 건너뛴다.
        for (&self.styled_faces) |*chain| {
            for (chain[0..self.chain_count]) |maybe_face| {
                if (maybe_face) |f| _ = f.vtable.Release(f);
            }
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
    /// #375 — 요청한 변종의 chain. 해당 변종 face 가 없는 칸은 regular 로 떨어뜨린다.
    fn faceAt(self: *const DWriteFontContext, i: usize, style: font_constants.FaceStyle) ?*dw.IDWriteFontFace {
        if (style != .regular) {
            if (self.styled_faces[style.index() - 1][i]) |f| return f;
        }
        return self.chain_faces[i];
    }

    /// `style` (#375) 은 SGR `1` · `3` 이 요구하는 face 변종이다. chain 순회만 이
    /// 값을 따르고, system fallback (`MapCharacters`) 경로와 grapheme · ligature 는
    /// regular 를 쓴다 — 컬러 emoji 에 굵기는 의미가 없다.
    pub fn resolveGlyph(self: *DWriteFontContext, codepoint: u21, style: font_constants.FaceStyle) ?GlyphResult {
        // 캐시는 **chain 밖** cp 의 system fallback 결과만 담는다 (chain 히트는 아래에서
        // 바로 반환하고 캐시에 넣지 않는다) — 그래서 변종이 캐시와 충돌하지 않는다.
        if (self.glyph_map.get(codepoint)) |c| {
            return .{ .face = c.face, .index = c.index, .owned = false };
        }

        const cp32: dw.UINT32 = codepoint;
        var glyph_index: dw.UINT16 = 0;

        // 1. user chain — config.font.family 순서대로. 글리프 가진 첫 face 반환.
        for (0..self.chain_count) |i| {
            const face = self.faceAt(i, style) orelse continue;
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
    ///
    /// #395 — 실제 구현은 `resolveGraphemeInner` 이고 여기서는 `perf.shape` 만 얹는다.
    /// cluster 셀마다 · 프레임마다 불리는 경로라, render 안에서 shaping 이 차지하는
    /// 몫을 이 카운터로 가른다. `return null` 경로가 여럿이라 본체를 건드리지 않도록
    /// wrapper 로 분리했다. Linux `resolveCluster` · mac `resolveGrapheme` 과 같은 모양.
    pub fn resolveGrapheme(self: *DWriteFontContext, cps: []const u21) ?ClusterResult {
        const t0 = perf.now();
        const result = self.resolveGraphemeInner(cps);
        perf.addTimed(&perf.shape, t0);
        // miss — chain 도 system fallback 도 못 맞춘 경우. 이 경로가 가장 비싸다
        // (chain 전체 순회 + `MapCharacters` + `CreateFontFace`).
        if (result == null) perf.incExtra(&perf.shape);
        return result;
    }

    fn resolveGraphemeInner(self: *DWriteFontContext, cps: []const u21) ?ClusterResult {
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

    /// 런 배칭 상한 ([#399](https://github.com/ensky0/tildaz/issues/399)). 넘으면 호출자가
    /// 런을 끊고 다음 런이 이어받으므로 이득이 사라지지 않고 여기서 멈출 뿐이다. 120 열에
    /// wide cluster 는 최대 60 개지만, 이 값이 아래 shaping 버퍼 크기를 정하고 (합쳐 약 8 KB)
    /// 실제 줄은 그보다 훨씬 짧아서 32 로 잡았다.
    pub const MAX_RUN_CLUSTERS: usize = 32;
    /// cluster 당 UTF-16 은 보통 2~8 unit 이다 (ZWJ family 가 8). 넘으면 0 을 돌려 개별 경로로.
    const MAX_RUN_U16: usize = 256;
    /// DirectWrite 권장값 `3 * textLength / 2 + 16`.
    const MAX_RUN_GLYPHS: usize = 3 * MAX_RUN_U16 / 2 + 16;

    /// **여러 cluster 를 `GetGlyphs` 한 번으로 shape 한다** (#399). 지금까지는 cluster 마다
    /// `resolveGrapheme` 을 불러 chain 을 처음부터 순회하고 `GetGlyphs` · `GetGlyphPlacements`
    /// 를 매번 새로 호출했는데, 그 **고정 비용이 지배적**이라 한 줄을 묶으면 크게 싸다.
    /// `render` 의 91.5 % 가 이 경로다 (#395 Linux 실측, macOS 는 92.0 %).
    ///
    /// 반환은 **채운 cluster 수**다. `out` 은 `clusters` 와 같은 순서로 채워지고, 0 이면
    /// 호출자가 기존 개별 경로로 떨어진다 — 렌더가 틀리느니 느린 게 낫다.
    ///
    /// **macOS 판과 갈리는 곳이 둘이다.**
    ///   - 결과가 **multi-glyph** 다 (`ClusterResult`). Segoe UI Emoji 의 ZWJ family 는 GSUB 가
    ///     단일 글리프로 합성하지 않고 여러 글리프를 advance / offset 으로 쌓아 그리도록
    ///     설계돼 있다 (#139). CoreText 는 cluster 당 글리프 하나였다.
    ///   - **face 를 우리가 고른다.** chain 을 순서대로 돌며 *한 face 로 런 전체* 를 shape 하고,
    ///     `.notdef` 이 하나라도 있으면 그 face 를 버린다 (개별 경로와 같은 판정). 기본 chain 에
    ///     `Segoe UI Emoji` 가 있어서 (`config.zig` 의 `glyph_fallback`) emoji 런도 chain 안에서
    ///     풀린다.
    ///
    /// **system fallback (`MapCharacters`) 은 런에서 쓰지 않는다.** 런의 어느 codepoint 를
    /// 기준으로 face 를 찾을지 애매하고, chain 이 전부 실패하는 경우는 드물다. 그때는 0 을
    /// 돌려 **개별 경로가 fallback 을 하게** 둔다 — 정확성은 그대로고 그 런만 느려진다.
    pub fn resolveGraphemeRun(
        self: *DWriteFontContext,
        clusters: []const []const u21,
        out: []ClusterResult,
    ) usize {
        const t0 = perf.now();
        const n = self.resolveGraphemeRunInner(clusters, out);
        perf.addTimed(&perf.shape, t0);
        // miss 는 **런 단위**로 센다 — 개별 경로로 떨어진 런의 수다.
        if (n == 0) perf.incExtra(&perf.shape);
        return n;
    }

    fn resolveGraphemeRunInner(
        self: *DWriteFontContext,
        clusters: []const []const u21,
        out: []ClusterResult,
    ) usize {
        if (clusters.len == 0 or clusters.len > MAX_RUN_CLUSTERS) return 0;
        if (out.len < clusters.len) return 0;
        if (self.text_analyzer == null) return 0;

        var u16_buf: [MAX_RUN_U16]WCHAR = undefined;
        // cluster `i` 의 UTF-16 시작 위치. 끝에 센티넬 (= 전체 길이) 을 넣어 범위를
        // `[cl_start[i], cl_start[i+1])` 로 읽는다. 이어붙인 뒤에는 길이 정보가 사라진다.
        var cl_start: [MAX_RUN_CLUSTERS + 1]u16 = undefined;
        var u16_len: dw.UINT32 = 0;

        for (clusters, 0..) |cps, ci| {
            if (cps.len == 0) return 0;
            cl_start[ci] = @intCast(u16_len);
            for (cps) |cp| {
                if (cp <= 0xFFFF) {
                    if (u16_len + 1 > MAX_RUN_U16) return 0;
                    u16_buf[u16_len] = @intCast(cp);
                    u16_len += 1;
                } else {
                    if (u16_len + 2 > MAX_RUN_U16) return 0;
                    const off = cp - 0x10000;
                    u16_buf[u16_len] = @intCast(0xD800 + (off >> 10));
                    u16_buf[u16_len + 1] = @intCast(0xDC00 + (off & 0x3FF));
                    u16_len += 2;
                }
            }
        }
        if (u16_len == 0) return 0;
        cl_start[clusters.len] = @intCast(u16_len);

        for (self.chain_faces[0..self.chain_count]) |maybe_face| {
            const face = maybe_face orelse continue;
            if (self.shapeRunOnFace(face, &u16_buf, u16_len, cl_start[0 .. clusters.len + 1], out))
                return clusters.len;
        }
        return 0;
    }

    /// `face` 로 **런 전체**를 shape 하고 글리프를 cluster 별로 잘라 `out` 에 담는다.
    /// 하나라도 어긋나면 false — 호출자가 다음 face 로 넘어간다.
    ///
    /// **글리프 → cluster 배분은 `cluster_map` 이 한다.** `GetGlyphs` 가 text index → glyph
    /// index 표를 이미 돌려주는데 지금까지는 cluster 하나만 넘기느라 안 쓰고 있었다. cluster
    /// `i` 의 글리프 범위는 `[cluster_map[s_i], cluster_map[s_{i+1}])` 이고 마지막은
    /// `actual_count` 다.
    fn shapeRunOnFace(
        self: *DWriteFontContext,
        face: *dw.IDWriteFontFace,
        text: [*]const WCHAR,
        text_len: dw.UINT32,
        /// 길이가 cluster 수 + 1 이다 (마지막이 센티넬).
        cl_start: []const u16,
        out: []ClusterResult,
    ) bool {
        const analyzer = self.text_analyzer orelse return false;
        const cluster_count = cl_start.len - 1;

        var cluster_map: [MAX_RUN_U16]u16 = undefined;
        var text_props: [MAX_RUN_U16]dw.DWRITE_SHAPING_TEXT_PROPERTIES = undefined;
        var glyph_indices: [MAX_RUN_GLYPHS]u16 = undefined;
        var glyph_props: [MAX_RUN_GLYPHS]dw.DWRITE_SHAPING_GLYPH_PROPERTIES = undefined;
        var glyph_advances: [MAX_RUN_GLYPHS]dw.FLOAT = undefined;
        var glyph_offsets: [MAX_RUN_GLYPHS]dw.DWRITE_GLYPH_OFFSET = undefined;
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
        if (hr < 0 or actual_count == 0 or actual_count > glyph_indices.len) return false;

        // `.notdef` 이 하나라도 있으면 이 face 는 런의 어떤 cluster 를 못 그린다는 뜻이다 —
        // 개별 경로 (`shapeOnFaceMulti`) 와 같은 판정이라 chain 순회 결과가 달라지지 않는다.
        for (glyph_indices[0..actual_count]) |gi| {
            if (gi == 0) return false;
        }

        // placement 도 **런 전체에 한 번**이다. 실패하면 개별 경로처럼 0 으로 채운다 (#139 의
        // left-pulled stack 은 못 그리지만 글리프 자체는 나온다).
        const placed = analyzer.GetGlyphPlacements(
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
        ) >= 0;

        for (0..cluster_count) |ci| {
            const s = cl_start[ci];
            const e = cl_start[ci + 1];
            if (s >= text_len or e > text_len or e <= s) return false;

            const g0: dw.UINT32 = cluster_map[s];
            // 마지막 cluster 의 끝은 `cluster_map[text_len]` 이 아니라 (범위 밖이다) 글리프 총수다.
            const g1: dw.UINT32 = if (ci + 1 == cluster_count) actual_count else cluster_map[e];
            // **범위가 비면 실패다.** DirectWrite 가 우리 cluster 둘을 자기 cluster 하나로
            // 합치면 (ligature) 이렇게 되는데, 그러면 어느 셀에 무엇을 그릴지 정할 수 없다.
            if (g1 <= g0 or g1 > actual_count) return false;
            const n = g1 - g0;
            if (n > MAX_CLUSTER_GLYPHS) return false;

            out[ci] = .{
                .face = face,
                .indices = undefined,
                .advances = undefined,
                .offsets = undefined,
                .count = @intCast(n),
                // chain face 는 context 가 소유한다 (deinit 까지 안 놓는다) — 개별 경로의
                // chain 성공 케이스와 같다.
                .owned = false,
            };
            for (0..n) |k| {
                out[ci].indices[k] = glyph_indices[g0 + k];
                out[ci].advances[k] = if (placed) glyph_advances[g0 + k] else 0;
                out[ci].offsets[k] = if (placed) glyph_offsets[g0 + k] else .{ .advanceOffset = 0, .ascenderOffset = 0 };
            }
        }
        return true;
    }

    /// 2-char ligature lookup (SPEC § 12.2). `cp0` + `cp1` 을 primary face 로
    /// shape (TextAnalyzer.GetGlyphs) 한 후 결과 glyph 들 vs natural
    /// (`GetGlyphIndices`) 비교로 `LigatureMatch` 판정 — 공유 `ligature.classify`
    /// 사용. Latin ligature 폰트 (Fira Code / JetBrains Mono / Cascadia Code)
    /// 사용 시 `==` / `=>` / `!=` 등 정상 합성.
    ///
    /// Latin ligature 는 primary 의 GSUB — fallback chain 안 봄.
    pub fn ligaturePair(self: *DWriteFontContext, cp0: u21, cp1: u21) ?LigatureMatch {
        if (self.ligature_cache.getPair(cp0, cp1)) |cached| return cached;
        var cps = [_]u21{ cp0, cp1 };
        const result = self.ligatureShape(&cps);
        self.ligature_cache.putPair(cp0, cp1, result);
        return result;
    }

    /// 3-char ligature lookup. `===` / `!==` / `<=>` / `<--` / `-->` / `<->` /
    /// `<==` / `==>` / `||=` / `>>=` 등.
    pub fn ligatureTriple(self: *DWriteFontContext, cp0: u21, cp1: u21, cp2: u21) ?LigatureMatch {
        if (self.ligature_cache.getTriple(cp0, cp1, cp2)) |cached| return cached;
        var cps = [_]u21{ cp0, cp1, cp2 };
        const result = self.ligatureShape(&cps);
        self.ligature_cache.putTriple(cp0, cp1, cp2, result);
        return result;
    }

    /// primary face 로 shape + `ligature.classify`. natural indices 는 primary
    /// face 의 `GetGlyphIndices` 로 직접 계산. fallback chain 안 봄 (Latin
    /// ligature 는 primary 의 GSUB).
    fn ligatureShape(self: *DWriteFontContext, cps: []const u21) ?LigatureMatch {
        if (cps.len == 0 or cps.len > 4 or self.text_analyzer == null) return null;
        if (self.chain_count == 0) return null;
        const face = self.chain_faces[0] orelse return null;

        // UTF-16 buffer. ASCII candidate 만 호출되어 surrogate 없음, but safety
        // 위해 처리도 포함.
        var u16_buf: [8]WCHAR = undefined;
        var u16_len: dw.UINT32 = 0;
        for (cps) |cp| {
            if (u16_len + 1 >= u16_buf.len) return null;
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

        // Natural indices — primary face 의 cp → glyph 직접 매핑.
        var natural: [4]u16 = .{ 0, 0, 0, 0 };
        var cps_u32: [4]u32 = .{ 0, 0, 0, 0 };
        for (cps, 0..) |cp, i| cps_u32[i] = @intCast(cp);
        _ = face.GetGlyphIndices(@ptrCast(&cps_u32), @intCast(cps.len), @ptrCast(&natural));

        // Shape on primary face.
        var indices_buf: [MAX_CLUSTER_GLYPHS]u16 = undefined;
        var advances_buf: [MAX_CLUSTER_GLYPHS]dw.FLOAT = undefined;
        var offsets_buf: [MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET = undefined;
        const cnt = self.shapeOnFaceMulti(face, &u16_buf, u16_len, &indices_buf, &advances_buf, &offsets_buf);
        if (cnt == 0) return null;

        // ShapedSlot[] 구성. DWrite `DWRITE_GLYPH_OFFSET.advanceOffset` (=
        // GPOS 의 advance 외 추가 x 조정) 를 `x_offset` 으로 추출. Fira Code
        // `||=` 의 spacer 디자인이 `=` glyph 을 `||` 쪽으로 당겨 시각상 연결
        // 시키는 GPOS adjustment 가 이 offset 에 들어있음. paint 단계가 cell
        // base position 에 더해 정확한 GPOS 위치에 그림.
        //
        // y_offset 은 mac 과 동등하게 0 — Fira Code 등의 GPOS y 조정 거의 없음.
        var slots: [4]ligature.ShapedSlot = undefined;
        const checked = @min(@as(usize, cnt), slots.len);
        for (0..checked) |i| {
            const cp_idx = @min(i, cps.len - 1);
            slots[i] = .{
                .glyph_index = indices_buf[i],
                .natural_glyph_index = natural[cp_idx],
                .x_offset = @intFromFloat(@round(offsets_buf[i].advanceOffset)),
                .y_offset = 0,
            };
        }
        return ligature.classify(cps.len, slots[0..checked]);
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
