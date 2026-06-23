//! 스크롤바 thumb geometry + 드래그 매핑 (순수, 플랫폼 무관). 렌더러(그리기)와
//! hit-test(클릭/드래그)가 **같은 소스**를 쓰게 해 thumb 그림 영역과 클릭 영역을
//! 항상 일치시킨다. 모든 입력/출력은 **픽셀 단위 f64** — 각 플랫폼은 자기 단위
//! (Windows `c_int` / macOS `f32` / Linux `i32`) 를 f64 px 로 변환만 해서 호출한다.
//!
//! #259 — 이전엔 같은 수식이 3 OS hit-test + 3 renderer 에 복붙돼 있었고, hit-test
//! 가 grab offset 을 기록하지 않아 thumb 가 길 때 thumb 윗변이 커서로 점프(= 맨
//! 위 좁은 띠에서만 잡힘)했다. 이 모듈로 수렴하면서 그 버그를 함께 고친다.

const std = @import("std");

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

    /// thumb 윗변의 절대 Y (px) — 렌더러가 그릴 위치.
    pub fn thumbTop(self: Hit) f64 {
        return self.track_top + self.g.thumb_y_rel;
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
