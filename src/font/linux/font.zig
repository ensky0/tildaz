//! Linux 폰트 컨텍스트 — fontconfig 로 system monospace 경로 조회 → FreeType
//! 으로 face 로드 → cell metric 측정 + ASCII (32..126) 미리 raster.
//!
//! [src/font/windows/font.zig](../windows/font.zig) (DWriteFontContext) /
//! [src/font/macos/font.zig](../macos/font.zig) (CoreTextFontContext) 와 같은
//! 역할. 호출자는 cell_width_px / cell_height_px / ascent_px 를 metric 으로 받고,
//! `glyph(cp)` 로 raster 결과를 lookup 한다.

const std = @import("std");
const fontconfig = @import("fontconfig.zig");
const freetype = @import("freetype.zig");
const log = @import("../../log.zig");

pub const Glyph = struct {
    /// 8bpp alpha. width × height 크기. width=0 또는 height=0 이면 invisible (예: space).
    bitmap: []u8,
    width: u32,
    height: u32,
    /// baseline 기준 좌측 offset.
    bitmap_left: i32,
    /// baseline 기준 위쪽 offset (양수 = baseline 위로).
    bitmap_top: i32,
    /// monospace 라 모든 글자가 비슷한 값.
    advance: u32,
};

const ASCII_START: u21 = 32;
const ASCII_END: u21 = 126;
const ASCII_COUNT: usize = @as(usize, ASCII_END - ASCII_START + 1);

pub const Context = struct {
    allocator: std.mem.Allocator,
    font_path: []u8,
    ft_api: freetype.Api,
    ft_lib: freetype.FT_Library,
    ft_face: freetype.FT_Face,

    /// monospace cell width — face metric 의 max_advance 기준. host renderer 가
    /// hit test / paint 좌표 계산에 사용.
    cell_width_px: u32,
    /// cell line height — face metric 의 height (ascent + descent + line gap).
    cell_height_px: u32,
    /// baseline 까지의 y offset (cell top 기준 + 방향).
    ascent_px: u32,
    descent_px: u32,

    ascii_atlas: [ASCII_COUNT]?Glyph,
    placeholder: Glyph,

    pub fn init(allocator: std.mem.Allocator, pixel_height: u32) !Context {
        const path = try fontconfig.lookupFile(allocator, "monospace");
        errdefer allocator.free(path);

        const path_z = try allocator.allocSentinel(u8, path.len, 0);
        defer allocator.free(path_z);
        @memcpy(path_z[0..path.len], path);

        var ft_api = try freetype.Api.load();
        errdefer ft_api.deinit();

        var ft_lib: freetype.FT_Library = undefined;
        if (ft_api.init_free_type(&ft_lib) != 0) return error.FreetypeInitFailed;
        errdefer _ = ft_api.done_free_type(ft_lib);

        var ft_face: freetype.FT_Face = undefined;
        if (ft_api.new_face(ft_lib, path_z.ptr, 0, &ft_face) != 0) return error.FreetypeNewFaceFailed;
        errdefer _ = ft_api.done_face(ft_face);

        if (ft_api.set_pixel_sizes(ft_face, 0, pixel_height) != 0) return error.FreetypeSetPixelSizesFailed;

        // 'M' 의 advance 가 monospace cell_width 의 표준 reference. metrics.max_advance
        // 는 wide CJK presentation 글자 / fallback notdef 등 영향으로 비정상 크게
        // 나오는 케이스 있음 (Noto Sans Mono CJK 등). 'M' 은 모든 monospace 폰트에
        // 있고, FT_LOAD_DEFAULT (raster 없음) 만이라 비용도 낮다.
        const m_idx = ft_api.get_char_index(ft_face, 'M');
        if (ft_api.load_glyph(ft_face, m_idx, 0) != 0) return error.FreetypeLoadGlyphFailed;
        const m_slot = ft_face.glyph orelse return error.FreetypeNoGlyphSlot;
        const m_advance: u32 = @intCast(@divFloor(m_slot.advance.x, 64));

        const size_rec = ft_face.size orelse return error.FreetypeNoSize;
        const m = size_rec.metrics;
        // 26.6 fixed → pixel. descender 는 음수.
        const ascent: u32 = @intCast(@divFloor(m.ascender, 64));
        const descent: u32 = @intCast(@divFloor(-m.descender, 64));
        const height: u32 = @intCast(@divFloor(m.height, 64));
        const raw_max_advance: u32 = @intCast(@divFloor(m.max_advance, 64));

        log.appendLine("font", "primary path={s} m_advance={d} max_advance={d} height={d} ascent={d} descent={d}", .{
            path, m_advance, raw_max_advance, height, ascent, descent,
        });

        var self: Context = .{
            .allocator = allocator,
            .font_path = path,
            .ft_api = ft_api,
            .ft_lib = ft_lib,
            .ft_face = ft_face,
            .cell_width_px = if (m_advance > 0) m_advance else pixel_height / 2,
            .cell_height_px = if (height > 0) height else pixel_height,
            .ascent_px = ascent,
            .descent_px = descent,
            .ascii_atlas = [_]?Glyph{null} ** ASCII_COUNT,
            .placeholder = .{ .bitmap = &.{}, .width = 0, .height = 0, .bitmap_left = 0, .bitmap_top = 0, .advance = 0 },
        };
        errdefer self.freeAtlas();

        var cp: u21 = ASCII_START;
        while (cp <= ASCII_END) : (cp += 1) {
            self.ascii_atlas[@intCast(cp - ASCII_START)] = try rasterOne(allocator, ft_api, ft_face, cp);
        }
        self.placeholder = try rasterOne(allocator, ft_api, ft_face, '?');

        return self;
    }

    pub fn deinit(self: *Context) void {
        self.freeAtlas();
        if (self.placeholder.bitmap.len > 0) self.allocator.free(self.placeholder.bitmap);
        _ = self.ft_api.done_face(self.ft_face);
        _ = self.ft_api.done_free_type(self.ft_lib);
        self.ft_api.deinit();
        self.allocator.free(self.font_path);
    }

    fn freeAtlas(self: *Context) void {
        for (&self.ascii_atlas) |*slot| {
            if (slot.*) |*g| {
                if (g.bitmap.len > 0) self.allocator.free(g.bitmap);
            }
            slot.* = null;
        }
    }

    pub fn glyph(self: *const Context, cp: u21) *const Glyph {
        if (cp >= ASCII_START and cp <= ASCII_END) {
            if (self.ascii_atlas[@intCast(cp - ASCII_START)]) |*g| return g;
        }
        return &self.placeholder;
    }
};

fn rasterOne(
    allocator: std.mem.Allocator,
    api: freetype.Api,
    face: freetype.FT_Face,
    cp: u21,
) !Glyph {
    const idx = api.get_char_index(face, cp);
    if (api.load_glyph(face, idx, freetype.FT_LOAD_RENDER) != 0) return error.FreetypeLoadGlyphFailed;
    const slot = face.glyph orelse return error.FreetypeNoGlyphSlot;
    const bm = slot.bitmap;

    // 8bpp alpha (FT_PIXEL_MODE_GRAY) 만 지원. mono / BGRA 는 invisible bitmap 으로 fallback
    // (L5-4 emoji / 별도 PR 에서 BGRA 처리, mono 는 현실적으로 거의 안 옴).
    var bitmap_slice: []u8 = &.{};
    if (bm.buffer != null and bm.pixel_mode == freetype.FT_PIXEL_MODE_GRAY and bm.width > 0 and bm.rows > 0) {
        const w: usize = @intCast(bm.width);
        const h: usize = @intCast(bm.rows);
        bitmap_slice = try allocator.alloc(u8, w * h);
        const pitch_abs: usize = if (bm.pitch >= 0) @intCast(bm.pitch) else @intCast(-bm.pitch);
        var row: usize = 0;
        while (row < h) : (row += 1) {
            const src = bm.buffer.?[row * pitch_abs .. row * pitch_abs + w];
            @memcpy(bitmap_slice[row * w .. row * w + w], src);
        }
    }

    return .{
        .bitmap = bitmap_slice,
        .width = bm.width,
        .height = bm.rows,
        .bitmap_left = slot.bitmap_left,
        .bitmap_top = slot.bitmap_top,
        .advance = @intCast(@divFloor(slot.advance.x, 64)),
    };
}
