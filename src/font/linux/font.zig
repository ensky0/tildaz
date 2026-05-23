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
const harfbuzz = @import("harfbuzz.zig");
const log = @import("../../log.zig");
const font_constants = @import("../constants.zig");
const ligature = @import("../ligature.zig");

pub const MAX_CHAIN: usize = font_constants.MAX_CHAIN;

// Cross-platform ligature 타입 re-export — caller (software_terminal.zig)
// 가 `font.LigatureMatch` 식으로 그대로 쓸 수 있게.
pub const LigatureGlyph = ligature.LigatureGlyph;
pub const LigatureSpacer = ligature.LigatureSpacer;
pub const LigatureMatch = ligature.LigatureMatch;

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

/// HarfBuzz 가 shape 한 한 glyph. `cluster` 는 입력 codepoint array 의 어느
/// index 의 char 에서 나왔는지 (ligature 면 여러 char 가 같은 cluster index 공유).
/// mac `resolveGrapheme` 의 CTRun glyph / Win `shapeOnFaceMulti` 의 dwrite glyph
/// 와 같은 의미.
pub const ShapedGlyph = struct {
    /// FreeType `FT_Load_Glyph(idx, ...)` 에 직접 넣을 수 있는 glyph index. shape
    /// 결과라 codepoint 와 다른 값 (예: `=>` 가 한 ligature glyph 인덱스로 collapse).
    glyph_index: u32,
    /// 입력 codepoint array 의 *시작* index. ligature 면 첫 char 의 index, 그 뒤
    /// char 들은 같은 cluster 공유 (= 결과 ShapedGlyph 에 안 나옴).
    cluster: u32,
    /// 26.6 fixed point 의 integer 부 (px) — HarfBuzz 반환값을 >> 6.
    x_advance: i32,
    x_offset: i32,
    y_offset: i32,
};

pub const Face = struct {
    allocator: std.mem.Allocator,
    ft_face: freetype.FT_Face,
    family: []u8,
    /// 로딩 시 fontconfig 가 반환한 파일 path — chain 중복 제거에 사용.
    path: []u8,
    /// codepoint → Glyph cache (단순 lookup path, `Context.glyph` 가 사용).
    glyph_cache: std.AutoHashMap(u21, Glyph),
    /// glyph_index → Glyph cache (shape 결과의 ligature glyph 등 codepoint 와
    /// 다른 idx 의 cache). `Context.shapeRun` 의 결과 raster 가 사용.
    glyph_by_index: std.AutoHashMap(u32, Glyph),
    /// HarfBuzz hb_font (FT_Face 의 referenced wrap). HarfBuzz API 가 advertise
    /// 안 되거나 dlopen 실패 시 null — 그 경우 `shapeRun` 도 fallback (= 단순
    /// codepoint loop).
    hb_font: ?*harfbuzz.hb_font_t = null,

    fn deinit(self: *Face, ft_api: freetype.Api, hb_api: ?*const harfbuzz.Api) void {
        var it = self.glyph_cache.valueIterator();
        while (it.next()) |g| {
            if (g.bitmap.len > 0) self.allocator.free(g.bitmap);
        }
        self.glyph_cache.deinit();
        var it2 = self.glyph_by_index.valueIterator();
        while (it2.next()) |g| {
            if (g.bitmap.len > 0) self.allocator.free(g.bitmap);
        }
        self.glyph_by_index.deinit();
        if (self.hb_font) |hb| {
            if (hb_api) |api| api.font_destroy(hb);
        }
        _ = ft_api.done_face(self.ft_face);
        self.allocator.free(self.family);
        self.allocator.free(self.path);
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    ft_api: freetype.Api,
    ft_lib: freetype.FT_Library,
    /// HarfBuzz dlopen 결과. dlopen 실패 시 null — `shapeRun` 이 fallback (단순
    /// codepoint loop, ligature 안 됨, 기능 자체는 유지). compositor / OS 가
    /// libharfbuzz.so.0 없는 minimal Linux 환경 graceful degrade.
    hb_api: ?harfbuzz.Api = null,
    /// shape 호출 사이 reuse 하는 buffer. shape 마다 clear_contents 호출 후 재사용.
    hb_buffer: ?*harfbuzz.hb_buffer_t = null,
    /// 2-char ligature lookahead cache. `paint` loop 가 매 cell-pair 마다
    /// `ligaturePair(cp0, cp1)` 호출 — cache miss 면 shape + `detectLigatureMatch`
    /// 분류 후 store. key `= cp0 << 32 | cp1` (u53 packed in u64). value
    /// `.single` = 단일-glyph ligature, `.spacer` = Fira Code 식 다중-glyph
    /// ligature, `null` = ligature 아님 (자연 그대로). HashMap lookup 이 shape
    /// 호출 보다 훨씬 빠름 — terminal 의 같은 ASCII pair 가 매 frame 반복
    /// 호출되는 패턴 최적화.
    ligature_pair_cache: std.AutoHashMap(u64, ?LigatureMatch),
    /// 3-char ligature cache. `paint` loop 가 2-char 보다 먼저 3-char 시도
    /// (`===` / `<=>` / `!==` / `<--` 등 흔한 3-char ligature).
    /// key = `cp0 << 42 | cp1 << 21 | cp2` (3 × 21 bits = 63 bits, u64 안).
    ligature_triple_cache: std.AutoHashMap(u64, ?LigatureMatch),
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

        // HarfBuzz dlopen 시도. 실패해도 fatal 아님 — `shapeRun` 이 fallback
        // (codepoint loop, ligature 안 됨). graceful degrade.
        var hb_api: ?harfbuzz.Api = harfbuzz.Api.load() catch |err| blk: {
            log.appendLine("font", "HarfBuzz load skipped: {s} — ligature / cluster shape 비활성", .{@errorName(err)});
            break :blk null;
        };
        errdefer if (hb_api) |*api| api.deinit();
        const hb_buffer = if (hb_api) |api| api.buffer_create() else null;
        errdefer if (hb_buffer) |b| if (hb_api) |api| api.buffer_destroy(b);

        var self: Context = .{
            .allocator = allocator,
            .ft_api = ft_api,
            .ft_lib = ft_lib,
            .hb_api = hb_api,
            .hb_buffer = hb_buffer,
            .ligature_pair_cache = std.AutoHashMap(u64, ?LigatureMatch).init(allocator),
            .ligature_triple_cache = std.AutoHashMap(u64, ?LigatureMatch).init(allocator),
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

        // HarfBuzz 가 advertise 됐으면 FT_Face 를 hb_font 로 wrap. `_referenced`
        // 변종은 FT_Reference_Face 자동 — hb_font_destroy 시 FT_Done_Face 도 자동.
        // FT_Face 의 ownership 은 *hb_font 와 우리 둘 다 부분 소유* — Face.deinit
        // 에서 hb_font_destroy 호출 → FT 의 ref count 감소, 우리 FT_Done_Face
        // 가 마지막 ref 제거.
        const hb_font: ?*harfbuzz.hb_font_t = if (self.hb_api) |*api|
            api.ft_font_create_referenced(@ptrCast(ft_face))
        else
            null;

        self.faces[self.face_count] = .{
            .allocator = self.allocator,
            .ft_face = ft_face,
            .family = family_owned,
            .path = fc_result.path,
            .glyph_cache = std.AutoHashMap(u21, Glyph).init(self.allocator),
            .glyph_by_index = std.AutoHashMap(u32, Glyph).init(self.allocator),
            .hb_font = hb_font,
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
        self.ligature_pair_cache.deinit();
        self.ligature_triple_cache.deinit();
        if (self.hb_api) |*api| {
            if (self.hb_buffer) |b| api.buffer_destroy(b);
            api.deinit();
            self.hb_api = null;
            self.hb_buffer = null;
        }
        _ = self.ft_api.done_free_type(self.ft_lib);
        self.ft_api.deinit();
    }

    fn freeFaces(self: *Context) void {
        const hb_api_ptr: ?*const harfbuzz.Api = if (self.hb_api) |*api| api else null;
        for (&self.faces) |*slot| {
            if (slot.*) |*face| face.deinit(self.ft_api, hb_api_ptr);
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

    /// 지정 face 의 glyph_index 로 raster + cache. shape 결과의 ligature glyph
    /// (codepoint 안 갖는 idx) lookup 에 사용. caller 는 `LigatureGlyph` 의
    /// `face_idx` + `glyph_index` 를 그대로 넣음. ZWJ family emoji cluster
    /// (NotoColorEmoji face) 등 face_idx > 0 에서 raster 되어야 BGRA 가
    /// 살아남는 케이스 대응.
    pub fn glyphByIndex(self: *Context, face_idx: u8, glyph_index: u32) *const Glyph {
        if (face_idx >= self.face_count) return &self.placeholder;
        const face = if (self.faces[face_idx]) |*f| f else return &self.placeholder;
        if (face.glyph_by_index.getPtr(glyph_index)) |cached| return cached;
        const g = rasterByIndex(self.allocator, self.ft_api, face.ft_face, glyph_index) catch {
            return &self.placeholder;
        };
        face.glyph_by_index.put(glyph_index, g) catch {
            if (g.bitmap.len > 0) self.allocator.free(g.bitmap);
            return &self.placeholder;
        };
        return face.glyph_by_index.getPtr(glyph_index).?;
    }

    /// Latin (또는 모든 single-face shape-able) codepoint sequence 를 HarfBuzz
    /// 로 shape. 결과 ShapedGlyph 들을 `out` 에 채워서 *개수* 반환. caller 는
    /// glyph_index 로 `glyphByIndex` 호출해 raster 받음.
    ///
    /// `cps.len <= 16` 권장 — short Latin sequence (terminal ligature run) 의
    /// 가벼운 path. HarfBuzz 미지원 환경 또는 primary face 의 hb_font 가 null
    /// 이면 fallback: 각 cp 의 단순 glyph_index 그대로 1:1 매핑 (= ligature 미적용,
    /// 기존 동작 동등). out 길이 부족하면 fit 만큼만 채움.
    ///
    /// terminal 패턴: ligature 면 결과 glyph 수 < cps 수. 첫 cluster 의 ShapedGlyph
    /// 만 그리고 나머지 cluster index 의 cell 은 빈 background — kitty / alacritty
    /// 패턴.
    pub fn shapeRun(self: *Context, cps: []const u21, out: []ShapedGlyph) usize {
        return self.shapeRunOnFace(0, cps, out);
    }

    /// `shapeRun` 의 multi-face 변종 — `face_idx` 지정. ZWJ family / VS-16 emoji
    /// cluster 가 emoji face (NotoColorEmoji 등) 에서만 GSUB 합성되는 케이스
    /// 대응. caller 는 `resolveCluster` 처럼 chain 순회로 매치 face 검색.
    ///
    /// HarfBuzz 미advertise / face hb_font 없음 — face_idx==0 면 fallback
    /// (cp → idx 1:1), 그 외 face 는 0 반환 (그 face 시도는 skip).
    pub fn shapeRunOnFace(self: *Context, face_idx: u8, cps: []const u21, out: []ShapedGlyph) usize {
        if (cps.len == 0 or out.len == 0 or self.face_count == 0) return 0;
        if (face_idx >= self.face_count) return 0;

        const hb_api = if (self.hb_api) |*api| api else {
            if (face_idx == 0) return self.shapeRunFallback(cps, out);
            return 0;
        };
        const hb_buf = self.hb_buffer orelse {
            if (face_idx == 0) return self.shapeRunFallback(cps, out);
            return 0;
        };
        const face = if (self.faces[face_idx]) |*f| f else return 0;
        const hb_font = face.hb_font orelse {
            if (face_idx == 0) return self.shapeRunFallback(cps, out);
            return 0;
        };

        // codepoint array 를 u32 로 reinterpret (u21 → u32 동일 비트 layout 아님
        // → 명시 변환 buffer 사용).
        var u32_buf: [64]u32 = undefined;
        const n = @min(cps.len, u32_buf.len);
        for (cps[0..n], 0..) |cp, i| u32_buf[i] = @intCast(cp);

        hb_api.buffer_clear_contents(hb_buf);
        hb_api.buffer_add_codepoints(hb_buf, &u32_buf, @intCast(n), 0, @intCast(n));
        // `guess_segment_properties` 가 direction / script / language 를 자동
        // 결정 — Latin 이면 LTR + Latn. 또는 명시 set 해도 OK.
        hb_api.buffer_guess_segment_properties(hb_buf);

        hb_api.shape(hb_font, hb_buf, null, 0);

        var glyph_count: c_uint = 0;
        const infos = hb_api.buffer_get_glyph_infos(hb_buf, &glyph_count);
        const positions = hb_api.buffer_get_glyph_positions(hb_buf, &glyph_count);

        const result_count = @min(@as(usize, glyph_count), out.len);
        for (0..result_count) |i| {
            out[i] = .{
                .glyph_index = infos[i].codepoint,
                .cluster = infos[i].cluster,
                .x_advance = @divFloor(positions[i].x_advance, 64),
                .x_offset = @divFloor(positions[i].x_offset, 64),
                .y_offset = @divFloor(positions[i].y_offset, 64),
            };
        }
        return result_count;
    }

    /// grapheme cluster (VS-16 / skin tone / ZWJ 시퀀스 / combining mark) 의
    /// shape 결과를 하나의 representative glyph 로 reduce. cps 는 base + extras
    /// 의 codepoint array (`cell.raw.codepoint()` + `cell.grapheme` 의 합).
    /// mac `CoreTextFontContext.resolveGrapheme` / Win `DWriteFontContext.
    /// resolveGrapheme` 와 같은 의미.
    ///
    /// HarfBuzz GSUB 가 합성 가능한 cluster (대부분 — VS-16 emoji, skin tone,
    /// ZWJ family) 는 shape 결과 1 glyph 이라 그 glyph_index 를 그대로 raster.
    /// chain 의 *모든 face* 를 순회 — primary monospace 가 VS-16 emoji 의 GSUB
    /// 합성 안 하는 케이스도 NotoColorEmoji face 에서 shape 시 1 glyph 가 되어
    /// face_idx>0 으로 매치. mac `CTLineCreateWithAttributedString` 의 자동
    /// fallback / Win `IDWriteTextAnalyzer.GetGlyphs` 의 face fallback 동등.
    ///
    /// 매치 정책 — 첫 face 가 *clean single-glyph* (= n==1 + glyph_index != 0)
    /// 결과 내면 그 face 결과 return. 그 외 (다중 glyph 또는 0-glyph) 는 다음
    /// face 시도. 모든 face 미매치면 null — caller 가 base codepoint chain
    /// lookup (`glyph(cp)`) 으로 fallback (cluster extras 무시되지만 base 표시).
    pub fn resolveCluster(self: *Context, cps: []const u21) ?LigatureGlyph {
        if (cps.len == 0 or self.face_count == 0 or self.hb_api == null) return null;

        var shape_buf: [16]ShapedGlyph = undefined;
        for (0..self.face_count) |face_idx| {
            const idx_u8: u8 = @intCast(face_idx);
            const n = self.shapeRunOnFace(idx_u8, cps, &shape_buf);
            if (n != 1) continue;
            if (shape_buf[0].glyph_index == 0) continue;
            return .{
                .face_idx = idx_u8,
                .glyph_index = shape_buf[0].glyph_index,
                .x_offset = shape_buf[0].x_offset,
                .y_offset = shape_buf[0].y_offset,
            };
        }
        return null;
    }

    /// 2-char ligature lookup with cache. paint loop 가 매 cell pair 에 호출.
    /// `cp0` + `cp1` shape 결과 glyph 1 개면 ligature → 그 정보 반환. 2 개면
    /// no ligature → null. cache 가 결과 보관 — 같은 pair 반복 호출 시 shape
    /// 호출 회피.
    ///
    /// caller 패턴 (software_terminal.paint):
    /// ```
    /// if (font_ctx.ligaturePair(cp0, cp1)) |lg| {
    ///     // ligature glyph 첫 cell 위치에 그리고 둘째 cell 은 skip
    /// } else {
    ///     // single-char path (기존)
    /// }
    /// ```
    pub fn ligaturePair(self: *Context, cp0: u21, cp1: u21) ?LigatureMatch {
        if (self.face_count == 0 or self.hb_api == null) return null;
        const key: u64 = (@as(u64, cp0) << 32) | @as(u64, cp1);
        if (self.ligature_pair_cache.get(key)) |cached| return cached;

        // cache miss — shape 실행. 결과 1 glyph 면 single-glyph ligature (JetBrains
        // Mono 등), N glyph 인데 indices 가 natural 과 다르면 spacer ligature
        // (Fira Code 등 — `=>` 가 자연 glyph 2개가 아닌 spacer pair 2개로 substitute).
        // 둘 다 아니면 ligature 아님.
        var pair_cps: [2]u21 = .{ cp0, cp1 };
        var shape_buf: [4]ShapedGlyph = undefined;
        const n = self.shapeRun(&pair_cps, &shape_buf);

        const result = detectLigatureMatch(self, &pair_cps, &shape_buf, n);
        self.ligature_pair_cache.put(key, result) catch {};
        return result;
    }

    /// 3-char ligature lookup with cache. `ligaturePair` 와 동일 패턴, 3 cp.
    /// Fira Code / JetBrains Mono / Cascadia Code 의 흔한 3-char ligature
    /// (`===` / `!==` / `<=>` / `<--` / `-->` / `<->` 등) 대응. paint loop 는
    /// 3-char 먼저 시도 → 결과 1 glyph 면 ligature 확정 + 3 cell skip; 아니면
    /// 2-char (`ligaturePair`) 시도; 둘 다 미매치면 single-char.
    ///
    /// key 는 3 × 21 bits = 63 bits packed in u64 — 충돌 없는 unique 식별.
    pub fn ligatureTriple(self: *Context, cp0: u21, cp1: u21, cp2: u21) ?LigatureMatch {
        if (self.face_count == 0 or self.hb_api == null) return null;
        const key: u64 = (@as(u64, cp0) << 42) | (@as(u64, cp1) << 21) | @as(u64, cp2);
        if (self.ligature_triple_cache.get(key)) |cached| return cached;

        var triple_cps: [3]u21 = .{ cp0, cp1, cp2 };
        var shape_buf: [4]ShapedGlyph = undefined;
        const n = self.shapeRun(&triple_cps, &shape_buf);

        const result = detectLigatureMatch(self, &triple_cps, &shape_buf, n);
        self.ligature_triple_cache.put(key, result) catch {};
        return result;
    }

    /// shape 결과 (`shape_buf[0..n]`) 와 입력 `cps` 를 비교해 single-glyph
    /// 또는 spacer-pattern ligature 판정.
    ///
    /// - `n < cps.len`: 입력보다 결과 glyph 수가 적음 = classic single-glyph
    ///   ligature (JetBrains Mono / Cascadia Code 의 일부). 첫 glyph 으로 N
    ///   cell width 차지.
    /// - `n == cps.len`: 결과 glyph 수가 입력과 같음. *naturalindices 와 다르면*
    ///   spacer-pattern ligature (Fira Code 의 디폴트 — `=>` 가 2 glyph 으로
    ///   substitute 되되 그 indices 가 자연 `=`, `>` 와 다름). 자연 그대로면
    ///   ligature 아님 (단순 `=>` 가 ligature 없는 폰트).
    /// - 그 외 (n == 0 or n > cps.len): 비정상 결과 — null.
    /// HarfBuzz shape 결과를 `ligature.ShapedSlot[]` 으로 normalize 후 공유
    /// `ligature.classify` 호출. natural indices 는 primary face 의 FreeType
    /// `get_char_index` 로 계산. mac / Windows 도 같은 `classify` 사용.
    ///
    /// `n > cps.len` 인 비정상 shape 결과는 classify 가 null 반환 — slots 채울
    /// 때 cps OOB 만 안 일어나면 됨 (cp_idx clamp).
    fn detectLigatureMatch(self: *Context, cps: []const u21, shape_buf: []const ShapedGlyph, n: usize) ?LigatureMatch {
        if (self.face_count == 0 or cps.len == 0) return null;
        const face = if (self.faces[0]) |*f| f else return null;

        var slots: [4]ligature.ShapedSlot = undefined;
        const checked = @min(n, slots.len);
        for (0..checked) |i| {
            const cp_idx = @min(i, cps.len - 1);
            slots[i] = .{
                .glyph_index = shape_buf[i].glyph_index,
                .natural_glyph_index = self.ft_api.get_char_index(face.ft_face, @intCast(cps[cp_idx])),
                .x_offset = shape_buf[i].x_offset,
                .y_offset = shape_buf[i].y_offset,
            };
        }
        return ligature.classify(cps.len, slots[0..checked]);
    }

    /// HarfBuzz 미지원 / 미적용 환경의 fallback. 각 codepoint 의 단순 glyph_index
    /// (FreeType `get_char_index`) 그대로 1:1 매핑 — ligature 없음, 기존 동작
    /// 동등.
    fn shapeRunFallback(self: *Context, cps: []const u21, out: []ShapedGlyph) usize {
        if (self.face_count == 0) return 0;
        const face = if (self.faces[0]) |*f| f else return 0;
        const n = @min(cps.len, out.len);
        for (cps[0..n], 0..) |cp, i| {
            const idx = self.ft_api.get_char_index(face.ft_face, cp);
            out[i] = .{
                .glyph_index = idx,
                .cluster = @intCast(i),
                .x_advance = @intCast(self.cell_width_px),
                .x_offset = 0,
                .y_offset = 0,
            };
        }
        return n;
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
    return rasterByIndexInner(allocator, api, face, idx);
}

/// shape 결과의 glyph_index (codepoint 안 갖는 ligature idx 등) 로 직접 raster.
/// `rasterOne` 이 cp → idx 변환 후 같은 path 호출.
fn rasterByIndex(
    allocator: std.mem.Allocator,
    api: freetype.Api,
    face: freetype.FT_Face,
    glyph_index: u32,
) !Glyph {
    return rasterByIndexInner(allocator, api, face, glyph_index);
}

fn rasterByIndexInner(
    allocator: std.mem.Allocator,
    api: freetype.Api,
    face: freetype.FT_Face,
    idx: u32,
) !Glyph {
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
