//! #343 — chrome 그리기의 공통 사각형 타입과 정수 스냅 규칙.
//!
//! 탭바 (`tab_chrome`) · 터미널 scrollbar (`scrollbar`) · command menu
//! (`command_menu`) 가 모두 "색칠된 사각형 목록" 을 만들고 renderer 는 자기 형식으로
//! 옮기기만 한다. 그 사각형 타입이 여기 한 곳에 있다 — 세 모듈이 서로를 import
//! 하지 않게 하려는 것이다 (scrollbar 가 tab_chrome 을 참조하면 방향이 거꾸로다).

const std = @import("std");

/// device pixel 단위 사각형. 색은 `chrome_palette` 와 같은 `[4]f32`.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
};

/// #357 — rect 를 **정수 device pixel 격자에 맞춘다** (양 끝 각각 반올림).
///
/// 공통 모듈이 정수 좌표를 내보내면 세 platform 이 같은 픽셀을 그린다:
///   - GPU (macOS · Windows) 는 픽셀 중심이 도형 안일 때 칠한다 —
///     `k + 0.5 ∈ [x, x+w)`. `x` · `w` 가 정수면 정확히 `x … x+w−1`.
///   - Linux software 는 `snap` 후 `[x, x+w)` 를 칠한다. `@round` 가 정수에
///     항등이라 역시 `x … x+w−1`.
/// 소수 좌표에서는 이 둘의 tie-break 가 갈렸다 — 홀수 두께 선이 Linux 는 픽셀 `B`,
/// mac/win 은 `B−1` (Windows 실측: 배율 100% 탭 구분선이 149/299/449).
///
/// 두께를 정수로 만든 `ui_metrics.linePx` 와 같은 논증의 **위치 판**이다. 두 규칙이
/// 함께 있어야 "같은 두께가 같은 자리에" 가 성립한다.
///
/// 부수 효과 — Linux 의 `snap` 이 no-op 이 되므로 [#277](https://github.com/ensky0/tildaz/issues/277)
/// 로 software renderer 를 EGL/OpenGL ES(f32) 로 옮겨도 픽셀이 흔들리지 않는다.
pub fn snapped(r: Rect) Rect {
    const x0 = @round(r.x);
    const y0 = @round(r.y);
    return .{
        .x = x0,
        .y = y0,
        .w = @max(1, @round(r.x + r.w) - x0),
        .h = @max(1, @round(r.y + r.h) - y0),
        .color = r.color,
    };
}

pub const IRect = struct { x: i32, y: i32, w: i32, h: i32 };

/// 정수 rasterizer (Linux software renderer) 전용 변환. **양 끝을 각각 반올림한 뒤
/// 크기를 뺀다** — 위치와 크기를 따로 절단하면 오차가 누적돼 아랫변이 1px 모자란다
/// ([#344](https://github.com/ensky0/tildaz/issues/344) 에서 scrollbar thumb 이
/// 실제로 그랬다). `scrollbar.thumbPx` 와 같은 계약이다.
///
/// [#277](https://github.com/ensky0/tildaz/issues/277) 이 Linux 를 EGL/OpenGL ES
/// (f32) 로 바꾸면 **이 함수와 그 호출부만** 걷어내면 된다 — rect 목록을 만드는
/// 코드는 그대로 남는다.
pub fn snap(r: Rect) IRect {
    const x0 = @round(r.x);
    const y0 = @round(r.y);
    const x1 = @round(r.x + r.w);
    const y1 = @round(r.y + r.h);
    return .{
        .x = @intFromFloat(x0),
        .y = @intFromFloat(y0),
        .w = @max(1, @as(i32, @intFromFloat(x1 - x0))),
        .h = @max(1, @as(i32, @intFromFloat(y1 - y0))),
    };
}

const testing = std.testing;

test "snap — 양 끝을 각각 반올림한다 (아랫변 보존)" {
    // 0.4 에서 시작해 높이 10.2 → 아랫변 10.6. 각각 반올림하면 0..11 = 11.
    // 위치·크기를 따로 절단하면 0 + 10 = 10 으로 아랫변이 모자란다 (#344).
    const r = Rect{ .x = 0, .y = 0.4, .w = 5, .h = 10.2, .color = .{ 0, 0, 0, 1 } };
    const i = snap(r);
    try testing.expectEqual(@as(i32, 0), i.y);
    try testing.expectEqual(@as(i32, 11), i.h);
}

test "snap — 폭 0 이어도 최소 1px" {
    const r = Rect{ .x = 3.2, .y = 0, .w = 0.1, .h = 0.1, .color = .{ 0, 0, 0, 1 } };
    const i = snap(r);
    try testing.expectEqual(@as(i32, 1), i.w);
    try testing.expectEqual(@as(i32, 1), i.h);
}

test "#357 snapped — 정수 rect 는 그대로, 소수는 양 끝 반올림" {
    const c = [4]f32{ 0, 0, 0, 1 };
    // 정수 입력은 항등 (Linux 픽셀 불변의 근거).
    const same = snapped(.{ .x = 150, .y = 0, .w = 1, .h = 28, .color = c });
    try testing.expectEqual(@as(f32, 150), same.x);
    try testing.expectEqual(@as(f32, 1), same.w);
    // 홀수 두께 선의 중심 정렬 — 149.5 .. 150.5 → 150, 폭 1 (Linux 값).
    const line = snapped(.{ .x = 149.5, .y = 0, .w = 1, .h = 28, .color = c });
    try testing.expectEqual(@as(f32, 150), line.x);
    try testing.expectEqual(@as(f32, 1), line.w);
    // 폭이 0 으로 무너지지 않는다.
    const thin = snapped(.{ .x = 10.2, .y = 0, .w = 0.1, .h = 0.1, .color = c });
    try testing.expectEqual(@as(f32, 1), thin.w);
    try testing.expectEqual(@as(f32, 1), thin.h);
}

test "#357 snapped 뒤에는 snap 이 no-op 이다 (#277 대비)" {
    const c = [4]f32{ 0, 0, 0, 1 };
    const r = snapped(.{ .x = 40.8, .y = 0.6, .w = 187.5, .h = 47.6, .color = c });
    const i = snap(r);
    try testing.expectEqual(@as(i32, @intFromFloat(r.x)), i.x);
    try testing.expectEqual(@as(i32, @intFromFloat(r.w)), i.w);
    try testing.expectEqual(@as(i32, @intFromFloat(r.y)), i.y);
    try testing.expectEqual(@as(i32, @intFromFloat(r.h)), i.h);
}
