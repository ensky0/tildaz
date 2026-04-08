// macOS CoreText 폰트 컨텍스트 + Glyph Atlas
// DirectWrite + GlyphAtlas(windows/) 의 macOS 대응 구현.
//
// 렌더링 파이프라인:
//   CTFont → CGBitmapContext → BGRA8 비트맵 → Metal 텍스처 서브영역 업로드

const std = @import("std");

const c = @cImport({
    @cInclude("CoreText/CoreText.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

// Metal 텍스처 업로드 (metal_bridge)
const metal_c = @cImport({
    @cInclude("macos/metal_bridge.h");
});

pub const ATLAS_SIZE: u32 = 2048;

// ─── GlyphEntry ───────────────────────────────────────────────────
pub const GlyphEntry = struct {
    atlas_x: u16,
    atlas_y: u16,
    width: u16,
    height: u16,
    offset_x: f32, // 셀 원점에서 글리프 좌상단까지의 오프셋
    offset_y: f32,
};

const GlyphKey = u21; // codepoint

// ─── CoreTextFont ─────────────────────────────────────────────────
pub const CoreTextFont = struct {
    alloc: std.mem.Allocator,
    ct_font: c.CTFontRef,
    scale: f32,
    cell_width: f32,
    cell_height: f32,
    ascent: f32,

    pub fn init(
        alloc: std.mem.Allocator,
        font_name: [*:0]const u8,
        font_size: f32,
        scale: f32, // Retina 배율
        cell_width: f32,
        cell_height: f32,
    ) !CoreTextFont {
        const name_cf = c.CFStringCreateWithCString(
            c.kCFAllocatorDefault,
            font_name,
            c.kCFStringEncodingUTF8,
        ) orelse return error.CFStringFailed;
        defer c.CFRelease(name_cf);

        const font = c.CTFontCreateWithName(name_cf, font_size * scale, null)
            orelse return error.FontCreateFailed;

        const ascent = @as(f32, @floatCast(c.CTFontGetAscent(font)));

        return .{
            .alloc = alloc,
            .ct_font = font,
            .scale = scale,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .ascent = ascent,
        };
    }

    pub fn deinit(self: *CoreTextFont) void {
        c.CFRelease(self.ct_font);
    }

    /// codepoint → CGGlyph 인덱스 반환
    pub fn getGlyph(self: *const CoreTextFont, codepoint: u21) ?c.CGGlyph {
        var chars: [2]u16 = undefined;
        var glyphs: [2]c.CGGlyph = undefined;
        const len = codeToUtf16(codepoint, &chars);
        if (!c.CTFontGetGlyphsForCharacters(self.ct_font, &chars, &glyphs, @intCast(len))) {
            return null;
        }
        return glyphs[0];
    }

    /// 글리프를 BGRA8 비트맵으로 래스터화.
    /// 반환: 비트맵 데이터 슬라이스 (호출자 해제 필요), 너비, 높이, 오프셋
    pub fn rasterizeGlyph(
        self: *const CoreTextFont,
        glyph: c.CGGlyph,
        out_w: *u16,
        out_h: *u16,
        out_ox: *f32,
        out_oy: *f32,
    ) ![]u8 {
        // 글리프 바운딩 박스
        var glyph_mut = glyph;
        var bbox: c.CGRect = undefined;
        c.CTFontGetBoundingRectsForGlyphs(
            self.ct_font,
            c.kCTFontOrientationDefault,
            &glyph_mut,
            &bbox,
            1,
        );

        const w: u32 = @intFromFloat(@ceil(bbox.size.width) + 2);
        const h: u32 = @intFromFloat(@ceil(bbox.size.height) + 2);

        if (w == 0 or h == 0) {
            out_w.* = 0;
            out_h.* = 0;
            return error.EmptyGlyph;
        }

        // CGBitmapContext (RGBA8 — CoreGraphics 기본)
        const stride = w * 4;
        const buf = try self.alloc.alloc(u8, h * stride);
        @memset(buf, 0);

        const color_space = c.CGColorSpaceCreateDeviceRGB();
        defer c.CGColorSpaceRelease(color_space);

        const ctx = c.CGBitmapContextCreate(
            buf.ptr,
            w,
            h,
            8,
            stride,
            color_space,
            c.kCGImageAlphaPremultipliedFirst | c.kCGBitmapByteOrder32Host,
        ) orelse {
            self.alloc.free(buf);
            return error.CGContextFailed;
        };
        defer c.CGContextRelease(ctx);

        // 서브픽셀 앤티에일리어싱
        c.CGContextSetAllowsFontSmoothing(ctx, true);
        c.CGContextSetShouldSmoothFonts(ctx, true);
        c.CGContextSetAllowsAntialiasing(ctx, true);
        c.CGContextSetShouldAntialias(ctx, true);

        // 글리프를 흰색으로 그림 (배경 투명)
        c.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);

        const draw_x: c.CGFloat = -bbox.origin.x + 1;
        const draw_y: c.CGFloat = -bbox.origin.y + 1;
        var pos = c.CGPoint{ .x = draw_x, .y = draw_y };
        c.CTFontDrawGlyphs(self.ct_font, &glyph_mut, &pos, 1, ctx);

        out_w.* = @intCast(w);
        out_h.* = @intCast(h);
        out_ox.* = @floatCast(bbox.origin.x - 1);
        out_oy.* = self.ascent - @as(f32, @floatCast(bbox.origin.y + bbox.size.height)) - 1;

        return buf;
    }
};

// ─── GlyphAtlas ───────────────────────────────────────────────────
pub const GlyphAtlas = struct {
    alloc: std.mem.Allocator,
    cache: std.AutoHashMap(GlyphKey, GlyphEntry),
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    row_height: u32 = 0,

    // Metal 텍스처 (불투명 포인터)
    metal_texture: ?*anyopaque,

    pub fn init(alloc: std.mem.Allocator, metal_texture: ?*anyopaque) GlyphAtlas {
        return .{
            .alloc = alloc,
            .cache = std.AutoHashMap(GlyphKey, GlyphEntry).init(alloc),
            .metal_texture = metal_texture,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.cache.deinit();
    }

    /// codepoint에 대한 GlyphEntry 반환. 없으면 래스터화 후 atlas에 추가.
    pub fn getOrRasterize(self: *GlyphAtlas, font: *const CoreTextFont, codepoint: u21) !GlyphEntry {
        if (self.cache.get(codepoint)) |entry| return entry;

        const glyph = font.getGlyph(codepoint) orelse return error.GlyphNotFound;

        var w: u16 = 0;
        var h: u16 = 0;
        var ox: f32 = 0;
        var oy: f32 = 0;
        const bitmap = font.rasterizeGlyph(glyph, &w, &h, &ox, &oy) catch return error.RasterizeFailed;
        defer self.alloc.free(bitmap);

        if (w == 0 or h == 0) return error.EmptyGlyph;

        // Atlas 팩킹 (행 기반)
        if (self.cursor_x + w > ATLAS_SIZE) {
            self.cursor_x = 0;
            self.cursor_y += self.row_height;
            self.row_height = 0;
        }
        if (self.cursor_y + h > ATLAS_SIZE) return error.AtlasFull;

        const ax = self.cursor_x;
        const ay = self.cursor_y;

        // Metal 텍스처 업로드
        if (self.metal_texture) |tex| {
            metal_c.tildazMetalUpdateTexture(tex, ax, ay, w, h, bitmap.ptr);
        }

        self.cursor_x += w;
        if (h > self.row_height) self.row_height = h;

        const entry = GlyphEntry{
            .atlas_x = @intCast(ax),
            .atlas_y = @intCast(ay),
            .width = w,
            .height = h,
            .offset_x = ox,
            .offset_y = oy,
        };

        try self.cache.put(codepoint, entry);
        return entry;
    }
};

// ─── 내부 헬퍼: codepoint → UTF-16 ───────────────────────────────
fn codeToUtf16(cp: u21, buf: *[2]u16) usize {
    if (cp < 0x10000) {
        buf[0] = @intCast(cp);
        return 1;
    } else {
        const c2 = cp - 0x10000;
        buf[0] = @intCast(0xD800 + (c2 >> 10));
        buf[1] = @intCast(0xDC00 + (c2 & 0x3FF));
        return 2;
    }
}
