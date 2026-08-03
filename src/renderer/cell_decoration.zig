//! SGR 선 속성 — `underline` (single · double) · `strikethrough` · `overline` 의
//! 사각형 조립 (#365). 세 renderer (Linux software / macOS Metal / Windows d3d11)
//! 공통 정책. [`cell_color.zig`](cell_color.zig) · [`block_element.zig`](block_element.zig)
//! 와 같은 패턴이다 — **정책은 여기 한 곳, platform 은 자기 목록에 넣는 것만.**
//!
//! ## 좌표 계약
//!
//! 돌려주는 `y` 는 **셀 top 기준 상대 physical px** 이고 폭은 담지 않는다. 폭은
//! 언제나 그 셀의 폭이고 (wide char 면 2배) 호출부가 이미 알고 있는 값이라, 여기서
//! 다시 계산하면 세 platform 의 wide 판정을 중복시키게 된다.
//!
//! 기준점은 **baseline = 셀 top + `ascent_px`** 다. 세 renderer 가 글리프를 그 식으로
//! 놓는다 (macOS `emitTextInstance` · Windows `emitClusterInstance` · Linux
//! `appendGlyph`). 같은 기준을 쓰므로 선과 글리프는 항상 일관되고, macOS 만 행 원점을
//! `top_pad_px` 만큼 올리는 기존 차이도 자동으로 따라간다 — 호출부가 글리프에 쓰는
//! 것과 같은 셀 top 을 넘기기만 하면 된다.
//!
//! ## 그리는 순서 — 글리프 **아래**
//!
//! 이 사각형들은 글리프보다 **먼저** 그려야 한다 (Linux `layer.cell_bg`,
//! macOS · Windows 는 bg pass). ghostty 와 같은 선택이고 이유도 같다 —
//! *"We draw underlines first so that they layer underneath text. This improves
//! readability when a colored underline is used which intersects parts of the
//! text (descenders)."* `underline_color` (SGR 58) 로 밑줄이 글자와 다른 색일 때
//! 차이가 실제로 보인다. 글리프 위에 그리면 `g` `y` `p` 의 꼬리가 선에 잘린다.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const ui_metrics = @import("../ui_metrics.zig");

/// 한 셀이 만들 수 있는 최대 사각형 수 — 이중 밑줄 2 + 취소선 1 + 윗줄 1.
pub const MAX_RECTS = 4;

/// 선 하나. `x` 와 `w` 는 담지 않는다 (위 「좌표 계약」).
pub const Rect = struct {
    /// 셀 top 기준 상대 y (physical px).
    y: f32,
    /// 두께 (physical px). 항상 정수이고 1 이상이다.
    h: f32,
    color: ghostty.color.RGB,
};

/// 이 셀에 그릴 선이 있는가. 호출부가 셀을 빠르게 거르는 용도이고,
/// [`rects`] 가 0 을 돌려주는 조건과 **정확히 같다**.
///
/// `invisible` (SGR 8) 이 여기 들어 있는 것은 의도다 — 선까지 전부 숨기는 것이
/// 이 저장소의 정책이라 (아래 [`rects`] 주석) 그 판단을 호출부 세 곳에 흩어 두지
/// 않는다.
pub fn hasDecoration(style: ghostty.Style) bool {
    if (style.flags.invisible) return false;
    return style.flags.underline != .none or
        style.flags.strikethrough or
        style.flags.overline;
}

/// 셀 하나가 그릴 선 사각형들을 `out` 에 채우고 개수를 돌려준다.
///
/// `fg` 는 호출부가 [`cell_color.resolveFg`](cell_color.zig) 로 구한 값이다 —
/// selection / inverse 교환이 이미 반영돼 있다. 밑줄은 SGR 58 로 색이 명시돼
/// 있으면 그 색을, 없으면 `fg` 를 쓴다 (ghostty `underlineColor(palette) orelse fg`
/// 와 같다). 취소선과 윗줄은 `underline_color` 를 보지 않고 항상 `fg` 다.
///
/// `ascent_px` · `cell_h` 는 physical px 다.
///
/// ## `invisible` (SGR 8) — 선까지 전부 숨긴다
///
/// xterm · ghostty 와 같은 선택이다 (2026-08-03 사용자 확정). ghostty 주석이 이
/// 갈래를 짚는다 — *"NOTE: This behavior matches xterm. Some other terminal
/// emulators, e.g. Alacritty, still render text decorations and only make the text
/// itself invisible."* 비밀번호 입력처럼 "아무것도 안 보임" 이 SGR 8 의 의도에 가깝다.
///
/// ## 미지원 밑줄 스타일은 `single` 로 떨어뜨린다
///
/// `curly` / `dotted` / `dashed` (SGR `4:3` · `4:4` · `4:5`) 는 [#374](https://github.com/ensky0/tildaz/issues/374)
/// 범위다. 여기서 아무것도 안 그리면 neovim 의 LSP 진단 밑줄이 **통째로 사라지므로**,
/// 최소한 직선으로는 보이게 한다. ghostty 파서도 모르는 스타일을 `single` 로
/// 떨어뜨린다 ([`sgr.zig`](https://github.com/ghostty-org/ghostty/blob/91f66da24527fa02d92b5fd0b41cd020f553a64c/src/terminal/sgr.zig#L277-L288)).
pub fn rects(
    style: ghostty.Style,
    fg: ghostty.color.RGB,
    palette: *const ghostty.color.Palette,
    ascent_px: f32,
    cell_h: f32,
    out: *[MAX_RECTS]Rect,
) usize {
    if (!hasDecoration(style)) return 0;

    const t = ui_metrics.cellLineThicknessPx(ascent_px);
    var n: usize = 0;

    // 위에서 아래 순서 — 윗줄, 취소선, 밑줄.

    if (style.flags.overline) {
        // ghostty 의 `overline_position = 0` 과 같다 — 셀 최상단.
        out[n] = .{ .y = clampY(0, t, cell_h), .h = t, .color = fg };
        n += 1;
    }

    if (style.flags.strikethrough) {
        // 상수는 선의 **중심** 위치다 (정석이 `x_height / 2` 이므로) — 사각형
        // 좌표로 바꾸려면 두께의 절반만큼 올려야 한다.
        const center = ascent_px - ascent_px * ui_metrics.STRIKETHROUGH_CENTER_RATIO;
        out[n] = .{ .y = clampY(@round(center - t / 2), t, cell_h), .h = t, .color = fg };
        n += 1;
    }

    if (style.flags.underline != .none) {
        const color = style.underlineColor(palette) orelse fg;
        const gap = @round(ascent_px * ui_metrics.UNDERLINE_GAP_RATIO);
        const single_y = ascent_px + gap;

        if (style.flags.underline == .double) {
            // ghostty 의 "negative underline" — 단일 밑줄 자리를 **비우고** 위아래로
            // 두께만큼 놓는다. 전체가 3×t 를 차지하므로 아래 선이 셀 밖으로 나가지
            // 않도록 기준선 자체를 먼저 당긴다 (ghostty `special.zig` 와 같은 방식).
            const y = @min(single_y, cell_h - 2 * t);
            out[n] = .{ .y = clampY(@round(y - t), t, cell_h), .h = t, .color = color };
            n += 1;
            out[n] = .{ .y = clampY(@round(y + t), t, cell_h), .h = t, .color = color };
            n += 1;
        } else {
            // `single` 과 미지원 3종 (`curly` · `dotted` · `dashed`) 이 여기로 온다.
            out[n] = .{ .y = clampY(@round(single_y), t, cell_h), .h = t, .color = color };
            n += 1;
        }
    }

    return n;
}

/// 선이 셀 밖으로 나가지 않게 가둔다. 아래로 넘치면 셀 바닥에 붙이고, 셀이 두께보다
/// 얇은 극단(작은 폰트 + 큰 두께)에서는 0 으로 떨어뜨려 음수 좌표를 만들지 않는다.
fn clampY(y: f32, h: f32, cell_h: f32) f32 {
    return @max(0, @min(y, cell_h - h));
}

// --- tests (순수 로직 — 세 platform 이 같은 값을 쓴다) ---

const test_palette = ghostty.color.default;
const test_fg = ghostty.color.RGB{ .r = 200, .g = 210, .b = 220 };

/// 실측 기준값 — Menlo 14pt @1.0x (`ascent_px` 13, `cell_h` 17).
const A: f32 = 13.0;
const H: f32 = 17.0;

fn collect(style: ghostty.Style) struct { n: usize, r: [MAX_RECTS]Rect } {
    var out: [MAX_RECTS]Rect = undefined;
    const n = rects(style, test_fg, &test_palette, A, H, &out);
    return .{ .n = n, .r = out };
}

test "선이 없는 셀은 사각형을 만들지 않는다" {
    try std.testing.expectEqual(@as(usize, 0), collect(.{}).n);
    try std.testing.expect(!hasDecoration(.{}));
    // inverse / bold 처럼 선과 무관한 flag 는 사각형을 만들지 않는다.
    try std.testing.expectEqual(@as(usize, 0), collect(.{ .flags = .{ .inverse = true, .bold = true } }).n);
}

test "single 밑줄 — baseline 아래 gap 만큼, 두께는 정수 1px 이상" {
    const got = collect(.{ .flags = .{ .underline = .single } });
    try std.testing.expectEqual(@as(usize, 1), got.n);
    // t = max(1, round(13 × 0.06)) = max(1, round(0.78)) = 1
    try std.testing.expectEqual(@as(f32, 1), got.r[0].h);
    // gap = round(13 × 0.07) = round(0.91) = 1 → y = 13 + 1 = 14
    try std.testing.expectEqual(@as(f32, 14), got.r[0].y);
    // 색이 명시되지 않았으면 fg.
    try std.testing.expectEqual(test_fg, got.r[0].color);
}

test "double 밑줄 — 단일 자리를 비우고 위아래로 두께만큼 (ghostty negative underline)" {
    const got = collect(.{ .flags = .{ .underline = .double } });
    try std.testing.expectEqual(@as(usize, 2), got.n);
    // single_y = 14, t = 1 → 위 선 13, 아래 선 15. 가운데 14 가 비어 "이중" 으로 보인다.
    try std.testing.expectEqual(@as(f32, 13), got.r[0].y);
    try std.testing.expectEqual(@as(f32, 15), got.r[1].y);
    try std.testing.expectEqual(got.r[0].y + 2 * got.r[0].h, got.r[1].y);
}

test "#374 미지원 스타일은 single 로 떨어진다 — 밑줄이 통째로 사라지지 않게" {
    const single_y = collect(.{ .flags = .{ .underline = .single } }).r[0].y;
    inline for (.{ .curly, .dotted, .dashed }) |style_kind| {
        const got = collect(.{ .flags = .{ .underline = style_kind } });
        try std.testing.expectEqual(@as(usize, 1), got.n);
        try std.testing.expectEqual(single_y, got.r[0].y);
    }
}

test "underline_color (SGR 58) 는 밑줄에만 적용되고 취소선·윗줄은 fg 를 쓴다" {
    const ul = ghostty.color.RGB{ .r = 255, .g = 0, .b = 0 };
    const got = collect(.{
        .underline_color = .{ .rgb = ul },
        .flags = .{ .underline = .single, .strikethrough = true, .overline = true },
    });
    try std.testing.expectEqual(@as(usize, 3), got.n);
    // 순서는 위에서 아래 — 윗줄, 취소선, 밑줄.
    try std.testing.expectEqual(test_fg, got.r[0].color); // overline
    try std.testing.expectEqual(test_fg, got.r[1].color); // strikethrough
    try std.testing.expectEqual(ul, got.r[2].color); // underline
}

test "underline_color 가 palette 색이면 palette 에서 읽는다" {
    const got = collect(.{
        .underline_color = .{ .palette = 1 },
        .flags = .{ .underline = .single },
    });
    try std.testing.expectEqual(test_palette[1], got.r[0].color);
}

test "윗줄은 셀 최상단, 취소선은 baseline 위" {
    const got = collect(.{ .flags = .{ .strikethrough = true, .overline = true } });
    try std.testing.expectEqual(@as(usize, 2), got.n);
    try std.testing.expectEqual(@as(f32, 0), got.r[0].y); // overline = 셀 top
    // center = 13 − 13×0.30 = 9.1 → y = round(9.1 − 0.5) = round(8.6) = 9
    try std.testing.expectEqual(@as(f32, 9), got.r[1].y);
    // 취소선은 baseline(13) 보다 위에 있어야 한다 — 소문자 한가운데를 지나는 선.
    try std.testing.expect(got.r[1].y + got.r[1].h < A);
}

test "invisible (SGR 8) 은 선까지 전부 숨긴다 — xterm · ghostty 정책" {
    const style = ghostty.Style{ .flags = .{
        .invisible = true,
        .underline = .double,
        .strikethrough = true,
        .overline = true,
    } };
    try std.testing.expect(!hasDecoration(style));
    try std.testing.expectEqual(@as(usize, 0), collect(style).n);
}

test "선은 셀을 벗어나지 않는다 — 큰 폰트·얇은 셀 경계" {
    // descent 가 거의 없어 baseline 이 셀 바닥에 붙은 극단. double 의 아래 선이
    // 밖으로 나가려 하므로 기준선이 당겨진다.
    var out: [MAX_RECTS]Rect = undefined;
    const n = rects(
        .{ .flags = .{ .underline = .double, .strikethrough = true, .overline = true } },
        test_fg,
        &test_palette,
        20.0, // ascent
        20.0, // cell_h — baseline 이 곧 셀 바닥
        &out,
    );
    for (out[0..n]) |r| {
        try std.testing.expect(r.y >= 0);
        try std.testing.expect(r.y + r.h <= 20.0);
        try std.testing.expect(r.h >= 1);
    }
}

test "두께는 폰트가 커지면 함께 굵어지고 항상 정수다" {
    // 같은 폰트를 키우거나 배율을 올리면 ascent_px 가 커진다.
    const cases = [_]struct { ascent: f32, expect_t: f32 }{
        .{ .ascent = 8, .expect_t = 1 }, // round(0.48) = 0 → 최소 1
        .{ .ascent = 13, .expect_t = 1 }, // round(0.78) = 1
        .{ .ascent = 26, .expect_t = 2 }, // round(1.56) = 2  (Menlo 14pt @2x)
        .{ .ascent = 45, .expect_t = 3 }, // round(2.70) = 3
    };
    for (cases) |c| {
        var out: [MAX_RECTS]Rect = undefined;
        const n = rects(.{ .flags = .{ .underline = .single } }, test_fg, &test_palette, c.ascent, c.ascent * 1.3, &out);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqual(c.expect_t, out[0].h);
        try std.testing.expectEqual(out[0].h, @round(out[0].h));
    }
}

test "MAX_RECTS 는 실제 최대치와 일치한다" {
    // double(2) + strikethrough(1) + overline(1) = 4.
    const got = collect(.{ .flags = .{ .underline = .double, .strikethrough = true, .overline = true } });
    try std.testing.expectEqual(@as(usize, MAX_RECTS), got.n);
}
