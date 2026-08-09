// DirectWrite font context — GL/D2D independent.
// Extracted from font_atlas.zig for use with Direct2D renderer.

const std = @import("std");
const dw = @import("directwrite.zig");
const font_constants = @import("../constants.zig");
const ligature = @import("../ligature.zig");
const cluster_cache = @import("../cluster_cache.zig");
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
    /// [#418](https://github.com/ensky0/tildaz/issues/418) — cluster 의 결합 기호가 **전부
    /// overlay 류** (Unicode combining class 1, 글자를 관통하는 mark) 인지. renderer 가
    /// 배치되지 않은 mark 를 **세로로도** base 잉크 중앙에 맞출지 정하는 데 쓴다.
    ///
    /// 이 판정은 codepoint 를 알아야 해서 폰트 층에서 한다 — atlas 는 glyph index 만 받는다.
    /// **전부** overlay 일 때만 참이다. 위 mark 와 섞이면 (`a` + acute + stroke) 보수적으로
    /// 거짓이 되어 세로 보정을 하지 않는다 — 위 mark 를 글자 가운데로 내리면 안 되기 때문이다.
    overlay_marks: bool = false,
};

/// [#418](https://github.com/ensky0/tildaz/issues/418) — **글자를 관통하는 결합 기호**인지.
///
/// Unicode combining class **1 (Overlay)** 에 해당하는 codepoint 집합이다. 이 부류는 base 위나
/// 아래가 아니라 **글자를 가로질러** 놓여야 하고, HarfBuzz 의 fallback mark positioning 도
/// combining class 로 위 · 아래 · 관통을 갈라 세로 위치를 정한다
/// (`hb-ot-shape-fallback` 의 `position_mark`).
///
/// 집합이 작고 고정이라 표로 둔다 — 이 때문에 Unicode 데이터 의존을 새로 들이지는 않는다
/// (`font/windows/font.zig` 는 ghostty 비의존을 유지한다).
fn isOverlayMark(cp: u21) bool {
    return switch (cp) {
        0x0334...0x0338 => true, // tilde · short stroke · long stroke · short solidus · long solidus
        0x20D2, 0x20D3 => true, // combining long / short vertical line overlay
        0x20E5, 0x20E6 => true, // reverse solidus · double vertical stroke overlay
        0x20EB => true, // long double solidus overlay
        else => false,
    };
}

/// cluster 의 결합 기호가 전부 overlay 류인지 (`ClusterResult.overlay_marks`).
fn clusterOverlayOnly(cps: []const u21) bool {
    if (cps.len < 2) return false;
    for (cps[1..]) |cp| {
        if (!isOverlayMark(cp)) return false;
    }
    return true;
}

const CachedGlyph = struct {
    face: *dw.IDWriteFontFace,
    index: u16,
};

/// #399 (B) — cluster 캐시가 값을 버릴 때 (퇴출 · 무효화 · 덮어쓰기) 부르는 해제다.
///
/// **`owned` 인 것만 놓는다.** chain face 는 context 가 process lifetime 동안 들고 있고
/// (atlas cache key 가 face 포인터라 안정성이 필수다) `MapCharacters` 로 얻은 face 만
/// 우리가 소유한다 — 그 구분이 곧 `owned` 다.
fn releaseCluster(v: ClusterResult) void {
    if (v.owned) _ = v.face.vtable.Release(v.face);
}

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
    /// [#416](https://github.com/ensky0/tildaz/issues/416) — `GetScriptProperties` 하나를
    /// 쓰려고 QueryInterface 해 둔 것. 없으면 (DirectWrite 1.0) script 를 그대로 쓴다.
    text_analyzer1: ?*dw.IDWriteTextAnalyzer1 = null,
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
    /// #399 (B) — grapheme cluster shaping 결과 cache. 세 platform 공용 모듈이고 값만
    /// platform 별이다.
    ///
    /// **Windows 값에는 소유권이 있다** (Linux 의 face index 와 다른 점이다). 그래서
    /// `release` 를 주입하고, 캐시가 소유권을 가져간 뒤 caller 에게는 `owned = false` 로
    /// 넘긴다 — 안 그러면 셀 루프가 매 프레임 `Release` 해서 캐시 안의 face 가 죽는다.
    ///
    /// negative 도 담는다. chain 이 못 맞춘 cluster 를 안 담으면 매 프레임 chain 전체 +
    /// `MapCharacters` + `CreateFontFace` 를 헛도는데, **Windows 는 그 경로가 가장 비싸다.**
    cluster_cache: cluster_cache.ClusterCache(ClusterResult, releaseCluster),
    /// #416 — base codepoint → `DWRITE_SCRIPT_ANALYSIS`. `AnalyzeScript` 를 cluster 마다
    /// 부르면 shaping 의 hot path (#395 에서 `render` 의 91.5 %) 에 COM 왕복이 하나 더 붙으므로
    /// 캐시한다. **폰트와 무관한 텍스트 속성**이라 face 가 키에 없다.
    script_map: std.AutoHashMap(u21, dw.DWRITE_SCRIPT_ANALYSIS),

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
            .cluster_cache = cluster_cache.ClusterCache(ClusterResult, releaseCluster).init(alloc),
            .script_map = std.AutoHashMap(u21, dw.DWRITE_SCRIPT_ANALYSIS).init(alloc),
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

        // 9. IDWriteTextAnalyzer1 — script 특성 조회용 (#416). 실패해도 동작은 이어진다
        //    (`scriptFor` 가 cursive 판정 없이 script 를 그대로 쓴다).
        if (analyzer) |a| {
            var a1: ?*anyopaque = null;
            if (a.QueryInterface(&dw.IID_IDWriteTextAnalyzer1, &a1) >= 0) {
                if (a1) |p| self.text_analyzer1 = @ptrCast(@alignCast(p));
            }
        }

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
        self.script_map.deinit();
        // #399 — 담아 둔 `MapCharacters` face 들을 여기서 놓는다 (`releaseCluster`).
        //
        // **따로 `clear()` 를 부를 자리는 없다.** 폰트 · DPI 가 바뀌면 renderer 가
        // `DWriteFontContext.init` 으로 Context 를 새로 만들고 옛 것을 `deinit` 한다
        // (`renderer/windows.zig` 의 `recreateFontResources`) — face 만 갈아 끼우는
        // 경로가 없어서, Linux 의 `freeFaces` 에 해당하는 무효화 지점이 이 자리 하나다.
        self.cluster_cache.deinit();
        if (self.rendering_params) |rp| _ = rp.Release();
        if (self.font_fallback) |fb| _ = fb.vtable.Release(fb);
        if (self.number_sub) |ns| _ = ns.Release();
        if (self.text_analyzer1) |ta1| _ = ta1.Release();
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

    /// [#420](https://github.com/ensky0/tildaz/issues/420) — cluster 를 **한 face 로 못 맞췄을 때**
    /// base 와 결합 기호를 각각 맞는 face 에서 얻는다.
    ///
    /// `resolveGrapheme` 은 cluster 전체를 한 face 로 shape 하고 `.notdef` 가 하나라도 나오면 그
    /// face 를 통째로 버린다. 그래서 **base 와 mark 가 서로 다른 폰트에만 있는 조합**은 어느
    /// face 도 통과하지 못하고 miss 가 된다. 실측 (Windows 11 · 2026-08-09):
    ///
    /// | cluster | Malgun Gothic | Segoe UI Symbol | 결과 |
    /// |---|---|---|---|
    /// | `U+AC00` (가) | ✅ | ✕ | 어느 face 도 둘 다 못 가짐 → **miss** |
    /// | `U+0301` (acute) | ✕ | ✅ | 〃 |
    ///
    /// miss 가 되면 셀 루프가 base codepoint 로 떨어져 `가` 만 그리고 **결합 기호가 조용히
    /// 사라진다.** system fallback (`MapCharacters`) 도 답이 아니다 — 문자열 전체를 한 폰트로
    /// 매핑하려 하므로 같은 이유로 실패한다 (`mapped_length = 1`).
    ///
    /// 그래서 base 는 base 대로, mark 는 mark 대로 face 를 찾아 돌려준다. **합성은 renderer 가
    /// 화면에서 한다** — atlas entry 는 face 하나짜리를 그대로 쓰고, mark 를 base 잉크 중앙에
    /// 맞춰 한 번 더 그린다 (`placeUnplacedMarks` 와 같은 정렬 규칙이다).
    ///
    /// **마지막 수단이다.** `resolveGrapheme` 이 성공하면 그쪽이 이긴다 — 한 face 안에서
    /// shaping 이 한 배치 (GPOS) 가 우리 fallback 정렬보다 항상 낫기 때문이다.
    pub const SplitCluster = struct {
        /// base codepoint 하나만으로 얻은 cluster (보통 글리프 1 개).
        base: ClusterResult,
        /// base 뒤의 결합 기호들. 못 찾은 것은 빠지므로 `cps.len - 1` 보다 적을 수 있다.
        marks: [MAX_CLUSTER_GLYPHS - 1]GlyphResult = undefined,
        mark_count: u8 = 0,
    };

    pub fn resolveGraphemeSplit(self: *DWriteFontContext, cps: []const u21) ?SplitCluster {
        if (cps.len < 2) return null;

        const base = self.resolveGrapheme(cps[0..1]) orelse return null;
        var out = SplitCluster{ .base = base };

        for (cps[1..]) |cp| {
            if (out.mark_count == out.marks.len) break;
            const g = self.resolveGlyph(cp, .regular) orelse continue;
            out.marks[out.mark_count] = g;
            out.mark_count += 1;
        }

        // mark 를 하나도 못 찾았으면 이 경로의 이득이 없다 — base 만 그리는 것은 호출자의
        // 기존 fallback 과 같다. base 를 우리가 소유했다면 여기서 놓는다.
        if (out.mark_count == 0) {
            if (base.owned) _ = base.face.vtable.Release(base.face);
            return null;
        }
        return out;
    }

    /// #399 (B) — 캐시를 씌운 층. shape 자체는 `resolveGraphemeUncached` 가 한다.
    ///
    /// **소유권이 이 함수의 핵심이다.** 셀 루프는 `result.owned` 면 매 프레임 `Release` 하는데
    /// (`renderer/windows.zig` 6 곳), 캐시에 담은 face 를 `owned = true` 로 돌려주면 그 Release
    /// 가 캐시 안의 face 를 죽인다 (use-after-free). 그래서 **캐시가 소유권을 가져가고 caller
    /// 에게는 `owned = false`** 로 준다. 해제는 `releaseCluster` 가 퇴출 · 무효화 때 한다.
    ///
    /// ⚠️ **담지 못하는 cluster 는 소유권을 넘기면 안 된다.** `ClusterCache.put` 은 키 상한
    /// (`MAX_KEY_CPS` = 8) 을 넘으면 담지 않고 **그 자리에서 값을 해제**한다 (소유권을 받았다고
    /// 보기 때문이다). 그때까지 `owned = false` 로 바꿔 주면 caller 가 이미 죽은 face 를 쓴다.
    /// 그래서 담을 수 있는지 **먼저 판정**하고, 못 담으면 원래 소유권 그대로 돌려준다.
    fn resolveGraphemeInner(self: *DWriteFontContext, cps: []const u21) ?ClusterResult {
        if (self.cluster_cache.get(cps)) |cached| {
            const c = cached orelse return null; // negative hit — chain 을 다시 헛돌지 않는다
            var out = c;
            out.owned = false; // 캐시가 계속 소유한다
            return out;
        }

        const result = self.resolveGraphemeUncached(cps);
        if (cps.len == 0 or cps.len > cluster_cache.MAX_KEY_CPS) return result;

        self.cluster_cache.put(cps, result);
        const r = result orelse return null;
        var out = r;
        out.owned = false;
        return out;
    }

    fn resolveGraphemeUncached(self: *DWriteFontContext, cps: []const u21) ?ClusterResult {
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

        // #416 — cluster 의 script. base codepoint 로 판정하고 캐시한다.
        const sa = self.scriptFor(cps[0]);
        // #418 — 결합 기호가 전부 관통 (overlay) 류인지. renderer 의 세로 보정 판단에 쓴다.
        const overlay = clusterOverlayOnly(cps);

        // 1. user chain 순회 — face 별로 cluster shape 시도.
        for (self.chain_faces[0..self.chain_count]) |maybe_face| {
            const face = maybe_face orelse continue;
            const cnt = self.shapeOnFaceMulti(face, &u16_buf, u16_len, sa, &indices_buf, &advances_buf, &offsets_buf);
            if (cnt > 0) {
                return .{ .face = face, .indices = indices_buf, .advances = advances_buf, .offsets = offsets_buf, .count = cnt, .owned = false, .overlay_marks = overlay };
            }
        }

        // 2. system fallback — OS 폰트 매칭에 물어 face 를 얻고 그 face 로 cluster 를 shape.
        //
        // **두 번 물어본다 (#418).** `MapCharacters` 의 `baseFamilyName` 은 *"이 family 에 어울리게
        // fallback 을 골라라"* 는 힌트인데, 그걸 주면 DirectWrite 가 **primary 서체를 지키려고
        // cluster 를 쪼갠다** — `k` + `U+0336` (긴 취소선) 에서 `mapped_length = 1` 로 base 만
        // 매핑하고 mark 는 포기해서, 그 face 로 shape 하면 `.notdef` 가 나와 실패했다. 결과는
        // **mark 가 조용히 사라진 화면**이었다 (`k̶` 가 `k` 로 보인다 — base 만 그려지니 사용자는
        // 입력이 무시된 것을 알 수 없다).
        //
        // `baseFamilyName = null` 로 물으면 힌트가 없으니 **cluster 전체를 덮는 폰트**를 찾아
        // 준다 (실측: `mapped_length = 2` · 두 글리프 모두 유효). 그래서 힌트를 준 시도를 먼저 하고
        // (서체 일관성이 그쪽이 낫다) 실패하면 힌트 없이 다시 묻는다.
        //
        // **폰트 이름을 코드에 박지 않는 것이 핵심이다** — OS 마다 설치 폰트가 다르고 우리는 폰트를
        // 배포하지 않는다. 같은 해법이 세 platform 에 적용된다: Linux 는 fontconfig charset 매치
        // (`system_fallback`), macOS 는 `CTFontCreateForString` 이 이 역할이다.
        //
        // cluster **중간 (mark) 위치**에서 `MapCharacters` 를 부르는 방법도 시도했는데
        // `E_INVALIDARG` 다 — combining mark 는 run 의 시작이 될 수 없다.
        //
        // 비용은 miss 경로에만 붙는다. chain 이 전부 실패한 cluster 만 여기 오고, 성공 · 실패
        // 모두 `cluster_cache` 에 담기므로 (negative 도 담는다) cluster 종류당 한 번이다.
        if (self.font_fallback != null) {
            const primary: ?[*:0]const WCHAR = @ptrCast(&self.primary_family_name);
            const hints = [2]?[*:0]const WCHAR{ primary, null };
            for (hints) |hint| {
                if (self.shapeViaSystemFallback(&u16_buf, u16_len, hint, sa, &indices_buf, &advances_buf, &offsets_buf)) |r| {
                    var result = r;
                    result.overlay_marks = overlay;
                    return result;
                }
            }
        }

        return null;
    }

    /// `MapCharacters` 로 face 를 얻어 **cluster 전체**를 shape 해 본다 (#418).
    /// `base_family` 는 fallback 선택 힌트다 — `null` 이면 힌트 없이 고르게 둔다.
    fn shapeViaSystemFallback(
        self: *DWriteFontContext,
        u16_buf: *const [32]WCHAR,
        u16_len: dw.UINT32,
        base_family: ?[*:0]const WCHAR,
        sa: dw.DWRITE_SCRIPT_ANALYSIS,
        indices_buf: *[MAX_CLUSTER_GLYPHS]u16,
        advances_buf: *[MAX_CLUSTER_GLYPHS]dw.FLOAT,
        offsets_buf: *[MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET,
    ) ?ClusterResult {
        const fallback = self.font_fallback orelse return null;

        var source = dw.SimpleTextAnalysisSource.create(u16_buf, u16_len, self.number_sub);
        var mapped_length: dw.UINT32 = 0;
        var mapped_font: ?*dw.IDWriteFont = null;
        var scale: dw.FLOAT = 1.0;
        if (fallback.MapCharacters(
            @ptrCast(&source),
            0,
            u16_len,
            self.font_collection,
            base_family,
            dw.DWRITE_FONT_WEIGHT_NORMAL,
            dw.DWRITE_FONT_STYLE_NORMAL,
            dw.DWRITE_FONT_STRETCH_NORMAL,
            &mapped_length,
            &mapped_font,
            &scale,
        ) < 0) return null;

        const mf = mapped_font orelse return null;
        defer _ = mf.vtable.Release(mf);

        var face_ptr: ?*dw.IDWriteFontFace = null;
        if (mf.CreateFontFace(&face_ptr) < 0) return null;
        const face = face_ptr orelse return null;

        // `mapped_length` 를 믿지 않는다 — shape 은 cluster **전체**로 하고 `.notdef` 판정에
        // 맡긴다. 일부만 매핑된 face 는 거기서 걸러진다.
        const cnt = self.shapeOnFaceMulti(face, u16_buf, u16_len, sa, indices_buf, advances_buf, offsets_buf);
        if (cnt == 0) {
            _ = face.vtable.Release(face);
            return null;
        }
        return .{ .face = face, .indices = indices_buf.*, .advances = advances_buf.*, .offsets = offsets_buf.*, .count = cnt, .owned = true };
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
        // **여기서 miss 를 세지 않는다.** 런이 실패하면 호출자가 그 셀들을 개별 경로로 다시
        // 도는데, 거기서 `resolveGrapheme` 이 같은 실패를 또 센다 — 한 실패가 두 번 잡혀
        // 카운터가 부풀었다 (Linux 에서 180 → 1,211 로 보였다, 61c8795). 런 실패는 정상적인
        // fallback 이지 shaping 실패가 아니다.
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

        // #399 (B) — shape 하기 전에 런의 cluster 를 **전부** 캐시에서 찾는다. 다 있으면
        // `GetGlyphs` 없이 끝난다. `zwj` 처럼 한 줄이 같은 cluster 면 첫 런 이후 shape 가 0 이다.
        //
        // 하나라도 없으면 (또는 캐시된 결과가 실패면) 아래 기존 경로로 간다 — 부분만 쓰고
        // 나머지를 shape 하는 식으로 섞지 않는다. 런은 **한 face 로 전체를 맞추는 것이 전제**라
        // 섞으면 그 전제가 깨진다.
        //
        // 여기서 담기는 값은 전부 chain face (`owned = false`) 라 소유권 문제가 없다 — 런
        // 경로는 `MapCharacters` 를 쓰지 않는다.
        var all_hit = true;
        for (clusters, 0..) |c, i| {
            if (self.cluster_cache.get(c)) |cached| {
                if (cached) |v| {
                    out[i] = v;
                    out[i].owned = false;
                    continue;
                }
            }
            all_hit = false;
            break;
        }
        if (all_hit) return clusters.len;

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

        // #416 — 런 전체를 **하나의 script 로** shape 한다. 런은 원래 "한 face 로 전체를 맞추는
        // 것" 이 전제인데 script 도 같은 성격이다 — `GetGlyphs` 가 script 를 런 단위로 받으므로
        // 섞인 런에 하나를 골라 주면 나머지 cluster 가 틀린 feature 로 shape 된다. 그래서
        // **다르면 0 을 돌려 개별 경로로 보낸다** (거기서는 cluster 마다 자기 script 를 쓴다).
        // 한 줄에 Latin 과 Arabic 이 섞이는 것은 드물어서 배칭 이득이 실질적으로 줄지 않는다.
        const sa = self.scriptFor(clusters[0][0]);
        for (clusters[1..]) |cps| {
            const s = self.scriptFor(cps[0]);
            if (s.script != sa.script or s.shapes != sa.shapes) return 0;
        }

        for (self.chain_faces[0..self.chain_count]) |maybe_face| {
            const face = maybe_face orelse continue;
            if (self.shapeRunOnFace(face, &u16_buf, u16_len, cl_start[0 .. clusters.len + 1], sa, out)) {
                // #418 — 관통 mark 여부는 codepoint 를 봐야 알 수 있고 `shapeRunOnFace` 는
                // UTF-16 만 받으므로 여기서 채운다 (캐시에 담기 전이어야 한다).
                for (0..clusters.len) |i| out[i].overlay_marks = clusterOverlayOnly(clusters[i]);
                // 다음 런이 shape 를 건너뛸 수 있게 담는다. 전부 chain face 라 캐시가 해제할
                // 것이 없고 (`owned = false`), 키에 안 들어가는 cluster 는 `put` 이 조용히
                // 버린다 — 그때도 값에 소유권이 없어 안전하다.
                for (0..clusters.len) |i| self.cluster_cache.put(clusters[i], out[i]);
                return clusters.len;
            }
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
        /// 런 전체의 script (#416). 호출자가 런 안에서 같은 것을 확인해 넘긴다.
        sa: dw.DWRITE_SCRIPT_ANALYSIS,
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
        const cnt = self.shapeOnFaceMulti(face, &u16_buf, u16_len, self.scriptFor(cps[0]), &indices_buf, &advances_buf, &offsets_buf);
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

    /// [#416](https://github.com/ensky0/tildaz/issues/416) — cluster 의 **script 를 판정한다.**
    ///
    /// `GetGlyphs` · `GetGlyphPlacements` 는 script 를 인자로 받고, 그 값으로 어떤 OpenType
    /// feature 를 적용할지 정한다. 지금까지 `script = 0` 을 넘겼는데 그건 어떤 문자 체계도
    /// 아니어서, **script 별 feature 가 통째로 안 걸렸다** — Arabic 의 `mark` (mark 를 base 의
    /// 어디에 놓을지) · `init`/`medi`/`fina` (연결형) 가 그렇다. 실측에서 폰트를 그대로 두고 이
    /// 값만 바꾸자 `Arial` · `Times New Roman` · `Courier New` 의 Arabic mark 배치가 전부
    /// 살아났다. Latin · 한글은 결과가 완전히 동일했다.
    ///
    /// HarfBuzz 는 `hb_buffer_guess_segment_properties` 로 script 를 스스로 추론하지만
    /// (그래서 Linux 는 이 증상이 없다) DirectWrite 는 그 판정을 호출자에게 맡긴다.
    ///
    /// **base codepoint 하나만 분석하고 캐시한다.** cluster 의 나머지는 combining mark 라
    /// script 가 *inherited* — base 를 따라가므로 결과가 같다. shaping 은 `render` 의 91.5 %
    /// (#395) 를 차지하는 hot path 라 cluster 마다 COM 왕복을 더할 수 없다.
    ///
    /// ## 예외 — **cursive script 에는 script 를 주지 않는다** (#416 · #417, 2026-08-09)
    ///
    /// 위 문단대로 script 를 넘긴 뒤 Windows 실기에서 Arabic 이 **더 나빠졌다.** cursive
    /// script 의 shaper 는 *앞뒤 글자와의 연결*을 보고 글자 모양 (`isol`/`init`/`medi`/`fina`)
    /// 을 고르는데, 터미널은 **셀 하나가 shaping 단위**라 그 문맥이 항상 없다. 그래서 shaper 가
    /// 홀로 선 글자에 연결형을 골라 버린다.
    ///
    /// | `U+0628` (ب) · Cascadia Code · 15pt | 글리프 | advance 합 |
    /// |---|---|---:|
    /// | script 안 줌 | `726` 하나 — isolated form (잉크 폭 8.64) | **8.79** (셀 9px 에 맞음) |
    /// | script = Arabic | `3125` (잉크 0) + `727` — final form (잉크 폭 12.82, `lsb = −6.52`) | **17.58** |
    ///
    /// [#417](https://github.com/ensky0/tildaz/issues/417) 이 *"Cascadia Code 의 Arabic 이
    /// 17.6 px 로 셀을 넘는다"* 고 적은 값이 바로 이 17.58 이다 — **폰트 설계가 아니라 이
    /// shaping 결과였다.** 게다가 글리프 순서가 시각 순서 (RTL) 로 뒤집혀 mark 가 배열 앞에
    /// 오는 바람에, renderer 의 mark 보정 (`placeUnplacedMarks` 는 `i > 0` 인 advance 0 글리프를
    /// mark 로 본다) 도 통째로 빗나갔다.
    ///
    /// **cursive 가 아닌 script 는 그대로 넘긴다.** Devanagari 는 script 가 있어야 conjunct 가
    /// 합성된다 (`क्षि` 가 script 지정 시 2 글리프 · advance 14.66, 안 주면 4 글리프 · 25.94).
    /// Hebrew · Thai · Lao · 한글 · 한자는 실측에서 script 유무가 **결과가 완전히 같았다.**
    ///
    /// 판정은 `IDWriteTextAnalyzer1.GetScriptProperties` 의 `isCursiveWriting` 이다 — script
    /// 목록을 코드에 박지 않고 **OS 가 아는 값**을 쓴다. 실측에서 Arabic · Syriac · Nko ·
    /// Mongolian 만 참이고 Latin · Hebrew · Hangul · Devanagari · Thai · Lao · Han · Hiragana 는
    /// 거짓이었다.
    ///
    /// 분석에 실패하면 `script = 0` 을 돌려준다 — 예전 동작 그대로다.
    fn scriptFor(self: *DWriteFontContext, base_cp: u21) dw.DWRITE_SCRIPT_ANALYSIS {
        const none = dw.DWRITE_SCRIPT_ANALYSIS{ .script = 0, .shapes = 0 };
        if (self.script_map.get(base_cp)) |cached| return cached;

        const analyzer = self.text_analyzer orelse return none;

        var u16_buf: [2]WCHAR = undefined;
        var u16_len: dw.UINT32 = 0;
        if (base_cp <= 0xFFFF) {
            u16_buf[0] = @intCast(base_cp);
            u16_len = 1;
        } else {
            const off = base_cp - 0x10000;
            u16_buf[0] = @intCast(0xD800 + (off >> 10));
            u16_buf[1] = @intCast(0xDC00 + (off & 0x3FF));
            u16_len = 2;
        }

        var source = dw.SimpleTextAnalysisSource.create(&u16_buf, u16_len, self.number_sub);
        var sink = dw.ScriptSink.create();
        const analyzed = if (analyzer.AnalyzeScript(@ptrCast(&source), 0, u16_len, @ptrCast(&sink)) >= 0 and sink.got != 0)
            sink.analysis
        else
            none;

        // cursive script 는 `none` 으로 낮춘다 (위 doc comment 의 예외). 캐시에도 낮춘 값을
        // 담아 codepoint 당 한 번만 물어본다.
        const result = if (self.isCursiveScript(analyzed)) none else analyzed;

        // 캐시가 실패해도 동작은 같다 — 다음에 다시 분석할 뿐이다.
        self.script_map.put(base_cp, result) catch {};
        return result;
    }

    /// script 가 **문맥에 따라 글자 모양이 바뀌는 (cursive)** 부류인지 (#416).
    /// `IDWriteTextAnalyzer1` 을 못 얻었으면 (DirectWrite 1.0) 거짓 — script 를 그대로 쓴다.
    fn isCursiveScript(self: *DWriteFontContext, sa: dw.DWRITE_SCRIPT_ANALYSIS) bool {
        if (sa.script == 0) return false;
        const a1 = self.text_analyzer1 orelse return false;
        var props = dw.DWRITE_SCRIPT_PROPERTIES{};
        if (a1.GetScriptProperties(sa, &props) < 0) return false;
        return props.isCursiveWriting();
    }

    /// `face` 로 cluster 를 OpenType shape — single glyph (가장 흔한 path) 또는
    /// multi-glyph cluster (#139, ZWJ family 등 GSUB 미합성). 결과는 indices array
    /// + count. .notdef 만 반환되면 null (다음 face / fallback).
    /// out_indices 는 `[MAX_CLUSTER_GLYPHS]u16`. 리턴 = count (0 = fail).
    fn shapeOnFaceMulti(self: *DWriteFontContext, face: *dw.IDWriteFontFace, text: [*]const WCHAR, text_len: dw.UINT32, sa: dw.DWRITE_SCRIPT_ANALYSIS, out_indices: *[MAX_CLUSTER_GLYPHS]u16, out_advances: *[MAX_CLUSTER_GLYPHS]dw.FLOAT, out_offsets: *[MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET) u8 {
        const analyzer = self.text_analyzer orelse return 0;

        var cluster_map: [32]u16 = undefined;
        var text_props: [32]dw.DWRITE_SHAPING_TEXT_PROPERTIES = undefined;
        var glyph_indices: [64]u16 = undefined;
        var glyph_props: [64]dw.DWRITE_SHAPING_GLYPH_PROPERTIES = undefined;
        var glyph_advances: [64]dw.FLOAT = undefined;
        var glyph_offsets: [64]dw.DWRITE_GLYPH_OFFSET = undefined;
        var actual_count: dw.UINT32 = 0;

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
