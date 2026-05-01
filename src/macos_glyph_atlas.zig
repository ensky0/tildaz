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
const ct = @import("macos_coretext.zig");

pub const ATLAS_SIZE: u32 = 2048;

pub const AtlasEntry = struct {
    x: u16, // 아틀라스 내 위치 (pixel).
    y: u16,
    w: u16, // 글리프 크기 (pixel).
    h: u16,
    bearing_x: i16, // cell origin 에서 글리프 좌상단까지 offset.
    bearing_y: i16,
    /// SBIX/COLR 컬러 글리프 (Apple Color Emoji 등). 셰이더가 fg 무시하고 atlas
    /// 그대로 출력하는 분기 트리거.
    is_color: bool,
};

const GlyphKey = struct {
    font: usize, // CTFontRef 의 포인터 값을 키로 (라이프타임 동안 stable 가정).
    index: u16,
};

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
        const key = GlyphKey{ .font = @intFromPtr(font), .index = glyph_index };
        if (self.cache.get(key)) |entry| return entry;

        const entry = self.rasterize(font, glyph_index) orelse return null;
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

        ct.CGContextSetAllowsFontSmoothing(ctx, true);
        ct.CGContextSetShouldSmoothFonts(ctx, false);
        ct.CGContextSetShouldAntialias(ctx, true);

        // 흰색 opaque fill — 일반 글리프엔 흰색 antialiased 마스크가 그려짐.
        // 컬러 글리프는 이 색깔 무시되고 SBIX bitmap 의 본래 색이 들어감.
        ct.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);

        // CTM scale = Retina factor. bitmap 은 gw x gh pixel 인데
        // CTFontDrawGlyphs 는 point 좌표로 그리므로 scale 보정 없으면 글리프가
        // 1/scale 크기로 작게 들어간다 (#75 nostalgic-edison 의 결정적 fix).
        ct.CGContextScaleCTM(ctx, @floatCast(s), @floatCast(s));

        // bounding rect origin (point 좌표, raw — CTM scale 이 곱해진다) 만큼
        // 음수로 보정해 글리프 좌하단을 (0,0) 에 정렬.
        const positions = [1]ct.CGPoint{.{
            .x = -bounding_rect.origin.x,
            .y = -bounding_rect.origin.y,
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
        };
    }

    /// 단순 row-based packing — 현재 row 에 안 들어가면 다음 row 로.
    /// 가득 차면 null (caller 가 reset 후 재시도).
    fn packGlyph(self: *GlyphAtlas, w: u32, h: u32) ?[2]u32 {
        const pad = 1;

        if (self.cursor_x + w + pad > ATLAS_SIZE) {
            self.cursor_x = 0;
            self.cursor_y += self.row_height + pad;
            self.row_height = 0;
        }

        if (self.cursor_y + h > ATLAS_SIZE) return null;

        const x = self.cursor_x;
        const y = self.cursor_y;
        self.cursor_x += w + pad;
        if (h > self.row_height) self.row_height = h;

        return .{ x, y };
    }
};
