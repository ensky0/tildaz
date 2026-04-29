// CoreText 폰트 컨텍스트 — codepoint → (font, glyph_index) 해석. 시스템 폰트
// fallback (CTFontCreateForString) 으로 emoji / 한글 / 기타 문자 처리.
//
// Windows 의 `src/dwrite_font.zig` (DWriteFontContext) 와 같은 역할. #75
// (claude/infallible-swartz) 패턴 그대로 차용.

const std = @import("std");
const ct = @import("macos_coretext.zig");

pub const GlyphResult = struct {
    font: ct.CTFontRef,
    index: ct.CGGlyph,
    /// true 면 caller 가 CFRelease 책임. fallback font 생성 후 cache 안 할 때.
    owned: bool,
};

pub const CoreTextFontContext = struct {
    primary_font: ct.CTFontRef,
    font_em_size: f32,
    ascent_px: f32,
    descent_px: f32,
    cell_width: u32,
    cell_height: u32,

    pub fn init(font_family: []const u8, font_size: f32, cell_w: u32, cell_h: u32) !CoreTextFontContext {
        // family 이름을 CFString 으로.
        const family_str = ct.CFStringCreateWithBytes(
            null,
            font_family.ptr,
            @intCast(font_family.len),
            ct.kCFStringEncodingUTF8,
            0,
        ) orelse return error.FontNameFailed;
        defer ct.CFRelease(family_str);

        const font = ct.CTFontCreateWithName(family_str, @floatCast(font_size), null) orelse return error.FontCreateFailed;

        return .{
            .primary_font = font,
            .font_em_size = font_size,
            .ascent_px = @floatCast(ct.CTFontGetAscent(font)),
            .descent_px = @floatCast(ct.CTFontGetDescent(font)),
            .cell_width = cell_w,
            .cell_height = cell_h,
        };
    }

    pub fn deinit(self: *CoreTextFontContext) void {
        ct.CFRelease(self.primary_font);
    }

    /// codepoint → (font, glyph_index) 해석. primary 에 없으면 CTFontCreateFor
    /// String 으로 시스템 fallback 시도 (Apple Color Emoji / Apple SD Gothic
    /// Neo 등). fallback 결과는 `owned = true` — caller 가 CFRelease 책임.
    pub fn resolveGlyph(self: *CoreTextFontContext, codepoint: u21) ?GlyphResult {
        // codepoint 를 UTF-16 surrogate pair (또는 single unit) 으로.
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

        // 1. primary font 에서 시도.
        var glyphs: [2]ct.CGGlyph = .{ 0, 0 };
        if (ct.CTFontGetGlyphsForCharacters(self.primary_font, &utf16_buf, &glyphs, @intCast(utf16_len))) {
            if (glyphs[0] != 0) {
                return .{ .font = self.primary_font, .index = glyphs[0], .owned = false };
            }
        }

        // 2. 시스템 fallback. CTFontCreateForString 이 알맞은 폰트 찾아 반환.
        const str = ct.CFStringCreateWithCharacters(null, &utf16_buf, @intCast(utf16_len)) orelse return null;
        defer ct.CFRelease(str);

        const fallback_font = ct.CTFontCreateForString(self.primary_font, str, ct.CFRange{ .location = 0, .length = @intCast(utf16_len) });
        if (fallback_font == null) return null;

        var fb_glyphs: [2]ct.CGGlyph = .{ 0, 0 };
        if (ct.CTFontGetGlyphsForCharacters(fallback_font.?, &utf16_buf, &fb_glyphs, @intCast(utf16_len))) {
            if (fb_glyphs[0] != 0) {
                return .{ .font = fallback_font.?, .index = fb_glyphs[0], .owned = true };
            }
        }

        // fallback 에서도 못 찾으면 release.
        ct.CFRelease(fallback_font.?);
        return null;
    }
};
