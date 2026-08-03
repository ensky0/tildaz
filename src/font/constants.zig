//! Font configuration limits shared by config parsing and platform font backends.

/// Maximum number of explicit font families in the rendering chain:
/// primary `font.family` + `font.glyph_fallback` entries.
pub const MAX_CHAIN: usize = 8;

/// SGR `1` (bold) · `3` (italic) 이 요구하는 폰트 face 변종 (#375).
///
/// 세 platform 이 **같은 family 안에서 자동 style-match** 한다 (2026-08-03 사용자
/// 결정) — `font.family_bold` 류 config 키를 두지 않고 각 OS 의 폰트 매칭 API 에
/// 맡긴다. 해당 face 가 없는 family 는 [`regular`](#regular) 로 떨어뜨리고
/// **synthetic (글리프를 두 번 그리거나 기울이는 것) 은 만들지 않는다** — 품질이
/// 낮고 세 platform 이 다르게 보인다.
///
/// `bold` 가 붙어도 `cell_color.resolveFg` 의 `bold_is_bright` (색 승격) 는 그대로
/// 동작한다. 둘은 독립이다.
pub const FaceStyle = enum(u2) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,

    pub const count: usize = 4;

    /// ghostty `Style.Flags` 의 두 bool 에서 만든다. renderer 세 곳이 이 함수만
    /// 부르므로 platform 별로 판정이 갈리지 않는다.
    pub fn from(bold: bool, italic: bool) FaceStyle {
        if (bold and italic) return .bold_italic;
        if (bold) return .bold;
        if (italic) return .italic;
        return .regular;
    }

    pub fn isBold(self: FaceStyle) bool {
        return self == .bold or self == .bold_italic;
    }

    pub fn isItalic(self: FaceStyle) bool {
        return self == .italic or self == .bold_italic;
    }

    pub fn index(self: FaceStyle) usize {
        return @intFromEnum(self);
    }
};

test "FaceStyle — 두 flag 조합이 네 변종에 1:1 로 대응한다" {
    const std = @import("std");
    try std.testing.expectEqual(FaceStyle.regular, FaceStyle.from(false, false));
    try std.testing.expectEqual(FaceStyle.bold, FaceStyle.from(true, false));
    try std.testing.expectEqual(FaceStyle.italic, FaceStyle.from(false, true));
    try std.testing.expectEqual(FaceStyle.bold_italic, FaceStyle.from(true, true));

    // 조회 helper 가 조합과 일치한다.
    for ([_]FaceStyle{ .regular, .bold, .italic, .bold_italic }) |s| {
        try std.testing.expectEqual(s, FaceStyle.from(s.isBold(), s.isItalic()));
        try std.testing.expect(s.index() < FaceStyle.count);
    }
}
