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
/// About 본문이 긴 절대경로 하나 때문에 화면 전체 폭으로 늘어나지 않게 하는
/// logical 최대 폭. 일반 본문은 content-driven 자연 폭을 그대로 사용한다.
pub const DIALOG_ABOUT_MAX_WIDTH_PT: u32 = 960;
pub const DIALOG_SCROLLBAR_GAP_PT: u32 = 8;
pub const TAB_WIDTH_PT: u32 = 150;
pub const TAB_PADDING_PT: u32 = 6;
/// 인접 탭 사이와 탭바 상하에 보이는 윤곽선의 logical gap.
/// 각 탭은 좌우에 절반(1pt), 상하에 전체(2pt)를 inset으로 사용한다.
/// 컨트롤 hover 박스도 네 방향에 전체(2pt)를 사용한다.
pub const TAB_GAP_PT: u32 = 2;

pub const TabGapPx = struct {
    tab_horizontal_inset: f32,
    tab_vertical_inset: f32,
    control_hover_inset: f32,
};

/// logical gap을 현재 화면 scale에 맞는 physical pixel inset으로 변환한다.
pub fn tabGapPx(scale: f32) TabGapPx {
    const gap_px = @as(f32, @floatFromInt(TAB_GAP_PT)) * scale;
    return .{
        .tab_horizontal_inset = gap_px / 2.0,
        .tab_vertical_inset = gap_px,
        .control_hover_inset = gap_px,
    };
}

/// 활성 탭 배경 (50/255 ≈ 0.196). Windows `TAB_ACTIVE_R` 와 동일.
pub const TAB_ACTIVE_BG: [4]f32 = .{ 50.0 / 255.0, 50.0 / 255.0, 50.0 / 255.0, 1.0 };
/// 탭바 배경 (탭 사이 + 외곽). 20/255 ≈ 0.078. Windows `TAB_BAR_R` 와 동일.
/// 비활성 탭과 활성 탭 *주변* 의 어두운 영역 — 탭의 윤곽선 역할.
pub const TAB_BAR_BG: [4]f32 = .{ 20.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0, 1.0 };
/// 탭 텍스트 색 (180/255 ≈ 0.706). Windows `TAB_TEXT_R` 와 동일.
pub const TAB_TEXT_COLOR: [4]f32 = .{ 180.0 / 255.0, 180.0 / 255.0, 180.0 / 255.0, 1.0 };

// 비활성 탭 배경은 상수가 아니라 *renderer 의 default_bg (terminal 배경)* 를
// 사용해요. cell grid 와 같은 색이라 비활성 탭이 cell 영역과 자연스럽게
// 이어지고 활성 탭만 두드러지는 효과 — Windows 패턴.
// 탭 placement 는 좌우 1pt + 상하 2pt gap 을 두고 sandwich. 현재 화면 scale을
// 곱한 physical pixel inset으로 변환하며, 그 gap으로 TAB_BAR_BG가 보여 탭의
// 명확한 윤곽선 역할을 한다.

// 탭바 컨트롤 버튼 (#117 — Firefox 패턴). width < height 로 살짝 세로 길쭉
// (탭바 height 28 vs width 24) — 가로 넓적하지 않은 chevron 느낌.
/// `<` / `>` 좌우 스크롤 화살표. 탭 viewport 가 탭으로 가득 차야 양 끝에 등장.
/// 한 번 클릭에 1 탭 너비씩 viewport 이동.
pub const TAB_ARROW_W_PT: u32 = 24;
/// `+` 새 탭 버튼. layout `[<][tabs][>][×][+]` — 우측 끝 고정 클러스터의
/// 최우측 구석 (#268 — 구석의 × 는 창 닫기로 읽혀서 + 가 구석).
/// MAX_TABS 도달 시 사라짐.
pub const TAB_PLUS_W_PT: u32 = 24;
/// `×` 활성 탭 닫기 버튼 — 우측 끝 고정 클러스터의 `+` 왼쪽 자리 (#268).
/// per-tab close 를 대체: 탭 전환 클릭과 물리적으로 분리해 misclick 방지.
pub const TAB_CLOSE_W_PT: u32 = 24;
/// 활성 화살표 / `+` 색 — 탭 텍스트보다 더 밝게 (강조).
pub const TAB_CTRL_ACTIVE_COLOR: [4]f32 = .{ 0.95, 0.95, 0.95, 1.0 };
/// 탭바 컨트롤 버튼 hover 배경 (#268 2b — VSCode 패턴의 은은한 밝은 박스).
/// 흰색 12% 알파 — 어두운 탭바 배경 위에서만 살짝 떠 보임.
pub const TAB_CTRL_HOVER_BG: [4]f32 = .{ 1.0, 1.0, 1.0, 0.12 };
/// 비활성 화살표 (더 갈 곳 없음) 의 색 — 활성과 명확히 구분되도록 어둡지만
/// 너무 어둡지 않게. Firefox 의 disabled chevron 과 동등 시각.
pub const TAB_ARROW_DISABLED_COLOR: [4]f32 = .{ 0.4, 0.4, 0.4, 1.0 };

// 탭바 컨트롤 아이콘 (`< > × +`) 절차적 그리기 (#199 / #268) — 폰트 독립.
// `src/tab_icons.zig` 가 선분 geometry 를 알파 커버리지 비트맵으로 rasterize,
// 세 renderer 가 같은 비트맵을 glyph 처럼 그림 (세 platform 픽셀 동일).
/// 아이콘 한 변 (bounding square). 버튼 box (24pt) 안에 여백 두고 들어가는 크기.
pub const TAB_ICON_SIZE_PT: u32 = 10;
/// 아이콘 선 두께 (pt). `pt × scale` 로 px 두께. AA 로 fractional scale 도 또렷.
pub const TAB_ICON_STROKE_PT: f32 = 1.5;

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
        try std.testing.expectApproxEqAbs(case.vertical, gap.tab_vertical_inset, 0.0001);
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

test "tab bar height uses common rounded physical pixels" {
    try std.testing.expectEqual(@as(u32, 28), tabBarHeightPx(1.0));
    try std.testing.expectEqual(@as(u32, 42), tabBarHeightPx(1.5));
    try std.testing.expectEqual(@as(u32, 48), tabBarHeightPx(1.7));
    try std.testing.expectEqual(@as(u32, 56), tabBarHeightPx(2.0));
}
