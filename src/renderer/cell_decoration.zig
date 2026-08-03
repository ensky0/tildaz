//! SGR 선 속성 — `underline` (single · double) · `strikethrough` · `overline` 의
//! 사각형 조립 (#365). 세 renderer (Linux software / macOS Metal / Windows d3d11)
//! 공통 정책. [`cell_color.zig`](cell_color.zig) · [`block_element.zig`](block_element.zig)
//! 와 같은 패턴이다 — **정책은 여기 한 곳, platform 은 자기 목록에 넣는 것만.**
//!
//! ## 좌표 계약
//!
//! 돌려주는 좌표는 **셀 좌상단 기준 상대 physical px** 이다. 호출부는 자기 셀의
//! 원점에 더하기만 하면 된다.
//!
//! `x` · `w` 를 담는 것은 점선 · 파선 ([#374](https://github.com/ensky0/tildaz/issues/374))
//! 때문이다. 그 전에는 폭이 언제나 셀 폭이라 `y` · `h` 만 냈지만, 점선은 셀 안을
//! 가로로 쪼개므로 여기서 폭을 정해야 한다. 대신 **셀 폭을 인자로 받는다** — wide
//! char 판정 (2배) 은 호출부가 이미 한 값을 그대로 넘긴다.
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

/// 밑줄 하나가 만들 수 있는 최대 조각 수. 점선 (#374) 이 가장 많고, 개수는
/// `cell_w / (2 × thickness)` 로 정해진다 — 둘 다 폰트 크기에 비례하므로 **비율이
/// 폰트 크기와 무관**하다. narrow 셀에서 4~5, **wide char 는 셀 폭이 2배라 그
/// 2배**가 나온다 (Menlo 15pt narrow 5 · wide 10, 30pt narrow 6 · wide 12).
/// 12 면 wide 까지 자르지 않고 들어가고, 그 이상은 [`dotCount`] 가 자른다.
pub const MAX_UNDERLINE_PIECES = 12;

/// 한 셀이 만들 수 있는 최대 사각형 수 — 밑줄 조각 + 취소선 1 + 윗줄 1.
/// 밑줄 스타일은 한 번에 하나뿐이라 이중 밑줄 (2) 은 점선 상한 안에 들어간다.
pub const MAX_RECTS = MAX_UNDERLINE_PIECES + 2;

/// 선 하나. 좌표는 셀 좌상단 기준 상대 physical px (위 「좌표 계약」).
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
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
/// ## `curly` 만 아직 `single` 로 떨어뜨린다
///
/// `dotted` (`4:4`) · `dashed` (`4:5`) 는 [#374](https://github.com/ensky0/tildaz/issues/374)
/// 로 구현했다. **`curly` (`4:3`) 만 남는다** — 사인파라 사각형으로 표현되지 않아
/// 세 platform 의 셰이더와 CPU 래스터라이저를 모두 손대야 한다.
///
/// 그동안 아무것도 안 그리면 neovim 의 LSP 진단 밑줄이 **통째로 사라지므로** 최소한
/// 직선으로는 보이게 한다. *ghostty 파서가 미지원 스타일을 `single` 로 떨어뜨리는
/// 것과는 층위가 다르다* — 그쪽은 `4:6` 이상의 미정의 숫자에만 해당하고, `4:3` 은
/// 파서가 `.curly` 로 정확히 넘긴 뒤 renderer 가 실제 곡선을 그린다. 우리는 파서가
/// 준 `.curly` 를 **렌더 단계에서** 직선으로 낮추는 것이다.
pub fn rects(
    style: ghostty.Style,
    fg: ghostty.color.RGB,
    palette: *const ghostty.color.Palette,
    ascent_px: f32,
    cell_w: f32,
    cell_h: f32,
    out: *[MAX_RECTS]Rect,
) usize {
    if (!hasDecoration(style)) return 0;

    const t = ui_metrics.cellLineThicknessPx(ascent_px);
    var n: usize = 0;

    // 위에서 아래 순서 — 윗줄, 취소선, 밑줄.

    if (style.flags.overline) {
        // ghostty 의 `overline_position = 0` 과 같다 — 셀 최상단.
        out[n] = .{ .x = 0, .w = cell_w, .y = clampY(0, t, cell_h), .h = t, .color = fg };
        n += 1;
    }

    if (style.flags.strikethrough) {
        // 상수는 선의 **중심** 위치다 (정석이 `x_height / 2` 이므로) — 사각형
        // 좌표로 바꾸려면 두께의 절반만큼 올려야 한다.
        const center = ascent_px - ascent_px * ui_metrics.STRIKETHROUGH_CENTER_RATIO;
        out[n] = .{ .x = 0, .w = cell_w, .y = clampY(@round(center - t / 2), t, cell_h), .h = t, .color = fg };
        n += 1;
    }

    if (style.flags.underline != .none) {
        const color = style.underlineColor(palette) orelse fg;
        const gap = @round(ascent_px * ui_metrics.UNDERLINE_GAP_RATIO);
        const y = clampY(@round(ascent_px + gap), t, cell_h);

        switch (style.flags.underline) {
            .none => unreachable, // 위 조건이 이미 걸렀다.

            .double => {
                // ghostty 의 "negative underline" — 단일 밑줄 자리를 **비우고** 위아래로
                // 두께만큼 놓는다. 전체가 3×t 를 차지하므로 아래 선이 셀 밖으로 나가지
                // 않도록 기준선 자체를 먼저 당긴다 (ghostty `special.zig` 와 같은 방식).
                const base = @min(ascent_px + gap, cell_h - 2 * t);
                out[n] = .{ .x = 0, .w = cell_w, .y = clampY(@round(base - t), t, cell_h), .h = t, .color = color };
                n += 1;
                out[n] = .{ .x = 0, .w = cell_w, .y = clampY(@round(base + t), t, cell_h), .h = t, .color = color };
                n += 1;
            },

            // #374 — 셀을 `count` 등분해 각 구간 **중앙**에 정사각형 dot 을 놓는다.
            // ghostty 와 같은 접근이고, 핵심은 **셀 경계 위상을 신경 쓸 필요가 없다**는
            // 점이다: 셀 폭이 모두 같으므로 셀마다 같은 리듬이 되어 이웃 셀과 자연히
            // 이어진다. 절대 x 좌표를 위상에 넣는 방식은 필요 없다.
            //
            // ghostty 는 원을 그리고 지름을 `√2 × thickness` 로 키운다 ("otherwise
            // dotted underlines look somewhat anemic") — 원이라 면적이 작기 때문이다.
            // 우리는 사각형이라 `thickness` 정사각형이면 충분하다.
            .dotted => {
                const count = dotCount(cell_w, t);
                const slot = cell_w / @as(f32, @floatFromInt(count));
                for (0..count) |i| {
                    const center_x = slot * (@as(f32, @floatFromInt(i)) + 0.5);
                    out[n] = .{
                        .x = clampX(@round(center_x - t / 2), t, cell_w),
                        .w = t,
                        .y = y,
                        .h = t,
                        .color = color,
                    };
                    n += 1;
                }
            },

            // #374 — ghostty 와 같은 식: `dash = 셀폭/3 + 1` 을 한 칸 걸러 놓아
            // 셀당 2 개가 된다. 마지막 조각이 셀을 넘으면 잘라 낸다.
            .dashed => {
                const dash_w = @max(1, @floor(cell_w / 3) + 1);
                var x: f32 = 0;
                while (x < cell_w and n < MAX_RECTS) : (x += 2 * dash_w) {
                    out[n] = .{ .x = x, .w = @min(dash_w, cell_w - x), .y = y, .h = t, .color = color };
                    n += 1;
                }
            },

            // `single` 과 아직 미지원인 `curly` 가 여기로 온다 (아래 주석).
            .single, .curly => {
                out[n] = .{ .x = 0, .w = cell_w, .y = y, .h = t, .color = color };
                n += 1;
            },
        }
    }

    return n;
}

/// 점선의 dot 개수. dot 과 그 사이 공백이 같은 폭이 되도록 주기를 `2 × thickness`
/// 로 잡는다. `cell_w` 와 `thickness` 가 둘 다 폰트 크기에 비례하므로 결과는 폰트
/// 크기와 거의 무관하고, wide char 는 셀 폭이 2배라 개수도 2배가 된다 (같은 밀도).
fn dotCount(cell_w: f32, thickness: f32) usize {
    const raw = @round(cell_w / (2 * thickness));
    if (!(raw >= 1)) return 1; // NaN · 0 · 음수 방어
    return @min(@as(usize, @intFromFloat(raw)), MAX_UNDERLINE_PIECES);
}

/// 선이 셀 밖으로 나가지 않게 가둔다. 아래로 넘치면 셀 바닥에 붙이고, 셀이 두께보다
/// 얇은 극단(작은 폰트 + 큰 두께)에서는 0 으로 떨어뜨려 음수 좌표를 만들지 않는다.
fn clampY(y: f32, h: f32, cell_h: f32) f32 {
    return @max(0, @min(y, cell_h - h));
}

/// [`clampY`] 의 가로 판.
fn clampX(x: f32, w: f32, cell_w: f32) f32 {
    return @max(0, @min(x, cell_w - w));
}

// --- tests (순수 로직 — 세 platform 이 같은 값을 쓴다) ---

const test_palette = ghostty.color.default;
const test_fg = ghostty.color.RGB{ .r = 200, .g = 210, .b = 220 };

/// 실측 기준값 — Menlo 14pt @1.0x (`ascent_px` 13, `cell_w` 8, `cell_h` 17).
/// 이 값에서 두께 `t` 는 `max(1, round(13 × 0.06)) = 1` 이다.
const A: f32 = 13.0;
const W: f32 = 8.0;
const H: f32 = 17.0;

fn collect(style: ghostty.Style) struct { n: usize, r: [MAX_RECTS]Rect } {
    var out: [MAX_RECTS]Rect = undefined;
    const n = rects(style, test_fg, &test_palette, A, W, H, &out);
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

test "#374 curly 는 아직 single 로 떨어진다 — 밑줄이 통째로 사라지지 않게" {
    const single = collect(.{ .flags = .{ .underline = .single } });
    const curly = collect(.{ .flags = .{ .underline = .curly } });
    try std.testing.expectEqual(@as(usize, 1), curly.n);
    try std.testing.expectEqual(single.r[0].y, curly.r[0].y);
    try std.testing.expectEqual(single.r[0].w, curly.r[0].w);
}

test "#374 dotted — 셀을 등분해 각 구간 중앙에 정사각형 dot" {
    const got = collect(.{ .flags = .{ .underline = .dotted } });
    // t = 1, cell_w = 8 → count = round(8 / 2) = 4. 구간 폭 2, 중앙 1·3·5·7.
    try std.testing.expectEqual(@as(usize, 4), got.n);
    const single_y = collect(.{ .flags = .{ .underline = .single } }).r[0].y;
    for (got.r[0..got.n], 0..) |d, i| {
        // 모든 dot 이 직선 밑줄과 같은 높이에 정사각형으로 놓인다.
        try std.testing.expectEqual(single_y, d.y);
        try std.testing.expectEqual(@as(f32, 1), d.h);
        try std.testing.expectEqual(@as(f32, 1), d.w);
        // 등간격 — i 번째 구간의 중앙.
        try std.testing.expectEqual(@as(f32, @floatFromInt(1 + 2 * i)), d.x);
        // 셀 밖으로 나가지 않는다.
        try std.testing.expect(d.x >= 0 and d.x + d.w <= W);
    }
}

test "#374 dotted — wide char 는 셀 폭이 2배라 dot 도 2배 (같은 밀도)" {
    var narrow: [MAX_RECTS]Rect = undefined;
    var wide: [MAX_RECTS]Rect = undefined;
    const style = ghostty.Style{ .flags = .{ .underline = .dotted } };
    const n_narrow = rects(style, test_fg, &test_palette, A, W, H, &narrow);
    const n_wide = rects(style, test_fg, &test_palette, A, 2 * W, H, &wide);
    try std.testing.expectEqual(n_narrow * 2, n_wide);
    // 밀도가 같다 — wide 의 dot 간격이 narrow 와 같아야 셀 경계에서 리듬이 안 깨진다.
    try std.testing.expectEqual(narrow[1].x - narrow[0].x, wide[1].x - wide[0].x);
}

test "#374 dotted — 개수는 MAX_UNDERLINE_PIECES 를 넘지 않는다" {
    var out: [MAX_RECTS]Rect = undefined;
    // 비현실적으로 넓은 셀 — 상한이 걸려야 버퍼가 넘치지 않는다.
    const n = rects(.{ .flags = .{ .underline = .dotted } }, test_fg, &test_palette, A, 4000, H, &out);
    try std.testing.expectEqual(@as(usize, MAX_UNDERLINE_PIECES), n);
    // 셀이 두께보다 좁은 극단에서도 최소 1 개.
    const n_tiny = rects(.{ .flags = .{ .underline = .dotted } }, test_fg, &test_palette, A, 1, H, &out);
    try std.testing.expectEqual(@as(usize, 1), n_tiny);
}

test "#374 dashed — 한 칸 걸러 놓아 셀당 2 개, 마지막은 셀 폭에서 잘린다" {
    const got = collect(.{ .flags = .{ .underline = .dashed } });
    // dash_w = floor(8/3) + 1 = 3 → x = 0(w 3), x = 6(w min(3, 2) = 2).
    try std.testing.expectEqual(@as(usize, 2), got.n);
    try std.testing.expectEqual(@as(f32, 0), got.r[0].x);
    try std.testing.expectEqual(@as(f32, 3), got.r[0].w);
    try std.testing.expectEqual(@as(f32, 6), got.r[1].x);
    try std.testing.expectEqual(@as(f32, 2), got.r[1].w);
    // 두 조각 사이가 비어야 "파선" 이다.
    try std.testing.expect(got.r[0].x + got.r[0].w < got.r[1].x);
    // 셀 밖으로 나가지 않는다.
    for (got.r[0..got.n]) |d| try std.testing.expect(d.x + d.w <= W);
}

test "#374 점선·파선도 underline_color 를 따르고 취소선·윗줄과 공존한다" {
    const ul = ghostty.color.RGB{ .r = 255, .g = 0, .b = 0 };
    inline for (.{ .dotted, .dashed }) |kind| {
        const got = collect(.{
            .underline_color = .{ .rgb = ul },
            .flags = .{ .underline = kind, .strikethrough = true, .overline = true },
        });
        // 윗줄 + 취소선은 fg, 나머지 밑줄 조각은 전부 underline_color.
        try std.testing.expectEqual(test_fg, got.r[0].color);
        try std.testing.expectEqual(test_fg, got.r[1].color);
        try std.testing.expect(got.n > 2);
        for (got.r[2..got.n]) |d| try std.testing.expectEqual(ul, d.color);
        // 윗줄·취소선은 셀 전체 폭이다 (점선이 되지 않는다).
        try std.testing.expectEqual(W, got.r[0].w);
        try std.testing.expectEqual(W, got.r[1].w);
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
    inline for (.{ .double, .dotted, .dashed, .single }) |kind| {
        const n = rects(
            .{ .flags = .{ .underline = kind, .strikethrough = true, .overline = true } },
            test_fg,
            &test_palette,
            20.0, // ascent
            10.0, // cell_w
            20.0, // cell_h — baseline 이 곧 셀 바닥
            &out,
        );
        for (out[0..n]) |r| {
            try std.testing.expect(r.y >= 0);
            try std.testing.expect(r.y + r.h <= 20.0);
            try std.testing.expect(r.x >= 0);
            try std.testing.expect(r.x + r.w <= 10.0);
            try std.testing.expect(r.h >= 1 and r.w >= 1);
        }
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
        const n = rects(.{ .flags = .{ .underline = .single } }, test_fg, &test_palette, c.ascent, c.ascent * 0.6, c.ascent * 1.3, &out);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqual(c.expect_t, out[0].h);
        try std.testing.expectEqual(out[0].h, @round(out[0].h));
    }
}

test "MAX_RECTS 는 실제 최대치를 담는다 — 점선이 상한을 정한다" {
    var out: [MAX_RECTS]Rect = undefined;
    // 가장 많이 나오는 조합 = 점선(상한) + 취소선 + 윗줄. 넘치면 버퍼가 깨진다.
    const n = rects(
        .{ .flags = .{ .underline = .dotted, .strikethrough = true, .overline = true } },
        test_fg,
        &test_palette,
        A,
        4000, // dotCount 가 상한에 걸리는 넓은 셀
        H,
        &out,
    );
    try std.testing.expectEqual(@as(usize, MAX_RECTS), n);
    try std.testing.expectEqual(@as(usize, MAX_UNDERLINE_PIECES + 2), MAX_RECTS);

    // 이중 밑줄(2)은 점선 상한 안에 들어가므로 별도 여유가 필요 없다.
    try std.testing.expect(MAX_UNDERLINE_PIECES >= 2);
    const dbl = collect(.{ .flags = .{ .underline = .double, .strikethrough = true, .overline = true } });
    try std.testing.expectEqual(@as(usize, 4), dbl.n);
}
