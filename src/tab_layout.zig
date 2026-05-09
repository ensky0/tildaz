//! 탭바 layout / hit-test 계산 — cross-platform pure functions. macOS host 와
//! Windows app_controller 양쪽이 같은 모듈 호출 (#159 Phase 1, #117 Firefox 패턴).
//!
//! 계산 input 은 viewport / tab count / DPI 적용된 cell 상수 (`Inputs`). state
//! (scroll_x, active_index 등) 도 인자로 받고 결과 (`Layout`, 새 scroll_x, hit
//! 결과) 반환 — **side effect 없음**. 호출처가 자기 글로벌 / member 갱신.
//!
//! Type 단위 — 모두 f32 (DPI 적용된 픽셀). Windows host (c_int 기반) 가 호출
//! 시 cast.

const std = @import("std");
const display_width = @import("font/display_width.zig");

pub const Layout = struct {
    tab_area_x: f32,
    tab_area_w: f32,
    arrows_visible: bool,
    arrow_w: f32,
    plus_w: f32,
    plus_x: f32,
    left_arrow_x: f32 = 0,
    right_arrow_x: f32 = 0,
    left_enabled: bool = false,
    right_enabled: bool = false,
};

pub const Inputs = struct {
    viewport_w: f32,
    tab_count: u32,
    tab_w: f32,
    arrow_w: f32,
    plus_w: f32,
    scroll_x: f32,
};

/// 탭바 layout 계산 — viewport / tab count / scroll 기반 영역 분할.
/// `[<][tabs][+][>]` (arrows_visible) 또는 `[tabs][+]` (no arrows). gap 없음 —
/// 사용자 의도 (`<`/`>`/`+` 와 tab 이 인접).
pub fn compute(inputs: Inputs) Layout {
    const total = inputs.tab_w * @as(f32, @floatFromInt(inputs.tab_count));
    const arrows_visible = total + inputs.plus_w > inputs.viewport_w;
    if (!arrows_visible) {
        return .{
            .tab_area_x = 0,
            .tab_area_w = @max(0, inputs.viewport_w - inputs.plus_w),
            .arrows_visible = false,
            .arrow_w = inputs.arrow_w,
            .plus_w = inputs.plus_w,
            .plus_x = total, // 마지막 탭 끝 = plus 시작 (gap 없음)
        };
    }
    const tab_area_x = inputs.arrow_w;
    const tab_area_w = @max(0, inputs.viewport_w - inputs.arrow_w * 2 - inputs.plus_w);
    const right_arrow_x = inputs.viewport_w - inputs.arrow_w;
    const plus_x = right_arrow_x - inputs.plus_w;
    const left_enabled = inputs.scroll_x > 0;
    const right_enabled = inputs.scroll_x + tab_area_w < total;
    return .{
        .tab_area_x = tab_area_x,
        .tab_area_w = tab_area_w,
        .arrows_visible = true,
        .arrow_w = inputs.arrow_w,
        .plus_w = inputs.plus_w,
        .plus_x = plus_x,
        .left_arrow_x = 0,
        .right_arrow_x = right_arrow_x,
        .left_enabled = left_enabled,
        .right_enabled = right_enabled,
    };
}

/// 활성 탭이 viewport 안에 보이도록 새 scroll_x 반환 (#117 정책 b: 보이면 그대로,
/// 안 보이면 minimum 이동). 호출처가 자기 state 에 저장. drag / 사용자 화살표
/// override 중에는 호출 안 함.
pub fn ensureActiveVisible(inputs: Inputs, layout: Layout, active_index: u32) f32 {
    const total = inputs.tab_w * @as(f32, @floatFromInt(inputs.tab_count));
    const vp = layout.tab_area_w;
    if (vp <= 0 or total <= vp) return 0;

    const active_f = @as(f32, @floatFromInt(active_index));
    const tab_l = active_f * inputs.tab_w;
    const tab_r = tab_l + inputs.tab_w;
    var sx = inputs.scroll_x;
    if (tab_l < sx) {
        sx = tab_l;
    } else if (tab_r > sx + vp) {
        sx = tab_r - vp;
    }
    const max_sx = total - vp;
    if (sx < 0) sx = 0;
    if (sx > max_sx) sx = max_sx;
    return sx;
}

pub const ArrowDir = enum { left, right };

/// `<` / `>` 화살표 클릭 시 새 scroll_x. 변화 없으면 null. 호출처가 결과 받아
/// 자기 글로벌 갱신 + user_override 활성화.
///
/// 방향-aware tab 경계 align — 누른 쪽 끝 탭이 안 잘리게:
///   - `<`: 좌측 viewport 가 가까운 tab 좌측 경계로. 잘려있던 좌측 끝 탭의
///     시작으로, 정확히 경계면 한 탭 좌측으로.
///   - `>`: 우측 viewport 가 가까운 tab 우측 경계로. 잘려있던 우측 끝 탭의
///     끝으로, 정확히 경계면 한 탭 우측으로.
///
/// 알고리즘 (epsilon 없는 exact math — 부동소수점 오차 영향 최소):
///   - `<`: target_tab = ceil(sx / tw) - 1. sx = target * tw.
///   - `>`: target_tab = floor((sx + vp) / tw) + 1. sx = target * tw - vp.
///
/// 정확 경계 (sx = N×tw): ceil(N) - 1 = N - 1 → 한 탭 좌측. 부분 잘림 (sx =
/// N.5×tw): ceil(N.5) - 1 = N → 잘린 탭의 시작. 우측 대칭. 0 / max_sx 끝
/// 도달 시 변화 없으면 null.
pub fn scrollByArrow(inputs: Inputs, layout: Layout, dir: ArrowDir) ?f32 {
    const total = inputs.tab_w * @as(f32, @floatFromInt(inputs.tab_count));
    const vp = layout.tab_area_w;
    if (vp <= 0 or total <= vp) return null;
    const max_sx = total - vp;
    var sx = inputs.scroll_x;
    switch (dir) {
        .left => {
            const target_tab = @ceil(sx / inputs.tab_w) - 1;
            sx = @max(0, target_tab * inputs.tab_w);
        },
        .right => {
            const right_edge = sx + vp;
            const target_tab = @floor(right_edge / inputs.tab_w) + 1;
            sx = @min(max_sx, target_tab * inputs.tab_w - vp);
        },
    }
    if (sx == inputs.scroll_x) return null;
    return sx;
}

pub const Area = enum { left_arrow, right_arrow, plus, tab_area, none };

/// 픽셀 좌표 (px, py) 가 탭바의 어느 영역에 있는지. py 가 [0, tab_bar_h) 밖 또는
/// px 가 음수면 .none. arrows_visible=false 면 좌/우 화살표 검사 skip.
pub fn hitArea(px: f32, py: f32, tab_bar_h: f32, layout: Layout) Area {
    if (px < 0 or py < 0 or py >= tab_bar_h) return .none;
    if (layout.arrows_visible) {
        if (px >= layout.left_arrow_x and px < layout.left_arrow_x + layout.arrow_w)
            return .left_arrow;
        if (px >= layout.right_arrow_x and px < layout.right_arrow_x + layout.arrow_w)
            return .right_arrow;
    }
    if (px >= layout.plus_x and px < layout.plus_x + layout.plus_w) return .plus;
    if (px >= layout.tab_area_x and px < layout.tab_area_x + layout.tab_area_w) return .tab_area;
    return .none;
}

/// rename text 영역 안 마우스 위치 → text 안 byte index. cursor follow scroll
/// 결과 좌측 잘림 영역도 처리. mouse_x 가 viewport 밖이면 null. native textbox
/// UX — caller 가 RenameState.setCursor 호출 후 commit 안 함 (#164 follow-up).
///
/// 인자:
///   - title: 현재 rename buffer text
///   - cursor_byte: 현재 cursor 위치 (scroll_offset 계산용)
///   - preedit_advance_total: preedit codepoint 들의 advance 합 (scroll reserve)
///   - text_x_start: 탭 내 text 시작 x — 화면 좌표 (`tab_x + tab_pad`)
///   - cw: cell width
///   - max_text_w: text 영역 너비 (`tab_w - close_w - 3*pad` 등 host 별 동등)
///   - mouse_x: 마우스 x (탭바 좌표)
///
/// 반환: byte index (mouse 가 codepoint 의 우반에 있으면 그 codepoint 끝, 좌반
/// 이면 시작). title 끝 이후면 title.len. mouse_x 가 영역 밖이면 null.
pub fn renameTextHit(
    title: []const u8,
    cursor_byte: usize,
    preedit_advance_total: f32,
    text_x_start: f32,
    cw: f32,
    max_text_w: f32,
    mouse_x: f32,
) ?usize {
    if (mouse_x < text_x_start or mouse_x >= text_x_start + max_text_w) return null;

    // scroll_offset 계산 — renderer 의 cursor follow scroll 과 동등.
    var probe_x: f32 = 0;
    var probe_iter = std.unicode.Utf8Iterator{ .bytes = title, .i = 0 };
    var probe_byte: usize = 0;
    while (probe_iter.nextCodepoint()) |pcp| {
        if (probe_byte >= cursor_byte) break;
        const pcw = display_width.codepointWidth(@intCast(pcp));
        probe_x += cw * @as(f32, @floatFromInt(pcw));
        const plen = std.unicode.utf8CodepointSequenceLength(pcp) catch 1;
        probe_byte += plen;
    }
    var scroll_offset: f32 = 0;
    if (probe_x > max_text_w - preedit_advance_total) {
        scroll_offset = probe_x - max_text_w + preedit_advance_total;
    }

    // mouse_x → text 안 byte 매핑.
    const target_x = mouse_x - text_x_start;
    var x_off: f32 = -scroll_offset;
    var byte_idx: usize = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = title, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const cp_w_cells = display_width.codepointWidth(@intCast(cp));
        const advance = cw * @as(f32, @floatFromInt(cp_w_cells));
        const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        if (target_x >= x_off and target_x < x_off + advance) {
            // mouse 가 codepoint 우반 → 그 codepoint 끝, 좌반 → 시작.
            if (target_x - x_off < advance / 2) return byte_idx;
            return byte_idx + cp_len;
        }
        byte_idx += cp_len;
        x_off += advance;
    }
    return byte_idx; // mouse_x 가 text 끝 이후 → title.len
}

pub const TabHit = struct { tab_index: usize, on_close: bool };

/// tab_area 안에서 px → 탭 인덱스 + close 버튼 hit. 호출자가 먼저 hitArea 가
/// .tab_area 인지 검사 후 호출. tab_area 좌표계: world_x = (px - tab_area_x) +
/// scroll_x.
pub fn hitTab(
    px: f32,
    py: f32,
    layout: Layout,
    tab_w: f32,
    tab_pad: f32,
    close_size: f32,
    tab_bar_h: f32,
    scroll_x: f32,
    tab_count: u32,
) ?TabHit {
    const local_x = px - layout.tab_area_x;
    const world_x = local_x + scroll_x;
    if (world_x < 0) return null;
    const tab_index = @as(usize, @intFromFloat(world_x / tab_w));
    if (tab_index >= tab_count) return null;

    const tab_x = @as(f32, @floatFromInt(tab_index)) * tab_w;
    const close_x_min = tab_x + tab_w - close_size - tab_pad;
    const close_x_max = close_x_min + close_size;
    const close_y_min = (tab_bar_h - close_size) * 0.5;
    const close_y_max = close_y_min + close_size;
    const on_close = (world_x >= close_x_min and world_x <= close_x_max and
        py >= close_y_min and py <= close_y_max);

    return .{ .tab_index = tab_index, .on_close = on_close };
}
