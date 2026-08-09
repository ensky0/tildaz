//! Runtime libharfbuzz wrapper — OpenType shaping (ligature / kerning /
//! contextual forms + ZWJ / combining mark cluster shape).
//!
//! `libfreetype` / `libfontconfig` 와 같은 dlopen 패턴. HarfBuzz 0.9.20+ 가
//! `hb_ft_font_create_referenced` 를 stable API 로 제공 — FreeType `FT_Face` 를
//! HarfBuzz `hb_font_t` 로 wrap. cluster shape 의 base.

const std = @import("std");

pub const hb_buffer_t = opaque {};
pub const hb_font_t = opaque {};
pub const hb_language_impl_t = opaque {};
pub const hb_language_t = ?*const hb_language_impl_t;

/// `hb_direction_t` — 4 = LTR. spec: https://harfbuzz.github.io/harfbuzz-hb-common.html#hb-direction-t
pub const HB_DIRECTION_INVALID: c_uint = 0;
pub const HB_DIRECTION_LTR: c_uint = 4;
pub const HB_DIRECTION_RTL: c_uint = 5;

/// `hb_script_t` — 4-char ISO 15924 tag packed big-endian. Latn / Hang / Hani 등.
/// `HB_SCRIPT_COMMON` (= 'Zyyy') = compositor 가 guess 하게 함.
pub const HB_SCRIPT_COMMON: c_uint = 0x5A797979; // 'Zyyy'
pub const HB_SCRIPT_LATIN: c_uint = 0x4C61746E; // 'Latn'

pub const hb_glyph_info_t = extern struct {
    codepoint: u32, // shape 후 = glyph index (FT_Get_Char_Index 결과와 동등)
    mask: u32,
    cluster: u32, // input codepoint array 의 어느 index 인지
    var1: u32,
    var2: u32,
};

pub const hb_glyph_position_t = extern struct {
    x_advance: i32, // 26.6 fixed point (px × 64)
    y_advance: i32,
    x_offset: i32,
    y_offset: i32,
    var_field: u32,
};

const HbBufferCreate = *const fn () callconv(.c) *hb_buffer_t;
const HbBufferDestroy = *const fn (buffer: *hb_buffer_t) callconv(.c) void;
const HbBufferClearContents = *const fn (buffer: *hb_buffer_t) callconv(.c) void;
const HbBufferAddCodepoints = *const fn (
    buffer: *hb_buffer_t,
    text: [*]const u32,
    text_length: c_int,
    item_offset: c_uint,
    item_length: c_int,
) callconv(.c) void;
const HbBufferSetDirection = *const fn (buffer: *hb_buffer_t, dir: c_uint) callconv(.c) void;
const HbBufferSetScript = *const fn (buffer: *hb_buffer_t, script: c_uint) callconv(.c) void;
const HbBufferSetLanguage = *const fn (buffer: *hb_buffer_t, lang: hb_language_t) callconv(.c) void;
const HbBufferGuessSegmentProperties = *const fn (buffer: *hb_buffer_t) callconv(.c) void;
const HbBufferSetClusterLevel = *const fn (buffer: *hb_buffer_t, level: c_uint) callconv(.c) void;

/// `hb_buffer_cluster_level_t`. 기본값 `MONOTONE_GRAPHEMES` 는 **base 와 뒤따르는 mark 를 한
/// cluster 로 병합**해서 (실측 — `k`+`U+0336` 이 둘 다 `cluster=0`) 글리프가 어느 codepoint 에서
/// 왔는지 되짚을 수 없다. `MONOTONE_CHARACTERS` 는 병합하지 않아 `cluster` 가 곧 codepoint
/// 인덱스가 된다 (#418).
pub const HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES: c_uint = 0;
pub const HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS: c_uint = 1;
const HbLanguageFromString = *const fn (str: [*]const u8, len: c_int) callconv(.c) hb_language_t;
const HbShape = *const fn (
    font: *hb_font_t,
    buffer: *hb_buffer_t,
    features: ?*const anyopaque,
    num_features: c_uint,
) callconv(.c) void;
const HbBufferGetGlyphInfos = *const fn (
    buffer: *hb_buffer_t,
    length: *c_uint,
) callconv(.c) [*]hb_glyph_info_t;
const HbBufferGetGlyphPositions = *const fn (
    buffer: *hb_buffer_t,
    length: *c_uint,
) callconv(.c) [*]hb_glyph_position_t;
const HbBufferGetLength = *const fn (buffer: *hb_buffer_t) callconv(.c) c_uint;
const HbFontDestroy = *const fn (font: *hb_font_t) callconv(.c) void;

// FT 통합 — `hb_ft_font_create_referenced(FT_Face)` 가 HarfBuzz 의 FT 통합 path.
// FT_Face 의 *_referenced 변종은 internal 에서 FT_Reference_Face 호출 → 해제는
// HarfBuzz 가 자동 (hb_font_destroy 시 FT_Done_Face 자동 호출). 결과 hb_font 는
// 우리 hb_font_destroy 만 부르면 됨. spec: https://harfbuzz.github.io/harfbuzz-hb-ft.html
const HbFtFontCreateReferenced = *const fn (face: *anyopaque) callconv(.c) *hb_font_t;
const HbFtFontChanged = *const fn (font: *hb_font_t) callconv(.c) void;

// #418 — codepoint 의 Unicode general category 조회.
//
// combining mark 를 **advance 로 판정할 수 없다** — `DejaVu Sans Mono` 는 관통 overlay 계열
// (`U+0335` · `U+0336` · `U+0338`) 에 advance 를 준다. 그대로 그리면 mark 가 옆 칸을 덮는다.
//
// **GDEF glyph class 로도 안 된다.** 같은 폰트가 그 글리프들을 `BASE_GLYPH` (class 1) 로
// 분류해 두었다 (실측 — `U+0305` · `U+0308` 은 `MARK` 인데 overlay 셋만 base 다). 폰트 데이터가
// 그러니 폰트에 물어서는 답이 안 나온다.
//
// 그래서 **codepoint 를 본다.** shaping 이 글리프를 합쳐 놓아도 (`a`+`U+0301` → `á`)
// `hb_glyph_info_t.cluster` 가 입력 codepoint 인덱스를 들고 있어서 되짚을 수 있다. 판정 자체는
// HarfBuzz 의 Unicode 데이터를 그대로 쓴다 — 우리가 결합 문자 테이블을 따로 들고 있지 않아도 된다.
//
// spec: https://harfbuzz.github.io/harfbuzz-hb-unicode.html
pub const hb_unicode_funcs_t = opaque {};
const HbUnicodeFuncsGetDefault = *const fn () callconv(.c) *hb_unicode_funcs_t;
const HbUnicodeGeneralCategory = *const fn (ufuncs: *hb_unicode_funcs_t, cp: u32) callconv(.c) c_uint;

/// `hb_unicode_general_category_t` 중 우리가 쓰는 값. enum 순서가 알파벳순이라
/// `Mc`(spacing) → `Me`(enclosing) → `Mn`(nonspacing) 이 10 · 11 · 12 다.
pub const HB_UNICODE_GENERAL_CATEGORY_SPACING_MARK: c_uint = 10;
pub const HB_UNICODE_GENERAL_CATEGORY_ENCLOSING_MARK: c_uint = 11;
pub const HB_UNICODE_GENERAL_CATEGORY_NON_SPACING_MARK: c_uint = 12;

pub const Api = struct {
    handle: *anyopaque,
    buffer_create: HbBufferCreate,
    buffer_destroy: HbBufferDestroy,
    buffer_clear_contents: HbBufferClearContents,
    buffer_add_codepoints: HbBufferAddCodepoints,
    buffer_set_direction: HbBufferSetDirection,
    buffer_set_script: HbBufferSetScript,
    buffer_set_language: HbBufferSetLanguage,
    buffer_guess_segment_properties: HbBufferGuessSegmentProperties,
    /// #418 — 없으면 null. 그때는 cluster 가 병합된 채로 와서 mark 판정이 advance 기준으로
    /// degrade 한다.
    buffer_set_cluster_level: ?HbBufferSetClusterLevel = null,
    language_from_string: HbLanguageFromString,
    shape: HbShape,
    buffer_get_glyph_infos: HbBufferGetGlyphInfos,
    buffer_get_glyph_positions: HbBufferGetGlyphPositions,
    buffer_get_length: HbBufferGetLength,
    font_destroy: HbFontDestroy,
    ft_font_create_referenced: HbFtFontCreateReferenced,
    ft_font_changed: HbFtFontChanged,
    /// #418 — Unicode general category 조회. **없어도 동작해야 하므로 optional 이다** — 축소
    /// libharfbuzz 에 이 심볼이 없을 수 있고, 그때는 mark 판정이 advance 기준으로 degrade 할 뿐
    /// shaping 전체가 죽으면 안 된다 (`dlopen` 실패 시 ligature 를 포기하고 계속 도는 것과 같은
    /// 방침).
    unicode_funcs_get_default: ?HbUnicodeFuncsGetDefault = null,
    unicode_general_category: ?HbUnicodeGeneralCategory = null,

    pub fn load() !Api {
        const handle = std.c.dlopen("libharfbuzz.so.0", .{ .LAZY = true }) orelse return error.HarfBuzzLibraryMissing;
        errdefer _ = std.c.dlclose(handle);

        return .{
            .handle = handle,
            .buffer_create = lookup(handle, HbBufferCreate, "hb_buffer_create") orelse return error.HarfBuzzSymbolMissing,
            .buffer_destroy = lookup(handle, HbBufferDestroy, "hb_buffer_destroy") orelse return error.HarfBuzzSymbolMissing,
            .buffer_clear_contents = lookup(handle, HbBufferClearContents, "hb_buffer_clear_contents") orelse return error.HarfBuzzSymbolMissing,
            .buffer_add_codepoints = lookup(handle, HbBufferAddCodepoints, "hb_buffer_add_codepoints") orelse return error.HarfBuzzSymbolMissing,
            .buffer_set_direction = lookup(handle, HbBufferSetDirection, "hb_buffer_set_direction") orelse return error.HarfBuzzSymbolMissing,
            .buffer_set_script = lookup(handle, HbBufferSetScript, "hb_buffer_set_script") orelse return error.HarfBuzzSymbolMissing,
            .buffer_set_language = lookup(handle, HbBufferSetLanguage, "hb_buffer_set_language") orelse return error.HarfBuzzSymbolMissing,
            .buffer_guess_segment_properties = lookup(handle, HbBufferGuessSegmentProperties, "hb_buffer_guess_segment_properties") orelse return error.HarfBuzzSymbolMissing,
            .language_from_string = lookup(handle, HbLanguageFromString, "hb_language_from_string") orelse return error.HarfBuzzSymbolMissing,
            .shape = lookup(handle, HbShape, "hb_shape") orelse return error.HarfBuzzSymbolMissing,
            .buffer_get_glyph_infos = lookup(handle, HbBufferGetGlyphInfos, "hb_buffer_get_glyph_infos") orelse return error.HarfBuzzSymbolMissing,
            .buffer_get_glyph_positions = lookup(handle, HbBufferGetGlyphPositions, "hb_buffer_get_glyph_positions") orelse return error.HarfBuzzSymbolMissing,
            .buffer_get_length = lookup(handle, HbBufferGetLength, "hb_buffer_get_length") orelse return error.HarfBuzzSymbolMissing,
            .font_destroy = lookup(handle, HbFontDestroy, "hb_font_destroy") orelse return error.HarfBuzzSymbolMissing,
            .ft_font_create_referenced = lookup(handle, HbFtFontCreateReferenced, "hb_ft_font_create_referenced") orelse return error.HarfBuzzSymbolMissing,
            .ft_font_changed = lookup(handle, HbFtFontChanged, "hb_ft_font_changed") orelse return error.HarfBuzzSymbolMissing,
            // 없으면 null 로 두고 계속 간다 (위 필드 주석).
            .buffer_set_cluster_level = lookup(handle, HbBufferSetClusterLevel, "hb_buffer_set_cluster_level"),
            .unicode_funcs_get_default = lookup(handle, HbUnicodeFuncsGetDefault, "hb_unicode_funcs_get_default"),
            .unicode_general_category = lookup(handle, HbUnicodeGeneralCategory, "hb_unicode_general_category"),
        };
    }

    /// #418 — 이 codepoint 가 **자리를 차지하지 않는 결합 문자**인가 (`Mn` · `Me`).
    ///
    /// `Mc` (spacing combining mark — Devanagari 모음 기호 등) 는 **뺀다.** 그것은 advance 를
    /// 갖는 것이 정상이라 pen 을 밀어야 한다. 심볼이 없으면 `false` — 호출처가 advance 기준
    /// 판정으로 degrade 한다.
    pub fn isNonSpacingMark(self: *const Api, cp: u21) bool {
        const get_funcs = self.unicode_funcs_get_default orelse return false;
        const get_cat = self.unicode_general_category orelse return false;
        const cat = get_cat(get_funcs(), @intCast(cp));
        return cat == HB_UNICODE_GENERAL_CATEGORY_NON_SPACING_MARK or
            cat == HB_UNICODE_GENERAL_CATEGORY_ENCLOSING_MARK;
    }

    pub fn deinit(self: *Api) void {
        _ = std.c.dlclose(self.handle);
    }
};

fn lookup(handle: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
    const symbol = std.c.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(symbol));
}
