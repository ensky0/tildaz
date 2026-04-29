// 글리프 텍스처 아틀라스 — CoreText 로 글리프 라스터 + 2D atlas (R8 단일 채널)
// 에 캐시. macOS Mojave 이후 subpixel/ClearType 미지원 → grayscale antialiasing.
// Metal 텍스처에 그대로 업로드 가능한 R8 (single-channel alpha) 형식.
//
// Windows 의 `src/glyph_atlas.zig` (R8G8B8A8 ClearType subpixel) 와 다른 점은
// macOS 가 grayscale 라 single-channel 로 충분. 셰이더도 단순.
//
// #75 (claude/infallible-swartz) 패턴 그대로 차용.

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

    // 아틀라스 픽셀 데이터 (R8 — alpha only).
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
        const pixels = try alloc.alloc(u8, ATLAS_SIZE * ATLAS_SIZE);
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
            };
        }

        const gw: u32 = @intFromFloat(gw_f);
        const gh: u32 = @intFromFloat(gh_f);

        if (gw > 256 or gh > 256) return null; // temp_buf 한계.

        // alpha-only CGBitmapContext (kCGImageAlphaOnly + colorspace=null).
        // 1 byte per pixel = glyph coverage. ghostty / #75 nostalgic-edison
        // 패턴 그대로.
        const bytes_per_row = gw;
        const ctx = ct.CGBitmapContextCreate(
            self.temp_buf.ptr,
            gw,
            gh,
            8,
            bytes_per_row,
            null,
            ct.kCGImageAlphaOnly,
        ) orelse return null;
        defer ct.CGContextRelease(ctx);

        // 0 으로 clear (alpha-only 라 byte 단위 memset 충분).
        @memset(self.temp_buf[0 .. gw * gh], 0);

        ct.CGContextSetAllowsFontSmoothing(ctx, true);
        ct.CGContextSetShouldSmoothFonts(ctx, false);
        ct.CGContextSetShouldAntialias(ctx, true);

        // alpha-only 컨텍스트엔 grayscale fill color (RGB 무의미). alpha=1 로
        // 두면 글리프가 그려진 픽셀에 1 (= 255) 가 기록된다.
        ct.CGContextSetGrayFillColor(ctx, 1, 1);

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

        // alpha-only temp_buf (1 byte per pixel) 을 atlas (R8) 로 row 단위 복사.
        const atlas_x = pos[0];
        const atlas_y = pos[1];
        for (0..gh) |row| {
            const src_off = row * bytes_per_row;
            const dst_off = (atlas_y + @as(u32, @intCast(row))) * ATLAS_SIZE + atlas_x;
            @memcpy(self.pixels[dst_off..][0..gw], self.temp_buf[src_off..][0..gw]);
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
