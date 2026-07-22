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

/// rename / IME preedit 의 cross-platform 산술 — mac/win 양쪽 renderer 와 host
/// 가 동일 호출. 한 곳 (helper) 변경 시 양쪽 자동 반영. (#163 통합 옵션 A)
/// preedit text 의 codepoint 별 advance 합 — wide char (CJK) 자모 = 2 cell.
pub fn computeAdvanceTotal(preedit_text: []const u8, cw: f32) f32 {
    var total: f32 = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = preedit_text, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const cells = display_width.codepointWidth(@intCast(cp));
        total += cw * @as(f32, @floatFromInt(cells));
    }
    return total;
}

/// cursor 우측 reserve (1 cell). preedit 폭은 cursorScrollOffset이 별도로 더한다.
/// preedit 활성/비활성 무관 고정 — transition jump 없음 (한글 typing 빠를 때
/// cursor 안정).
pub fn cursorReserve(cw: f32) f32 {
    return cw;
}

pub const RenameCursorVertical = struct {
    y: f32,
    height: f32,
};

/// Rename cursor의 text cell 안 세로 경계. 입력과 결과는 renderer가 사용하는
/// physical pixel 좌표다. 위·아래 2px inset을 같은 계산에서 만들어 한쪽만
/// 빠지는 회귀를 막는다 (#315).
pub fn renameCursorVertical(cell_top: f32, cell_height: f32) RenameCursorVertical {
    const inset_px: f32 = 2;
    return .{
        .y = cell_top + inset_px,
        .height = cell_height - inset_px * 2,
    };
}

/// rename text 의 cursor follow scroll — native textbox 패턴 (#168). cursor 가
/// 현재 viewport [0, max-reserve] 안이면 prev_offset 유지. 우측 out 시 우측
/// align (cursor + preedit 끝이 max-reserve 에 pin), 좌측 out 시 좌측 align
/// (cursor 가 0). cached state — caller 가 매 frame 새 값 받아 RenameState
/// 에 write back.
pub fn cursorScrollOffset(
    title: []const u8,
    cursor_byte: usize,
    cw: f32,
    max_text_w: f32,
    preedit_advance_total: f32,
    prev_offset: f32,
) f32 {
    var cursor_x: f32 = 0;
    var probe_iter = std.unicode.Utf8Iterator{ .bytes = title, .i = 0 };
    var probe_byte: usize = 0;
    while (probe_iter.nextCodepoint()) |pcp| {
        if (probe_byte >= cursor_byte) break;
        const pcw = display_width.codepointWidth(@intCast(pcp));
        cursor_x += cw * @as(f32, @floatFromInt(pcw));
        const plen = std.unicode.utf8CodepointSequenceLength(pcp) catch 1;
        probe_byte += plen;
    }
    const reserve = cursorReserve(cw);
    const right_limit = max_text_w - reserve;
    const cursor_visual = cursor_x - prev_offset;
    const preedit_end_visual = cursor_visual + preedit_advance_total;

    // cursor + preedit 우측 out → 우측 align.
    if (preedit_end_visual > right_limit) {
        return cursor_x + preedit_advance_total - right_limit;
    }
    // cursor 좌측 out → 좌측 align (cursor visual = 0).
    if (cursor_visual < 0) {
        return cursor_x;
    }
    return prev_offset;
}

/// 탭바 title text 의 codepoint 별 layout 명령. iterTabText 가 codepoint 별로
/// 호출자의 callback 에 emit. 호출자가 platform native 그리기 (mac
/// CoreText/Metal, win DirectWrite/D3D11 — atlas / instance buffer / glyph y
/// 좌표 계산 등) 처리. (#163 옵션 A 확장)
pub const TextCmd = union(enum) {
    /// title codepoint 또는 synthetic truncation ellipsis (viewport 안).
    /// 호출자가 atlas resolve + glyph instance.
    glyph: struct { cp: u21, x: f32, advance: f32 },
    /// rename cursor 1 px vertical bar.
    cursor: struct { x: f32 },
    /// preedit cell BG (보라). cursor 뒤 inline.
    preedit_bg: struct { x: f32, advance: f32 },
    /// preedit cell glyph. preedit_bg 와 동일 위치.
    preedit_glyph: struct { cp: u21, x: f32, advance: f32 },
};

const truncate_ellipsis_cp: u21 = '…';

/// 탭바 title text 의 cross-platform layout iter — codepoint 별 cb 호출.
/// cursor follow scroll / preedit push-right (cursor 뒤 main text 우측 이동) /
/// truncate ellipsis / max 잘림 모두 처리. mac/win 양쪽이 같은 helper 호출 →
/// 같은 fix 양쪽 자동 반영 (#159 / #163 / #164 패턴 확장).
///
/// 인자:
///   title: rename buf (rename 활성) 또는 tab title
///   cursor_byte: rename 활성 시 cursor 위치 (null = rename 비활성)
///   preedit_text: IME preedit (rename 활성 시 cursor 옆 inline)
///   text_x_start: 탭 내 text 시작 x — 화면 절대 좌표 (`tab_x + tab_pad`)
///   cw: cell width (DPI scaled)
///   max_text_w: text 영역 너비 (`tab_w - close_w - 3*pad` 등)
///   is_renaming: 이 탭이 rename 활성 여부
///   needs_truncate: commit 후 (rename 비활성) + total > max → ellipsis
///   ctx: callback 의 사용자 context (anytype — closure 대용)
///   cb: comptime callback. 매 cmd 마다 호출. zero-overhead inline.
pub fn iterTabText(
    title: []const u8,
    cursor_byte: ?usize,
    preedit_text: []const u8,
    text_x_start: f32,
    cw: f32,
    max_text_w: f32,
    is_renaming: bool,
    needs_truncate: bool,
    /// rename 활성 시 RenameState.scroll_offset 의 ptr (helper 가 갱신).
    /// rename 비활성 시 null.
    rename_scroll_offset_inout: ?*f32,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), TextCmd) void,
) void {
    const reserve = cursorReserve(cw);
    const ellipsis_cells = display_width.codepointWidth(truncate_ellipsis_cp);
    const ellipsis_w = cw * @as(f32, @floatFromInt(ellipsis_cells));
    const truncate_at = if (needs_truncate) max_text_w - ellipsis_w else max_text_w;
    const preedit_advance = if (is_renaming) computeAdvanceTotal(preedit_text, cw) else 0;

    const scroll_offset: f32 = blk: {
        if (is_renaming and cursor_byte != null and rename_scroll_offset_inout != null) {
            const new_offset = cursorScrollOffset(
                title,
                cursor_byte.?,
                cw,
                max_text_w,
                preedit_advance,
                rename_scroll_offset_inout.?.*,
            );
            rename_scroll_offset_inout.?.* = new_offset;
            break :blk new_offset;
        }
        break :blk 0;
    };

    var text_x = text_x_start - scroll_offset;
    var byte_idx: usize = 0;
    var cursor_drawn = false;
    var cursor_x: f32 = text_x;
    var truncated = false;

    var iter = std.unicode.Utf8Iterator{ .bytes = title, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const cp_w_cells = display_width.codepointWidth(@intCast(cp));
        const advance = cw * @as(f32, @floatFromInt(cp_w_cells));
        const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;

        // truncate threshold (rename 비활성, long text)
        if (text_x - text_x_start + advance > truncate_at) {
            if (needs_truncate) {
                cb(ctx, .{ .glyph = .{
                    .cp = truncate_ellipsis_cp,
                    .x = text_x,
                    .advance = ellipsis_w,
                } });
            }
            truncated = true;
            break;
        }
        // rename 중 close 와 reserve 간격 보장 — max - reserve 도달 시 잘림
        if (is_renaming and text_x - text_x_start + advance > max_text_w - reserve) break;

        // cursor mid (byte_idx 가 cursor_byte 도달)
        if (cursor_byte) |cb_pos| {
            if (byte_idx == cb_pos and !cursor_drawn) {
                cursor_x = text_x;
                if (text_x >= text_x_start) cb(ctx, .{ .cursor = .{ .x = text_x } });
                cursor_drawn = true;
                // cursor 통과 — main text 의 cursor 뒤 글자를 preedit advance 만큼 우측 이동.
                text_x += preedit_advance;
            }
        }
        byte_idx += cp_len;

        // viewport 좌측 잘림 — advance 만 누적, glyph X
        if (text_x < text_x_start) {
            text_x += advance;
            continue;
        }
        cb(ctx, .{ .glyph = .{ .cp = @intCast(cp), .x = text_x, .advance = advance } });
        text_x += advance;
    }

    // cursor at end (cursor_byte == title.len). truncated 면 X.
    if (is_renaming and !cursor_drawn and !truncated) {
        if (cursor_byte) |cb_pos| if (cb_pos >= title.len) {
            cursor_x = text_x;
            if (text_x >= text_x_start) cb(ctx, .{ .cursor = .{ .x = text_x } });
        };
    }

    // preedit overlay — cursor_x 부터 codepoint 별 보라 BG + glyph.
    if (is_renaming and preedit_text.len > 0) {
        var pre_x = cursor_x;
        var pre_iter = std.unicode.Utf8Iterator{ .bytes = preedit_text, .i = 0 };
        while (pre_iter.nextCodepoint()) |pcp| {
            const pcells = display_width.codepointWidth(@intCast(pcp));
            const padv = cw * @as(f32, @floatFromInt(pcells));
            // close 영역까지만 (preedit 길어지면 close 까지 — textbox 일반).
            if (pre_x + padv > text_x_start + max_text_w) break;
            if (pre_x < text_x_start) {
                pre_x += padv;
                continue;
            }
            cb(ctx, .{ .preedit_bg = .{ .x = pre_x, .advance = padv } });
            cb(ctx, .{ .preedit_glyph = .{ .cp = @intCast(pcp), .x = pre_x, .advance = padv } });
            pre_x += padv;
        }
    }
}

/// rename text 영역 안 마우스 위치 → text 안 byte index. cursor follow scroll
/// 결과 좌측 잘림 영역도 처리. mouse_x 가 viewport 밖이면 null. native textbox
/// UX — caller 가 RenameState.setCursor 호출 후 commit 안 함 (#164 follow-up).
///
/// 인자:
///   - title: 현재 rename buffer text
///   - scroll_offset: RenameState.scroll_offset (#168 cached state — render 와
///     동일 시점 값 사용 → click 위치 visual 일치)
///   - text_x_start: 탭 내 text 시작 x — 화면 좌표 (`tab_x + tab_pad`)
///   - cw: cell width
///   - max_text_w: text 영역 너비 (`tab_w - close_w - 3*pad` 등 host 별 동등)
///   - mouse_x: 마우스 x (탭바 좌표)
///
/// 반환: byte index (mouse 가 codepoint 의 우반에 있으면 그 codepoint 끝, 좌반
/// 이면 시작). title 끝 이후면 title.len. mouse_x 가 영역 밖이면 null.
pub fn renameTextHit(
    title: []const u8,
    scroll_offset: f32,
    text_x_start: f32,
    cw: f32,
    max_text_w: f32,
    mouse_x: f32,
) ?usize {
    if (mouse_x < text_x_start or mouse_x >= text_x_start + max_text_w) return null;

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

/// #193 — cursor shape (I-beam) 결정용 — rename 활성 탭의 text 입력 영역 hit.
/// rename 비활성, 다른 탭, 탭바 밖 모두 false. SPEC.md §3.1
/// "탭바 — rename 활성 탭의 text 입력 영역" 행.
pub fn hitRenameText(
    px: f32,
    py: f32,
    layout: Layout,
    tab_w: f32,
    tab_bar_h: f32,
    scroll_x: f32,
    tab_count: u32,
    rename_tab_index: ?usize,
) bool {
    const idx = rename_tab_index orelse return false;
    if (py < 0 or py >= tab_bar_h) return false;
    if (hitArea(px, py, tab_bar_h, layout) != .tab_area) return false;
    const hit = hitTab(px, layout, tab_w, scroll_x, tab_count) orelse return false;
    return hit == idx;
}

test "committed title truncation emits one-cell ellipsis and preserves more ASCII" {
    const Trace = struct {
        cps: [16]u21 = undefined,
        xs: [16]f32 = undefined,
        advances: [16]f32 = undefined,
        len: usize = 0,

        fn emit(self: *@This(), cmd: TextCmd) void {
            switch (cmd) {
                .glyph => |glyph| {
                    self.cps[self.len] = glyph.cp;
                    self.xs[self.len] = glyph.x;
                    self.advances[self.len] = glyph.advance;
                    self.len += 1;
                },
                else => {},
            }
        }
    };

    try std.testing.expectEqual(@as(u8, 1), display_width.codepointWidth(truncate_ellipsis_cp));

    var trace: Trace = .{};
    iterTabText(
        "ABCDEFG",
        null,
        "",
        0,
        10,
        60,
        false,
        true,
        null,
        &trace,
        Trace.emit,
    );

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

        fn emit(self: *@This(), cmd: TextCmd) void {
            switch (cmd) {
                .glyph => |glyph| {
                    self.cps[self.len] = glyph.cp;
                    self.xs[self.len] = glyph.x;
                    self.advances[self.len] = glyph.advance;
                    self.len += 1;
                },
                else => {},
            }
        }
    };

    var trace: Trace = .{};
    iterTabText(
        "가나다라",
        null,
        "",
        0,
        10,
        60,
        false,
        true,
        null,
        &trace,
        Trace.emit,
    );

    const expected = [_]u21{ '가', '나', truncate_ellipsis_cp };
    try std.testing.expectEqualSlices(u21, &expected, trace.cps[0..trace.len]);
    try std.testing.expectEqual(@as(f32, 40), trace.xs[trace.len - 1]);
    try std.testing.expectEqual(@as(f32, 10), trace.advances[trace.len - 1]);
    try std.testing.expect(trace.xs[trace.len - 1] + trace.advances[trace.len - 1] <= 60);
}

test "one-cell cursor reserve keeps wide preedit commit scroll stable" {
    const cw: f32 = 10;
    const max_text_w: f32 = 60;
    try std.testing.expectEqual(cw, cursorReserve(cw));

    const preedit = "한";
    const preedit_advance = computeAdvanceTotal(preedit, cw);
    try std.testing.expectEqual(@as(f32, 20), preedit_advance);

    const before_commit = "ABCDE";
    const during_preedit = cursorScrollOffset(
        before_commit,
        before_commit.len,
        cw,
        max_text_w,
        preedit_advance,
        0,
    );
    try std.testing.expectEqual(@as(f32, 20), during_preedit);

    const after_commit = "ABCDE한";
    const after_preedit = cursorScrollOffset(
        after_commit,
        after_commit.len,
        cw,
        max_text_w,
        0,
        during_preedit,
    );
    try std.testing.expectEqual(during_preedit, after_preedit);

    const cursor_x = 5 * cw + preedit_advance - after_preedit;
    try std.testing.expectEqual(@as(f32, 50), cursor_x);
    try std.testing.expectEqual(cw, max_text_w - cursor_x);

    const long_ascii = "ABCDEFG";
    const ascii_offset = cursorScrollOffset(
        long_ascii,
        long_ascii.len,
        cw,
        max_text_w,
        0,
        0,
    );
    try std.testing.expectEqual(@as(f32, 20), ascii_offset);
    try std.testing.expectEqual(@as(f32, 50), 7 * cw - ascii_offset);
}

test "#315 rename cursor keeps symmetric vertical inset across scales" {
    const Case = struct {
        scale: f32,
        cell_height: f32,
    };
    const cases = [_]Case{
        .{ .scale = 1.0, .cell_height = 16 },
        .{ .scale = 1.5, .cell_height = 24 },
        .{ .scale = 2.0, .cell_height = 32 },
    };

    for (cases) |case| {
        const cell_top = 10 * case.scale;
        const cursor = renameCursorVertical(cell_top, case.cell_height);
        try std.testing.expectEqual(cell_top + 2, cursor.y);
        try std.testing.expectEqual(case.cell_height - 4, cursor.height);
        try std.testing.expectEqual(cell_top + case.cell_height - 2, cursor.y + cursor.height);
    }
}
