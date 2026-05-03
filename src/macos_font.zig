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

pub const MAX_FALLBACK_FONTS = 8;

pub const CoreTextFontContext = struct {
    primary_font: ct.CTFontRef,
    font_em_size: f32,
    ascent_px: f32,
    descent_px: f32,
    /// 폰트의 위쪽 internal leading (= ascent − cap_height). 대문자 위쪽
    /// 여백. cell box top 부터 ascent 만큼 내려간 위치가 baseline 인데
    /// 대문자 visible top 은 그보다 `top_pad_px` 만큼 더 아래 — 시각적
    /// padding 보정에 사용 (좌/우/하 padding 과 위 padding 을 같게 보이게).
    top_pad_px: f32,
    /// Monospace cell 크기 — 폰트의 'M' advance + ascent/descent/leading 으로
    /// 측정. host 가 hardcoded 상수 대신 이 값을 사용하면 폰트 교체 시에도
    /// 글자 사이 공백 / 줄 높이 가 자동 맞춰진다.
    cell_width: u32,
    cell_height: u32,
    /// 실제 lookup 성공한 primary 폰트 family name (debug / 로그 용).
    font_family: []const u8,
    /// config.font.family 의 *모든* chain 폰트 — codepoint 별 글리프 fallback
    /// 에 사용 (Windows DWriteFontContext 와 동등). [0] 은 primary 와 동일.
    fallback_fonts: [MAX_FALLBACK_FONTS]ct.CTFontRef,
    fallback_count: usize,

    pub fn init(
        font_families: []const []const u8,
        font_size: f32,
        retina_scale: f32,
        /// Windows 의 `config.cell_width` 와 동일 의미 — 측정된 advance 에
        /// 곱해 글자 사이 padding 조절. 1.0 = 폰트 그대로.
        cell_width_scale: f32,
        /// Windows 의 `config.line_height` — 측정된 ascent+descent+leading
        /// 에 곱해 줄 높이 조절. 0.95 정도면 약간 빽빽.
        line_height_scale: f32,
    ) !CoreTextFontContext {
        // Font *glyph fallback chain* — config.font.family 의 모든 폰트가
        // system 에 있어야 한다 (Windows DWriteFontContext 와 동등 strict 정책).
        // `CTFontCreateWithName` 은 lookup 실패 시 system substitute (대개
        // `.SF NS Mono`) 를 반환하니 `CTFontCopyFamilyName` 으로 *실제 family
        // name* 검증 → 우리 요청과 다르면 사용자가 명시한 폰트가 시스템에 없는
        // 것 → fatal `Font not found: "Foo"` (Windows messages 와 동일).
        //
        // 모든 chain 폰트를 fallback_fonts 에 저장 → resolveGlyph 가 codepoint
        // 별로 순회 (primary → secondary → ... → system auto fallback).
        var fallback_fonts: [MAX_FALLBACK_FONTS]ct.CTFontRef = undefined;
        var fallback_count: usize = 0;
        var font: ct.CTFontRef = undefined;
        var font_family: []const u8 = "";
        for (font_families) |family| {
            if (family.len == 0) continue;
            if (fallback_count >= MAX_FALLBACK_FONTS) break;
            const family_str = ct.CFStringCreateWithBytes(
                null,
                family.ptr,
                @intCast(family.len),
                ct.kCFStringEncodingUTF8,
                0,
            ) orelse {
                @import("font_validate.zig").showNotFoundFatal(family, font_families);
            };
            defer ct.CFRelease(family_str);
            const candidate = ct.CTFontCreateWithName(family_str, @floatCast(font_size), null) orelse {
                @import("font_validate.zig").showNotFoundFatal(family, font_families);
            };
            const actual_family = ct.CTFontCopyFamilyName(candidate);
            const matched = ct.CFStringCompare(actual_family, family_str, 0) == 0;
            ct.CFRelease(actual_family);
            if (!matched) {
                ct.CFRelease(candidate);
                @import("font_validate.zig").showNotFoundFatal(family, font_families);
            }
            fallback_fonts[fallback_count] = candidate;
            if (fallback_count == 0) {
                font = candidate;
                font_family = family;
            }
            fallback_count += 1;
        }
        if (fallback_count == 0) return error.FontCreateFailed;

        // CoreText 의 ascent / descent / leading 은 point 단위. atlas /
        // renderer 가 모두 pixel 단위로 동작하므로 init 시 scale 곱해 통일.
        const ascent: f32 = @floatCast(ct.CTFontGetAscent(font));
        const descent: f32 = @floatCast(ct.CTFontGetDescent(font));
        const leading: f32 = @floatCast(ct.CTFontGetLeading(font));
        const cap_height: f32 = @floatCast(ct.CTFontGetCapHeight(font));

        // Monospace 셀 폭 측정 — 'M' / 'i' / '.' advance 가 모두 같은지 확인
        // 후 'M' 의 advance 를 cell width 로. 한 글자라도 advance 가 다르면
        // proportional 폰트 (또는 system fallback) 가 매칭된 것 — terminal
        // 용도엔 부적합하므로 stderr 로 강한 경고. layout 자체는 진행 (셸이
        // 보이는 게 아예 안 보이는 것보단 낫다).
        const probes = [_]u16{ 'M', 'i', '.', 'W' };
        var probe_glyphs: [probes.len]ct.CGGlyph = @splat(0);
        _ = ct.CTFontGetGlyphsForCharacters(font, &probes, &probe_glyphs, probes.len);
        var probe_adv: [probes.len]ct.CGSize = @splat(.{ .width = 0, .height = 0 });
        _ = ct.CTFontGetAdvancesForGlyphs(
            font,
            ct.kCTFontOrientationHorizontal,
            &probe_glyphs,
            @ptrCast(&probe_adv),
            probes.len,
        );
        const advance_pt: f32 = @floatCast(probe_adv[0].width);

        // 'M' 글리프의 실제 visible top — 폰트 designer 의 cap_height metric
        // 보다 실제 raster 결과에 정확. ascent − bbox.top 이 위쪽 internal
        // leading. (cap_height 만 쓰면 폰트마다 metric 과 raster 결과가 살짝
        // 달라 보정이 부정확해질 수 있다.)
        var m_bbox: ct.CGRect = undefined;
        _ = ct.CTFontGetBoundingRectsForGlyphs(
            font,
            ct.kCTFontOrientationHorizontal,
            probe_glyphs[0..1].ptr,
            @ptrCast(&m_bbox),
            1,
        );
        const m_top_pt: f32 = @floatCast(m_bbox.origin.y + m_bbox.size.height);

        for (probe_adv[1..], probes[1..]) |a, ch| {
            const w: f32 = @floatCast(a.width);
            if (@abs(w - advance_pt) > 0.01) {
                @import("macos_log.zig").appendLine(
                    "font",
                    "WARNING: '{c}' advance ({d}) != 'M' advance ({d}). '{s}' is not monospace — terminal layout will look broken.",
                    .{ @as(u8, @intCast(ch)), w, advance_pt, font_family },
                );
                break;
            }
        }

        // 픽셀 단위 cell. Windows 와 동일: advance × cell_width_scale,
        // (ascent+descent+leading) × line_height_scale. ceil 로 글리프 잘림
        // 방지. 1.1 / 0.95 같은 미적 보정값을 그대로 적용 가능.
        const cell_w_px: u32 = @intFromFloat(@ceil(advance_pt * cell_width_scale * retina_scale));
        const cell_h_px: u32 = @intFromFloat(@ceil((ascent + descent + leading) * line_height_scale * retina_scale));

        // top_pad_px = ascent − 'M' bbox top. 폰트 metric (cap_height) 대신
        // 실제 'M' raster bbox 사용 — 폰트마다 metric 과 글리프 실제 모양이
        // 약간 다를 수 있어 더 정확.
        _ = cap_height;
        const top_pad_pt: f32 = ascent - m_top_pt;

        return .{
            .primary_font = font,
            .font_em_size = font_size,
            .ascent_px = ascent * retina_scale,
            .descent_px = descent * retina_scale,
            .top_pad_px = top_pad_pt * retina_scale,
            .cell_width = cell_w_px,
            .cell_height = cell_h_px,
            .font_family = font_family,
            .fallback_fonts = fallback_fonts,
            .fallback_count = fallback_count,
        };
    }

    // chain 의 한 폰트가 system 에 없을 때 — `font_validate.showNotFoundFatal`
    // (cross-platform) 가 chain dump + 미설치 표시 + config 경로 안내 + fatal.
    // Windows / macOS 같은 메시지 형식 사용.

    pub fn deinit(self: *CoreTextFontContext) void {
        for (self.fallback_fonts[0..self.fallback_count]) |f| {
            ct.CFRelease(f);
        }
    }

    /// grapheme cluster (base + extras) 통째 shape → 첫 run 의 첫 glyph 반환.
    /// VS-16 / skin tone / ZWJ 시퀀스 처리 (#132 B). CTLine 이 font fallback +
    /// glyph substitution 모두 자동 → cluster 가 단일 컬러 emoji 글리프로 reduce.
    ///
    /// `cps` 는 [base_cp, extras...] 의 codepoint 배열. UTF-16 으로 변환 후
    /// CFAttributedString (primary font 속성) → CTLine → 첫 CTRun 사용.
    /// 결과의 `font` 는 CTLine 이 fallback 으로 픽한 것 (Apple Color Emoji 등) —
    /// 우리가 따로 retain 안 했지만 CTLine 이 살아있는 동안만 유효. Caller 는
    /// 즉시 atlas getOrInsert 호출해 글리프 라스터 후 결과 사용 안 함.
    /// `owned = false` (CT 가 관리). 실패 시 null → caller 가 base codepoint 만
    /// 으로 fallback.
    pub fn resolveGrapheme(self: *CoreTextFontContext, cps: []const u21) ?GlyphResult {
        if (cps.len == 0) return null;

        // UTF-16 buffer — 각 codepoint 가 1~2 unit. 최대 16 cp 까지 지원 (긴
        // ZWJ 시퀀스는 보통 ≤ 8 cp). overflow 시 truncate.
        var utf16_buf: [32]u16 = undefined;
        var utf16_len: usize = 0;
        for (cps) |cp| {
            if (cp <= 0xFFFF) {
                if (utf16_len + 1 > utf16_buf.len) break;
                utf16_buf[utf16_len] = @intCast(cp);
                utf16_len += 1;
            } else {
                if (utf16_len + 2 > utf16_buf.len) break;
                const offset = cp - 0x10000;
                utf16_buf[utf16_len] = @intCast(0xD800 + (offset >> 10));
                utf16_buf[utf16_len + 1] = @intCast(0xDC00 + (offset & 0x3FF));
                utf16_len += 2;
            }
        }
        if (utf16_len == 0) return null;

        const cf_str = ct.CFStringCreateWithCharacters(null, &utf16_buf, @intCast(utf16_len)) orelse return null;
        defer ct.CFRelease(cf_str);

        // CFDictionary { kCTFontAttributeName: primary_font } — CT 가 shaping
        // 시 이 font 부터 시작해 emoji 자동 fallback.
        const keys = [1]?*const anyopaque{@ptrCast(ct.kCTFontAttributeName)};
        const values = [1]?*const anyopaque{@ptrCast(self.primary_font)};
        const attrs = ct.CFDictionaryCreate(
            null,
            &keys,
            &values,
            1,
            @ptrCast(&ct.kCFTypeDictionaryKeyCallBacks),
            @ptrCast(&ct.kCFTypeDictionaryValueCallBacks),
        ) orelse return null;
        defer ct.CFRelease(attrs);

        const attr_str = ct.CFAttributedStringCreate(null, cf_str, attrs) orelse return null;
        defer ct.CFRelease(attr_str);

        const line = ct.CTLineCreateWithAttributedString(attr_str) orelse return null;
        defer ct.CFRelease(line);

        const runs = ct.CTLineGetGlyphRuns(line);
        const run_count = ct.CFArrayGetCount(runs);
        if (run_count == 0) return null;

        // 첫 run — 대부분 grapheme cluster 가 1 run + 1 glyph 으로 shape 됨.
        const run_ptr = ct.CFArrayGetValueAtIndex(runs, 0) orelse return null;
        const run: ct.CTRunRef = @constCast(run_ptr);

        const glyph_count = ct.CTRunGetGlyphCount(run);
        if (glyph_count == 0) return null;

        var glyph: ct.CGGlyph = 0;
        if (ct.CTRunGetGlyphsPtr(run)) |ptr| {
            glyph = ptr[0];
        } else {
            ct.CTRunGetGlyphs(run, ct.CFRange{ .location = 0, .length = 1 }, @ptrCast(&glyph));
        }
        if (glyph == 0) return null;

        // run 의 실제 사용 폰트 — CT 가 fallback 으로 골라준 것 (Apple Color Emoji 등).
        // GetAttributes 와 GetValue 는 non-owning reference 라 line 이 release 되면
        // 무효. CFRetain 으로 caller 에게 ownership 넘김 → resolveGlyph 의 시스템
        // fallback path (`owned = true`) 와 같은 패턴 → renderer 가 atlas
        // getOrInsert 후 CFRelease.
        const run_attrs = ct.CTRunGetAttributes(run);
        const font_val = ct.CFDictionaryGetValue(run_attrs, @ptrCast(ct.kCTFontAttributeName)) orelse return null;
        const run_font: ct.CTFontRef = @constCast(font_val);
        _ = ct.CFRetain(run_font);

        return .{ .font = run_font, .index = glyph, .owned = true };
    }

    /// codepoint → (font, glyph_index) 해석. config.font.family chain 순회 →
    /// 첫 번째 글리프 가진 폰트 사용 (Windows DWriteFontContext 와 동등). chain
    /// 모두 없으면 `CTFontCreateForString` 의 system auto fallback (Apple Color
    /// Emoji 등). system fallback 결과는 `owned = true` — caller 가 CFRelease.
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

        // 1. chain 순회 — 글리프 가진 첫 폰트 사용.
        for (self.fallback_fonts[0..self.fallback_count]) |f| {
            var glyphs: [2]ct.CGGlyph = .{ 0, 0 };
            if (ct.CTFontGetGlyphsForCharacters(f, &utf16_buf, &glyphs, @intCast(utf16_len))) {
                if (glyphs[0] != 0) {
                    return .{ .font = f, .index = glyphs[0], .owned = false };
                }
            }
        }

        // 2. chain 모두 없으면 system auto fallback (CTFontCreateForString).
        //    Apple Color Emoji 같이 chain 에 명시 안 한 폰트 자동 찾음.
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
