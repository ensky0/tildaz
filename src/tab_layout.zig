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
    /// #329 — MAX_TABS 도달 시에도 `+` 는 자리를 유지하고 비활성(색 / hover
    /// 없음 / click noop)이 된다. arrow 의 left_enabled/right_enabled 와 같은
    /// 패턴. 한도 판단은 host 가 Inputs.plus_enabled 로 전달한다.
    plus_enabled: bool = true,
    close_w: f32,
    close_x: f32,
    more_w: f32,
    more_x: f32,
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
    /// tab_count < MAX_TABS. host 가 채운다 — tab_layout 은 한도 상수를 모른다.
    plus_enabled: bool = true,
    close_w: f32,
    more_w: f32,
    scroll_x: f32,
};

/// 탭바 layout 계산 — viewport / tab count / scroll 기반 영역 분할.
/// `[<][tabs][>][+][×][…]` (arrows_visible) 또는 `[tabs][+][×][…]`
/// (no arrows).
///
/// #268/#329 — `+` (새 탭) / `×` (활성 탭 닫기) / `…` (메뉴)는 탭을
/// 따라다니지 않고 **우측 끝
/// 고정 클러스터**. 클러스터가 탭 본체와 분리돼 per-tab X misclick 사고 방지
/// + 위치 고정으로 근육 기억. per-tab close 는 제거됨 (#199 대체).
pub fn compute(inputs: Inputs) Layout {
    const total = inputs.tab_w * @as(f32, @floatFromInt(inputs.tab_count));
    const controls = computeControls(inputs.viewport_w, inputs.plus_w, inputs.close_w, inputs.more_w);
    const cluster_w = inputs.plus_w + inputs.close_w + inputs.more_w;
    const arrows_visible = total > inputs.viewport_w - cluster_w;
    if (!arrows_visible) {
        return .{
            .tab_area_x = 0,
            .tab_area_w = @max(0, inputs.viewport_w - cluster_w),
            .arrows_visible = false,
            .arrow_w = inputs.arrow_w,
            .plus_w = controls.plus_w,
            .plus_x = controls.plus_x,
            .plus_enabled = inputs.plus_enabled,
            .close_w = controls.close_w,
            .close_x = controls.close_x,
            .more_w = controls.more_w,
            .more_x = controls.more_x,
        };
    }
    const tab_area_x = inputs.arrow_w;
    const tab_area_w = @max(0, inputs.viewport_w - inputs.arrow_w * 2 - cluster_w);
    const right_arrow_x = @max(0, controls.plus_x - inputs.arrow_w);
    const left_enabled = inputs.scroll_x > 0;
    const right_enabled = inputs.scroll_x + tab_area_w < total;
    return .{
        .tab_area_x = tab_area_x,
        .tab_area_w = tab_area_w,
        .arrows_visible = true,
        .arrow_w = inputs.arrow_w,
        .plus_w = controls.plus_w,
        .plus_x = controls.plus_x,
        .plus_enabled = inputs.plus_enabled,
        .close_w = controls.close_w,
        .close_x = controls.close_x,
        .more_w = controls.more_w,
        .more_x = controls.more_x,
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

pub const Area = enum { left_arrow, right_arrow, plus, close, more, tab_area, none };

/// 탭 영역을 포함하지 않는 우측 control cluster geometry. 단일 탭 overlay는
/// 이것만 사용해 숨은 상단 activation zone이 terminal click을 가로채지 않게 한다.
pub const ControlLayout = struct {
    plus_w: f32,
    plus_x: f32,
    close_w: f32,
    close_x: f32,
    more_w: f32,
    more_x: f32,
};

/// `[+][×][…]`를 viewport 우측에 고정한다. 아주 좁은 viewport에서도 음수
/// 좌표를 만들지 않고 왼쪽 0부터 clip되게 한다.
pub fn computeControls(viewport_w: f32, plus_w: f32, close_w: f32, more_w: f32) ControlLayout {
    const cluster_w = plus_w + close_w + more_w;
    const cluster_x = @max(0, viewport_w - cluster_w);
    return .{
        .plus_w = plus_w,
        .plus_x = cluster_x,
        .close_w = close_w,
        .close_x = cluster_x + plus_w,
        .more_w = more_w,
        .more_x = cluster_x + plus_w + close_w,
    };
}

pub fn hitControls(px: f32, py: f32, control_h: f32, layout: ControlLayout) Area {
    if (px < 0 or py < 0 or py >= control_h) return .none;
    if (px >= layout.more_x and px < layout.more_x + layout.more_w) return .more;
    if (px >= layout.close_x and px < layout.close_x + layout.close_w) return .close;
    if (px >= layout.plus_x and px < layout.plus_x + layout.plus_w) return .plus;
    return .none;
}

/// 픽셀 좌표 (px, py) 가 탭바의 어느 영역에 있는지. py 가 [0, tab_bar_h) 밖 또는
/// px 가 음수면 .none. arrows_visible=false 면 좌/우 화살표 검사 skip.
/// `.close` = 우측 끝 활성 탭 닫기 버튼 (#268).
pub fn hitArea(px: f32, py: f32, tab_bar_h: f32, layout: Layout) Area {
    if (px < 0 or py < 0 or py >= tab_bar_h) return .none;
    const control_hit = hitControls(px, py, tab_bar_h, .{
        .plus_w = layout.plus_w,
        .plus_x = layout.plus_x,
        .close_w = layout.close_w,
        .close_x = layout.close_x,
        .more_w = layout.more_w,
        .more_x = layout.more_x,
    });
    if (control_hit != .none) return control_hit;
    if (layout.arrows_visible) {
        if (px >= layout.left_arrow_x and px < layout.left_arrow_x + layout.arrow_w)
            return .left_arrow;
        if (px >= layout.right_arrow_x and px < layout.right_arrow_x + layout.arrow_w)
            return .right_arrow;
    }
    if (px >= layout.tab_area_x and px < layout.tab_area_x + layout.tab_area_w) return .tab_area;
    return .none;
}

/// 탭 슬롯 경계 `bi` 에 세로 구분선이 그려지는가 (#342).
///
/// renderer 3곳의 세로선 루프와 **활성 탭 amber 밑줄의 inset 계산이 같은 판정을
/// 써야** 한다. 밑줄은 선이 실제로 그려지는 경계에서만 물러나야 하는데, 두 곳이
/// 따로 판정하면 반드시 어긋난다 — 한쪽만 아는 경계에서 밑줄이 선을 침범하거나
/// (덮어써서 가려짐) 반대로 선이 없는데 물러나 틈이 생긴다.
///
/// 좌표는 호출처의 수 체계 그대로 받는다. Linux software renderer 는 i32 로
/// 계산하므로 `@floatFromInt` 로 승격해 넘기면 (이 크기에서 정확) 정수 비교와
/// 같은 결과가 나온다 — f32 원본을 넘겨 truncation 차이가 끼어드는 걸 막는다.
///
/// 경계는 `bi ∈ [first, tab_count]`. `first` 는 화살표가 없으면 1 — 탭 영역
/// 맨 왼쪽(bi=0)에는 선을 두지 않는다. 화살표가 있으면 0 도 후보라 좌우 대칭이
/// 된다 (#334 4차 결정). tab_area 밖으로 잘린 경계는 그리지 않는다.
pub fn hasSeparator(
    bi: usize,
    tab_count: usize,
    arrows_visible: bool,
    tab_area_x: f32,
    tab_area_end: f32,
    tab_w: f32,
    scroll_x: f32,
) bool {
    const first: usize = if (arrows_visible) 0 else 1;
    if (bi < first or bi > tab_count) return false;
    const x = tab_area_x + @as(f32, @floatFromInt(bi)) * tab_w - scroll_x;
    return x >= tab_area_x and x <= tab_area_end;
}

test "#342 separator skips the strip's left edge unless arrows are visible" {
    // 탭 4개 × 150, 화살표 없음, scroll 0 — 경계 1..4 만 선.
    try std.testing.expect(!hasSeparator(0, 4, false, 0, 600, 150, 0));
    try std.testing.expect(hasSeparator(1, 4, false, 0, 600, 150, 0));
    try std.testing.expect(hasSeparator(4, 4, false, 0, 600, 150, 0));
    // 탭 수를 넘는 경계는 없음.
    try std.testing.expect(!hasSeparator(5, 4, false, 0, 600, 150, 0));
    // 화살표가 있으면 bi=0 도 후보 (좌우 대칭, #334 4차).
    try std.testing.expect(hasSeparator(0, 4, true, 24, 624, 150, 0));
}

test "#342 separator is clipped outside the tab area" {
    // scroll 로 경계가 tab_area 왼쪽 밖으로 나가면 안 그린다.
    try std.testing.expect(!hasSeparator(1, 4, false, 0, 400, 150, 200));
    // 오른쪽 끝과 정확히 정렬되면 (== tab_area_end) 그린다.
    try std.testing.expect(hasSeparator(2, 4, false, 0, 300, 150, 0));
    try std.testing.expect(!hasSeparator(3, 4, false, 0, 300, 150, 0));
}

test "#329 tab controls are ordered plus close more and use half-open hit bounds" {
    const controls = computeControls(300, 24, 24, 24);
    try std.testing.expectEqual(@as(f32, 228), controls.plus_x);
    try std.testing.expectEqual(@as(f32, 252), controls.close_x);
    try std.testing.expectEqual(@as(f32, 276), controls.more_x);
    try std.testing.expectEqual(Area.plus, hitControls(228, 0, 28, controls));
    try std.testing.expectEqual(Area.close, hitControls(252, 27.999, 28, controls));
    try std.testing.expectEqual(Area.more, hitControls(299.999, 0, 28, controls));
    try std.testing.expectEqual(Area.none, hitControls(300, 0, 28, controls));
    try std.testing.expectEqual(Area.none, hitControls(228, 28, 28, controls));
}

test "#329 multi-tab layout includes more in normal overflow and max-tab cluster" {
    const normal = compute(.{
        .viewport_w = 500,
        .tab_count = 2,
        .tab_w = 150,
        .arrow_w = 24,
        .plus_w = 24,
        .close_w = 24,
        .more_w = 24,
        .scroll_x = 0,
    });
    try std.testing.expect(!normal.arrows_visible);
    try std.testing.expectEqual(@as(f32, 428), normal.plus_x);
    try std.testing.expectEqual(@as(f32, 452), normal.close_x);
    try std.testing.expectEqual(@as(f32, 476), normal.more_x);
    try std.testing.expectEqual(@as(f32, 428), normal.tab_area_w);

    const overflow = compute(.{
        .viewport_w = 400,
        .tab_count = 3,
        .tab_w = 150,
        .arrow_w = 24,
        .plus_w = 24,
        .close_w = 24,
        .more_w = 24,
        .scroll_x = 0,
    });
    try std.testing.expect(overflow.arrows_visible);
    try std.testing.expect(overflow.plus_enabled);
    try std.testing.expectEqual(@as(f32, 304), overflow.right_arrow_x);
    try std.testing.expectEqual(@as(f32, 328), overflow.plus_x);

    // #329 정책 변경 (2026-07-22) — MAX_TABS 에서도 `+` 는 자리를 유지하고
    // 비활성 플래그만 내려간다. 세 버튼 좌표는 평소와 동일하고 hit 도 `.plus`
    // 를 그대로 반환한다 (noop 처리는 host 클릭 분기).
    const at_limit = compute(.{
        .viewport_w = 500,
        .tab_count = 32,
        .tab_w = 150,
        .arrow_w = 24,
        .plus_w = 24,
        .plus_enabled = false,
        .close_w = 24,
        .more_w = 24,
        .scroll_x = 0,
    });
    try std.testing.expect(!at_limit.plus_enabled);
    try std.testing.expectEqual(@as(f32, 24), at_limit.plus_w);
    try std.testing.expectEqual(@as(f32, 428), at_limit.plus_x);
    try std.testing.expectEqual(@as(f32, 452), at_limit.close_x);
    try std.testing.expectEqual(@as(f32, 476), at_limit.more_x);
    try std.testing.expectEqual(Area.plus, hitArea(430, 10, 28, at_limit));
}

test "#329 control layout never produces negative coordinates in a narrow viewport" {
    const controls = computeControls(40, 24, 24, 24);
    try std.testing.expect(controls.plus_x >= 0);
    try std.testing.expect(controls.close_x >= 0);
    try std.testing.expect(controls.more_x >= 0);
}

const truncate_ellipsis_cp: u21 = '…';

/// 탭바 title text 의 glyph layout — codepoint 별 cb 호출. iterTabText 가
/// emit 하고 호출자가 platform native 그리기 (mac CoreText/Metal, win
/// DirectWrite/D3D11, Linux software — atlas / instance buffer / glyph y 좌표
/// 계산 등) 처리. (#163 옵션 A)
pub const Glyph = struct { cp: u21, x: f32, advance: f32 };

/// 탭바 title text 의 cross-platform layout iter — codepoint 별 cb 호출.
/// truncate ellipsis / max 잘림 처리. 세 platform 이 같은 helper 호출 →
/// 같은 fix 전부 자동 반영 (#159 / #163 패턴).
///
/// 인자:
///   title: tab title
///   text_x_start: 탭 내 text 시작 x — 화면 절대 좌표 (`tab_x + tab_pad`)
///   cw: cell width (DPI scaled)
///   max_text_w: text 영역 너비 (`tab_w - close_w - 3*pad` 등)
///   needs_truncate: total > max → ellipsis
///   ctx: callback 의 사용자 context (anytype — closure 대용)
///   cb: comptime callback. 매 glyph 마다 호출. zero-overhead inline.
pub fn iterTabText(
    title: []const u8,
    text_x_start: f32,
    cw: f32,
    max_text_w: f32,
    needs_truncate: bool,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), Glyph) void,
) void {
    const ellipsis_cells = display_width.codepointWidth(truncate_ellipsis_cp);
    const ellipsis_w = cw * @as(f32, @floatFromInt(ellipsis_cells));
    const truncate_at = if (needs_truncate) max_text_w - ellipsis_w else max_text_w;

    var text_x = text_x_start;
    var iter = std.unicode.Utf8Iterator{ .bytes = title, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const cp_w_cells = display_width.codepointWidth(@intCast(cp));
        const advance = cw * @as(f32, @floatFromInt(cp_w_cells));

        // truncate threshold (long text)
        if (text_x - text_x_start + advance > truncate_at) {
            if (needs_truncate) {
                cb(ctx, .{
                    .cp = truncate_ellipsis_cp,
                    .x = text_x,
                    .advance = ellipsis_w,
                });
            }
            break;
        }
        cb(ctx, .{ .cp = @intCast(cp), .x = text_x, .advance = advance });
        text_x += advance;
    }
}

/// tab_area 안에서 px → 탭 인덱스. 호출자가 먼저 hitArea 가 .tab_area 인지
/// 검사 후 호출. tab_area 좌표계: world_x = (px - tab_area_x) + scroll_x.
/// #268 — per-tab close 가 제거되어 탭 인덱스만 반환 (탭 어디를 눌러도 전환).
pub fn hitTab(
    px: f32,
    layout: Layout,
    tab_w: f32,
    scroll_x: f32,
    tab_count: u32,
) ?usize {
    const local_x = px - layout.tab_area_x;
    const world_x = local_x + scroll_x;
    if (world_x < 0) return null;
    const tab_index = @as(usize, @intFromFloat(world_x / tab_w));
    if (tab_index >= tab_count) return null;
    return tab_index;
}

test "committed title truncation emits one-cell ellipsis and preserves more ASCII" {
    const Trace = struct {
        cps: [16]u21 = undefined,
        xs: [16]f32 = undefined,
        advances: [16]f32 = undefined,
        len: usize = 0,

        fn emit(self: *@This(), glyph: Glyph) void {
            self.cps[self.len] = glyph.cp;
            self.xs[self.len] = glyph.x;
            self.advances[self.len] = glyph.advance;
            self.len += 1;
        }
    };

    try std.testing.expectEqual(@as(u8, 1), display_width.codepointWidth(truncate_ellipsis_cp));

    var trace: Trace = .{};
    iterTabText("ABCDEFG", 0, 10, 60, true, &trace, Trace.emit);

    const expected = [_]u21{ 'A', 'B', 'C', 'D', 'E', truncate_ellipsis_cp };
    try std.testing.expectEqualSlices(u21, &expected, trace.cps[0..trace.len]);
    try std.testing.expectEqual(@as(f32, 50), trace.xs[trace.len - 1]);
    try std.testing.expectEqual(@as(f32, 10), trace.advances[trace.len - 1]);
}

test "committed CJK title truncation keeps wide glyph boundaries and one ellipsis" {
    const Trace = struct {
        cps: [16]u21 = undefined,
        xs: [16]f32 = undefined,
        advances: [16]f32 = undefined,
        len: usize = 0,

        fn emit(self: *@This(), glyph: Glyph) void {
            self.cps[self.len] = glyph.cp;
            self.xs[self.len] = glyph.x;
            self.advances[self.len] = glyph.advance;
            self.len += 1;
        }
    };

    var trace: Trace = .{};
    iterTabText("가나다라", 0, 10, 60, true, &trace, Trace.emit);

    const expected = [_]u21{ '가', '나', truncate_ellipsis_cp };
    try std.testing.expectEqualSlices(u21, &expected, trace.cps[0..trace.len]);
    try std.testing.expectEqual(@as(f32, 40), trace.xs[trace.len - 1]);
    try std.testing.expectEqual(@as(f32, 10), trace.advances[trace.len - 1]);
    try std.testing.expect(trace.xs[trace.len - 1] + trace.advances[trace.len - 1] <= 60);
}
