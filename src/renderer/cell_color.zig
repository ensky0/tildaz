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

pub fn resolveFg(
    style: ghostty.Style,
    raw: *const ghostty.Cell,
    colors: *const ghostty.RenderState.Colors,
    is_selected: bool,
    is_inverse: bool,
) ghostty.color.RGB {
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

/// null = cell 고유 bg 없음 (default background) — 처리 방식만 platform 몫.
pub fn resolveBg(
    style: ghostty.Style,
    raw: *const ghostty.Cell,
    colors: *const ghostty.RenderState.Colors,
    is_selected: bool,
    is_inverse: bool,
) ?ghostty.color.RGB {
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
    const fg = resolveFg(style, &raw, &test_colors, false, false);
    try std.testing.expectEqual(test_colors.foreground, fg);
    try std.testing.expectEqual(@as(?ghostty.color.RGB, null), resolveBg(style, &raw, &test_colors, false, false));
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
    try std.testing.expectEqual(cell_bg, resolveFg(style, &raw, &test_colors, true, false));
    try std.testing.expectEqual(@as(?ghostty.color.RGB, cell_fg), resolveBg(style, &raw, &test_colors, true, false));
    // inverse 도 동일 교환
    try std.testing.expectEqual(cell_bg, resolveFg(style, &raw, &test_colors, false, true));
    try std.testing.expectEqual(@as(?ghostty.color.RGB, cell_fg), resolveBg(style, &raw, &test_colors, false, true));
}

test "selection — cell 고유 색 없으면 theme fg/bg 로 교환" {
    const style = ghostty.Style{};
    const raw = ghostty.Cell{};
    try std.testing.expectEqual(test_colors.background, resolveFg(style, &raw, &test_colors, true, false));
    try std.testing.expectEqual(@as(?ghostty.color.RGB, test_colors.foreground), resolveBg(style, &raw, &test_colors, true, false));
}

test "bold — 평시 fg 는 bright 승격, 교환 bg 는 승격 없음" {
    // palette 1 (red) + bold → 평시 fg 는 bright red (palette 9).
    const style = ghostty.Style{
        .fg_color = .{ .palette = 1 },
        .flags = .{ .bold = true },
    };
    const raw = ghostty.Cell{};
    try std.testing.expectEqual(ghostty.color.default[9], resolveFg(style, &raw, &test_colors, false, false));
    // 교환된 bg 는 bold 미반영 — palette 1 그대로 (Windows/macOS 현행).
    try std.testing.expectEqual(@as(?ghostty.color.RGB, ghostty.color.default[1]), resolveBg(style, &raw, &test_colors, false, true));
}

test "faint — fg 를 bg 와 50% blend" {
    const style = ghostty.Style{
        .fg_color = .{ .rgb = .{ .r = 100, .g = 100, .b = 100 } },
        .flags = .{ .faint = true },
    };
    const raw = ghostty.Cell{};
    const expected = themes.faintBlend(.{ .r = 100, .g = 100, .b = 100 }, test_colors.background);
    try std.testing.expectEqual(expected, resolveFg(style, &raw, &test_colors, false, false));
}
