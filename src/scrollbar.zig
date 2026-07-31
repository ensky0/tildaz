//! 스크롤바 thumb geometry + 드래그 매핑 (순수, 플랫폼 무관). 렌더러(그리기)와
//! hit-test(클릭/드래그)가 **같은 소스**를 쓰게 해 thumb 그림 영역과 클릭 영역을
//! 항상 일치시킨다. 모든 입력/출력은 **픽셀 단위 f64** — 각 플랫폼은 자기 단위
//! (Windows `c_int` / macOS `f32` / Linux `i32`) 를 f64 px 로 변환만 해서 호출한다.
//!
//! #259 — 이전엔 같은 수식이 3 OS hit-test + 3 renderer 에 복붙돼 있었고, hit-test
//! 가 grab offset 을 기록하지 않아 thumb 가 길 때 thumb 윗변이 커서로 점프(= 맨
//! 위 좁은 띠에서만 잡힘)했다. 이 모듈로 수렴하면서 그 버그를 함께 고친다.

const std = @import("std");
const ui_rect = @import("ui_rect.zig");
const ui_metrics = @import("ui_metrics.zig");
const themes = @import("themes.zig");

/// thumb 의 세로 geometry. track_top 기준 상대 좌표.
pub const Geom = struct {
    /// thumb 높이 (>= min_thumb_h).
    thumb_h: f64,
    /// track_top 기준 thumb 윗변 위치.
    thumb_y_rel: f64,
    /// thumb 가 움직일 수 있는 세로 여유 = track_h - thumb_h.
    available: f64,
};

/// thumb 이 도는 세로 구간. 위/아래 padding 모두 반영하고 탭바 아래에서 시작.
pub const Track = struct {
    /// 윈도우 좌상 기준 track 윗변 (px).
    top: f64,
    /// track 높이 (px).
    h: f64,
};

/// track geometry. `top = tab_bar_h + pad`, `h = viewport_h - tab_bar_h - 2*pad`
/// (셀 영역의 위·아래 padding 을 모두 반영). 렌더러와 hit-test 가 같은 값을 써야
/// thumb 그림과 클릭 매핑이 어긋나지 않는다.
pub fn track(viewport_h: f64, tab_bar_h: f64, pad: f64) Track {
    return .{ .top = tab_bar_h + pad, .h = viewport_h - tab_bar_h - 2 * pad };
}

/// thumb geometry 계산. `total <= len`(스크롤백 없음) 또는 thumb 가 들어갈 여유가
/// 없으면(`track_h <= 0` / `available <= 0`) null — 스크롤바를 그릴 필요도 잡을
/// 필요도 없다.
pub fn geom(total: usize, len: usize, offset: usize, track_h: f64, min_thumb_h: f64) ?Geom {
    if (total <= len or track_h <= 0) return null;
    const total_f: f64 = @floatFromInt(total);
    const ratio_px = track_h / total_f;
    const thumb_h = @max(min_thumb_h, ratio_px * @as(f64, @floatFromInt(len)));
    const available = track_h - thumb_h;
    if (available <= 0) return null;
    const max_off: f64 = @floatFromInt(total - len);
    const thumb_y_rel = if (max_off > 0)
        @as(f64, @floatFromInt(offset)) / max_off * available
    else
        0;
    return .{ .thumb_h = thumb_h, .thumb_y_rel = thumb_y_rel, .available = available };
}

/// 정수 픽셀 격자에 스냅한 thumb 사각형 (#344).
pub const ThumbPx = struct {
    /// 윈도우 좌상 기준 thumb 윗변 (정수값을 담은 f64).
    top: f64,
    /// thumb 높이 (정수값, 최소 1).
    h: f64,
};

/// thumb 을 정수 픽셀에 스냅한다 (#344). **양 끝을 각각 반올림한 뒤 높이를 뺀다** —
/// 이 순서가 핵심이다.
///
/// track 아랫변 `track_top + track_h` 는 정수인데, 맨 아래로 내렸을 때 thumb 아랫변이
/// 정확히 거기에 떨어져야 위·아래 여백이 같아진다. 윗변과 높이를 *따로* 정수화하면
/// 두 절단 오차가 누적돼 `⌊T − thumb_h⌋ + ⌊thumb_h⌋ = T − 1` 이 되어 **아래 여백만
/// 1px 커진다**. 양 끝을 각각 반올림하면 아랫변이 `round(T) = T` 로 보존된다.
///
/// 세 renderer 가 이 함수 하나만 쓰게 해서 platform 픽셀을 일치시킨다. 이전에는
/// Linux 만 `@intFromFloat` 로 절단하고 macOS / Windows 는 f32 를 그대로 GPU 에
/// 넘겨 결과가 달랐다 (같은 부류의 정수/실수 갈래는 #343 에서 통째로 정리).
///
/// hit-test 는 계속 f64 원본(`track_top` + `Geom`)을 쓴다 — 그리기만 격자에 맞추고
/// 클릭 매핑은 연속값을 유지해, 스냅 때문에 드래그가 튀지 않는다.
pub fn thumbPx(track_top: f64, g: Geom) ThumbPx {
    const top = @round(track_top + g.thumb_y_rel);
    const bottom = @round(track_top + g.thumb_y_rel + g.thumb_h);
    return .{ .top = top, .h = @max(1, bottom - top) };
}

/// mouse-down 시 grab offset 산출. `mouse_rel_y = mouse_y - track_top`.
/// thumb 위를 잡으면 잡은 지점을 유지(`mouse_rel_y - thumb_y_rel`), thumb 밖(빈
/// track) 을 잡으면 thumb 가 커서 중심에 오게(`thumb_h/2`) — 잡은 지점이 커서 아래
/// 고정돼 thumb 어디를 잡아도 자연스럽게 따라온다.
pub fn grabOffset(g: Geom, mouse_rel_y: f64) f64 {
    const on_thumb = mouse_rel_y >= g.thumb_y_rel and mouse_rel_y <= g.thumb_y_rel + g.thumb_h;
    return if (on_thumb) mouse_rel_y - g.thumb_y_rel else g.thumb_h / 2;
}

/// 드래그 중 목표 offset(row). `thumb_top = clamp(mouse_rel_y - grab, 0, available)`
/// 를 ratio 로 환산. delta(`target - sb.offset`) 계산은 호출처 책임.
pub fn targetOffset(total: usize, len: usize, g: Geom, mouse_rel_y: f64, grab: f64) usize {
    const thumb_top = std.math.clamp(mouse_rel_y - grab, 0, g.available);
    const ratio = thumb_top / g.available;
    return @intFromFloat(ratio * @as(f64, @floatFromInt(total - len)));
}

/// 렌더러·hit-test 공용 단일 진입점. track + geom 을 한 번에 구해 thumb 위치(그리기)
/// 와 grab/target 매핑(드래그) 을 같은 소스로 제공한다. 스크롤바 불필요면 null.
pub const Hit = struct {
    g: Geom,
    track_top: f64,
    total: usize,
    len: usize,
    offset: usize,

    /// mouse-down(`mouse_y` = 윈도우 좌상 기준 px) → grab offset.
    pub fn grab(self: Hit, mouse_y: f64) f64 {
        return grabOffset(self.g, mouse_y - self.track_top);
    }

    /// 드래그(`mouse_y` = px, `grab` = down 때 저장한 offset) → 목표 offset(row).
    pub fn target(self: Hit, mouse_y: f64, grab_off: f64) usize {
        return targetOffset(self.total, self.len, self.g, mouse_y - self.track_top, grab_off);
    }

    /// thumb 윗변의 절대 Y (px), 스냅 전 연속값. **그리기에는 `thumb()` 을 쓴다** —
    /// 이 값을 renderer 가 각자 정수화하면 platform 마다 결과가 갈린다 (#344).
    pub fn thumbTop(self: Hit) f64 {
        return self.track_top + self.g.thumb_y_rel;
    }

    /// 정수 픽셀에 스냅한 thumb 사각형 — 세 renderer 의 유일한 그리기 입력 (#344).
    pub fn thumb(self: Hit) ThumbPx {
        return thumbPx(self.track_top, self.g);
    }
};

/// scrollbar 상태(`total`/`len`/`offset`) + track geometry 입력 → `Hit`.
/// `viewport_h`/`tab_bar_h`/`pad`/`min_thumb_h` 모두 f64 px.
pub fn hit(
    total: usize,
    len: usize,
    offset: usize,
    viewport_h: f64,
    tab_bar_h: f64,
    pad: f64,
    min_thumb_h: f64,
) ?Hit {
    const tr = track(viewport_h, tab_bar_h, pad);
    const g = geom(total, len, offset, tr.h, min_thumb_h) orelse return null;
    return .{ .g = g, .track_top = tr.top, .total = total, .len = len, .offset = offset };
}

test "geom: no scrollback returns null" {
    try std.testing.expect(geom(10, 10, 0, 500, 32) == null);
    try std.testing.expect(geom(5, 10, 0, 500, 32) == null);
}

test "geom: thumb height + min clamp" {
    // total=200, len=50, track=500 → ratio 2.5px/row, thumb = 2.5*50 = 125
    const g = geom(200, 50, 0, 500, 32).?;
    try std.testing.expectApproxEqAbs(@as(f64, 125), g.thumb_h, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 375), g.available, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), g.thumb_y_rel, 0.001); // offset 0 → top

    // 매우 긴 scrollback → ratio*len < min_thumb → min_thumb 로 clamp
    const g2 = geom(100000, 50, 0, 500, 32).?;
    try std.testing.expectApproxEqAbs(@as(f64, 32), g2.thumb_h, 0.001);
}

test "geom: thumb_y_rel tracks offset" {
    // offset = max(total-len) → thumb 바닥 (thumb_y_rel == available)
    const g = geom(200, 50, 150, 500, 32).?;
    try std.testing.expectApproxEqAbs(g.available, g.thumb_y_rel, 0.001);
}

test "grabOffset: on thumb keeps grab point, off thumb centers" {
    const g = geom(200, 50, 0, 500, 32).?; // thumb_y_rel=0, thumb_h=125
    // thumb 중간(60) 클릭 → grab = 60 - 0 = 60
    try std.testing.expectApproxEqAbs(@as(f64, 60), grabOffset(g, 60), 0.001);
    // thumb 밖(아래쪽 300) 클릭 → 커서 중심 = thumb_h/2 = 62.5
    try std.testing.expectApproxEqAbs(@as(f64, 62.5), grabOffset(g, 300), 0.001);
}

test "targetOffset: long thumb body drag follows cursor (#259 regression)" {
    // total=200, len=150, track=500 → thumb = 500/200*150 = 375, available = 125
    const g = geom(200, 150, 0, 500, 32).?;
    try std.testing.expectApproxEqAbs(@as(f64, 375), g.thumb_h, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 125), g.available, 0.001);

    // 버그 재현 방지: thumb 의 *몸통* (윗변 0 기준 200px 지점) 을 잡고
    // grab = 200 (잡은 지점) 으로 그 자리에 가만히 두면 offset 변화 없음.
    // (이전 jump-to 매핑이면 rel_y=200 > available=125 → 즉시 bottom 으로 점프했음)
    try std.testing.expectEqual(@as(usize, 0), targetOffset(200, 150, g, 200, 200));

    // 그 상태에서 30px 아래로 드래그 → thumb_top = 230 - 200 = 30
    // ratio = 30/125 = 0.24, target = 0.24 * (200-150) = 12
    try std.testing.expectEqual(@as(usize, 12), targetOffset(200, 150, g, 230, 200));
}

test "hit: single entry point ties geom + track" {
    // viewport 600, tabbar 28, pad 6 → track_top = 34, track_h = 600-28-12 = 560
    const h = hit(200, 50, 0, 600, 28, 6, 32).?;
    try std.testing.expectApproxEqAbs(@as(f64, 34), h.track_top, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 34), h.thumbTop(), 0.001); // offset 0
    // down at thumb top (y=34) → grab 0
    try std.testing.expectApproxEqAbs(@as(f64, 0), h.grab(34), 0.001);
    try std.testing.expect(hit(10, 10, 0, 600, 28, 6, 32) == null);
}

test "#344 thumb snapping keeps the top and bottom track gaps equal" {
    // 위 여백 = track_top - tab_bar_h, 아래 여백 = viewport_h - thumb 아랫변.
    // 둘 다 pad 여야 한다 — 어떤 total/len 조합에서도.
    const pad: f64 = 6;
    const tab_bar_h: f64 = 28;
    const viewport_h: f64 = 600;
    const tr = track(viewport_h, tab_bar_h, pad);

    const cases = [_][2]usize{
        .{ 1000, 50 }, .{ 333, 40 }, .{ 97, 31 }, .{ 5000, 54 }, .{ 61, 60 },
    };
    for (cases) |c| {
        const total = c[0];
        const len = c[1];
        const g_top = geom(total, len, 0, tr.h, 32) orelse continue;
        const g_bot = geom(total, len, total - len, tr.h, 32) orelse continue;

        const t_top = thumbPx(tr.top, g_top);
        const t_bot = thumbPx(tr.top, g_bot);

        try std.testing.expectEqual(pad, t_top.top - tab_bar_h);
        try std.testing.expectEqual(pad, viewport_h - (t_bot.top + t_bot.h));
    }
}

test "#344 snapped thumb is integral and never collapses" {
    const tr = track(480, 28, 6);
    var offset: usize = 0;
    while (offset <= 900) : (offset += 37) {
        const g = geom(1000, 100, offset, tr.h, 32) orelse continue;
        const t = thumbPx(tr.top, g);
        try std.testing.expectEqual(t.top, @round(t.top));
        try std.testing.expectEqual(t.h, @round(t.h));
        try std.testing.expect(t.h >= 1);
        // 아랫변이 track 을 넘지 않는다.
        try std.testing.expect(t.top + t.h <= tr.top + tr.h);
    }
}

test "#344 the old two-truncation approach loses a pixel at the bottom" {
    // 회귀 근거 기록 — 왜 양 끝을 각각 반올림해야 하는지.
    //
    // thumb_h 가 **소수일 때만** 오차가 누적된다. min_thumb 로 clamp 되어 32 같은
    // 정수가 나오는 조합(예 total=1000, len=50)에서는 옛 방식도 우연히 맞는다.
    // 실사용에서는 `track_h / total * len` 이 거의 항상 소수다.
    const tr = track(600, 28, 6); // top=34, h=560 → 아랫변 594
    const g = geom(333, 40, 333 - 40, tr.h, 32).?;
    try std.testing.expect(g.thumb_h != @round(g.thumb_h)); // 소수임을 명시

    const exact_bottom = tr.top + tr.h;
    const old_top = @floor(tr.top + g.thumb_y_rel);
    const old_bottom = old_top + @floor(g.thumb_h);
    try std.testing.expectEqual(exact_bottom - 1, old_bottom); // 정확히 1px 모자람

    const t = thumbPx(tr.top, g);
    try std.testing.expectEqual(exact_bottom, t.top + t.h); // 새 방식은 정확히 도달
}

/// #343 단계 2 — 터미널 우측 scrollbar thumb 의 **사각형과 색**. 세 renderer 가
/// 이 함수 하나를 호출한다. `null` = 스크롤백이 없어 그리지 않음 (`hit` 과 동일 판정).
///
/// 이전에는 세 renderer 가 각자 `hit` → `thumb()` → 색 합성 → rect 방출을 적어
/// 뒀다. 계산(`hit` / `thumbPx`, #344) 과 색(`ui_metrics.scrollbarColor`, #346·#353)
/// 은 이미 공유였고 **마지막 rect 한 줄과 색 3줄만 삼중**이었다 — 그것을 없앤다.
///
/// 색 판정 입력은 terminal 의 현재 배경 (OSC 11 · reverse_colors 반영) 이라 셸이
/// 배경을 바꾸면 thumb 도 따라 전환된다 (#346). 합성은 `scrollbarColor` 가 끝내므로
/// 알파는 1.0 — renderer 의 blend unit 정밀도 차이를 타지 않는다 (#353).
pub fn thumbRect(
    total: usize,
    len: usize,
    offset: usize,
    viewport_w: f64,
    viewport_h: f64,
    track_top: f64,
    pad: f64,
    min_thumb_h: f64,
    sb_w: f64,
    terminal_bg: [3]u8,
) ?ui_rect.Rect {
    const h = hit(total, len, offset, viewport_h, track_top, pad, min_thumb_h) orelse return null;
    const t = h.thumb();
    const dark = themes.isDarkRgb(terminal_bg[0], terminal_bg[1], terminal_bg[2]);
    const c = ui_metrics.scrollbarColor(terminal_bg, dark);
    const f = struct {
        fn v(x: u8) f32 {
            return @as(f32, @floatFromInt(x)) / 255.0;
        }
    }.v;
    return .{
        .x = @floatCast(viewport_w - sb_w),
        .y = @floatCast(t.top),
        .w = @floatCast(sb_w),
        .h = @floatCast(t.h),
        .color = .{ f(c[0]), f(c[1]), f(c[2]), 1 },
    };
}

test "thumbRect — 스크롤백 없으면 null, 있으면 우측 끝에 붙는다" {
    try std.testing.expect(thumbRect(10, 10, 0, 800, 600, 0, 6, 32, 10, .{ 0, 0, 0 }) == null);
    const r = thumbRect(1000, 60, 0, 800, 600, 0, 6, 32, 10, .{ 0, 0, 0 }).?;
    try std.testing.expectEqual(@as(f32, 790), r.x);
    try std.testing.expectEqual(@as(f32, 10), r.w);
    // 어두운 배경 → 흰색 30% 합성 = 77 (#353).
    try std.testing.expectEqual(@as(f32, 77.0 / 255.0), r.color[0]);
}
