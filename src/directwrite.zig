// DirectWrite COM interface definitions for TildaZ font rendering.
// All vtable slots match Windows SDK dwrite.h / dwrite_2.h order.

const std = @import("std");

pub const HRESULT = c_long;
pub const BOOL = std.os.windows.BOOL;
pub const WCHAR = u16;
pub const FLOAT = f32;
pub const UINT16 = u16;
pub const UINT32 = u32;
pub const INT32 = c_int;
pub const HDC = ?*anyopaque;
pub const HMONITOR = ?*anyopaque;
pub const RECT = extern struct { left: c_long, top: c_long, right: c_long, bottom: c_long };
pub const COLORREF = u32;
pub const SIZE = extern struct { cx: c_long, cy: c_long };

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

// --- GUIDs ---

pub const IID_IDWriteFactory = GUID{
    .Data1 = 0xb859ee5a,
    .Data2 = 0xd838,
    .Data3 = 0x4b5b,
    .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};

pub const IID_IDWriteFactory2 = GUID{
    .Data1 = 0x0439fc60,
    .Data2 = 0xca44,
    .Data3 = 0x4994,
    .Data4 = .{ 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec },
};

pub const CLSID_NumberSubstitution = GUID{
    .Data1 = 0x14885CC9,
    .Data2 = 0xBAB0,
    .Data3 = 0x45F5,
    .Data4 = .{ 0x9D, 0x17, 0x2E, 0x56, 0x00, 0x31, 0x00, 0x00 },
};

// --- Enums / Constants ---

pub const DWRITE_FACTORY_TYPE_SHARED: u32 = 0;

pub const DWRITE_FONT_WEIGHT_NORMAL: u32 = 400;
pub const DWRITE_FONT_STRETCH_NORMAL: u32 = 5;
pub const DWRITE_FONT_STYLE_NORMAL: u32 = 0;

pub const DWRITE_MEASURING_MODE_NATURAL: u32 = 0;

pub const DWRITE_PIXEL_GEOMETRY_FLAT: u32 = 0;
pub const DWRITE_PIXEL_GEOMETRY_RGB: u32 = 1;

pub const DWRITE_RENDERING_MODE_ALIASED: u32 = 1;
pub const DWRITE_RENDERING_MODE_NATURAL: u32 = 4;
pub const DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC: u32 = 5;
pub const DWRITE_RENDERING_MODE_OUTLINE: u32 = 6;

pub const DWRITE_TEXTURE_ALIASED_1x1: u32 = 0;
pub const DWRITE_TEXTURE_CLEARTYPE_3x1: u32 = 1;

pub const DWRITE_READING_DIRECTION_LEFT_TO_RIGHT: u32 = 0;

pub const DWRITE_NUMBER_SUBSTITUTION_METHOD_NONE: u32 = 0;

pub const DWRITE_FONT_SIMULATIONS_NONE: u32 = 0;

// --- Structures ---

pub const DWRITE_FONT_METRICS = extern struct {
    designUnitsPerEm: UINT16,
    ascent: UINT16,
    descent: UINT16,
    lineGap: INT32,
    capHeight: UINT16,
    xHeight: UINT16,
    underlinePosition: INT32,
    underlineThickness: UINT16,
    strikethroughPosition: INT32,
    strikethroughThickness: UINT16,
};

pub const DWRITE_GLYPH_OFFSET = extern struct {
    advanceOffset: FLOAT,
    ascenderOffset: FLOAT,
};

pub const DWRITE_GLYPH_METRICS = extern struct {
    leftSideBearing: INT32,
    advanceWidth: UINT32,
    rightSideBearing: INT32,
    topSideBearing: INT32,
    advanceHeight: UINT32,
    bottomSideBearing: INT32,
    verticalOriginY: INT32,
};

pub const DWRITE_GLYPH_RUN = extern struct {
    fontFace: ?*IDWriteFontFace,
    fontEmSize: FLOAT,
    glyphCount: UINT32,
    glyphIndices: [*]const UINT16,
    glyphAdvances: ?[*]const FLOAT,
    glyphOffsets: ?[*]const DWRITE_GLYPH_OFFSET,
    isSideways: BOOL,
    bidiLevel: UINT32,
};

pub const DWRITE_MATRIX = extern struct {
    m11: FLOAT,
    m12: FLOAT,
    m21: FLOAT,
    m22: FLOAT,
    dx: FLOAT,
    dy: FLOAT,
};

// --- IUnknown ---

pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IUnknown) callconv(.c) u32,
        Release: *const fn (*IUnknown) callconv(.c) u32,
    };

    pub fn Release(self: *IUnknown) u32 {
        return self.vtable.Release(self);
    }

    pub fn QueryInterface(self: *IUnknown, riid: *const GUID, ppv: *?*anyopaque) HRESULT {
        return self.vtable.QueryInterface(self, riid, ppv);
    }
};

// --- IDWriteFactory ---
// IUnknown (3) + 18 own methods = 21 vtable slots

pub const IDWriteFactory = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteFactory, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFactory) callconv(.c) u32,
        Release: *const fn (*IDWriteFactory) callconv(.c) u32,
        // IDWriteFactory methods (18)
        GetSystemFontCollection: *const fn (*IDWriteFactory, *?*IDWriteFontCollection, BOOL) callconv(.c) HRESULT,
        CreateCustomFontCollection: *const anyopaque,
        RegisterFontCollectionLoader: *const anyopaque,
        UnregisterFontCollectionLoader: *const anyopaque,
        CreateFontFileReference: *const anyopaque,
        CreateCustomFontFileReference: *const anyopaque,
        CreateFontFace: *const anyopaque,
        CreateRenderingParams: *const fn (*IDWriteFactory, *?*IDWriteRenderingParams) callconv(.c) HRESULT,
        CreateMonitorRenderingParams: *const anyopaque,
        CreateCustomRenderingParams: *const fn (*IDWriteFactory, FLOAT, FLOAT, FLOAT, u32, u32, *?*IDWriteRenderingParams) callconv(.c) HRESULT,
        RegisterFontFileLoader: *const anyopaque,
        UnregisterFontFileLoader: *const anyopaque,
        CreateTextFormat: *const anyopaque,
        CreateTypography: *const anyopaque,
        GetGdiInterop: *const fn (*IDWriteFactory, *?*IDWriteGdiInterop) callconv(.c) HRESULT,
        CreateTextLayout: *const anyopaque,
        CreateGdiCompatibleTextLayout: *const anyopaque,
        CreateEllipsisTrimmingSign: *const anyopaque,
        CreateTextAnalyzer: *const fn (*IDWriteFactory, *?*IDWriteTextAnalyzer) callconv(.c) HRESULT,
        CreateNumberSubstitution: *const fn (*IDWriteFactory, u32, [*:0]const WCHAR, BOOL, *?*IUnknown) callconv(.c) HRESULT,
        CreateGlyphRunAnalysis: *const fn (*IDWriteFactory, *const DWRITE_GLYPH_RUN, FLOAT, ?*const DWRITE_MATRIX, u32, u32, FLOAT, FLOAT, *?*IDWriteGlyphRunAnalysis) callconv(.c) HRESULT,
    };

    pub fn Release(self: *IDWriteFactory) u32 {
        return self.vtable.Release(self);
    }

    pub fn QueryInterface(self: *IDWriteFactory, riid: *const GUID, ppv: *?*anyopaque) HRESULT {
        return self.vtable.QueryInterface(self, riid, ppv);
    }

    pub fn GetSystemFontCollection(self: *IDWriteFactory, collection: *?*IDWriteFontCollection, check_for_updates: BOOL) HRESULT {
        return self.vtable.GetSystemFontCollection(self, collection, check_for_updates);
    }

    pub fn CreateRenderingParams(self: *IDWriteFactory, params: *?*IDWriteRenderingParams) HRESULT {
        return self.vtable.CreateRenderingParams(self, params);
    }

    pub fn CreateCustomRenderingParams(self: *IDWriteFactory, gamma: FLOAT, enhanced_contrast: FLOAT, clear_type_level: FLOAT, pixel_geometry: u32, rendering_mode: u32, params: *?*IDWriteRenderingParams) HRESULT {
        return self.vtable.CreateCustomRenderingParams(self, gamma, enhanced_contrast, clear_type_level, pixel_geometry, rendering_mode, params);
    }

    pub fn GetGdiInterop(self: *IDWriteFactory, gdi_interop: *?*IDWriteGdiInterop) HRESULT {
        return self.vtable.GetGdiInterop(self, gdi_interop);
    }

    pub fn CreateNumberSubstitution(self: *IDWriteFactory, method: u32, locale: [*:0]const WCHAR, ignore_user_override: BOOL, number_sub: *?*IUnknown) HRESULT {
        return self.vtable.CreateNumberSubstitution(self, method, locale, ignore_user_override, number_sub);
    }

    pub fn CreateGlyphRunAnalysis(self: *IDWriteFactory, glyph_run: *const DWRITE_GLYPH_RUN, pixels_per_dip: FLOAT, transform: ?*const DWRITE_MATRIX, rendering_mode: u32, measuring_mode: u32, baseline_x: FLOAT, baseline_y: FLOAT, analysis: *?*IDWriteGlyphRunAnalysis) HRESULT {
        return self.vtable.CreateGlyphRunAnalysis(self, glyph_run, pixels_per_dip, transform, rendering_mode, measuring_mode, baseline_x, baseline_y, analysis);
    }

    pub fn CreateTextAnalyzer(self: *IDWriteFactory, analyzer: *?*IDWriteTextAnalyzer) HRESULT {
        return self.vtable.CreateTextAnalyzer(self, analyzer);
    }
};

// --- DirectWrite shaping structs (for IDWriteTextAnalyzer.GetGlyphs) ---

/// Per-cluster script + shape kind. `script` 는 OpenType script tag (예: 0=common,
/// 22=hangul, 8=arabic, etc.), `shapes` 는 0=DEFAULT / 1=NO_VISUAL (control chars
/// 같이 시각 글리프 없는 cluster). 우리는 grapheme cluster 단위 shaping 만
/// 필요하고 분석은 default 면 충분 — emoji 의 ZWJ / VS-16 / skin tone 은
/// OpenType GSUB 가 알아서 cluster 결합 처리.
pub const DWRITE_SCRIPT_ANALYSIS = extern struct {
    script: UINT16 = 0,
    shapes: UINT32 = 0,
};

/// 16 bits packed flags. `isShapedAlone:1` / `reserved1:1` / `canBreakShapingAfter:1` /
/// `reserved:13`. 우리는 read-only, 0 으로 init.
pub const DWRITE_SHAPING_TEXT_PROPERTIES = extern struct {
    bits: UINT16 = 0,
};

/// 16 bits packed flags. `justification:4` / `isClusterStart:1` / `isDiacritic:1` /
/// `isZeroWidthSpace:1` / `reserved:9`. `isClusterStart` 비트로 cluster 의
/// *첫* glyph 식별 가능 (ZWJ 결합 후엔 cluster 가 1 개 glyph 로 줄지만 일반
/// case 에는 cluster start glyph 만 사용).
pub const DWRITE_SHAPING_GLYPH_PROPERTIES = extern struct {
    bits: UINT16 = 0,
};

// --- IDWriteTextAnalyzer ---
// IUnknown (3) + 4 analyze methods + GetGlyphs + GetGlyphPlacements +
// GetGdiCompatibleGlyphPlacements = 10 vtable slots.

pub const IDWriteTextAnalyzer = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteTextAnalyzer, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteTextAnalyzer) callconv(.c) u32,
        Release: *const fn (*IDWriteTextAnalyzer) callconv(.c) u32,
        // 4 analyze methods (we don't use them — opaque)
        AnalyzeScript: *const anyopaque,
        AnalyzeBidi: *const anyopaque,
        AnalyzeNumberSubstitution: *const anyopaque,
        AnalyzeLineBreakpoints: *const anyopaque,
        // GetGlyphs — 우리가 cluster shaping 으로 호출. signature 그대로 매칭.
        GetGlyphs: *const fn (
            *IDWriteTextAnalyzer,
            text_string: [*]const WCHAR,
            text_length: UINT32,
            font_face: *IDWriteFontFace,
            is_sideways: BOOL,
            is_right_to_left: BOOL,
            script_analysis: *const DWRITE_SCRIPT_ANALYSIS,
            locale_name: ?[*:0]const WCHAR,
            number_substitution: ?*IUnknown,
            features: ?[*]const ?*const anyopaque, // DWRITE_TYPOGRAPHIC_FEATURES** — null 로 OK
            feature_range_lengths: ?[*]const UINT32,
            feature_ranges: UINT32,
            max_glyph_count: UINT32,
            cluster_map: [*]UINT16,
            text_props: [*]DWRITE_SHAPING_TEXT_PROPERTIES,
            glyph_indices: [*]UINT16,
            glyph_props: [*]DWRITE_SHAPING_GLYPH_PROPERTIES,
            actual_glyph_count: *UINT32,
        ) callconv(.c) HRESULT,
        GetGlyphPlacements: *const anyopaque,
        GetGdiCompatibleGlyphPlacements: *const anyopaque,
    };

    pub fn Release(self: *IDWriteTextAnalyzer) u32 {
        return self.vtable.Release(self);
    }

    pub fn GetGlyphs(
        self: *IDWriteTextAnalyzer,
        text_string: [*]const WCHAR,
        text_length: UINT32,
        font_face: *IDWriteFontFace,
        is_sideways: BOOL,
        is_right_to_left: BOOL,
        script_analysis: *const DWRITE_SCRIPT_ANALYSIS,
        locale_name: ?[*:0]const WCHAR,
        number_substitution: ?*IUnknown,
        features: ?[*]const ?*const anyopaque,
        feature_range_lengths: ?[*]const UINT32,
        feature_ranges: UINT32,
        max_glyph_count: UINT32,
        cluster_map: [*]UINT16,
        text_props: [*]DWRITE_SHAPING_TEXT_PROPERTIES,
        glyph_indices: [*]UINT16,
        glyph_props: [*]DWRITE_SHAPING_GLYPH_PROPERTIES,
        actual_glyph_count: *UINT32,
    ) HRESULT {
        return self.vtable.GetGlyphs(
            self,
            text_string,
            text_length,
            font_face,
            is_sideways,
            is_right_to_left,
            script_analysis,
            locale_name,
            number_substitution,
            features,
            feature_range_lengths,
            feature_ranges,
            max_glyph_count,
            cluster_map,
            text_props,
            glyph_indices,
            glyph_props,
            actual_glyph_count,
        );
    }
};

// --- IDWriteFactory2 ---
// Extends IDWriteFactory1 which extends IDWriteFactory.
// IDWriteFactory: 3 + 18 = 21
// IDWriteFactory1: +3 (GetEudcFontCollection, CreateCustomRenderingParams1, GetSystemFontFallback... no)
// Actually: IDWriteFactory1 adds 3 methods = 24 slots, IDWriteFactory2 adds 1 = 25 slots
// IDWriteFactory1 methods: GetEudcFontCollection, CreateCustomRenderingParams(1), CreateCustomRenderingParams(1) no...
// Let me be precise:
// IDWriteFactory1 extends IDWriteFactory with 3 new methods:
//   GetEudcFontCollection, CreateCustomRenderingParams(gamma,enhContrast,enhContrastGrayscale,ctLevel,pixGeo,renderMode)
//   , CreateCustomRenderingParams... no, just those 2? Actually:
// IDWriteFactory1: GetEudcFontCollection, CreateCustomRenderingParams(6-param version)
// Wait, checking SDK: IDWriteFactory1 has 2 methods, IDWriteFactory2 has 3 methods
// So: 21 (Factory) + 2 (Factory1) + 3 (Factory2) = 26? Let me recount.
//
// From dwrite_1.h:
// IDWriteFactory1 : IDWriteFactory — adds:
//   GetEudcFontCollection
//   CreateCustomRenderingParams (with grayscaleEnhancedContrast)
// = 2 new methods → 23 total
//
// From dwrite_2.h:
// IDWriteFactory2 : IDWriteFactory1 — adds:
//   GetSystemFontFallback
//   CreateSystemFontFallback... wait no
//   CreateFontFallbackBuilder
//   TranslateColorGlyphRun
//   CreateCustomRenderingParams (4-param extra)
//   CreateGlyphRunAnalysis (new overload)
// Actually let me just count what I need. I only need GetSystemFontFallback.
// The vtable index matters. Let me count from the SDK headers precisely.
//
// IDWriteFactory2 vtable (cumulative):
//   [0-2]: IUnknown (3)
//   [3-20]: IDWriteFactory (18)
//   [21-22]: IDWriteFactory1 (2: GetEudcFontCollection, CreateCustomRenderingParams1)
//   [23]: IDWriteFactory2::GetSystemFontFallback
//   [24]: IDWriteFactory2::CreateFontFallbackBuilder
//   [25-26]?: TranslateColorGlyphRun, CreateCustomRenderingParams2, CreateGlyphRunAnalysis2
//
// I need slot 23 = GetSystemFontFallback

pub const IDWriteFactory2 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteFactory2, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFactory2) callconv(.c) u32,
        Release: *const fn (*IDWriteFactory2) callconv(.c) u32,
        // IDWriteFactory (18)
        GetSystemFontCollection: *const anyopaque,
        CreateCustomFontCollection: *const anyopaque,
        RegisterFontCollectionLoader: *const anyopaque,
        UnregisterFontCollectionLoader: *const anyopaque,
        CreateFontFileReference: *const anyopaque,
        CreateCustomFontFileReference: *const anyopaque,
        CreateFontFace: *const anyopaque,
        CreateRenderingParams: *const anyopaque,
        CreateMonitorRenderingParams: *const anyopaque,
        CreateCustomRenderingParams: *const anyopaque,
        RegisterFontFileLoader: *const anyopaque,
        UnregisterFontFileLoader: *const anyopaque,
        CreateTextFormat: *const anyopaque,
        CreateTypography: *const anyopaque,
        GetGdiInterop: *const anyopaque,
        CreateTextLayout: *const anyopaque,
        CreateGdiCompatibleTextLayout: *const anyopaque,
        CreateEllipsisTrimmingSign: *const anyopaque,
        CreateTextAnalyzer: *const anyopaque,
        CreateNumberSubstitution: *const anyopaque,
        CreateGlyphRunAnalysis: *const anyopaque,
        // IDWriteFactory1 (2)
        GetEudcFontCollection: *const anyopaque,
        CreateCustomRenderingParams1: *const anyopaque,
        // IDWriteFactory2 (4)
        GetSystemFontFallback: *const fn (*IDWriteFactory2, *?*IDWriteFontFallback) callconv(.c) HRESULT,
        CreateFontFallbackBuilder: *const anyopaque,
        TranslateColorGlyphRun: *const fn (
            *IDWriteFactory2,
            FLOAT, // baselineOriginX
            FLOAT, // baselineOriginY
            *const DWRITE_GLYPH_RUN,
            ?*const anyopaque, // glyphRunDescription (DWRITE_GLYPH_RUN_DESCRIPTION) — null OK
            u32, // measuringMode
            ?*const DWRITE_MATRIX, // worldToDeviceTransform — null OK
            UINT32, // colorPaletteIndex (0 = default)
            *?*IDWriteColorGlyphRunEnumerator,
        ) callconv(.c) HRESULT,
        CreateCustomRenderingParams2: *const anyopaque,
        CreateGlyphRunAnalysis2: *const anyopaque,
    };

    pub fn Release(self: *IDWriteFactory2) u32 {
        return self.vtable.Release(self);
    }

    pub fn GetSystemFontFallback(self: *IDWriteFactory2, fallback: *?*IDWriteFontFallback) HRESULT {
        return self.vtable.GetSystemFontFallback(self, fallback);
    }

    pub fn TranslateColorGlyphRun(
        self: *IDWriteFactory2,
        baseline_x: FLOAT,
        baseline_y: FLOAT,
        glyph_run: *const DWRITE_GLYPH_RUN,
        run_description: ?*const anyopaque,
        measuring_mode: u32,
        transform: ?*const DWRITE_MATRIX,
        palette_index: UINT32,
        enumerator: *?*IDWriteColorGlyphRunEnumerator,
    ) HRESULT {
        return self.vtable.TranslateColorGlyphRun(
            self,
            baseline_x,
            baseline_y,
            glyph_run,
            run_description,
            measuring_mode,
            transform,
            palette_index,
            enumerator,
        );
    }
};

// --- 컬러 emoji 글리프 (#134) ---
//
// IDWriteFactory2.TranslateColorGlyphRun 이 컬러 글리프 (Segoe UI Emoji 같은
// COLR/CPAL 폰트) 를 enumerator 로 분해 — enumerator 가 layer 별로
// IDWriteColorGlyphRun (sub-glyph_run + 색) 을 반환. 우리는 각 layer 의 alpha
// mask 를 일반 path 로 라스터 + layer 색을 곱해 BGRA 로 누적.

/// `runColor` 4 float (R, G, B, A premultiplied 아님 — 일반 sRGB).
pub const DWRITE_COLOR_F = extern struct {
    r: FLOAT,
    g: FLOAT,
    b: FLOAT,
    a: FLOAT,
};

/// `paletteIndex` 가 이 값이면 layer 가 *uncolored* — 사용자 fg 색으로 채워야
/// 함. 우리는 atlas 캐싱이라 fg 가 cache 시점에 안 정해짐 — 일단 흰색으로 누적
/// (검은 silhouette 보다는 fg-colored 가 맞으니 흰색으로 그려두면 셰이더가
/// 색 모드면 그대로 흰색, mono 모드면 fg 곱).
pub const DWRITE_NO_PALETTE_INDEX: UINT16 = 0xFFFF;

/// `TranslateColorGlyphRun` 이 *컬러 아닌* 글리프 run 에 대해 반환하는 HRESULT.
/// caller 는 이 코드면 fall-through 해서 일반 alpha rasterize.
pub const DWRITE_E_NOCOLOR: HRESULT = @bitCast(@as(u32, 0x88985003));

pub const IDWriteColorGlyphRun = extern struct {
    glyph_run: DWRITE_GLYPH_RUN,
    glyph_run_description: ?*const anyopaque, // DWRITE_GLYPH_RUN_DESCRIPTION — 우리 안 사용
    baseline_origin_x: FLOAT,
    baseline_origin_y: FLOAT,
    run_color: DWRITE_COLOR_F,
    palette_index: UINT16,
};

pub const IDWriteColorGlyphRunEnumerator = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteColorGlyphRunEnumerator, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteColorGlyphRunEnumerator) callconv(.c) u32,
        Release: *const fn (*IDWriteColorGlyphRunEnumerator) callconv(.c) u32,
        // IDWriteColorGlyphRunEnumerator (2)
        MoveNext: *const fn (*IDWriteColorGlyphRunEnumerator, *BOOL) callconv(.c) HRESULT,
        GetCurrentRun: *const fn (*IDWriteColorGlyphRunEnumerator, *?*const IDWriteColorGlyphRun) callconv(.c) HRESULT,
    };

    pub fn Release(self: *IDWriteColorGlyphRunEnumerator) u32 {
        return self.vtable.Release(self);
    }

    pub fn MoveNext(self: *IDWriteColorGlyphRunEnumerator, has_run: *BOOL) HRESULT {
        return self.vtable.MoveNext(self, has_run);
    }

    pub fn GetCurrentRun(self: *IDWriteColorGlyphRunEnumerator, run: *?*const IDWriteColorGlyphRun) HRESULT {
        return self.vtable.GetCurrentRun(self, run);
    }
};

// --- IDWriteFontCollection ---
// IUnknown (3) + 4 own = 7

pub const IDWriteFontCollection = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteFontCollection, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFontCollection) callconv(.c) u32,
        Release: *const fn (*IDWriteFontCollection) callconv(.c) u32,
        // IDWriteFontCollection (4)
        GetFontFamilyCount: *const fn (*IDWriteFontCollection) callconv(.c) UINT32,
        GetFontFamily: *const fn (*IDWriteFontCollection, UINT32, *?*IDWriteFontFamily) callconv(.c) HRESULT,
        FindFamilyName: *const fn (*IDWriteFontCollection, [*:0]const WCHAR, *UINT32, *BOOL) callconv(.c) HRESULT,
        GetFontFromFontFace: *const anyopaque,
    };

    pub fn Release(self: *IDWriteFontCollection) u32 {
        return self.vtable.Release(self);
    }

    pub fn FindFamilyName(self: *IDWriteFontCollection, family_name: [*:0]const WCHAR, index: *UINT32, exists: *BOOL) HRESULT {
        return self.vtable.FindFamilyName(self, family_name, index, exists);
    }

    pub fn GetFontFamily(self: *IDWriteFontCollection, index: UINT32, family: *?*IDWriteFontFamily) HRESULT {
        return self.vtable.GetFontFamily(self, index, family);
    }
};

// --- IDWriteFontFamily ---
// IDWriteFontFamily : IDWriteFontList : IUnknown
// IUnknown (3) + IDWriteFontList (3: GetFontCollection, GetFontCount, GetFont) + IDWriteFontFamily (3: GetFamilyNames, GetFirstMatchingFont, GetMatchingFonts) = 9

pub const IDWriteFontFamily = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteFontFamily, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFontFamily) callconv(.c) u32,
        Release: *const fn (*IDWriteFontFamily) callconv(.c) u32,
        // IDWriteFontList (3)
        GetFontCollection: *const anyopaque,
        GetFontCount: *const anyopaque,
        GetFont: *const anyopaque,
        // IDWriteFontFamily (3)
        GetFamilyNames: *const anyopaque,
        GetFirstMatchingFont: *const fn (*IDWriteFontFamily, u32, u32, u32, *?*IDWriteFont) callconv(.c) HRESULT,
        GetMatchingFonts: *const anyopaque,
    };

    pub fn Release(self: *IDWriteFontFamily) u32 {
        return self.vtable.Release(self);
    }

    pub fn GetFirstMatchingFont(self: *IDWriteFontFamily, weight: u32, stretch: u32, style: u32, font: *?*IDWriteFont) HRESULT {
        return self.vtable.GetFirstMatchingFont(self, weight, stretch, style, font);
    }
};

// --- IDWriteFont ---
// IDWriteFont : IUnknown
// IUnknown (3) + 11 own = 14

pub const IDWriteFont = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteFont, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFont) callconv(.c) u32,
        Release: *const fn (*IDWriteFont) callconv(.c) u32,
        // IDWriteFont (10)
        GetFontFamily: *const anyopaque,
        GetWeight: *const anyopaque,
        GetStretch: *const anyopaque,
        GetStyle: *const anyopaque,
        IsSymbolFont: *const anyopaque,
        GetFaceNames: *const anyopaque,
        GetInformationalStrings: *const anyopaque,
        GetSimulations: *const anyopaque,
        GetMetrics: *const anyopaque,
        HasCharacter: *const anyopaque,
        CreateFontFace: *const fn (*IDWriteFont, *?*IDWriteFontFace) callconv(.c) HRESULT,
    };

    pub fn Release(self: *IDWriteFont) u32 {
        return self.vtable.Release(self);
    }

    pub fn CreateFontFace(self: *IDWriteFont, face: *?*IDWriteFontFace) HRESULT {
        return self.vtable.CreateFontFace(self, face);
    }
};

// --- IDWriteFontFace ---
// IDWriteFontFace : IUnknown
// IUnknown (3) + 15 own = 18

pub const IDWriteFontFace = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteFontFace, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFontFace) callconv(.c) u32,
        Release: *const fn (*IDWriteFontFace) callconv(.c) u32,
        // IDWriteFontFace (15)
        GetType: *const anyopaque,
        GetFiles: *const anyopaque,
        GetIndex: *const anyopaque,
        GetSimulations: *const anyopaque,
        IsSymbolFont: *const anyopaque,
        GetMetrics: *const fn (*IDWriteFontFace, *DWRITE_FONT_METRICS) callconv(.c) void,
        GetGlyphCount: *const anyopaque,
        GetDesignGlyphMetrics: *const fn (*IDWriteFontFace, [*]const UINT16, UINT32, [*]DWRITE_GLYPH_METRICS, BOOL) callconv(.c) HRESULT,
        GetGlyphIndices: *const fn (*IDWriteFontFace, [*]const UINT32, UINT32, [*]UINT16) callconv(.c) HRESULT,
        TryGetFontTable: *const anyopaque,
        ReleaseFontTable: *const anyopaque,
        GetGlyphRunOutline: *const anyopaque,
        GetRecommendedRenderingMode: *const fn (*IDWriteFontFace, FLOAT, FLOAT, u32, ?*IDWriteRenderingParams, *u32) callconv(.c) HRESULT,
        GetGdiCompatibleMetrics: *const anyopaque,
        GetGdiCompatibleGlyphMetrics: *const anyopaque,
    };

    pub fn Release(self: *IDWriteFontFace) u32 {
        return self.vtable.Release(self);
    }

    pub fn GetMetrics(self: *IDWriteFontFace, metrics: *DWRITE_FONT_METRICS) void {
        self.vtable.GetMetrics(self, metrics);
    }

    pub fn GetGlyphIndices(self: *IDWriteFontFace, codepoints: [*]const UINT32, count: UINT32, glyph_indices: [*]UINT16) HRESULT {
        return self.vtable.GetGlyphIndices(self, codepoints, count, glyph_indices);
    }

    pub fn GetDesignGlyphMetrics(self: *IDWriteFontFace, glyph_indices: [*]const UINT16, count: UINT32, metrics: [*]DWRITE_GLYPH_METRICS, is_sideways: BOOL) HRESULT {
        return self.vtable.GetDesignGlyphMetrics(self, glyph_indices, count, metrics, is_sideways);
    }

    pub fn GetRecommendedRenderingMode(self: *IDWriteFontFace, em_size: FLOAT, pixels_per_dip: FLOAT, measuring_mode: u32, rendering_params: ?*IDWriteRenderingParams, rendering_mode: *u32) HRESULT {
        return self.vtable.GetRecommendedRenderingMode(self, em_size, pixels_per_dip, measuring_mode, rendering_params, rendering_mode);
    }
};

// --- IDWriteGdiInterop ---
// IUnknown (3) + 5 own = 8

pub const IDWriteGdiInterop = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteGdiInterop, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteGdiInterop) callconv(.c) u32,
        Release: *const fn (*IDWriteGdiInterop) callconv(.c) u32,
        // IDWriteGdiInterop (5)
        CreateFontFromLOGFONT: *const anyopaque,
        ConvertFontToLOGFONT: *const anyopaque,
        ConvertFontFaceToLOGFONT: *const anyopaque,
        CreateFontFaceFromHdc: *const anyopaque,
        CreateBitmapRenderTarget: *const fn (*IDWriteGdiInterop, HDC, UINT32, UINT32, *?*IDWriteBitmapRenderTarget) callconv(.c) HRESULT,
    };

    pub fn Release(self: *IDWriteGdiInterop) u32 {
        return self.vtable.Release(self);
    }

    pub fn CreateBitmapRenderTarget(self: *IDWriteGdiInterop, hdc: HDC, width: UINT32, height: UINT32, target: *?*IDWriteBitmapRenderTarget) HRESULT {
        return self.vtable.CreateBitmapRenderTarget(self, hdc, width, height, target);
    }
};

// --- IDWriteBitmapRenderTarget ---
// IUnknown (3) + 8 own = 11

pub const IDWriteBitmapRenderTarget = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteBitmapRenderTarget, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteBitmapRenderTarget) callconv(.c) u32,
        Release: *const fn (*IDWriteBitmapRenderTarget) callconv(.c) u32,
        // IDWriteBitmapRenderTarget (8)
        DrawGlyphRun: *const fn (*IDWriteBitmapRenderTarget, FLOAT, FLOAT, u32, *const DWRITE_GLYPH_RUN, *IDWriteRenderingParams, COLORREF, ?*RECT) callconv(.c) HRESULT,
        GetMemoryDC: *const fn (*IDWriteBitmapRenderTarget) callconv(.c) HDC,
        GetPixelsPerDip: *const anyopaque,
        SetPixelsPerDip: *const anyopaque,
        GetCurrentTransform: *const anyopaque,
        SetCurrentTransform: *const anyopaque,
        GetSize: *const fn (*IDWriteBitmapRenderTarget, *SIZE) callconv(.c) HRESULT,
        Resize: *const fn (*IDWriteBitmapRenderTarget, UINT32, UINT32) callconv(.c) HRESULT,
    };

    pub fn Release(self: *IDWriteBitmapRenderTarget) u32 {
        return self.vtable.Release(self);
    }

    pub fn DrawGlyphRun(self: *IDWriteBitmapRenderTarget, baseline_origin_x: FLOAT, baseline_origin_y: FLOAT, measuring_mode: u32, glyph_run: *const DWRITE_GLYPH_RUN, rendering_params: *IDWriteRenderingParams, text_color: COLORREF, blackbox_rect: ?*RECT) HRESULT {
        return self.vtable.DrawGlyphRun(self, baseline_origin_x, baseline_origin_y, measuring_mode, glyph_run, rendering_params, text_color, blackbox_rect);
    }

    pub fn GetMemoryDC(self: *IDWriteBitmapRenderTarget) HDC {
        return self.vtable.GetMemoryDC(self);
    }

    pub fn Resize(self: *IDWriteBitmapRenderTarget, width: UINT32, height: UINT32) HRESULT {
        return self.vtable.Resize(self, width, height);
    }
};

// --- IDWriteRenderingParams ---
// IUnknown (3) + 5 own = 8
// We only create it, never call methods on it — just pass to DrawGlyphRun.

pub const IDWriteRenderingParams = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IDWriteRenderingParams, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteRenderingParams) callconv(.c) u32,
        Release: *const fn (*IDWriteRenderingParams) callconv(.c) u32,
        GetGamma: *const fn (*IDWriteRenderingParams) callconv(.c) FLOAT,
        GetEnhancedContrast: *const fn (*IDWriteRenderingParams) callconv(.c) FLOAT,
        GetClearTypeLevel: *const fn (*IDWriteRenderingParams) callconv(.c) FLOAT,
        GetPixelGeometry: *const fn (*IDWriteRenderingParams) callconv(.c) u32,
        GetRenderingMode: *const fn (*IDWriteRenderingParams) callconv(.c) u32,
    };

    pub fn Release(self: *IDWriteRenderingParams) u32 {
        return self.vtable.Release(self);
    }

    pub fn GetGamma(self: *IDWriteRenderingParams) FLOAT {
        return self.vtable.GetGamma(self);
    }

    pub fn GetEnhancedContrast(self: *IDWriteRenderingParams) FLOAT {
        return self.vtable.GetEnhancedContrast(self);
    }

    pub fn GetClearTypeLevel(self: *IDWriteRenderingParams) FLOAT {
        return self.vtable.GetClearTypeLevel(self);
    }

    pub fn GetPixelGeometry(self: *IDWriteRenderingParams) u32 {
        return self.vtable.GetPixelGeometry(self);
    }

    pub fn GetRenderingMode(self: *IDWriteRenderingParams) u32 {
        return self.vtable.GetRenderingMode(self);
    }
};

// --- IDWriteGlyphRunAnalysis ---
// IUnknown (3) + 3 own = 6

pub const IDWriteGlyphRunAnalysis = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteGlyphRunAnalysis, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteGlyphRunAnalysis) callconv(.c) u32,
        Release: *const fn (*IDWriteGlyphRunAnalysis) callconv(.c) u32,
        // IDWriteGlyphRunAnalysis (3)
        GetAlphaTextureBounds: *const fn (*IDWriteGlyphRunAnalysis, u32, *RECT) callconv(.c) HRESULT,
        CreateAlphaTexture: *const fn (*IDWriteGlyphRunAnalysis, u32, *const RECT, [*]u8, UINT32) callconv(.c) HRESULT,
        GetAlphaBlendParams: *const fn (*IDWriteGlyphRunAnalysis, *IDWriteRenderingParams, *FLOAT, *FLOAT, *FLOAT) callconv(.c) HRESULT,
    };

    pub fn Release(self: *IDWriteGlyphRunAnalysis) u32 {
        return self.vtable.Release(self);
    }

    pub fn GetAlphaTextureBounds(self: *IDWriteGlyphRunAnalysis, texture_type: u32, bounds: *RECT) HRESULT {
        return self.vtable.GetAlphaTextureBounds(self, texture_type, bounds);
    }

    pub fn CreateAlphaTexture(self: *IDWriteGlyphRunAnalysis, texture_type: u32, bounds: *const RECT, alpha_values: [*]u8, buffer_size: UINT32) HRESULT {
        return self.vtable.CreateAlphaTexture(self, texture_type, bounds, alpha_values, buffer_size);
    }

    pub fn GetAlphaBlendParams(self: *IDWriteGlyphRunAnalysis, rendering_params: *IDWriteRenderingParams, blend_gamma: *FLOAT, blend_enhanced_contrast: *FLOAT, blend_clear_type_level: *FLOAT) HRESULT {
        return self.vtable.GetAlphaBlendParams(self, rendering_params, blend_gamma, blend_enhanced_contrast, blend_clear_type_level);
    }
};

// --- IDWriteFontFallback ---
// IUnknown (3) + 1 own = 4

pub const IDWriteFontFallback = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteFontFallback, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFontFallback) callconv(.c) u32,
        Release: *const fn (*IDWriteFontFallback) callconv(.c) u32,
        // IDWriteFontFallback (1)
        MapCharacters: *const fn (
            *IDWriteFontFallback,
            *IDWriteTextAnalysisSource, // analysisSource
            UINT32, // textPosition
            UINT32, // textLength
            ?*IDWriteFontCollection, // baseFontCollection
            ?[*:0]const WCHAR, // baseFamilyName
            u32, // baseWeight
            u32, // baseStyle
            u32, // baseStretch
            *UINT32, // mappedLength
            *?*IDWriteFont, // mappedFont
            *FLOAT, // scale
        ) callconv(.c) HRESULT,
    };

    pub fn Release(self: *IDWriteFontFallback) u32 {
        return self.vtable.Release(self);
    }

    pub fn MapCharacters(
        self: *IDWriteFontFallback,
        source: *IDWriteTextAnalysisSource,
        text_position: UINT32,
        text_length: UINT32,
        base_collection: ?*IDWriteFontCollection,
        base_family: ?[*:0]const WCHAR,
        base_weight: u32,
        base_style: u32,
        base_stretch: u32,
        mapped_length: *UINT32,
        mapped_font: *?*IDWriteFont,
        scale: *FLOAT,
    ) HRESULT {
        return self.vtable.MapCharacters(self, source, text_position, text_length, base_collection, base_family, base_weight, base_style, base_stretch, mapped_length, mapped_font, scale);
    }
};

// --- IDWriteTextAnalysisSource ---
// IUnknown (3) + 5 own = 8
// We implement this interface for MapCharacters.

pub const IDWriteTextAnalysisSource = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*IDWriteTextAnalysisSource, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteTextAnalysisSource) callconv(.c) u32,
        Release: *const fn (*IDWriteTextAnalysisSource) callconv(.c) u32,
        // IDWriteTextAnalysisSource (5)
        GetTextAtPosition: *const fn (*IDWriteTextAnalysisSource, UINT32, *?[*]const WCHAR, *UINT32) callconv(.c) HRESULT,
        GetTextBeforePosition: *const fn (*IDWriteTextAnalysisSource, UINT32, *?[*]const WCHAR, *UINT32) callconv(.c) HRESULT,
        GetParagraphReadingDirection: *const fn (*IDWriteTextAnalysisSource) callconv(.c) u32,
        GetLocaleName: *const fn (*IDWriteTextAnalysisSource, UINT32, *UINT32, *?[*:0]const WCHAR) callconv(.c) HRESULT,
        GetNumberSubstitution: *const fn (*IDWriteTextAnalysisSource, UINT32, *UINT32, *?*IUnknown) callconv(.c) HRESULT,
    };
};

// --- SimpleTextAnalysisSource ---
// Stack-allocated implementation of IDWriteTextAnalysisSource for MapCharacters.

pub const SimpleTextAnalysisSource = extern struct {
    base: IDWriteTextAnalysisSource,
    text: [*]const WCHAR,
    text_len: UINT32,
    number_sub: ?*IUnknown,

    const vtable_instance = IDWriteTextAnalysisSource.VTable{
        .QueryInterface = @ptrCast(&queryInterface),
        .AddRef = @ptrCast(&addRef),
        .Release = @ptrCast(&release),
        .GetTextAtPosition = @ptrCast(&getTextAtPosition),
        .GetTextBeforePosition = @ptrCast(&getTextBeforePosition),
        .GetParagraphReadingDirection = @ptrCast(&getParagraphReadingDirection),
        .GetLocaleName = @ptrCast(&getLocaleName),
        .GetNumberSubstitution = @ptrCast(&getNumberSubstitution),
    };

    pub fn create(text: [*]const WCHAR, text_len: UINT32, number_sub: ?*IUnknown) SimpleTextAnalysisSource {
        return .{
            .base = .{ .vtable = &vtable_instance },
            .text = text,
            .text_len = text_len,
            .number_sub = number_sub,
        };
    }

    fn self(ptr: *SimpleTextAnalysisSource) *SimpleTextAnalysisSource {
        return ptr;
    }

    fn queryInterface(this: *SimpleTextAnalysisSource, _: *const GUID, _: *?*anyopaque) callconv(.c) HRESULT {
        _ = this;
        return @as(HRESULT, @bitCast(@as(u32, 0x80004002))); // E_NOINTERFACE
    }

    fn addRef(_: *SimpleTextAnalysisSource) callconv(.c) u32 {
        return 1; // stack-allocated, no ref counting
    }

    fn release(_: *SimpleTextAnalysisSource) callconv(.c) u32 {
        return 1; // stack-allocated, no ref counting
    }

    fn getTextAtPosition(this: *SimpleTextAnalysisSource, position: UINT32, text_string: *?[*]const WCHAR, text_length: *UINT32) callconv(.c) HRESULT {
        if (position >= this.text_len) {
            text_string.* = null;
            text_length.* = 0;
        } else {
            text_string.* = this.text + position;
            text_length.* = this.text_len - position;
        }
        return 0; // S_OK
    }

    fn getTextBeforePosition(_: *SimpleTextAnalysisSource, _: UINT32, text_string: *?[*]const WCHAR, text_length: *UINT32) callconv(.c) HRESULT {
        text_string.* = null;
        text_length.* = 0;
        return 0; // S_OK
    }

    fn getParagraphReadingDirection(_: *SimpleTextAnalysisSource) callconv(.c) u32 {
        return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
    }

    const locale_name: [*:0]const WCHAR = std.unicode.utf8ToUtf16LeStringLiteral("en-us");

    fn getLocaleName(_: *SimpleTextAnalysisSource, _: UINT32, text_length: *UINT32, locale: *?[*:0]const WCHAR) callconv(.c) HRESULT {
        text_length.* = std.math.maxInt(UINT32);
        locale.* = locale_name;
        return 0; // S_OK
    }

    fn getNumberSubstitution(this: *SimpleTextAnalysisSource, _: UINT32, text_length: *UINT32, sub: *?*IUnknown) callconv(.c) HRESULT {
        text_length.* = std.math.maxInt(UINT32);
        sub.* = this.number_sub;
        return 0; // S_OK
    }
};

// --- GDI helpers for bitmap extraction ---

pub const BITMAP = extern struct {
    bmType: c_long,
    bmWidth: c_long,
    bmHeight: c_long,
    bmWidthBytes: c_long,
    bmPlanes: u16,
    bmBitsPixel: u16,
    bmBits: ?[*]u8,
};

pub const OBJ_BITMAP: c_int = 7;

pub extern "gdi32" fn GetCurrentObject(hdc: HDC, obj_type: c_int) callconv(.c) ?*anyopaque;
pub extern "gdi32" fn GetObjectW(h: ?*anyopaque, c: c_int, pv: ?*anyopaque) callconv(.c) c_int;

// --- DWriteCreateFactory ---

pub extern "dwrite" fn DWriteCreateFactory(factory_type: u32, riid: *const GUID, factory: *?*anyopaque) callconv(.c) HRESULT;
