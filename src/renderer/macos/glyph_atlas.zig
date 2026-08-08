// 글리프 텍스처 아틀라스 — CoreText 로 글리프 라스터 + 2D atlas (BGRA8) 에 캐시.
// macOS Mojave 이후 subpixel/ClearType 미지원이라 일반 텍스트는 grayscale alpha
// 로 충분하지만, Apple Color Emoji (SBIX) 같은 컬러 글리프는 BGRA premultiplied
// 비트맵이 필요해 atlas 자체를 BGRA8 로 통일 (#132). Metal 텍스처는 BGRA8Unorm.
//
// 라스터 path 단일화: 모든 글리프를 RGBA premultiplied + 흰색 fill 로 그림.
// - 일반 글리프: antialiased 흰색 → atlas 픽셀 = (a, a, a, a). 셰이더가 fg 와 곱해 tint.
// - 컬러 글리프 (CTFontGetSymbolicTraits & kCTFontTraitColorGlyphs): SBIX bitmap
//   이 fill 색깔 무시하고 그대로 합성 → atlas 픽셀 = 본래 색 premultiplied. 셰이더
//   는 fg 무시하고 atlas 그대로 출력.
// AtlasEntry.is_color 가 셰이더 path 결정 — TextInstance 의 color_flag 로 전달.
//
// #75 (claude/infallible-swartz) 패턴 + #132 컬러 emoji 확장.

const std = @import("std");
const ct = @import("../../font/macos/coretext.zig");
const tab_icons = @import("../../tab_icons.zig");
const atlas_common = @import("../glyph_atlas_common.zig");

pub const ATLAS_SIZE: u32 = 2048;

// #282 G5 — AtlasEntry / GlyphKey / packing 은 Windows atlas 와 공통(라인 동일).
pub const AtlasEntry = atlas_common.AtlasEntry;
const GlyphKey = atlas_common.GlyphKey;

pub const GlyphAtlas = struct {
    alloc: std.mem.Allocator,
    cache: std.AutoHashMap(GlyphKey, AtlasEntry),

    // 단순 row-based packing 상태.
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    row_height: u32 = 0,

    // 라스터 시 사용할 폰트 메트릭.
    font_size: f32,
    scale: f32, // Retina backing scale (1.0 / 2.0).

    // 아틀라스 픽셀 데이터 (BGRA8 — 4 bytes per pixel, premultiplied alpha).
    // 일반 글리프는 (a, a, a, a) (흰색 premult), 컬러 글리프는 (B*a, G*a, R*a, a).
    pixels: []u8,

    // Metal 업로드를 위한 dirty 영역 트래킹.
    dirty: bool = false,
    dirty_min_y: u32 = ATLAS_SIZE,
    dirty_max_y: u32 = 0,

    // 글리프 라스터 임시 버퍼 (RGBA premultiplied, max 256x256).
    temp_buf: []u8,

    pub fn init(
        alloc: std.mem.Allocator,
        font_size: f32,
        scale: f32,
    ) !GlyphAtlas {
        // BGRA8 = 4 bytes per pixel.
        const pixels = try alloc.alloc(u8, ATLAS_SIZE * ATLAS_SIZE * 4);
        @memset(pixels, 0);

        const temp_buf = try alloc.alloc(u8, 256 * 256 * 4);

        return .{
            .alloc = alloc,
            .cache = std.AutoHashMap(GlyphKey, AtlasEntry).init(alloc),
            .font_size = font_size,
            .scale = scale,
            .pixels = pixels,
            .temp_buf = temp_buf,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.alloc.free(self.temp_buf);
        self.alloc.free(self.pixels);
        self.cache.deinit();
    }

    /// 글리프 lookup or rasterize. 라스터 실패 시 null.
    pub fn getOrInsert(self: *GlyphAtlas, font: ct.CTFontRef, glyph_index: ct.CGGlyph) ?AtlasEntry {
        const key = GlyphKey{ .font_ptr = @intFromPtr(font), .index = glyph_index };
        if (self.cache.get(key)) |entry| return entry;

        const entry = self.rasterize(font, glyph_index) orelse return null;
        self.cache.put(key, entry) catch return null;
        return entry;
    }

    /// #401 — **cluster 가 글리프 여러 개일 때 하나의 비트맵으로 합성**한다.
    ///
    /// Apple Color Emoji 는 `👨‍❤️‍👨` 같은 `❤️` 조합을 글리프 2 개로 준다 (`👨‍👩‍👧` 는 1 개다).
    /// 예전에는 첫 글리프만 그려서 `👨` 만 보였다. Windows 의 `getOrInsertCluster` 와 같은
    /// 자리이고, 거기서 `advances` · `offsets` 를 넘기는 것이 여기서는 `positions` 다 — `CTRun`
    /// 이 준 GPOS 적용 위치라 이대로 그려야 모양이 맞는다.
    ///
    /// 글리프가 하나면 기존 경로로 넘긴다 — 키가 `(font, index)` 라 캐시 적중률이 그쪽이 높다.
    pub fn getOrInsertCluster(
        self: *GlyphAtlas,
        font: ct.CTFontRef,
        glyphs: []const ct.CGGlyph,
        positions: []const ct.CGPoint,
        /// cluster 가 차지하는 가로 폭 (pt). 0 이면 모르는 것이라 첫 글리프 advance 로 물러선다.
        /// 폰트 층이 `CTRunGetTypographicBounds` 로 재서 넘긴다 (#401).
        cluster_advance_pt: f32,
    ) ?AtlasEntry {
        if (glyphs.len == 0) return null;
        if (glyphs.len == 1) return self.getOrInsert(font, glyphs[0]);

        // 키는 글리프 인덱스들의 해시다. 같은 폰트 안에서 인덱스 조합이 같으면 결과가 같다
        // (positions 는 그 조합에서 결정되므로 키에 안 넣는다).
        var h = std.hash.Wyhash.init(0xC1_05_7E_47);
        for (glyphs) |g| h.update(std.mem.asBytes(&g));
        const key = GlyphKey{ .font_ptr = @intFromPtr(font), .index = @truncate(h.final()) };
        if (self.cache.get(key)) |entry| return entry;

        const entry = self.rasterizeCluster(font, glyphs, positions, cluster_advance_pt) orelse return null;
        self.cache.put(key, entry) catch return null;
        return entry;
    }

    /// 탭바 컨트롤 아이콘 (`< > × +`) 을 `tab_icons` 로 rasterize 해 atlas 에
    /// 캐시 (#268). 폰트 글리프가 아니라 우리가 만든 알파 커버리지라 codepoint
    /// 대신 아이콘 enum 을 key 로 씀 (font=0 은 유효한 CTFontRef 아님). 커버리지
    /// `a` 를 흰색 premultiplied (a,a,a,a) 로 써서 일반 글리프와 같은 셰이더
    /// tint 경로 사용. scale 변경 시 `applyScale` 이 `reset` 하므로 다음 render
    /// 에서 새 size 로 재라스터.
    pub fn getOrInsertIcon(self: *GlyphAtlas, icon: tab_icons.Icon, size: u32, stroke_px: f32) ?AtlasEntry {
        const key = GlyphKey{ .font_ptr = 0, .index = @intFromEnum(icon) };
        if (self.cache.get(key)) |entry| return entry;
        if (size == 0 or size > tab_icons.MAX_SIZE) return null;

        var cov: [tab_icons.MAX_SIZE * tab_icons.MAX_SIZE]u8 = undefined;
        tab_icons.rasterize(icon, size, stroke_px, &cov);

        const bytes_per_row = size * 4;
        for (0..size) |row| {
            for (0..size) |col| {
                const a = cov[row * size + col];
                const off = row * bytes_per_row + col * 4;
                // BGRA premultiplied 흰색 — 일반 글리프와 동일 (a,a,a,a).
                self.temp_buf[off + 0] = a;
                self.temp_buf[off + 1] = a;
                self.temp_buf[off + 2] = a;
                self.temp_buf[off + 3] = a;
            }
        }

        const pos = self.packGlyph(size, size) orelse blk: {
            self.reset();
            break :blk self.packGlyph(size, size) orelse return null;
        };
        const atlas_x = pos[0];
        const atlas_y = pos[1];
        const atlas_row_bytes = ATLAS_SIZE * 4;
        for (0..size) |row| {
            const src_off = row * bytes_per_row;
            const dst_off = (atlas_y + @as(u32, @intCast(row))) * atlas_row_bytes + atlas_x * 4;
            @memcpy(self.pixels[dst_off..][0..bytes_per_row], self.temp_buf[src_off..][0..bytes_per_row]);
        }

        self.dirty = true;
        if (atlas_y < self.dirty_min_y) self.dirty_min_y = atlas_y;
        if (atlas_y + size > self.dirty_max_y) self.dirty_max_y = atlas_y + size;

        const entry = AtlasEntry{
            .x = @intCast(atlas_x),
            .y = @intCast(atlas_y),
            .w = @intCast(size),
            .h = @intCast(size),
            .bearing_x = 0,
            .bearing_y = 0,
            .is_color = false,
        };
        self.cache.put(key, entry) catch return null;
        return entry;
    }

    /// 아틀라스 reset (cache + packing 상태 + 픽셀 모두 클리어).
    pub fn reset(self: *GlyphAtlas) void {
        self.cache.clearRetainingCapacity();
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.row_height = 0;
        @memset(self.pixels, 0);
        self.dirty = true;
        self.dirty_min_y = 0;
        self.dirty_max_y = ATLAS_SIZE;
    }

    /// #401 — 여러 글리프를 `positions` 대로 한 비트맵에 그린다. `rasterize` 의 multi-glyph 판이라
    /// 주석은 그쪽을 참고한다 (색 · smoothing · CTM scale · baseline 정렬 이유가 모두 같다).
    ///
    /// **다른 것은 bounding box 하나다.** 글리프마다 rect 를 받아 각자의 position 만큼 옮긴 뒤
    /// 합집합을 낸다 — 그래야 겹쳐 쌓이는 글리프 (Apple Color Emoji 의 `❤️` 조합) 가 안 잘린다.
    fn rasterizeCluster(
        self: *GlyphAtlas,
        font: ct.CTFontRef,
        glyphs: []const ct.CGGlyph,
        positions: []const ct.CGPoint,
        cluster_advance_pt: f32,
    ) ?AtlasEntry {
        const n = glyphs.len;
        if (n == 0 or n > 16 or positions.len < n) return null;

        var rects: [16]ct.CGRect = undefined;
        _ = ct.CTFontGetBoundingRectsForGlyphs(
            font,
            ct.kCTFontOrientationDefault,
            glyphs.ptr,
            @ptrCast(&rects),
            @intCast(n),
        );

        // 각 글리프 rect 를 자기 position 만큼 옮겨 합집합. 여기가 단일 글리프판과 갈리는 곳이다.
        var min_x = rects[0].origin.x + positions[0].x;
        var min_y = rects[0].origin.y + positions[0].y;
        var max_x = min_x + rects[0].size.width;
        var max_y = min_y + rects[0].size.height;
        for (1..n) |i| {
            const rx = rects[i].origin.x + positions[i].x;
            const ry = rects[i].origin.y + positions[i].y;
            if (rx < min_x) min_x = rx;
            if (ry < min_y) min_y = ry;
            if (rx + rects[i].size.width > max_x) max_x = rx + rects[i].size.width;
            if (ry + rects[i].size.height > max_y) max_y = ry + rects[i].size.height;
        }

        const traits = ct.CTFontGetSymbolicTraits(font);
        const is_color = (traits & ct.kCTFontTraitColorGlyphs) != 0;

        // cluster 가 차지하는 폭. renderer 가 이 값으로 셀 안 가운데 정렬을 한다
        // (`glyphCenterDx`). 폰트 층이 재 준 값을 쓰고, 못 받았을 때만 첫 글리프 advance 로
        // 물러선다 — 그 값은 **가로로 늘어서는 cluster 에서 틀린다** (Devanagari `क्षि` 는
        // 첫 글리프 4.09 pt, cluster 15.33 pt. 실측으로 14 px 밀렸다, #401).
        const advance_px: f32 = if (cluster_advance_pt > 0)
            cluster_advance_pt * @as(f32, @floatCast(self.scale))
        else blk: {
            var adv = [1]ct.CGSize{.{ .width = 0, .height = 0 }};
            var first = [1]ct.CGGlyph{glyphs[0]};
            _ = ct.CTFontGetAdvancesForGlyphs(font, ct.kCTFontOrientationDefault, &first, &adv, 1);
            break :blk @floatCast(adv[0].width * self.scale);
        };

        const s = self.scale;
        const x0 = @floor(min_x * s);
        const y0 = @floor(min_y * s);
        const x1 = @ceil(max_x * s);
        const y1 = @ceil(max_y * s);
        const gw_f = x1 - x0;
        const gh_f = y1 - y0;
        if (gw_f <= 0 or gh_f <= 0) return null;

        const gw: u32 = @intFromFloat(gw_f);
        const gh: u32 = @intFromFloat(gh_f);
        if (gw > 256 or gh > 256) return null; // temp_buf 한계.

        const bytes_per_row = gw * 4;
        const colorspace = ct.CGColorSpaceCreateDeviceRGB() orelse return null;
        defer ct.CGColorSpaceRelease(colorspace);
        const ctx = ct.CGBitmapContextCreate(
            self.temp_buf.ptr,
            gw,
            gh,
            8,
            bytes_per_row,
            colorspace,
            ct.kCGImageAlphaPremultipliedFirst | ct.kCGBitmapByteOrder32Little,
        ) orelse return null;
        defer ct.CGContextRelease(ctx);

        @memset(self.temp_buf[0 .. gw * gh * 4], 0);
        ct.CGContextSetAllowsFontSmoothing(ctx, true);
        ct.CGContextSetShouldSmoothFonts(ctx, true);
        ct.CGContextSetShouldAntialias(ctx, true);
        ct.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
        ct.CGContextScaleCTM(ctx, @floatCast(s), @floatCast(s));

        // 합집합 원점을 비트맵 (0,0) 에 맞추고, 각 글리프는 자기 position 을 더해 그린다.
        // 원점 보정이 `floor(·*s)/s` 인 이유는 단일 글리프판과 같다 (#156 baseline jitter).
        const base_x = -@floor(min_x * s) / s;
        const base_y = -@floor(min_y * s) / s;
        var draw_pos: [16]ct.CGPoint = undefined;
        for (0..n) |i| {
            draw_pos[i] = .{ .x = base_x + positions[i].x, .y = base_y + positions[i].y };
        }
        ct.CTFontDrawGlyphs(font, glyphs.ptr, &draw_pos, n, ctx);

        const pos = self.packGlyph(gw, gh) orelse blk: {
            self.reset();
            break :blk self.packGlyph(gw, gh) orelse return null;
        };
        const atlas_x = pos[0];
        const atlas_y = pos[1];
        const atlas_row_bytes = ATLAS_SIZE * 4;
        for (0..gh) |row| {
            const src_off = row * bytes_per_row;
            const dst_off = (atlas_y + @as(u32, @intCast(row))) * atlas_row_bytes + atlas_x * 4;
            @memcpy(self.pixels[dst_off..][0..bytes_per_row], self.temp_buf[src_off..][0..bytes_per_row]);
        }
        self.dirty = true;
        if (atlas_y < self.dirty_min_y) self.dirty_min_y = atlas_y;
        if (atlas_y + gh > self.dirty_max_y) self.dirty_max_y = atlas_y + gh;

        return AtlasEntry{
            .x = @intCast(atlas_x),
            .y = @intCast(atlas_y),
            .w = @intCast(gw),
            .h = @intCast(gh),
            .bearing_x = @intFromFloat(x0),
            .bearing_y = @intFromFloat(y0),
            .is_color = is_color,
            .advance = advance_px,
        };
    }

    fn rasterize(self: *GlyphAtlas, font: ct.CTFontRef, glyph_index: ct.CGGlyph) ?AtlasEntry {
        const glyphs = [1]ct.CGGlyph{glyph_index};
        var bounding_rect: ct.CGRect = undefined;
        _ = ct.CTFontGetBoundingRectsForGlyphs(
            font,
            ct.kCTFontOrientationDefault,
            &glyphs,
            @ptrCast(&bounding_rect),
            1,
        );

        // 폰트 트레이트 — SBIX/COLR (Apple Color Emoji 등) 면 컬러 글리프.
        // 같은 RGBA path 로 그리지만 셰이더 분기를 위해 entry 에 플래그 저장.
        const traits = ct.CTFontGetSymbolicTraits(font);
        const is_color = (traits & ct.kCTFontTraitColorGlyphs) != 0;

        // 글리프 advance (pt) → 물리 px. 셀 영역 가운데 정렬용 (#299).
        var adv_size = [1]ct.CGSize{.{ .width = 0, .height = 0 }};
        _ = ct.CTFontGetAdvancesForGlyphs(font, ct.kCTFontOrientationDefault, &glyphs, &adv_size, 1);
        const advance_px: f32 = @floatCast(adv_size[0].width * self.scale);

        // Retina 스케일 적용 + 정수 픽셀 align.
        const s = self.scale;
        const x0 = @floor(bounding_rect.origin.x * s);
        const y0 = @floor(bounding_rect.origin.y * s);
        const x1 = @ceil((bounding_rect.origin.x + bounding_rect.size.width) * s);
        const y1 = @ceil((bounding_rect.origin.y + bounding_rect.size.height) * s);

        const gw_f = x1 - x0;
        const gh_f = y1 - y0;

        if (gw_f <= 0 or gh_f <= 0) {
            // 빈 글리프 (space, control char 등).
            return AtlasEntry{
                .x = 0,
                .y = 0,
                .w = 0,
                .h = 0,
                .bearing_x = @intFromFloat(x0),
                .bearing_y = @intFromFloat(y0),
                .is_color = is_color,
                .advance = advance_px,
            };
        }

        const gw: u32 = @intFromFloat(gw_f);
        const gh: u32 = @intFromFloat(gh_f);

        if (gw > 256 or gh > 256) return null; // temp_buf 한계.

        // BGRA premultiplied CGBitmapContext.
        // PremultipliedFirst + ByteOrder32Little = 메모리 레이아웃 BGRA →
        // Metal BGRA8Unorm 텍스처와 직접 매칭.
        // - 일반 글리프: 흰색 fill 로 antialiased 라스터 → 픽셀 = (a, a, a, a).
        //   셰이더가 fg 와 곱해 색 입힘.
        // - 컬러 글리프 (SBIX): fill 색 무시되고 본래 비트맵 합성 → 픽셀 = 본래 색
        //   premultiplied. 셰이더는 atlas 그대로 출력.
        const bytes_per_row = gw * 4;
        const colorspace = ct.CGColorSpaceCreateDeviceRGB() orelse return null;
        defer ct.CGColorSpaceRelease(colorspace);
        const ctx = ct.CGBitmapContextCreate(
            self.temp_buf.ptr,
            gw,
            gh,
            8,
            bytes_per_row,
            colorspace,
            ct.kCGImageAlphaPremultipliedFirst | ct.kCGBitmapByteOrder32Little,
        ) orelse return null;
        defer ct.CGContextRelease(ctx);

        // 매 글리프마다 temp_buf 의 사용 영역 (gw*gh*4 bytes) 만 0 으로 clear.
        @memset(self.temp_buf[0 .. gw * gh * 4], 0);

        // Apple 의 LCD font smoothing (회색 stroke fattening). Terminal.app /
        // iTerm2 default 와 동등 (#157). retina 환경에서 stroke 약간 두꺼워져
        // 검정 배경 흰 글자 가독성 향상. RGB subpixel 이 아니라 회색 fattening
        // 이라 색 fringing 없음. 사용자 취향 차이 있어 향후 config 옵션화 검토.
        ct.CGContextSetAllowsFontSmoothing(ctx, true);
        ct.CGContextSetShouldSmoothFonts(ctx, true);
        ct.CGContextSetShouldAntialias(ctx, true);

        // 흰색 opaque fill — 일반 글리프엔 흰색 antialiased 마스크가 그려짐.
        // 컬러 글리프는 이 색깔 무시되고 SBIX bitmap 의 본래 색이 들어감.
        ct.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);

        // CTM scale = Retina factor. bitmap 은 gw x gh pixel 인데
        // CTFontDrawGlyphs 는 point 좌표로 그리므로 scale 보정 없으면 글리프가
        // 1/scale 크기로 작게 들어간다 (#75 nostalgic-edison 의 결정적 fix).
        ct.CGContextScaleCTM(ctx, @floatCast(s), @floatCast(s));

        // 글리프의 baseline 위치를 bitmap 안에서 *정수 pixel* 그리드와 정확히
        // 정렬 (#156). 직접 `-origin.x`/`-origin.y` 를 쓰면 bitmap 의 (0,0)
        // pixel 이 글리프별로 fractional offset 만큼 어긋나, 정수 bearing 으로
        // 화면에 placement 할 때 글리프마다 ±0.5 logical-px baseline jitter
        // 발생 (사용자 시연: C 내려가고, 4/7 올라감).
        //
        // floor(origin*s)/s 로 보정하면 bitmap (0,0) 이 정확히 bearing pixel
        // 위치에 align. 글리프의 진짜 fractional 위치는 bitmap 안에서 sub-pixel
        // anti-aliasing 으로 흡수 (gw/gh 가 ceil-floor 라 충분한 여유). renderer
        // 는 정수 bearing 만 쓰면 baseline 일관 정렬. iTerm2 / Terminal.app
        // 표준 패턴.
        const pos_x_pt = -@floor(bounding_rect.origin.x * s) / s;
        const pos_y_pt = -@floor(bounding_rect.origin.y * s) / s;
        const positions = [1]ct.CGPoint{.{
            .x = pos_x_pt,
            .y = pos_y_pt,
        }};
        ct.CTFontDrawGlyphs(font, &glyphs, &positions, 1, ctx);

        // 아틀라스에 packing.
        const pos = self.packGlyph(gw, gh) orelse blk: {
            self.reset();
            break :blk self.packGlyph(gw, gh) orelse return null;
        };

        // BGRA temp_buf (4 bytes per pixel) 를 atlas (BGRA8) 로 row 단위 복사.
        const atlas_x = pos[0];
        const atlas_y = pos[1];
        const atlas_row_bytes = ATLAS_SIZE * 4;
        for (0..gh) |row| {
            const src_off = row * bytes_per_row;
            const dst_off = (atlas_y + @as(u32, @intCast(row))) * atlas_row_bytes + atlas_x * 4;
            @memcpy(self.pixels[dst_off..][0..bytes_per_row], self.temp_buf[src_off..][0..bytes_per_row]);
        }

        // dirty 영역 마킹.
        self.dirty = true;
        if (atlas_y < self.dirty_min_y) self.dirty_min_y = atlas_y;
        if (atlas_y + gh > self.dirty_max_y) self.dirty_max_y = atlas_y + gh;

        return AtlasEntry{
            .x = @intCast(atlas_x),
            .y = @intCast(atlas_y),
            .w = @intCast(gw),
            .h = @intCast(gh),
            .bearing_x = @intFromFloat(x0),
            .bearing_y = @intFromFloat(y0),
            .is_color = is_color,
            .advance = advance_px,
        };
    }

    /// #282 G5 — 공통 row-based packing 에 위임.
    fn packGlyph(self: *GlyphAtlas, w: u32, h: u32) ?[2]u32 {
        return atlas_common.packRow(&self.cursor_x, &self.cursor_y, &self.row_height, ATLAS_SIZE, w, h);
    }
};
