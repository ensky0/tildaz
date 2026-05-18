//! Linux 폰트 컨텍스트 — fontconfig 로 family path 조회 + FreeType 으로 face
//! 로드 + per-face lazy raster cache + chain fallback lookup.
//!
//! [src/font/windows/font.zig](../windows/font.zig) (DWriteFontContext) /
//! [src/font/macos/font.zig](../macos/font.zig) (CoreTextFontContext) 와 같은
//! 역할. `glyph(cp)` 가 primary → fallback chain 순회로 첫 매치 face 에서
//! raster + cache. chain 모두 미스면 primary 의 placeholder ('?') 반환.
//!
//! 8bpp gray (`FT_PIXEL_MODE_GRAY`) 와 color (`FT_PIXEL_MODE_BGRA`, Noto Color
//! Emoji 등) 둘 다 raster — Glyph.pixel_mode 로 호출자 (`software_terminal.paint`)
//! 가 두 path 갈래.

const std = @import("std");
const fontconfig = @import("fontconfig.zig");
const freetype = @import("freetype.zig");
const log = @import("../../log.zig");
const font_constants = @import("../constants.zig");

pub const MAX_CHAIN: usize = font_constants.MAX_CHAIN;

pub const Glyph = struct {
    /// gray = width × height × 1 byte (alpha). BGRA = width × height × 4 byte
    /// (premultiplied alpha). width=0 또는 height=0 이면 invisible (예: space).
    bitmap: []u8,
    width: u32,
    height: u32,
    bitmap_left: i32,
    bitmap_top: i32,
    advance: u32,
    /// `FT_PIXEL_MODE_GRAY` 또는 `FT_PIXEL_MODE_BGRA`. 그 외는 invisible bitmap.
    pixel_mode: u8,
};

pub const Face = struct {
    allocator: std.mem.Allocator,
    ft_face: freetype.FT_Face,
    family: []u8,
    /// 로딩 시 fontconfig 가 반환한 파일 path — chain 중복 제거에 사용.
    path: []u8,
    glyph_cache: std.AutoHashMap(u21, Glyph),

    fn deinit(self: *Face, api: freetype.Api) void {
        var it = self.glyph_cache.valueIterator();
        while (it.next()) |g| {
            if (g.bitmap.len > 0) self.allocator.free(g.bitmap);
        }
        self.glyph_cache.deinit();
        _ = api.done_face(self.ft_face);
        self.allocator.free(self.family);
        self.allocator.free(self.path);
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    ft_api: freetype.Api,
    ft_lib: freetype.FT_Library,
    faces: [MAX_CHAIN]?Face,
    face_count: usize,

    cell_width_px: u32,
    cell_height_px: u32,
    ascent_px: u32,
    descent_px: u32,

    placeholder: Glyph,

    pub fn init(
        allocator: std.mem.Allocator,
        families: []const []const u8,
        pixel_height: u32,
        cell_width_ratio: f32,
        line_height_ratio: f32,
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
            .placeholder = .{
                .bitmap = &.{},
                .width = 0,
                .height = 0,
                .bitmap_left = 0,
                .bitmap_top = 0,
                .advance = 0,
                .pixel_mode = freetype.FT_PIXEL_MODE_GRAY,
            },
        };
        errdefer self.freeFaces();

        const max_load = @min(families.len, MAX_CHAIN);
        for (families[0..max_load], 0..) |family, i| {
            self.tryLoadFamily(family, i, pixel_height) catch |err| {
                log.appendLine("font", "chain[{d}] skip family={s} err={s}", .{ i, family, @errorName(err) });
            };
        }

        if (self.face_count == 0) return error.NoFaceLoaded;

        // L13-β — config.cell_width_ratio / line_height_ratio 적용. measured
        // 값에 곱해 저장 — `Renderer.cellWidth/cellHeight` getter 가 단순
        // 반환만 하면 자동으로 ratio 가 적용됨. 1.0 / 1.1 등 사용자가
        // config.json 으로 조절 가능 (Config 검증 범위 0.5..2.0).
        if (cell_width_ratio != 1.0) {
            const w_f: f32 = @floatFromInt(self.cell_width_px);
            self.cell_width_px = @intFromFloat(@max(1.0, w_f * cell_width_ratio));
        }
        if (line_height_ratio != 1.0) {
            const h_f: f32 = @floatFromInt(self.cell_height_px);
            self.cell_height_px = @intFromFloat(@max(1.0, h_f * line_height_ratio));
        }
        log.appendLine("font", "applied ratios cell_w={} cell_h={} cell_width_ratio={d:.2} line_height_ratio={d:.2}", .{
            self.cell_width_px,
            self.cell_height_px,
            cell_width_ratio,
            line_height_ratio,
        });

        return self;
    }

    /// 한 family 의 path 조회 + face 등록. 실패는 caller 가 잡고 skip (err return).
    fn tryLoadFamily(self: *Context, family: []const u8, log_idx: usize, pixel_height: u32) !void {
        const family_z = try self.allocator.allocSentinel(u8, family.len, 0);
        defer self.allocator.free(family_z);
        @memcpy(family_z[0..family.len], family);

        const fc_result = try fontconfig.lookup(self.allocator, family_z.ptr);
        defer self.allocator.free(fc_result.family);
        var path_owned_by_face = false;
        defer if (!path_owned_by_face) self.allocator.free(fc_result.path);

        // fontconfig 는 정확한 매치 없으면 fallback substitution 으로 다른 family
        // 의 path 를 반환한다. generic family ("monospace" 등) 는 substitution 이
        // 의도 — 시스템 default 매치. specific family 는 결과 family 명이 우리
        // 요청과 substring 매치 안 되면 substitution 으로 판단 + skip.
        if (!isGenericFamily(family) and std.ascii.indexOfIgnoreCase(fc_result.family, family) == null) {
            log.appendLine("font", "chain[{d}] skip family={s} (fontconfig substituted to {s})", .{
                log_idx, family, fc_result.family,
            });
            return error.FontconfigFallbackSubstitution;
        }

        // 같은 path 가 chain 안 이미 있으면 dedup. log 인덱스 = 매치된 face 의
        // 실제 index (자기 자신이 아니라).
        for (self.faces[0..self.face_count], 0..) |slot, idx| {
            const existing = slot orelse continue;
            if (std.mem.eql(u8, existing.path, fc_result.path)) {
                log.appendLine("font", "chain[{d}] dedup family={s} path={s} (same as chain[{d}])", .{
                    log_idx, family, fc_result.path, idx,
                });
                return;
            }
        }

        const path_z = try self.allocator.allocSentinel(u8, fc_result.path.len, 0);
        defer self.allocator.free(path_z);
        @memcpy(path_z[0..fc_result.path.len], fc_result.path);

        var ft_face: freetype.FT_Face = undefined;
        if (self.ft_api.new_face(self.ft_lib, path_z.ptr, 0, &ft_face) != 0) {
            return error.FreetypeNewFaceFailed;
        }
        errdefer _ = self.ft_api.done_face(ft_face);

        // set_pixel_sizes 가 fixed-strike 폰트 (Noto Color Emoji 등) 에서 fail
        // 가능. fail 면 첫 strike 선택으로 fallback.
        if (self.ft_api.set_pixel_sizes(ft_face, 0, pixel_height) != 0) {
            if (ft_face.num_fixed_sizes <= 0 or self.ft_api.select_size(ft_face, 0) != 0) {
                return error.FreetypeSetSizeFailed;
            }
        }

        // primary face 자격 — 'M' glyph 가 있어야 cell metric 측정 가능. emoji
        // 폰트 (Noto Color Emoji 등) 가 chain 의 첫 family 로 시도되어도 'M' 없으면
        // primary 자리 미적임. 다음 family 시도.
        const m_idx = self.ft_api.get_char_index(ft_face, 'M');
        if (self.face_count == 0 and m_idx == 0) {
            return error.NoLatinM;
        }

        const family_owned = try self.allocator.dupe(u8, family);
        errdefer self.allocator.free(family_owned);

        self.faces[self.face_count] = .{
            .allocator = self.allocator,
            .ft_face = ft_face,
            .family = family_owned,
            .path = fc_result.path,
            .glyph_cache = std.AutoHashMap(u21, Glyph).init(self.allocator),
        };
        path_owned_by_face = true;
        self.face_count += 1;

        log.appendLine("font", "chain[{d}] family={s} path={s}", .{ log_idx, family, fc_result.path });

        if (self.face_count == 1) {
            if (m_idx != 0 and self.ft_api.load_glyph(ft_face, m_idx, 0) == 0) {
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
            self.placeholder = rasterOne(self.allocator, self.ft_api, ft_face, '?') catch self.placeholder;
        }
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

/// fontconfig 가 fallback substitution 으로 시스템 default 매치하는 게 의도된
/// generic family. 그 외는 결과 family 명이 요청과 다르면 substitution 으로
/// 판단해서 chain 에 안 추가.
fn isGenericFamily(family: []const u8) bool {
    const generic = [_][]const u8{ "monospace", "sans-serif", "serif" };
    for (generic) |g| {
        if (std.ascii.eqlIgnoreCase(family, g)) return true;
    }
    return false;
}

fn rasterOne(
    allocator: std.mem.Allocator,
    api: freetype.Api,
    face: freetype.FT_Face,
    cp: u21,
) !Glyph {
    const idx = api.get_char_index(face, cp);
    // FT_LOAD_COLOR — emoji (BGRA) 도 raster. mono 폰트엔 무시.
    const load_flags = freetype.FT_LOAD_RENDER | freetype.FT_LOAD_COLOR;
    if (api.load_glyph(face, idx, load_flags) != 0) return error.FreetypeLoadGlyphFailed;
    const slot = face.glyph orelse return error.FreetypeNoGlyphSlot;
    const bm = slot.bitmap;

    var bitmap_slice: []u8 = &.{};
    var stored_pixel_mode: u8 = bm.pixel_mode;
    if (bm.buffer != null and bm.width > 0 and bm.rows > 0) {
        const w: usize = @intCast(bm.width);
        const h: usize = @intCast(bm.rows);
        const bytes_per_pixel: usize = switch (bm.pixel_mode) {
            freetype.FT_PIXEL_MODE_GRAY => 1,
            freetype.FT_PIXEL_MODE_BGRA => 4,
            else => 0,
        };
        if (bytes_per_pixel > 0) {
            bitmap_slice = try allocator.alloc(u8, w * h * bytes_per_pixel);
            const pitch_abs: usize = if (bm.pitch >= 0) @intCast(bm.pitch) else @intCast(-bm.pitch);
            const row_bytes = w * bytes_per_pixel;
            var row: usize = 0;
            while (row < h) : (row += 1) {
                const src = bm.buffer.?[row * pitch_abs .. row * pitch_abs + row_bytes];
                @memcpy(bitmap_slice[row * row_bytes .. row * row_bytes + row_bytes], src);
            }
        } else {
            stored_pixel_mode = freetype.FT_PIXEL_MODE_GRAY; // 빈 bitmap fallback
        }
    } else {
        stored_pixel_mode = freetype.FT_PIXEL_MODE_GRAY;
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
        .pixel_mode = stored_pixel_mode,
    };
}
