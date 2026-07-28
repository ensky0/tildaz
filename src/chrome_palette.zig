//! 탭바 · command menu chrome 색을 terminal theme 배경에서 파생 (#335).
//!
//! [`ui_metrics.zig`](ui_metrics.zig) 의 chrome 색 상수는 **anchor** 다 — Tilda
//! (순수 검정) 배경에서의 값이고 #334 / #342 가 시연으로 확정했다. 이 모듈은 그
//! anchor 를 다른 theme 배경으로 옮긴다. 세 renderer 는 결과만 참조한다.
//!
//! 파생식 (채널별, linear-light):
//!
//!     C = k · bg + A           (dark theme)
//!     C = (bg − A) / k         (light theme — dark 식의 역함수)
//!
//! `A` = anchor 의 linear 값, `k = 1 + Y(A)/0.05` (= anchor 가 검정 위에서 갖는
//! WCAG 대비비). 성질 셋:
//!
//!   1. **anchor 정확 재현** — bg = 검정이면 `C = A`. Tilda 는 현행 값 그대로다.
//!   2. **대비비 보존** — `Y(C) + 0.05 = k · (Y(bg) + 0.05)` 가 항등이라 요소
//!      *쌍* 의 대비도 theme 과 무관하게 상수다. #334 / #342 가 튜닝한 관계
//!      (탭바 1.33 / 구분선 1.93 / 제목 7.58 / hint 6.44 …) 가 그대로 따라온다.
//!   3. **theme 색상 운반** — `k·bg` 항이 배경의 chromaticity 를 싣고 `A` 가 집
//!      tint (`33/35/38` 의 살짝 파란 끼) 를 더한다. 예외 처리가 없다.
//!
//! light 가 dark 의 역함수라 방향도 자동으로 뒤집힌다 — 밝은 theme 에서는 탭바 ·
//! 구분선 · 제목이 모두 *어두워지는* 쪽으로 파생된다.
//!
//! **헤드룸 캡** — `k` 가 큰 두 요소 (`ctrl_active` 18.8 · `menu_label` 17.7) 는
//! chrome 이 밝아지면 목표 대비를 만들 흰색이 남지 않는다 (Tilda 는 chrome 이
//! `33/35/38` 이라 14:1 이 성립하지만 Nord 는 `40/47/84` 라 불가능). 이때 채널별로
//! 각각 잘라내면 hue 가 틀어지므로 chrome→목표 **방향 전체를 스케일백**한다.
//! 캡이 걸려도 대비는 최악 7.75 (Nord) 로 아이콘은 chrome 에서 가장 밝게 남는다.
//!
//! **8-bit 양자화** — 출력 RGB 는 8-bit 격자에 놓는다. 세 platform 이 결국 8-bit
//! 픽셀에 쓰므로 공유 모듈에서 한 번 양자화하면 Linux · macOS · Windows 가
//! *정의상* 같은 값을 받는다 (이전에는 `MENU_HOVER_BG` 처럼 소수로 적힌 상수에서
//! Linux 의 truncate 와 GPU 의 round 가 1/255 씩 갈렸다).

const std = @import("std");
const ui_metrics = @import("ui_metrics.zig");

/// 파생된 chrome 색 한 벌. 세 renderer 가 `ui_metrics` 상수 대신 이 값을 참조한다.
/// 각 항은 renderer 가 쓰는 `[4]f32` (0..1) 이고 RGB 는 8-bit 격자 위에 있다.
/// alpha 는 모두 1.0 — hover 배경까지 미리 합성된 solid 다.
pub const Palette = struct {
    tab_bar_bg: [4]f32,
    separator: [4]f32,
    tab_text: [4]f32,
    ctrl_active: [4]f32,
    arrow_disabled: [4]f32,
    ctrl_hover_bg: [4]f32,
    menu_hover_bg: [4]f32,
    menu_label: [4]f32,
    menu_hint: [4]f32,
};

/// theme 배경에서 chrome 팔레트를 만든다.
///
/// `dark` 는 [`themes.isDarkRgb`](themes.zig) 의 결과를 받는다 — 명도 판정의 단일
/// 정의를 그 모듈에 두고 여기선 결과만 쓴다. 덕분에 이 모듈은 ghostty 에 의존하지
/// 않고 `zig test src/chrome_palette.zig` 로 단독 검증할 수 있다.
///
/// 입력은 config 로 고른 theme 의 배경이므로 renderer init 에서 한 번만 부르면
/// 된다 (theme 은 runtime 에 바뀌지 않는다 — config 변경은 재시작).
pub fn derive(theme_bg: [3]u8, dark: bool) Palette {
    const bg = linearOf(theme_bg);

    // 1단계 — 표면 (탭바 · 메뉴 배경). 채널별 클램프로 둔다: 방향 스케일백은
    // 한 채널이 경계에 닿으면 lift 를 통째로 잃어 띠가 사라질 수 있다.
    const bar = clampChannels(target(bg, anchor(ui_metrics.TAB_BAR_BG), dark));

    // 2단계 — chrome 위 요소. 목표는 같은 식으로 잡고 헤드룸만 캡한다.
    return .{
        .tab_bar_bg = toColor(bar),
        .separator = onChrome(bg, bar, ui_metrics.TAB_SEPARATOR_COLOR, dark),
        .tab_text = onChrome(bg, bar, ui_metrics.TAB_TEXT_COLOR, dark),
        .ctrl_active = onChrome(bg, bar, ui_metrics.TAB_CTRL_ACTIVE_COLOR, dark),
        .arrow_disabled = onChrome(bg, bar, ui_metrics.TAB_ARROW_DISABLED_COLOR, dark),
        .ctrl_hover_bg = onChrome(bg, bar, ui_metrics.TAB_CTRL_HOVER_BG, dark),
        .menu_hover_bg = onChrome(bg, bar, ui_metrics.MENU_HOVER_BG, dark),
        .menu_label = onChrome(bg, bar, ui_metrics.MENU_LABEL_COLOR, dark),
        .menu_hint = onChrome(bg, bar, ui_metrics.MENU_HINT_COLOR, dark),
    };
}

fn onChrome(bg: [3]f64, bar: [3]f64, anchor_color: [4]f32, dark: bool) [4]f32 {
    return toColor(capToward(bar, target(bg, anchor(anchor_color), dark)));
}

/// anchor 상수를 8-bit 로 확정한 뒤 linear 로. 상수는 8-bit 디자인 값이라
/// (`79.0/255.0` 등) 이 왕복이 정확하다.
fn anchor(c: [4]f32) [3]f64 {
    return linearOf(.{ quant(c[0]), quant(c[1]), quant(c[2]) });
}

fn target(bg: [3]f64, a: [3]f64, dark: bool) [3]f64 {
    const k = 1.0 + luminance(a) / 0.05;
    var out: [3]f64 = undefined;
    for (0..3) |i| out[i] = if (dark) k * bg[i] + a[i] else (bg[i] - a[i]) / k;
    return out;
}

/// 목표가 `[0,1]` 을 넘으면 `chrome → 목표` 방향을 유지한 채 전체를 스케일백해
/// 가장 먼 채널이 정확히 경계에 닿게 한다. 채널별 클리핑은 hue 를 틀어서 쓰지 않는다.
fn capToward(chrome: [3]f64, t: [3]f64) [3]f64 {
    var s: f64 = 1.0;
    for (0..3) |i| {
        const d = t[i] - chrome[i];
        if (d > 0.0 and chrome[i] + d > 1.0) s = @min(s, (1.0 - chrome[i]) / d);
        if (d < 0.0 and chrome[i] + d < 0.0) s = @min(s, -chrome[i] / d);
    }
    // chrome 이 이미 경계에 붙어 방향 보존이 불가능한 경우 (현재 theme 18종에서는
    // 도달하지 않는다). 요소가 chrome 에 묻혀 사라지는 것보다 hue 가 틀어지는 게
    // 나으므로 채널별 클램프로 떨어뜨린다.
    if (s <= 0.0) return clampChannels(t);

    var out: [3]f64 = undefined;
    for (0..3) |i| out[i] = std.math.clamp(chrome[i] + s * (t[i] - chrome[i]), 0.0, 1.0);
    return out;
}

fn clampChannels(v: [3]f64) [3]f64 {
    return .{
        std.math.clamp(v[0], 0.0, 1.0),
        std.math.clamp(v[1], 0.0, 1.0),
        std.math.clamp(v[2], 0.0, 1.0),
    };
}

/// Rec. 709 relative luminance (WCAG 대비 정의와 같은 가중치). theme 의 dark/light
/// *판정* 은 `themes.isDarkRgb` 의 BT.601 을 쓰고, 여기선 대비 *크기* 만 다룬다.
fn luminance(l: [3]f64) f64 {
    return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2];
}

fn linearOf(c: [3]u8) [3]f64 {
    var out: [3]f64 = undefined;
    for (0..3) |i| out[i] = srgbToLinear(@as(f64, @floatFromInt(c[i])) / 255.0);
    return out;
}

fn srgbToLinear(v: f64) f64 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(v: f64) f64 {
    const c = std.math.clamp(v, 0.0, 1.0);
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f64, c, 1.0 / 2.4) - 0.055;
}

fn quant(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v * 255.0), 0.0, 255.0));
}

fn toColor(l: [3]f64) [4]f32 {
    var out: [4]f32 = .{ 0, 0, 0, 1.0 };
    for (0..3) |i| {
        const v8 = std.math.clamp(@round(linearToSrgb(l[i]) * 255.0), 0.0, 255.0);
        out[i] = @as(f32, @floatCast(v8)) / 255.0;
    }
    return out;
}

// --- tests (순수 로직 — `zig test src/chrome_palette.zig` 로 단독 검증) ---

/// theme 배경 목록 — `themes.zig` 와 같은 값. 파생 입력이 config 로 고르는 이 18종
/// 으로 한정되므로 경계 검증도 이 집합에서 한다.
const test_themes = [_]struct { name: []const u8, bg: [3]u8, dark: bool }{
    .{ .name = "Tilda", .bg = .{ 0x00, 0x00, 0x00 }, .dark = true },
    .{ .name = "Ghostty", .bg = .{ 0x1d, 0x1f, 0x21 }, .dark = true },
    .{ .name = "Windows Terminal", .bg = .{ 0x0c, 0x0c, 0x0c }, .dark = true },
    .{ .name = "Catppuccin Mocha", .bg = .{ 0x1e, 0x1e, 0x2e }, .dark = true },
    .{ .name = "Dracula", .bg = .{ 0x28, 0x2a, 0x36 }, .dark = true },
    .{ .name = "Gruvbox Dark", .bg = .{ 0x28, 0x28, 0x28 }, .dark = true },
    .{ .name = "Tokyo Night", .bg = .{ 0x1a, 0x1b, 0x26 }, .dark = true },
    .{ .name = "Nord", .bg = .{ 0x2e, 0x34, 0x40 }, .dark = true },
    .{ .name = "One Half Dark", .bg = .{ 0x28, 0x2c, 0x34 }, .dark = true },
    .{ .name = "Solarized Dark", .bg = .{ 0x00, 0x1e, 0x27 }, .dark = true },
    .{ .name = "Monokai Soda", .bg = .{ 0x1a, 0x1a, 0x1a }, .dark = true },
    .{ .name = "Rose Pine", .bg = .{ 0x19, 0x17, 0x24 }, .dark = true },
    .{ .name = "Kanagawa", .bg = .{ 0x1f, 0x1f, 0x28 }, .dark = true },
    .{ .name = "Everforest Dark", .bg = .{ 0x1e, 0x23, 0x26 }, .dark = true },
    .{ .name = "Catppuccin Latte", .bg = .{ 0xef, 0xf1, 0xf5 }, .dark = false },
    .{ .name = "Solarized Light", .bg = .{ 0xfd, 0xf6, 0xe3 }, .dark = false },
    .{ .name = "Gruvbox Light", .bg = .{ 0xfb, 0xf1, 0xc7 }, .dark = false },
    .{ .name = "One Half Light", .bg = .{ 0xfa, 0xfa, 0xfa }, .dark = false },
};

fn contrast(a: [4]f32, b: [4]f32) f64 {
    const la = luminance(linearOf(.{ quant(a[0]), quant(a[1]), quant(a[2]) }));
    const lb = luminance(linearOf(.{ quant(b[0]), quant(b[1]), quant(b[2]) }));
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

test "Tilda 검정에서 anchor 를 정확히 재현 — 현행 상수와 픽셀 동일" {
    const p = derive(.{ 0, 0, 0 }, true);
    const cases = [_]struct { got: [4]f32, want: [4]f32 }{
        .{ .got = p.tab_bar_bg, .want = ui_metrics.TAB_BAR_BG },
        .{ .got = p.separator, .want = ui_metrics.TAB_SEPARATOR_COLOR },
        .{ .got = p.tab_text, .want = ui_metrics.TAB_TEXT_COLOR },
        .{ .got = p.ctrl_active, .want = ui_metrics.TAB_CTRL_ACTIVE_COLOR },
        .{ .got = p.arrow_disabled, .want = ui_metrics.TAB_ARROW_DISABLED_COLOR },
        .{ .got = p.ctrl_hover_bg, .want = ui_metrics.TAB_CTRL_HOVER_BG },
        .{ .got = p.menu_hover_bg, .want = ui_metrics.MENU_HOVER_BG },
        .{ .got = p.menu_label, .want = ui_metrics.MENU_LABEL_COLOR },
        .{ .got = p.menu_hint, .want = ui_metrics.MENU_HINT_COLOR },
    };
    for (cases) |c| {
        for (0..3) |i| try std.testing.expectEqual(quant(c.want[i]), quant(c.got[i]));
        try std.testing.expectEqual(@as(f32, 1.0), c.got[3]);
    }
}

test "캡 없는 7개 요소는 18개 theme 전부에서 대비비가 보존된다" {
    const ref = derive(.{ 0, 0, 0 }, true);
    const bar_cr = contrast(ref.tab_bar_bg, .{ 0, 0, 0, 1 });
    const sep_cr = contrast(ref.separator, ref.tab_bar_bg);
    const text_cr = contrast(ref.tab_text, ref.tab_bar_bg);
    const hint_cr = contrast(ref.menu_hint, ref.tab_bar_bg);
    const dis_cr = contrast(ref.arrow_disabled, ref.tab_bar_bg);

    for (test_themes) |t| {
        const p = derive(t.bg, t.dark);
        const bg: [4]f32 = .{
            @as(f32, @floatFromInt(t.bg[0])) / 255.0,
            @as(f32, @floatFromInt(t.bg[1])) / 255.0,
            @as(f32, @floatFromInt(t.bg[2])) / 255.0,
            1.0,
        };
        // 8-bit 양자화 오차만 허용 (Tilda 기준값에서 ±0.05 이내).
        try std.testing.expectApproxEqAbs(bar_cr, contrast(p.tab_bar_bg, bg), 0.05);
        try std.testing.expectApproxEqAbs(sep_cr, contrast(p.separator, p.tab_bar_bg), 0.05);
        try std.testing.expectApproxEqAbs(text_cr, contrast(p.tab_text, p.tab_bar_bg), 0.1);
        try std.testing.expectApproxEqAbs(hint_cr, contrast(p.menu_hint, p.tab_bar_bg), 0.1);
        try std.testing.expectApproxEqAbs(dis_cr, contrast(p.arrow_disabled, p.tab_bar_bg), 0.05);
    }
}

test "밝은 theme 은 chrome 이 배경보다 어둡고 그 위 요소는 더 어둡다" {
    for (test_themes) |t| {
        if (t.dark) continue;
        const p = derive(t.bg, t.dark);
        const bg_lum = luminance(linearOf(t.bg));
        const bar_lum = luminance(linearOf(.{ quant(p.tab_bar_bg[0]), quant(p.tab_bar_bg[1]), quant(p.tab_bar_bg[2]) }));
        const sep_lum = luminance(linearOf(.{ quant(p.separator[0]), quant(p.separator[1]), quant(p.separator[2]) }));
        const text_lum = luminance(linearOf(.{ quant(p.tab_text[0]), quant(p.tab_text[1]), quant(p.tab_text[2]) }));
        try std.testing.expect(bar_lum < bg_lum);
        try std.testing.expect(sep_lum < bar_lum);
        try std.testing.expect(text_lum < sep_lum);
    }
}

test "어두운 theme 은 chrome 이 배경보다 밝고 그 위 요소는 더 밝다" {
    for (test_themes) |t| {
        if (!t.dark) continue;
        const p = derive(t.bg, t.dark);
        const bg_lum = luminance(linearOf(t.bg));
        const bar_lum = luminance(linearOf(.{ quant(p.tab_bar_bg[0]), quant(p.tab_bar_bg[1]), quant(p.tab_bar_bg[2]) }));
        const sep_lum = luminance(linearOf(.{ quant(p.separator[0]), quant(p.separator[1]), quant(p.separator[2]) }));
        try std.testing.expect(bar_lum > bg_lum);
        try std.testing.expect(sep_lum > bar_lum);
    }
}

test "light 식은 dark 식의 역함수" {
    const a = anchor(ui_metrics.TAB_BAR_BG);
    const bg = linearOf(.{ 0x2e, 0x34, 0x40 });
    const lifted = target(bg, a, true);
    const back = target(lifted, a, false);
    for (0..3) |i| try std.testing.expectApproxEqAbs(bg[i], back[i], 1e-12);
}

test "헤드룸 캡 — 가장 밝은 채널이 정확히 255 에 닿고 요소는 chrome 보다 밝다" {
    // Nord 는 ctrl_active / menu_label 이 캡에 걸리는 최악 theme.
    const p = derive(.{ 0x2e, 0x34, 0x40 }, true);
    var max_ch: u8 = 0;
    for (0..3) |i| max_ch = @max(max_ch, quant(p.ctrl_active[i]));
    try std.testing.expectEqual(@as(u8, 255), max_ch);
    // 캡이 걸려도 아이콘은 chrome 에서 가장 밝게 남는다 (#335 — 최악 7.75).
    try std.testing.expect(contrast(p.ctrl_active, p.tab_bar_bg) > 7.0);
    try std.testing.expect(contrast(p.menu_label, p.tab_bar_bg) > 7.0);
}

test "출력은 8-bit 격자 위에 놓인다 — 세 platform 이 같은 값을 받는다" {
    for (test_themes) |t| {
        const p = derive(t.bg, t.dark);
        const all = [_][4]f32{
            p.tab_bar_bg,    p.separator,     p.tab_text,   p.ctrl_active, p.arrow_disabled,
            p.ctrl_hover_bg, p.menu_hover_bg, p.menu_label, p.menu_hint,
        };
        for (all) |c| {
            for (0..3) |i| {
                const v8: f32 = @floatFromInt(quant(c[i]));
                try std.testing.expectEqual(v8 / 255.0, c[i]);
            }
        }
    }
}
