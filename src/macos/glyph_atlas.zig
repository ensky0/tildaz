// Glyph texture atlas — rasterizes glyphs via CoreText, caches in a 2D atlas.
// macOS uses grayscale antialiasing (no subpixel/ClearType since Mojave).
// The atlas stores single-channel alpha data (R8) for the Metal texture.

const std = @import("std");
const ct = @import("coretext.zig");

pub const ATLAS_SIZE: u32 = 2048;

pub const AtlasEntry = struct {
    x: u16, // position in atlas (pixels)
    y: u16,
    w: u16, // glyph dimensions (pixels)
    h: u16,
    bearing_x: i16, // offset from cell origin to glyph top-left
    bearing_y: i16,
};

const GlyphKey = struct {
    font: usize, // pointer value as key
    index: u16,
};

pub const GlyphAtlas = struct {
    alloc: std.mem.Allocator,
    cache: std.AutoHashMap(GlyphKey, AtlasEntry),

    // Atlas packing state (simple row-based)
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    row_height: u32 = 0,

    // Font metrics for rasterization
    font_size: f32,
    scale: f32, // Retina scale factor (1.0 or 2.0)

    // Atlas pixel data (R8 — single channel alpha)
    pixels: []u8,

    // Dirty tracking for GPU upload
    dirty: bool = false,
    dirty_min_y: u32 = ATLAS_SIZE,
    dirty_max_y: u32 = 0,

    // Temporary buffer for glyph rasterization
    temp_buf: []u8,

    pub fn init(
        alloc: std.mem.Allocator,
        font_size: f32,
        scale: f32,
    ) !GlyphAtlas {
        const pixels = try alloc.alloc(u8, ATLAS_SIZE * ATLAS_SIZE);
        @memset(pixels, 0);

        // Temp buffer: max glyph 256x256, RGBA (4 bytes per pixel for CGBitmapContext)
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

    /// Look up or rasterize a glyph. Returns null if rasterization fails.
    pub fn getOrInsert(self: *GlyphAtlas, font: ct.CTFontRef, glyph_index: ct.CGGlyph) ?AtlasEntry {
        const key = GlyphKey{ .font = @intFromPtr(font), .index = glyph_index };
        if (self.cache.get(key)) |entry| return entry;

        const entry = self.rasterize(font, glyph_index) orelse return null;
        self.cache.put(key, entry) catch return null;
        return entry;
    }

    /// Reset the atlas (clear cache and packing state).
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
        // Get glyph bounding rect
        const glyphs = [1]ct.CGGlyph{glyph_index};
        var bounding_rect: ct.CGRect = undefined;
        _ = ct.CTFontGetBoundingRectsForGlyphs(
            font,
            ct.kCTFontOrientationDefault,
            &glyphs,
            @ptrCast(&bounding_rect),
            1,
        );

        // Scale by Retina factor
        const s = self.scale;
        const x0 = @floor(bounding_rect.origin.x * s);
        const y0 = @floor(bounding_rect.origin.y * s);
        const x1 = @ceil((bounding_rect.origin.x + bounding_rect.size.width) * s);
        const y1 = @ceil((bounding_rect.origin.y + bounding_rect.size.height) * s);

        const gw_f = x1 - x0;
        const gh_f = y1 - y0;

        if (gw_f <= 0 or gh_f <= 0) {
            // Empty glyph (space, etc.)
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

        if (gw > 256 or gh > 256) return null;

        // Create alpha-only bitmap context (kCGImageAlphaOnly).
        // Following ghostty's approach: null colorspace + alpha-only format.
        // Apple docs: for alpha-only, colorspace must be null.
        // This gives us direct glyph coverage as alpha values (0=transparent, 255=opaque).
        const bytes_per_row = gw;
        const ctx = ct.CGBitmapContextCreate(
            self.temp_buf.ptr,
            gw,
            gh,
            8, // bits per component
            bytes_per_row,
            null, // alpha-only: no color space needed
            ct.kCGImageAlphaOnly, // alpha-only: 1 byte/pixel = glyph coverage
        ) orelse return null;
        defer ct.CGContextRelease(ctx);

        // Clear to transparent (alpha=0)
        @memset(self.temp_buf[0 .. gw * gh], 0);

        // Enable antialiasing, disable subpixel smoothing
        ct.CGContextSetAllowsFontSmoothing(ctx, true);
        ct.CGContextSetShouldSmoothFonts(ctx, false);
        ct.CGContextSetShouldAntialias(ctx, true);

        // Set fill color (alpha=1 for full coverage where glyph is drawn)
        ct.CGContextSetGrayFillColor(ctx, 1, 1);

        // Scale CTM: Retina factor. The bitmap is pixel-sized (gw x gh),
        // but CTFontDrawGlyphs works in point coordinates.
        ct.CGContextScaleCTM(ctx, @floatCast(s), @floatCast(s));

        // Draw glyph at negated origin (point coordinates).
        // This positions the glyph so its bounding box bottom-left aligns to (0,0).
        const positions = [1]ct.CGPoint{.{
            .x = -bounding_rect.origin.x,
            .y = -bounding_rect.origin.y,
        }};
        ct.CTFontDrawGlyphs(font, &glyphs, &positions, 1, ctx);

        // Pack into atlas
        const pos = self.packGlyph(gw, gh) orelse blk: {
            self.reset();
            break :blk self.packGlyph(gw, gh) orelse return null;
        };

        // Copy alpha pixels from temp_buf → atlas (no flip, following ghostty's approach).
        // CG Y-up storage is compensated by bearing_y in the renderer.
        const atlas_x = pos[0];
        const atlas_y = pos[1];
        for (0..gh) |row| {
            const src_start = @as(u32, @intCast(row)) * bytes_per_row;
            const dst_start = (atlas_y + @as(u32, @intCast(row))) * ATLAS_SIZE + atlas_x;
            @memcpy(self.pixels[dst_start..][0..gw], self.temp_buf[src_start..][0..gw]);
        }

        // Mark dirty region
        self.dirty = true;
        if (atlas_y < self.dirty_min_y) self.dirty_min_y = atlas_y;
        if (atlas_y + gh > self.dirty_max_y) self.dirty_max_y = atlas_y + gh;

        // bearing_x: baseline에서 glyph left까지 (pixel, 양수=오른쪽)
        // bearing_y: baseline에서 glyph TOP까지 (pixel, 화면 Y-down 좌표)
        //   CG 좌표: y0 = baseline에서 glyph bottom (양수=위)
        //   화면 좌표: glyph top = -(y0 + gh) (음수=위)
        return AtlasEntry{
            .x = @intCast(atlas_x),
            .y = @intCast(atlas_y),
            .w = @intCast(gw),
            .h = @intCast(gh),
            .bearing_x = @intFromFloat(x0),
            .bearing_y = -@as(i16, @intFromFloat(y0)) - @as(i16, @intCast(gh)),
        };
    }

    /// Simple row-based packing. Returns (x, y) or null if full.
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
