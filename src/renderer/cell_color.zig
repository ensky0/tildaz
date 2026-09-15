// Cell fg/bg 색 해석 — 세 renderer (Windows d3d11 / macOS Metal / Linux
// software) 공통 정책 (#282 B2). `block_element.zig` 패턴: 정책은 여기
// 한 곳, platform 은 출력 포맷 변환 (float 화 / default-bg 처리) 만.
//
// 규칙 (Windows / macOS 출하 renderer 의 검증된 시각이 기준):
//   - selection / inverse: cell 고유 fg ↔ bg 를 교환. theme 전역 색으로
//     대체하지 않는다 — cell 에 고유 색이 없을 때만 theme default 로.
//     교환된 bg 는 bold=bright 를 반영하지 않는다 (평시 fg 만 반영).
//   - 평시 fg: bold → bright palette 승격, faint → bg 와 50% blend.
//   - 평시 bg: cell 고유 bg 없으면 null — GPU renderer 는 instance 를 안
//     만들고 (전역 clear 색), software renderer 는 theme 배경으로 그린다.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const themes = @import("../themes.zig");
const cell_highlight = @import("../cell_highlight.zig");
const chrome_palette = @import("../chrome_palette.zig");
const ui_metrics = @import("../ui_metrics.zig");

/// GPU renderer frame clear와 비활성 탭이 함께 쓰는 active terminal 배경.
/// OSC 11의 현재 RGB가 있으면 그것을 정규화하고, terminal이 값을 제공하지 않는
/// 예외에만 renderer init theme fallback을 유지한다 (#282 B8).
pub fn resolveFrameBackground(background: ?ghostty.color.RGB, fallback: [3]f32) [3]f32 {
    const bg = background orelse return fallback;
    return .{
        @as(f32, @floatFromInt(bg.r)) / 255.0,
        @as(f32, @floatFromInt(bg.g)) / 255.0,
        @as(f32, @floatFromInt(bg.b)) / 255.0,
    };
}

/// 검색 강조가 걸린 셀의 fg / bg. `null` 이면 강조가 없다 (평소 경로).
pub const HighlightColors = struct {
    bg: ghostty.color.RGB,
    fg: ghostty.color.RGB,
};

/// 강조 종류에서 색 한 벌을 만든다. **정책은 여기 한 곳**이고 세 renderer 는 결과만 쓴다.
///
/// - **현재 매치는 amber (`TAB_ACCENT_COLOR`) 채움.** 앱이 이미 "활성" 에 쓰는 색이라
///   (활성 탭 밑줄 · pane 포커스) 검색의 "지금 이것" 도 같은 색으로 모은다.
/// - **그 위 글자는 theme 과 무관하게 어둡다** (`SEARCH_CURRENT_FG`). amber 는
///   `chrome_palette` 파생을 타지 않는 고정 밝은 색이라, 밝은 theme 의 밝은 글자색을
///   쓰면 대비가 2:1 아래로 떨어져 읽히지 않는다.
/// - **나머지 매치는 chrome 의 hover 색**을 쓴다 — 메뉴 hover 와 같은 "약한 강조" 다.
/// - **링크 hover (tag 0) 는 여기서 색을 주지 않는다** — #647 의 몫이라 `null` 이다.
///   `cell_highlight.at` 이 그 tag 를 돌려줘도 이 함수가 색을 모르면 평소대로 그린다.
pub fn highlightColors(
    tag: cell_highlight.Tag,
    chrome: *const chrome_palette.Palette,
) ?HighlightColors {
    return switch (tag) {
        .search_current => .{
            .bg = rgbOf(ui_metrics.TAB_ACCENT_COLOR),
            .fg = rgbOf(ui_metrics.SEARCH_CURRENT_FG),
        },
        .search_match => .{
            .bg = rgbOf(chrome.menu_hover_bg),
            .fg = rgbOf(chrome.menu_label),
        },
        .link_hover => null,
    };
}

/// 이 열에 걸린 강조 중 **색을 가진 것** 가운데 우선순위가 가장 높은 것.
///
/// `cell_highlight.at` 은 tag 값이 가장 작은 것 하나를 돌려주는데, 그 tag 가 색을 주지
/// 않으면 (`link_hover` — #647 은 색 대신 밑줄로 표현한다) 색이 통째로 사라진다. 그러면
/// **검색 매치이면서 링크인 칸에 마우스를 올렸을 때 매치 표시가 없어져** 어디가 매치인지가
/// 포인터 위치에 따라 깜빡인다.
///
/// 그래서 색 결정은 "우선순위 최상" 이 아니라 "색이 있는 것 중 최상" 으로 고른다. 두 기능이
/// *다른 축* (색 · 밑줄) 을 쓰므로 한 칸에서 공존하는 것이 맞다.
pub fn highlightAt(
    hls: []const ghostty.RenderState.Highlight,
    x: u16,
    chrome: *const chrome_palette.Palette,
) ?HighlightColors {
    var best: ?cell_highlight.Tag = null;
    var best_colors: ?HighlightColors = null;
    for (hls) |h| {
        if (x < h.range[0] or x > h.range[1]) continue;
        const tag = blk: {
            inline for (comptime std.enums.values(cell_highlight.Tag)) |t| {
                if (t.value() == h.tag) break :blk t;
            }
            continue;
        };
        const colors = highlightColors(tag, chrome) orelse continue; // 색 없는 종류는 건너뛴다
        if (best == null or tag.value() < best.?.value()) {
            best = tag;
            best_colors = colors;
        }
    }
    return best_colors;
}

fn rgbOf(c: [4]f32) ghostty.color.RGB {
    return .{
        .r = @intFromFloat(@round(std.math.clamp(c[0], 0.0, 1.0) * 255.0)),
        .g = @intFromFloat(@round(std.math.clamp(c[1], 0.0, 1.0) * 255.0)),
        .b = @intFromFloat(@round(std.math.clamp(c[2], 0.0, 1.0) * 255.0)),
    };
}

pub fn resolveFg(
    style: ghostty.Style,
    raw: *const ghostty.Cell,
    colors: *const ghostty.RenderState.Colors,
    is_selected: bool,
    is_inverse: bool,
    hl: ?HighlightColors,
) ghostty.color.RGB {
    // **선택이 검색 강조를 이긴다.** 선택은 사용자가 방금 만든 것이고 복사할 대상이라,
    // 겹치면 그쪽이 보여야 한다. 검색 매치는 그 아래 깔린 정적인 표시다.
    if (!is_selected) if (hl) |h| return h.fg;
    if (is_selected or is_inverse) {
        return style.bg(raw, &colors.palette) orelse colors.background;
    }
    const base = style.fg(.{
        .default = colors.foreground,
        .palette = &colors.palette,
        .bold = .bright,
    });
    if (style.flags.faint) {
        const bg = style.bg(raw, &colors.palette) orelse colors.background;
        return themes.faintBlend(base, bg);
    }
    return base;
}

/// #376 — SGR 5 (blink) 의 off 위상을 **faint 로** 표현한다. `faint_phase` 는
/// [`ui_metrics.blinkFaintPhase`](../ui_metrics.zig) 가 준 프레임 단위 값이다.
///
/// **flag 를 갈아 끼우는 방식인 이유.** `resolveFg` 에 인자를 하나 더 다는 대신
/// style 의 `faint` 를 세워서 돌려주면, fg 해석 (`themes.faintBlend`) 뿐 아니라
/// [`cell_decoration`](cell_decoration.zig) 이 그리는 밑줄·취소선·윗줄 색까지
/// **한 번에** 따라온다 — 선은 `fg` 를 받아 그리기 때문이다. 세 renderer 의
/// 호출부 10곳에 인자를 퍼뜨리지 않아도 된다.
///
/// 이미 `faint` 인 셀에 blink 가 걸려 있으면 off 위상에서 변화가 없다 (둘 다
/// 같은 blend). 알려진 귀결이고, Windows Terminal 도 같은 조합에서 같은 문제를
/// 겪는다 ([microsoft/terminal#15676](https://github.com/microsoft/terminal/issues/15676)).
pub fn applyBlinkPhase(style: ghostty.Style, faint_phase: bool) ghostty.Style {
    if (!faint_phase or !style.flags.blink) return style;
    var faded = style;
    faded.flags.faint = true;
    return faded;
}

/// null = cell 고유 bg 없음 (default background) — 처리 방식만 platform 몫.
pub fn resolveBg(
    style: ghostty.Style,
    raw: *const ghostty.Cell,
    colors: *const ghostty.RenderState.Colors,
    is_selected: bool,
    is_inverse: bool,
    hl: ?HighlightColors,
) ?ghostty.color.RGB {
    // `resolveFg` 와 같은 우선순위 — 선택이 위다.
    if (!is_selected) if (hl) |h| return h.bg;
    if (is_selected or is_inverse) {
        return style.fg(.{
            .default = colors.foreground,
            .palette = &colors.palette,
        });
    }
    return style.bg(raw, &colors.palette);
}

// --- tests (순수 로직 — 어느 host 에서든 3 platform 규칙 검증) ---

const test_colors = ghostty.RenderState.Colors{
    .background = .{ .r = 10, .g = 20, .b = 30 },
    .foreground = .{ .r = 200, .g = 210, .b = 220 },
    .cursor = null,
    .palette = ghostty.color.default,
};

test "frame background — current terminal RGB 전체를 사용하고 null만 fallback" {
    const fallback = [3]f32{ 0.9, 0.8, 0.7 };
    const actual = resolveFrameBackground(.{ .r = 51, .g = 102, .b = 204 }, fallback);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), actual[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), actual[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), actual[2], 0.0001);
    try std.testing.expectEqual(fallback, resolveFrameBackground(null, fallback));
}

test "평시 — cell 고유 색 없으면 fg=theme fg, bg=null" {
    const style = ghostty.Style{};
    const raw = ghostty.Cell{};
    const fg = resolveFg(style, &raw, &test_colors, false, false, null);
    try std.testing.expectEqual(test_colors.foreground, fg);
    try std.testing.expectEqual(@as(?ghostty.color.RGB, null), resolveBg(style, &raw, &test_colors, false, false, null));
}

test "selection/inverse — cell 고유 fg/bg 교환" {
    const cell_fg = ghostty.color.RGB{ .r = 1, .g = 2, .b = 3 };
    const cell_bg = ghostty.color.RGB{ .r = 4, .g = 5, .b = 6 };
    const style = ghostty.Style{
        .fg_color = .{ .rgb = cell_fg },
        .bg_color = .{ .rgb = cell_bg },
    };
    const raw = ghostty.Cell{};
    // selected: fg ← cell bg, bg ← cell fg
    try std.testing.expectEqual(cell_bg, resolveFg(style, &raw, &test_colors, true, false, null));
    try std.testing.expectEqual(@as(?ghostty.color.RGB, cell_fg), resolveBg(style, &raw, &test_colors, true, false, null));
    // inverse 도 동일 교환
    try std.testing.expectEqual(cell_bg, resolveFg(style, &raw, &test_colors, false, true, null));
    try std.testing.expectEqual(@as(?ghostty.color.RGB, cell_fg), resolveBg(style, &raw, &test_colors, false, true, null));
}

test "selection — cell 고유 색 없으면 theme fg/bg 로 교환" {
    const style = ghostty.Style{};
    const raw = ghostty.Cell{};
    try std.testing.expectEqual(test_colors.background, resolveFg(style, &raw, &test_colors, true, false, null));
    try std.testing.expectEqual(@as(?ghostty.color.RGB, test_colors.foreground), resolveBg(style, &raw, &test_colors, true, false, null));
}

test "bold — 평시 fg 는 bright 승격, 교환 bg 는 승격 없음" {
    // palette 1 (red) + bold → 평시 fg 는 bright red (palette 9).
    const style = ghostty.Style{
        .fg_color = .{ .palette = 1 },
        .flags = .{ .bold = true },
    };
    const raw = ghostty.Cell{};
    try std.testing.expectEqual(ghostty.color.default[9], resolveFg(style, &raw, &test_colors, false, false, null));
    // 교환된 bg 는 bold 미반영 — palette 1 그대로 (Windows/macOS 현행).
    try std.testing.expectEqual(@as(?ghostty.color.RGB, ghostty.color.default[1]), resolveBg(style, &raw, &test_colors, false, true, null));
}

test "#376 blink 의 off 위상은 faint 로 표현된다" {
    const blink = ghostty.Style{ .flags = .{ .blink = true } };

    // on 위상 — 손대지 않는다.
    try std.testing.expect(!applyBlinkPhase(blink, false).flags.faint);
    try std.testing.expect(applyBlinkPhase(blink, false).flags.blink);

    // off 위상 — faint 가 서고 blink 플래그는 남는다 (다음 위상에 다시 켜져야 하므로).
    const faded = applyBlinkPhase(blink, true);
    try std.testing.expect(faded.flags.faint);
    try std.testing.expect(faded.flags.blink);

    // blink 없는 셀은 위상과 무관하게 그대로다.
    const plain = ghostty.Style{ .flags = .{ .underline = .single } };
    try std.testing.expect(!applyBlinkPhase(plain, true).flags.faint);
    try std.testing.expectEqual(plain.flags, applyBlinkPhase(plain, true).flags);
}

test "#376 blink off 위상의 fg 는 faint 와 같은 색이다 — 같은 blend 경로" {
    const cell_fg = ghostty.color.RGB{ .r = 100, .g = 150, .b = 200 };
    const raw = ghostty.Cell{};
    const blink = ghostty.Style{ .fg_color = .{ .rgb = cell_fg }, .flags = .{ .blink = true } };
    const faint = ghostty.Style{ .fg_color = .{ .rgb = cell_fg }, .flags = .{ .faint = true } };

    // off 위상 = faint 셀과 동일한 색.
    try std.testing.expectEqual(
        resolveFg(faint, &raw, &test_colors, false, false, null),
        resolveFg(applyBlinkPhase(blink, true), &raw, &test_colors, false, false, null),
    );
    // on 위상 = 평범한 셀과 동일한 색.
    try std.testing.expectEqual(
        cell_fg,
        resolveFg(applyBlinkPhase(blink, false), &raw, &test_colors, false, false, null),
    );
}

test "faint — fg 를 bg 와 50% blend" {
    const style = ghostty.Style{
        .fg_color = .{ .rgb = .{ .r = 100, .g = 100, .b = 100 } },
        .flags = .{ .faint = true },
    };
    const raw = ghostty.Cell{};
    const expected = themes.faintBlend(.{ .r = 100, .g = 100, .b = 100 }, test_colors.background);
    try std.testing.expectEqual(expected, resolveFg(style, &raw, &test_colors, false, false, null));
}

test "#646 강조 색 — 현재 매치는 amber 채움에 어두운 글자" {
    const chrome = chrome_palette.derive(.{ 0, 0, 0 }, true);
    const hl = highlightColors(.search_current, &chrome).?;
    // 배경은 앱의 활성 색 (amber) 그대로.
    try std.testing.expectEqual(@as(u8, 247), hl.bg.r);
    try std.testing.expectEqual(@as(u8, 164), hl.bg.g);
    try std.testing.expectEqual(@as(u8, 29), hl.bg.b);
    // 글자는 어둡다 — amber 위 대비를 위해.
    try std.testing.expectEqual(@as(u8, 0), hl.fg.r);
}

test "#646 강조 색 — 밝은 theme 에서도 현재 매치 글자는 어둡다" {
    // amber 는 chrome_palette 파생을 타지 않으므로 밝은 theme 에서도 같은 배경이다.
    // 그 위 글자까지 밝아지면 대비가 무너지므로 theme 과 무관하게 어두워야 한다.
    const light = chrome_palette.derive(.{ 0xef, 0xf1, 0xf5 }, false);
    const hl = highlightColors(.search_current, &light).?;
    try std.testing.expectEqual(@as(u8, 247), hl.bg.r);
    try std.testing.expectEqual(@as(u8, 0), hl.fg.r);
    try std.testing.expectEqual(@as(u8, 0), hl.fg.g);
    try std.testing.expectEqual(@as(u8, 0), hl.fg.b);
}

test "#646 강조 색 — 나머지 매치는 chrome hover 색을 쓴다" {
    const chrome = chrome_palette.derive(.{ 0, 0, 0 }, true);
    const hl = highlightColors(.search_match, &chrome).?;
    try std.testing.expectEqual(@as(u8, 64), hl.bg.r);
    try std.testing.expectEqual(@as(u8, 235), hl.fg.r);
}

test "#646 강조 색 — 링크 hover 는 이 모듈이 색을 모른다 (#647 몫)" {
    const chrome = chrome_palette.derive(.{ 0, 0, 0 }, true);
    try std.testing.expect(highlightColors(.link_hover, &chrome) == null);
}

test "#646 선택이 검색 강조를 이긴다" {
    const chrome = chrome_palette.derive(.{ 0, 0, 0 }, true);
    const hl = highlightColors(.search_current, &chrome);
    const style = ghostty.Style{};
    const raw = ghostty.Cell{};

    // 선택된 셀은 강조가 걸려 있어도 선택 색 (fg ↔ bg 교환) 으로 그린다.
    try std.testing.expectEqual(test_colors.background, resolveFg(style, &raw, &test_colors, true, false, hl));
    try std.testing.expectEqual(
        @as(?ghostty.color.RGB, test_colors.foreground),
        resolveBg(style, &raw, &test_colors, true, false, hl),
    );

    // 선택이 아니면 강조 색이 이긴다.
    try std.testing.expectEqual(hl.?.fg, resolveFg(style, &raw, &test_colors, false, false, hl));
    try std.testing.expectEqual(@as(?ghostty.color.RGB, hl.?.bg), resolveBg(style, &raw, &test_colors, false, false, hl));
}

test "#646 · #647 링크 hover 가 검색 강조를 덮어 색을 지우지 않는다" {
    const chrome = chrome_palette.derive(.{ 0, 0, 0 }, true);
    const style = ghostty.Style{};
    const raw = ghostty.Cell{};

    // 검색 매치이면서 동시에 링크 hover 인 셀 — 두 기능이 같은 칸에서 만난다.
    const hls = [_]ghostty.RenderState.Highlight{
        .{ .tag = cell_highlight.Tag.search_match.value(), .range = .{ 0, 9 } },
        .{ .tag = cell_highlight.Tag.link_hover.value(), .range = .{ 0, 9 } },
    };

    // 링크는 색을 주지 않고 (밑줄로 표현한다) 검색은 배경색을 준다. 둘이 겹쳐도
    // **검색 강조 색은 살아 있어야 한다** — 마우스를 올렸다고 매치 표시가 사라지면
    // "어디가 매치인지" 가 포인터 위치에 따라 깜빡인다.
    const hl = highlightAt(&hls, 5, &chrome);
    try std.testing.expect(hl != null);
    try std.testing.expectEqual(rgbOf(chrome.menu_hover_bg), hl.?.bg);

    // 링크만 걸린 칸은 여전히 색이 없다 (밑줄이 그 몫이다).
    const only_link = [_]ghostty.RenderState.Highlight{
        .{ .tag = cell_highlight.Tag.link_hover.value(), .range = .{ 0, 9 } },
    };
    try std.testing.expect(highlightAt(&only_link, 5, &chrome) == null);

    _ = style;
    _ = raw;
}
