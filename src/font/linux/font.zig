//! Linux 폰트 컨텍스트 — fontconfig 로 family path 조회 + FreeType 으로 face
//! 로드 + per-face lazy raster cache + chain fallback lookup.
//!
//! [src/font/windows/font.zig](../windows/font.zig) (DWriteFontContext) /
//! [src/font/macos/font.zig](../macos/font.zig) (CoreTextFontContext) 와 같은
//! 역할. `glyph(cp)` 가 primary → fallback chain 순회로 첫 매치 face 에서
//! raster + cache. chain 모두 미스면 primary 의 placeholder ('?') 반환.

const std = @import("std");
const fontconfig = @import("fontconfig.zig");
const freetype = @import("freetype.zig");
const log = @import("../../log.zig");
const font_constants = @import("../constants.zig");

pub const MAX_CHAIN: usize = font_constants.MAX_CHAIN;

pub const Glyph = struct {
    /// 8bpp alpha. width × height 크기. width=0 또는 height=0 이면 invisible (예: space).
    bitmap: []u8,
    width: u32,
    height: u32,
    /// baseline 기준 좌측 offset.
    bitmap_left: i32,
    /// baseline 기준 위쪽 offset (양수 = baseline 위로).
    bitmap_top: i32,
    advance: u32,
};

pub const Face = struct {
    allocator: std.mem.Allocator,
    ft_face: freetype.FT_Face,
    family: []u8,
    glyph_cache: std.AutoHashMap(u21, Glyph),

    fn deinit(self: *Face, api: freetype.Api) void {
        var it = self.glyph_cache.valueIterator();
        while (it.next()) |g| {
            if (g.bitmap.len > 0) self.allocator.free(g.bitmap);
        }
        self.glyph_cache.deinit();
        _ = api.done_face(self.ft_face);
        self.allocator.free(self.family);
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    ft_api: freetype.Api,
    ft_lib: freetype.FT_Library,
    faces: [MAX_CHAIN]?Face,
    face_count: usize,

    /// primary face 의 'M' advance 기준. monospace 면 모든 글자가 cell_width 안.
    /// proportional 폰트면 글자별 advance 가 다르고 paint 가 cell 안 center 정렬.
    cell_width_px: u32,
    /// primary face 의 line height (ascent + descent + line gap).
    cell_height_px: u32,
    ascent_px: u32,
    descent_px: u32,

    /// primary face 의 '?' glyph. chain 모두 미스일 때 사용.
    placeholder: Glyph,

    pub fn init(
        allocator: std.mem.Allocator,
        families: []const []const u8,
        pixel_height: u32,
    ) !Context {
        if (families.len == 0) return error.NoFamilies;

        var ft_api = try freetype.Api.load();
        errdefer ft_api.deinit();

        var ft_lib: freetype.FT_Library = undefined;
        if (ft_api.init_free_type(&ft_lib) != 0) return error.FreetypeInitFailed;
        errdefer _ = ft_api.done_free_type(ft_lib);

        var self: Context = .{
            .allocator = allocator,
            .ft_api = ft_api,
            .ft_lib = ft_lib,
            .faces = [_]?Face{null} ** MAX_CHAIN,
            .face_count = 0,
            .cell_width_px = pixel_height / 2,
            .cell_height_px = pixel_height,
            .ascent_px = 0,
            .descent_px = 0,
            .placeholder = .{ .bitmap = &.{}, .width = 0, .height = 0, .bitmap_left = 0, .bitmap_top = 0, .advance = 0 },
        };
        errdefer self.freeFaces();

        const max_load = @min(families.len, MAX_CHAIN);
        for (families[0..max_load], 0..) |family, i| {
            const family_z = try allocator.allocSentinel(u8, family.len, 0);
            defer allocator.free(family_z);
            @memcpy(family_z[0..family.len], family);

            const path = fontconfig.lookupFile(allocator, family_z.ptr) catch |err| {
                log.appendLine("font", "fontconfig lookup failed family={s} err={s}", .{ family, @errorName(err) });
                continue;
            };
            defer allocator.free(path);

            const path_z = try allocator.allocSentinel(u8, path.len, 0);
            defer allocator.free(path_z);
            @memcpy(path_z[0..path.len], path);

            var ft_face: freetype.FT_Face = undefined;
            if (ft_api.new_face(ft_lib, path_z.ptr, 0, &ft_face) != 0) {
                log.appendLine("font", "FreeType new_face failed family={s} path={s}", .{ family, path });
                continue;
            }

            if (ft_api.set_pixel_sizes(ft_face, 0, pixel_height) != 0) {
                _ = ft_api.done_face(ft_face);
                log.appendLine("font", "FreeType set_pixel_sizes failed family={s}", .{family});
                continue;
            }

            const family_owned = try allocator.dupe(u8, family);
            errdefer allocator.free(family_owned);

            self.faces[self.face_count] = .{
                .allocator = allocator,
                .ft_face = ft_face,
                .family = family_owned,
                .glyph_cache = std.AutoHashMap(u21, Glyph).init(allocator),
            };
            self.face_count += 1;

            log.appendLine("font", "chain[{d}] family={s} path={s}", .{ i, family, path });

            // primary face (= 첫 로드된 face) 의 metric 을 cell 크기로 사용.
            if (self.face_count == 1) {
                const m_idx = ft_api.get_char_index(ft_face, 'M');
                if (ft_api.load_glyph(ft_face, m_idx, 0) == 0) {
                    if (ft_face.glyph) |m_slot| {
                        const adv = @divFloor(m_slot.advance.x, 64);
                        if (adv > 0) self.cell_width_px = @intCast(adv);
                    }
                }
                if (ft_face.size) |size_rec| {
                    const m = size_rec.metrics;
                    const ascent = @divFloor(m.ascender, 64);
                    const descent = @divFloor(-m.descender, 64);
                    const height = @divFloor(m.height, 64);
                    if (ascent > 0) self.ascent_px = @intCast(ascent);
                    if (descent > 0) self.descent_px = @intCast(descent);
                    if (height > 0) self.cell_height_px = @intCast(height);
                }
                log.appendLine("font", "primary metric cell_w={d} cell_h={d} ascent={d} descent={d}", .{
                    self.cell_width_px, self.cell_height_px, self.ascent_px, self.descent_px,
                });
                self.placeholder = rasterOne(allocator, ft_api, ft_face, '?') catch self.placeholder;
            }
        }

        if (self.face_count == 0) return error.NoFaceLoaded;

        return self;
    }

    pub fn deinit(self: *Context) void {
        self.freeFaces();
        if (self.placeholder.bitmap.len > 0) self.allocator.free(self.placeholder.bitmap);
        _ = self.ft_api.done_free_type(self.ft_lib);
        self.ft_api.deinit();
    }

    fn freeFaces(self: *Context) void {
        for (&self.faces) |*slot| {
            if (slot.*) |*face| face.deinit(self.ft_api);
            slot.* = null;
        }
        self.face_count = 0;
    }

    /// `cp` 의 글리프를 chain 순회로 lookup. 첫 매치 face 의 cache 에서 lazy
    /// raster + insert. chain 모두 미스 (또는 raster / OOM 실패) → placeholder.
    pub fn glyph(self: *Context, cp: u21) *const Glyph {
        for (self.faces[0..self.face_count]) |*slot| {
            const face = if (slot.*) |*f| f else continue;
            const idx = self.ft_api.get_char_index(face.ft_face, cp);
            if (idx == 0) continue;

            if (face.glyph_cache.getPtr(cp)) |cached| return cached;

            const g = rasterOne(self.allocator, self.ft_api, face.ft_face, cp) catch {
                return &self.placeholder;
            };
            face.glyph_cache.put(cp, g) catch {
                if (g.bitmap.len > 0) self.allocator.free(g.bitmap);
                return &self.placeholder;
            };
            return face.glyph_cache.getPtr(cp).?;
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
    // (L5-4 emoji 에서 BGRA, mono 는 현실적으로 거의 안 옴).
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

    const advance_raw = @divFloor(slot.advance.x, 64);
    const advance_clamped: u32 = if (advance_raw > 0) @intCast(advance_raw) else 0;

    return .{
        .bitmap = bitmap_slice,
        .width = bm.width,
        .height = bm.rows,
        .bitmap_left = slot.bitmap_left,
        .bitmap_top = slot.bitmap_top,
        .advance = advance_clamped,
    };
}
