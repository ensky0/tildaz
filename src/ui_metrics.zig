//! 크로스 플랫폼 UI 디자인 상수. logical points 단위 — 사용처에서 DPI /
//! Retina scale 을 곱해 pixel 단위로 변환. Linux · macOS · Windows 가 동일
//! 값을 사용해 세 플랫폼 시각적 일관성 유지.

const std = @import("std");
const font_spec = @import("font/spec.zig");

/// 터미널 영역 안쪽 padding. 글자가 윈도우 모서리에 딱 붙지 않게.
pub const TERMINAL_PADDING_PT: u32 = 6;

/// 우측 scrollbar 너비.
pub const SCROLLBAR_W_PT: u32 = 10;

/// 터미널 커서 — 셀 좌측 세로 막대(bar)의 폭. #297 UX 결정 (2026-07-12):
/// 세 platform 모두 bar 커서로 통일 (이전: Windows/macOS full-cell block
/// alpha 0.7, Linux 하단 2px underline — 제각각).
pub const CURSOR_BAR_W_PT: f32 = 2.0;

/// bar 커서 폭의 physical px 변환 — 최소 1px 보장 (scale < 0.5 에서도 소멸 방지).
pub fn cursorBarWidthPx(scale: f32) f32 {
    return @max(1.0, @round(CURSOR_BAR_W_PT * scale));
}

/// scrollbar thumb 의 최소 높이 — scrollback 이 길어 ratio 가 매우 작아도
/// thumb 가 클릭 가능한 크기 유지.
pub const SCROLLBAR_MIN_THUMB_H_PT: u32 = 32;

/// scrollbar thumb 색상 — 흰색 알파 30%, 어떤 배경 위에서도 살짝 보임.
pub const SCROLLBAR_COLOR: [4]f32 = .{ 1, 1, 1, 0.3 };

// 탭바 — Windows `d3d11_renderer.zig` 의 TAB_* 상수와 같은 디자인 (시각 일관성).
pub const TAB_BAR_HEIGHT_PT: u32 = 28;
/// 터미널 콘텐츠 font와 독립된 탭 제목 logical size. 같은 font family/fallback을
/// 사용하되 terminal의 `font.size_point` 변경에는 영향받지 않는다.
pub const TAB_LABEL_FONT_PT: u32 = 13;
/// Linux custom dialog typography (#306). Family/fallback stays aligned with
/// the terminal, while size remains independent from terminal font settings.
pub const DIALOG_BODY_FONT_PT: u32 = 15;
pub const DIALOG_TITLE_FONT_PT: u32 = 18;
/// Dialog action controls use logical points. Native backends convert this
/// through their current screen scale (AppKit does so automatically).
pub const DIALOG_ACTION_BUTTON_HEIGHT_PT: u32 = 48;
/// 안내·오류·확인·prompt·About에 공통으로 표시하는 TildaZ 앱 아이콘.
/// Linux와 Windows는 이 logical 크기에 현재 scale/DPI를 곱하고, macOS는
/// NSAlert가 bundle icon을 native 크기로 배치한다.
pub const DIALOG_ICON_SIZE_PT: u32 = 64;
pub const DIALOG_ICON_GAP_PT: u32 = 8;

/// `docs/style.css --brand-orange` / `docs/favicon.svg`와 같은 dialog accent.
/// platform backend는 이 RGB를 native color 형식으로 변환해 사용한다.
pub const DIALOG_SEPARATOR_COLOR = .{ .r = 0xF7, .g = 0xA4, .b = 0x1D };
pub const DIALOG_SEPARATOR_THICKNESS_PT: u32 = 2;
/// Dialog는 preferred 폭 안에서 먼저 실제 wrap 높이를 측정한다. 고정 chrome을
/// 포함해 현재 screen 높이를 넘을 때만 maximum 폭으로 확장한 뒤 다시 측정한다.
pub const DIALOG_PREFERRED_WIDTH_PT: u32 = 580;
/// 긴 절대경로에서도 screen 전체 폭을 차지하지 않게 하는 logical 최대 폭.
pub const DIALOG_MAX_WIDTH_PT: u32 = 960;
pub const DIALOG_SCROLLBAR_GAP_PT: u32 = 8;
pub const TAB_WIDTH_PT: u32 = 150;
pub const TAB_PADDING_PT: u32 = 6;
/// 컨트롤 hover 박스의 네 방향 inset(2pt)과 탭 제목 x offset 의 근원 gap.
/// #334 개편 전에는 탭 배경 사각형의 상하/좌우 inset 으로도 쓰였으나, 탭
/// 배경이 탭바와 통일되며 그 용도는 사라졌다 (`tab_vertical_inset` 제거).
pub const TAB_GAP_PT: u32 = 2;

pub const TabGapPx = struct {
    tab_horizontal_inset: f32,
    control_hover_inset: f32,
};

/// logical gap을 현재 화면 scale에 맞는 physical pixel inset으로 변환한다.
pub fn tabGapPx(scale: f32) TabGapPx {
    const gap_px = @as(f32, @floatFromInt(TAB_GAP_PT)) * scale;
    return .{
        .tab_horizontal_inset = gap_px / 2.0,
        .control_hover_inset = gap_px,
    };
}

// ── chrome 색 anchor (#335) ─────────────────────────────────────────
// 아래 9개 색 상수는 **anchor** 다 — Tilda (순수 검정) 배경에서의 값이고 #334 /
// #342 가 시연으로 확정했다. renderer 는 이 상수를 직접 참조하지 않고
// [`chrome_palette.derive`](chrome_palette.zig) 가 현재 theme 배경으로 옮긴 결과를
// 쓴다. bg = 검정이면 파생 결과가 anchor 와 같으므로 Tilda 는 아래 값 그대로다.
//
// 모두 **8-bit 격자 위의 값**을 `N.0/255.0` 으로 적는다 (파생이 anchor 를 8-bit 로
// 확정해 쓰므로 격자에서 벗어나면 Tilda 재현이 어긋난다). 예전에 `0.25` / `0.92`
// 처럼 소수로 적힌 상수는 Linux 의 truncate 와 GPU 의 round 가 1/255 갈렸는데
// (`MENU_HOVER_BG` 63 vs 64 등), 8-bit 로 적으면서 세 platform 이 같아졌다.
//
// amber accent (`TAB_ACCENT_COLOR`) 는 브랜드 색이라 파생하지 않는다 — 2026-07-28
// 사용자 확정. 밝은 theme 에서 밑줄 대비가 1.35~1.46 으로 낮아지는 것은 알려진 귀결.

/// 탭바 배경 = 모든 탭(활성 포함)의 배경 (#334 2026-07-22 결정 — Tilda 문법).
/// 이전의 "활성 탭만 밝은 회색 + 비활성은 terminal 배경(#282)" 정책을 대체:
/// 탭바 전체가 하나의 회색 띠가 되고, 활성 탭은 amber 밑줄로만 구분한다.
/// 33/35/38 은 사용자가 Tilda(Breeze dark)에서 실측한 값 — 순수 중성 회색
/// (52/52/52)은 상대적으로 따뜻하게(갈색 끼) 보였고, 살짝 파란 끼의 이
/// 회색이 더 예쁘다는 사용자 확정 (2026-07-22).
pub const TAB_BAR_BG: [4]f32 = .{ 33.0 / 255.0, 35.0 / 255.0, 38.0 / 255.0, 1.0 };
/// #334 — 탭 사이 세로 구분선 색 (두께는 `TAB_SEPARATOR_W_PT`). 탭과 탭바가
/// 같은 색이라 경계는 명시적인 선으로. drag 재배열 중 빈 원위치 슬롯도 이
/// 구분선 + 제목 부재로 인지한다. command menu 의 테두리·내부 구분선도 같은
/// 값을 참조한다 (2026-07-22 "메뉴는 탭바와 한 문법" 결정).
///
/// #342 (2026-07-27) — 100/100/106 → 79/79/84. 100 은 탭바 배경이 52/255 이던
/// 튜닝 라운드의 값인데, 그 뒤 배경만 33/35/38 로 내려가고 이 값은 남아 대비가
/// 2.12 → 2.68 로 저절로 올라가 있었다. 79/79/84 는 1.93.
pub const TAB_SEPARATOR_COLOR: [4]f32 = .{ 79.0 / 255.0, 79.0 / 255.0, 84.0 / 255.0, 1.0 };
/// #334 — 활성 탭 하단 accent 밑줄. TildaZ amber (#F7A41D) — dialog 구분선
/// (`DIALOG_SEPARATOR_COLOR`) 과 같은 색으로 "강조 = amber" 문법 통일.
/// 같은 제목 탭이 흔한 터미널에서 배경 밝기 차이만으로는 활성 탭이 곁눈에
/// 안 들어와 accent 밑줄로 보강 (Tilda 의 파란 밑줄과 같은 자리).
pub const TAB_ACCENT_COLOR: [4]f32 = .{ 247.0 / 255.0, 164.0 / 255.0, 29.0 / 255.0, 1.0 };
/// #334 — 활성 탭 amber 밑줄 두께 (logical pt). 활성 탭 슬롯 구간에만 얹힌다.
/// #342 로 가로 경계선이 사라져 탭바 **맨 아래 모서리**에 붙는다 (이전에는
/// 경계선 바로 위). 좌우 끝은 세로 구분선이 덮는다 — 아래 `TAB_SEPARATOR_W_PT`.
pub const TAB_ACTIVE_UNDERLINE_PT: u32 = 2;
/// #342 — 탭 사이 세로 구분선 두께 (logical pt). 색은 `TAB_SEPARATOR_COLOR`.
///
/// #334 의 `TAB_BOTTOM_BORDER_PT` 를 이름만 바꾼 것이다. 원래 탭바-터미널 가로
/// 경계선 두께였고 세로 구분선이 그 값을 빌려 썼는데, 가로 경계선이 제거되며
/// (2026-07-27 사용자 결정) 세로선 전용이 됐다. 이름이 남으면 없는 요소를
/// 가리키게 되므로 함께 정리.
pub const TAB_SEPARATOR_W_PT: u32 = 1;
/// #334 — command menu 스크롤 표시 chevron 의 비트맵 한 변 (logical pt).
/// 탭바 아이콘(10pt)보다 크게 — 메뉴 폭에 어울리는 납작한 꺾쇠.
pub const MENU_INDICATOR_ICON_PT: u32 = 14;
// command menu 색 (#329/#334) — 배경은 `TAB_BAR_BG`, 테두리/구분선은
// `TAB_SEPARATOR_COLOR` 를 그대로 재사용 (탭바와 한 문법, 2026-07-22 사용자
// 확정). 아래 셋은 메뉴 고유 값 — 세 renderer 가 이 상수만 참조한다.
/// 메뉴 항목의 hover / keyboard focus 강조 배경.
pub const MENU_HOVER_BG: [4]f32 = .{ 64.0 / 255.0, 64.0 / 255.0, 71.0 / 255.0, 1.0 };
/// 메뉴 항목 label 텍스트 색.
pub const MENU_LABEL_COLOR: [4]f32 = .{ 235.0 / 255.0, 235.0 / 255.0, 240.0 / 255.0, 1.0 };
/// 메뉴 우측 단축키 hint 색 — label 보다 어둡게 (독립 값).
pub const MENU_HINT_COLOR: [4]f32 = .{ 166.0 / 255.0, 166.0 / 255.0, 173.0 / 255.0, 1.0 };
/// 탭 텍스트 색 (180/255 ≈ 0.706). Windows `TAB_TEXT_R` 와 동일.
pub const TAB_TEXT_COLOR: [4]f32 = .{ 180.0 / 255.0, 180.0 / 255.0, 180.0 / 255.0, 1.0 };

// 탭바 컨트롤 버튼 (#117 — Firefox 패턴). width < height 로 살짝 세로 길쭉
// (탭바 height 28 vs width 24) — 가로 넓적하지 않은 chevron 느낌.
/// `<` / `>` 좌우 스크롤 화살표. 탭 viewport 가 탭으로 가득 차야 양 끝에 등장.
/// 한 번 클릭에 1 탭 너비씩 viewport 이동.
pub const TAB_ARROW_W_PT: u32 = 24;
/// `+` 새 탭 버튼. #329부터 우측 고정 클러스터는 `[+][×][…]` 순서.
/// MAX_TABS 도달 시에도 자리 유지 — 비활성 색 + click noop (2026-07-22 결정).
pub const TAB_PLUS_W_PT: u32 = 24;
/// `×` 활성 탭 닫기 버튼 — 우측 고정 클러스터의 가운데 자리.
/// per-tab close 를 대체: 탭 전환 클릭과 물리적으로 분리해 misclick 방지.
pub const TAB_CLOSE_W_PT: u32 = 24;
/// `…` command/shortcut menu 버튼 — 우측 고정 클러스터의 최우측 자리.
pub const TAB_MORE_W_PT: u32 = 24;
/// 활성 화살표 / `+` 색 — 탭 텍스트보다 더 밝게 (강조).
pub const TAB_CTRL_ACTIVE_COLOR: [4]f32 = .{ 242.0 / 255.0, 242.0 / 255.0, 242.0 / 255.0, 1.0 };
/// 탭바 컨트롤 버튼 hover 배경 (#268 2b — VSCode 패턴의 은은한 밝은 박스).
/// 어두운 탭바 배경 위에서만 살짝 떠 보이는 밝기.
///
/// #335 — 이전엔 `{ 1, 1, 1, 0.12 }` (흰색 12% 알파) 였다. 파생이 anchor 를 색으로
/// 받아야 하므로 **합성 결과 solid** 로 바꿨다. 값은 세 platform 이 실제로 그리던
/// 것과 같다 — 블렌드가 gamma space 에서 일어나기 때문이다 (Windows swapchain
/// `DXGI_FORMAT_B8G8R8A8_UNORM` = `_SRGB` 아님 · macOS layer pixelFormat 80
/// `BGRA8Unorm` · Linux `blendU8` 이 u8 값에서 혼합). linear space 였다면
/// `102/103/105` 였을 것이므로 확인이 필요했다.
///
/// 단 Linux 만 `@intFromFloat` 로 truncate 해 `59.64 → 59` 였다 (R 채널 1 낮음).
/// 이제 세 platform 이 같은 `60` 을 쓴다.
pub const TAB_CTRL_HOVER_BG: [4]f32 = .{ 60.0 / 255.0, 61.0 / 255.0, 64.0 / 255.0, 1.0 };
/// 비활성 화살표 (더 갈 곳 없음) 의 색 — 활성과 명확히 구분되도록 어둡지만
/// 너무 어둡지 않게. Firefox 의 disabled chevron 과 동등 시각.
pub const TAB_ARROW_DISABLED_COLOR: [4]f32 = .{ 102.0 / 255.0, 102.0 / 255.0, 102.0 / 255.0, 1.0 };

// 탭바 컨트롤 아이콘 (`< > + × …`) 절차적 그리기 (#199 / #268 / #329) — 폰트 독립.
// `src/tab_icons.zig` 가 선분 geometry 를 알파 커버리지 비트맵으로 rasterize,
// 세 renderer 가 같은 비트맵을 glyph 처럼 그림 (세 platform 픽셀 동일).
/// 아이콘 한 변 (bounding square). 버튼 box (24pt) 안에 여백 두고 들어가는 크기.
pub const TAB_ICON_SIZE_PT: u32 = 10;
/// 아이콘 선 두께 (pt). `pt × scale` 로 px 두께. AA 로 fractional scale 도 또렷.
pub const TAB_ICON_STROKE_PT: f32 = 1.5;
/// `…`의 점은 같은 1.5pt stroke로 그리면 `+`/`×`보다 가늘어 보이므로
/// diameter만 별도로 광학 보정한다.
pub const TAB_MORE_DOT_DIAMETER_PT: f32 = 2.2;

pub fn tabLabelFontSpec() font_spec.Spec {
    return .{
        .size_logical = @floatFromInt(TAB_LABEL_FONT_PT),
        .cell_width_ratio = 1.0,
        .line_height_ratio = 1.0,
    };
}

pub fn dialogBodyFontSpec() font_spec.Spec {
    return .{
        .size_logical = @floatFromInt(DIALOG_BODY_FONT_PT),
        .cell_width_ratio = 1.0,
        .line_height_ratio = 1.1,
    };
}

pub fn dialogTitleFontSpec() font_spec.Spec {
    return .{
        .size_logical = @floatFromInt(DIALOG_TITLE_FONT_PT),
        .cell_width_ratio = 1.0,
        .line_height_ratio = 1.1,
    };
}

pub fn tabBarHeightPx(scale: f32) u32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(TAB_BAR_HEIGHT_PT)) * scale));
}

test "tab gap scales from logical points to physical pixels" {
    const Case = struct {
        scale: f32,
        horizontal: f32,
        vertical: f32,
    };
    const cases = [_]Case{
        .{ .scale = 1.0, .horizontal = 1.0, .vertical = 2.0 },
        .{ .scale = 1.5, .horizontal = 1.5, .vertical = 3.0 },
        .{ .scale = 1.7, .horizontal = 1.7, .vertical = 3.4 },
        .{ .scale = 2.0, .horizontal = 2.0, .vertical = 4.0 },
    };

    for (cases) |case| {
        const gap = tabGapPx(case.scale);
        try std.testing.expectApproxEqAbs(case.horizontal, gap.tab_horizontal_inset, 0.0001);
        try std.testing.expectApproxEqAbs(case.vertical, gap.control_hover_inset, 0.0001);
    }
}

test "tab label font uses a fixed logical size" {
    const spec = tabLabelFontSpec();
    try std.testing.expectEqual(@as(f32, @floatFromInt(TAB_LABEL_FONT_PT)), spec.size_logical);
    try std.testing.expectEqual(@as(f32, 1.0), spec.cell_width_ratio);
    try std.testing.expectEqual(@as(f32, 1.0), spec.line_height_ratio);
}

test "dialog fonts use fixed 15pt body and 18pt title sizes" {
    const body = dialogBodyFontSpec();
    const title = dialogTitleFontSpec();
    try std.testing.expectEqual(@as(f32, 15.0), body.size_logical);
    try std.testing.expectEqual(@as(f32, 18.0), title.size_logical);
    try std.testing.expectEqual(@as(f32, 1.0), body.cell_width_ratio);
    try std.testing.expectEqual(@as(f32, 1.1), body.line_height_ratio);
    try std.testing.expectEqual(@as(f32, 1.0), title.cell_width_ratio);
    try std.testing.expectEqual(@as(f32, 1.1), title.line_height_ratio);
}

test "dialog icon uses common logical size and gap" {
    try std.testing.expectEqual(@as(u32, 48), DIALOG_ACTION_BUTTON_HEIGHT_PT);
    try std.testing.expectEqual(@as(u32, 64), DIALOG_ICON_SIZE_PT);
    try std.testing.expectEqual(@as(u32, 8), DIALOG_ICON_GAP_PT);
    try std.testing.expectEqual(@as(u8, 0xF7), DIALOG_SEPARATOR_COLOR.r);
    try std.testing.expectEqual(@as(u8, 0xA4), DIALOG_SEPARATOR_COLOR.g);
    try std.testing.expectEqual(@as(u8, 0x1D), DIALOG_SEPARATOR_COLOR.b);
    try std.testing.expectEqual(@as(u32, 2), DIALOG_SEPARATOR_THICKNESS_PT);
    try std.testing.expectEqual(@as(u32, 580), DIALOG_PREFERRED_WIDTH_PT);
    try std.testing.expectEqual(@as(u32, 960), DIALOG_MAX_WIDTH_PT);
}

test "tab bar height uses common rounded physical pixels" {
    try std.testing.expectEqual(@as(u32, 28), tabBarHeightPx(1.0));
    try std.testing.expectEqual(@as(u32, 42), tabBarHeightPx(1.5));
    try std.testing.expectEqual(@as(u32, 48), tabBarHeightPx(1.7));
    try std.testing.expectEqual(@as(u32, 56), tabBarHeightPx(2.0));
}

test "#335 chrome 색 anchor 는 8-bit 격자 위에 있다" {
    // `chrome_palette` 가 anchor 를 8-bit 로 확정해 파생하므로, 격자에서 벗어난
    // 값이 섞이면 Tilda 재현이 1/255 어긋난다.
    const anchors = [_][4]f32{
        TAB_BAR_BG,            TAB_SEPARATOR_COLOR,      TAB_TEXT_COLOR,
        TAB_CTRL_ACTIVE_COLOR, TAB_ARROW_DISABLED_COLOR, TAB_CTRL_HOVER_BG,
        MENU_HOVER_BG,         MENU_LABEL_COLOR,         MENU_HINT_COLOR,
    };
    for (anchors) |a| {
        try std.testing.expectEqual(@as(f32, 1.0), a[3]);
        for (a[0..3]) |c| {
            const scaled = c * 255.0;
            try std.testing.expectApproxEqAbs(@round(scaled), scaled, 1e-3);
        }
    }
}

test "#329 three-button cluster uses single common metrics" {
    try std.testing.expectEqual(@as(u32, 24), TAB_PLUS_W_PT);
    try std.testing.expectEqual(@as(u32, 24), TAB_CLOSE_W_PT);
    try std.testing.expectEqual(@as(u32, 24), TAB_MORE_W_PT);
    try std.testing.expectEqual(@as(u32, 72), TAB_PLUS_W_PT + TAB_CLOSE_W_PT + TAB_MORE_W_PT);
}
