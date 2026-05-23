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
    language_from_string: HbLanguageFromString,
    shape: HbShape,
    buffer_get_glyph_infos: HbBufferGetGlyphInfos,
    buffer_get_glyph_positions: HbBufferGetGlyphPositions,
    buffer_get_length: HbBufferGetLength,
    font_destroy: HbFontDestroy,
    ft_font_create_referenced: HbFtFontCreateReferenced,
    ft_font_changed: HbFtFontChanged,

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
        };
    }

    pub fn deinit(self: *Api) void {
        _ = std.c.dlclose(self.handle);
    }
};

fn lookup(handle: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
    const symbol = std.c.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(symbol));
}
