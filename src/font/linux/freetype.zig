//! Runtime libfreetype wrapper — TrueType / OpenType 폰트 raster.
//!
//! `libxkbcommon` 과 같은 dlopen 패턴. FreeType 은 struct field 액세스 (face->glyph
//! ->bitmap.buffer 등) 가 표준 API 라 ABI struct layout 을 정확히 옮긴다. ABI 안정
//! 보장 = libfreetype.so.6 (FreeType 2.0+).

const std = @import("std");

pub const FT_Pos = c_long;
pub const FT_Fixed = c_long;
pub const FT_Long = c_long;
pub const FT_ULong = c_ulong;
pub const FT_Short = c_short;
pub const FT_UShort = c_ushort;
pub const FT_Int = c_int;
pub const FT_UInt = c_uint;
pub const FT_F26Dot6 = c_long;
pub const FT_Error = c_int;

pub const FT_LOAD_RENDER: c_int = 0x4;
/// `( 1L << 20 )` — color emoji (BGRA) raster 활성화. mono 폰트엔 무시됨.
pub const FT_LOAD_COLOR: c_int = 0x100000;

pub const FT_PIXEL_MODE_MONO: u8 = 1;
pub const FT_PIXEL_MODE_GRAY: u8 = 2;
pub const FT_PIXEL_MODE_BGRA: u8 = 7;

pub const FT_Vector = extern struct {
    x: FT_Pos,
    y: FT_Pos,
};

pub const FT_Generic = extern struct {
    data: ?*anyopaque,
    finalizer: ?*const fn (object: ?*anyopaque) callconv(.c) void,
};

pub const FT_BBox = extern struct {
    xMin: FT_Pos,
    yMin: FT_Pos,
    xMax: FT_Pos,
    yMax: FT_Pos,
};

pub const FT_Glyph_Metrics = extern struct {
    width: FT_Pos,
    height: FT_Pos,
    horiBearingX: FT_Pos,
    horiBearingY: FT_Pos,
    horiAdvance: FT_Pos,
    vertBearingX: FT_Pos,
    vertBearingY: FT_Pos,
    vertAdvance: FT_Pos,
};

pub const FT_Bitmap_Size = extern struct {
    height: FT_Short,
    width: FT_Short,
    size: FT_Pos,
    x_ppem: FT_Pos,
    y_ppem: FT_Pos,
};

pub const FT_Bitmap = extern struct {
    rows: c_uint,
    width: c_uint,
    pitch: c_int,
    buffer: ?[*]u8,
    num_grays: c_ushort,
    pixel_mode: u8,
    palette_mode: u8,
    palette: ?*anyopaque,
};

pub const FT_Outline = extern struct {
    n_contours: c_short,
    n_points: c_short,
    points: ?*anyopaque,
    tags: ?*anyopaque,
    contours: ?*anyopaque,
    flags: c_int,
};

pub const FT_Size_Metrics = extern struct {
    x_ppem: c_ushort,
    y_ppem: c_ushort,
    x_scale: FT_Fixed,
    y_scale: FT_Fixed,
    ascender: FT_Pos,
    descender: FT_Pos,
    height: FT_Pos,
    max_advance: FT_Pos,
};

pub const FT_SizeRec = extern struct {
    face: ?*anyopaque,
    generic: FT_Generic,
    metrics: FT_Size_Metrics,
    internal: ?*anyopaque,
};

pub const FT_GlyphSlotRec = extern struct {
    library: ?*anyopaque,
    face: ?*anyopaque,
    next: ?*FT_GlyphSlotRec,
    glyph_index: FT_UInt,
    generic: FT_Generic,
    metrics: FT_Glyph_Metrics,
    linearHoriAdvance: FT_Fixed,
    linearVertAdvance: FT_Fixed,
    advance: FT_Vector,
    format: c_uint,
    bitmap: FT_Bitmap,
    bitmap_left: FT_Int,
    bitmap_top: FT_Int,
    outline: FT_Outline,
    num_subglyphs: FT_UInt,
    subglyphs: ?*anyopaque,
    control_data: ?*anyopaque,
    control_len: c_long,
    lsb_delta: FT_Pos,
    rsb_delta: FT_Pos,
    other: ?*anyopaque,
    internal: ?*anyopaque,
};

/// FT_FaceRec — `glyph` 와 `size` 까지의 prefix 만 정확히 옮긴다.
/// FreeType 이 자체 alloc 하므로 우리는 pointer 통해 액세스만, 끝 internal field
/// 는 우리가 안 봐도 OK. 단 `glyph` / `size` 까지의 layout offset 은 정확해야 함.
pub const FT_FaceRec = extern struct {
    num_faces: FT_Long,
    face_index: FT_Long,
    face_flags: FT_Long,
    style_flags: FT_Long,
    num_glyphs: FT_Long,
    family_name: ?[*:0]u8,
    style_name: ?[*:0]u8,
    num_fixed_sizes: FT_Int,
    available_sizes: ?[*]FT_Bitmap_Size,
    num_charmaps: FT_Int,
    charmaps: ?*anyopaque,
    generic: FT_Generic,
    bbox: FT_BBox,
    units_per_EM: FT_UShort,
    ascender: FT_Short,
    descender: FT_Short,
    height: FT_Short,
    max_advance_width: FT_Short,
    max_advance_height: FT_Short,
    underline_position: FT_Short,
    underline_thickness: FT_Short,
    glyph: ?*FT_GlyphSlotRec,
    size: ?*FT_SizeRec,
    // 그 뒤 charmap / internal field 등 — 우리는 액세스 안 함.
};

pub const FT_Library = *opaque {};
pub const FT_Face = *FT_FaceRec;

const FtInitFreeType = *const fn (library: *FT_Library) callconv(.c) FT_Error;
const FtDoneFreeType = *const fn (library: FT_Library) callconv(.c) FT_Error;
const FtNewFace = *const fn (
    library: FT_Library,
    filepath: [*:0]const u8,
    face_index: FT_Long,
    face: *FT_Face,
) callconv(.c) FT_Error;
const FtDoneFace = *const fn (face: FT_Face) callconv(.c) FT_Error;
const FtSetPixelSizes = *const fn (
    face: FT_Face,
    pixel_width: FT_UInt,
    pixel_height: FT_UInt,
) callconv(.c) FT_Error;
const FtSelectSize = *const fn (face: FT_Face, strike_index: c_int) callconv(.c) FT_Error;
const FtGetCharIndex = *const fn (face: FT_Face, charcode: FT_ULong) callconv(.c) FT_UInt;
const FtLoadGlyph = *const fn (
    face: FT_Face,
    glyph_index: FT_UInt,
    load_flags: c_int,
) callconv(.c) FT_Error;

pub const Api = struct {
    handle: *anyopaque,
    init_free_type: FtInitFreeType,
    done_free_type: FtDoneFreeType,
    new_face: FtNewFace,
    done_face: FtDoneFace,
    set_pixel_sizes: FtSetPixelSizes,
    select_size: FtSelectSize,
    get_char_index: FtGetCharIndex,
    load_glyph: FtLoadGlyph,

    pub fn load() !Api {
        const handle = std.c.dlopen("libfreetype.so.6", .{ .LAZY = true }) orelse return error.FreetypeLibraryMissing;
        errdefer _ = std.c.dlclose(handle);

        return .{
            .handle = handle,
            .init_free_type = lookup(handle, FtInitFreeType, "FT_Init_FreeType") orelse return error.FreetypeSymbolMissing,
            .done_free_type = lookup(handle, FtDoneFreeType, "FT_Done_FreeType") orelse return error.FreetypeSymbolMissing,
            .new_face = lookup(handle, FtNewFace, "FT_New_Face") orelse return error.FreetypeSymbolMissing,
            .done_face = lookup(handle, FtDoneFace, "FT_Done_Face") orelse return error.FreetypeSymbolMissing,
            .set_pixel_sizes = lookup(handle, FtSetPixelSizes, "FT_Set_Pixel_Sizes") orelse return error.FreetypeSymbolMissing,
            .select_size = lookup(handle, FtSelectSize, "FT_Select_Size") orelse return error.FreetypeSymbolMissing,
            .get_char_index = lookup(handle, FtGetCharIndex, "FT_Get_Char_Index") orelse return error.FreetypeSymbolMissing,
            .load_glyph = lookup(handle, FtLoadGlyph, "FT_Load_Glyph") orelse return error.FreetypeSymbolMissing,
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
