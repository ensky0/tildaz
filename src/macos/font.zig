// CoreText font context — resolves codepoints to glyphs with system font fallback.
// macOS equivalent of windows/font.zig (DWriteFontContext).

const std = @import("std");
const ct = @import("coretext.zig");

pub const GlyphResult = struct {
    font: ct.CTFontRef,
    index: ct.CGGlyph,
    owned: bool, // true = caller must CFRelease font
};

pub const CoreTextFontContext = struct {
    primary_font: ct.CTFontRef,
    font_em_size: f32,
    ascent_px: f32,
    descent_px: f32,
    cell_width: u32,
    cell_height: u32,

    pub fn init(font_family: []const u8, font_size: f32, cell_w: u32, cell_h: u32, retina_scale: f32) !CoreTextFontContext {
        // Create CFString from font family name
        const family_str = ct.CFStringCreateWithBytes(
            null,
            font_family.ptr,
            @intCast(font_family.len),
            ct.kCFStringEncodingUTF8,
            0,
        ) orelse return error.FontNameFailed;
        defer ct.CFRelease(family_str);

        // Create CTFont with the specified family and size
        const font = ct.CTFontCreateWithName(family_str, @floatCast(font_size), null) orelse return error.FontCreateFailed;

        // CoreText returns point units; convert to pixel by multiplying scale
        const ascent: f32 = @floatCast(ct.CTFontGetAscent(font));
        const descent: f32 = @floatCast(ct.CTFontGetDescent(font));

        return .{
            .primary_font = font,
            .font_em_size = font_size,
            .ascent_px = ascent * retina_scale,
            .descent_px = descent * retina_scale,
            .cell_width = cell_w,
            .cell_height = cell_h,
        };
    }

    pub fn deinit(self: *CoreTextFontContext) void {
        ct.CFRelease(self.primary_font);
    }

    /// Resolve a codepoint to (font, glyph_index). Uses CoreText font fallback.
    /// If `owned` is true, caller must CFRelease the font.
    pub fn resolveGlyph(self: *CoreTextFontContext, codepoint: u21) ?GlyphResult {
        // Try primary font first
        var utf16_buf: [2]u16 = undefined;
        var utf16_len: usize = undefined;
        if (codepoint <= 0xFFFF) {
            utf16_buf[0] = @intCast(codepoint);
            utf16_len = 1;
        } else {
            const cp = codepoint - 0x10000;
            utf16_buf[0] = @intCast(0xD800 + (cp >> 10));
            utf16_buf[1] = @intCast(0xDC00 + (cp & 0x3FF));
            utf16_len = 2;
        }

        var glyphs: [2]ct.CGGlyph = .{ 0, 0 };
        if (ct.CTFontGetGlyphsForCharacters(self.primary_font, &utf16_buf, &glyphs, @intCast(utf16_len))) {
            if (glyphs[0] != 0) {
                return .{ .font = self.primary_font, .index = glyphs[0], .owned = false };
            }
        }

        // Fallback: CTFontCreateForString finds a font that can render this character
        const str = ct.CFStringCreateWithCharacters(null, &utf16_buf, @intCast(utf16_len)) orelse return null;
        defer ct.CFRelease(str);

        const fallback_font = ct.CTFontCreateForString(self.primary_font, str, ct.CFRange{ .location = 0, .length = @intCast(utf16_len) });
        if (fallback_font == null) return null;

        // Try to get glyph from fallback font
        var fb_glyphs: [2]ct.CGGlyph = .{ 0, 0 };
        if (ct.CTFontGetGlyphsForCharacters(fallback_font.?, &utf16_buf, &fb_glyphs, @intCast(utf16_len))) {
            if (fb_glyphs[0] != 0) {
                return .{ .font = fallback_font.?, .index = fb_glyphs[0], .owned = true };
            }
        }

        // Fallback font didn't work either
        ct.CFRelease(fallback_font.?);
        return null;
    }
};
