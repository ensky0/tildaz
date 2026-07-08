//! 탭바 컨트롤 아이콘 (`< > × +`) 의 절차적 rasterizer — 폰트 독립 (#199 / #268).
//!
//! 아이콘 모양을 정규화 [0,1]² 선분(segment)으로 **한 번** 정의하고, 8-bit 알파
//! 커버리지 비트맵으로 rasterize 한다. 세 renderer (Linux software blit / macOS
//! Metal atlas / Windows D3D atlas) 가 *같은 비트맵* 을 폰트 glyph 처럼 그린다
//! → 세 platform 픽셀 동일 + 폰트를 바꿔도 모양 불변. 선 두께 / 크기를 pt 로
//! 완전 통제 (호출처가 `pt × scale` 로 size/stroke px 를 계산해 넘김).
//!
//! 이 모듈은 **scale 을 모른다** — px 단위 (size, stroke) 만 받는 순수 함수.
//! 탭바 텍스트를 `tab_layout.iterTabText` 공통 helper 로 그리는 것과 같은 결:
//! geometry 는 공통, 최종 blit 은 각 renderer 의 primitive.

const std = @import("std");

pub const Icon = enum { chevron_left, chevron_right, close, plus };

/// 정규화 좌표계 [0,1]² 의 선분. (0,0) = 좌상단, (1,1) = 우하단.
const Seg = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

/// rasterize 가 지원하는 최대 아이콘 한 변 (px). 호출처가 이 크기의 stack
/// 버퍼(`[MAX_SIZE * MAX_SIZE]u8`)를 잡아 넘기면 힙 할당 없이 그린다. 아이콘은
/// pt 기준 작아서 (≈11pt) scale 4x 여도 44px < 64.
pub const MAX_SIZE: u32 = 64;

// 광학 균형을 위해 모든 아이콘을 중심 (0.5,0.5) 기준 같은 "reach"(중심→끝점
// 거리 R) 로 설계한다. `+` 는 축 방향, `×` 는 대각선 방향 끝점이 *같은 반지름
// 원* 위에 놓여 시각적으로 같은 크기 (단순히 정사각 box 를 꽉 채우면 `×` 는
// 대각선이 √2 배라 `+` 보다 커 보임 — 폰트 디자이너가 하던 광학 보정을 우리가
// 직접). chevron 은 열린 모양이라 폭/높이를 따로 잡아 세로로만 길어 보이지 않게.
const R: f32 = 0.42; // `+` 팔 / `×` 대각선 끝점의 중심 거리 (box 반 = 0.5)
const D: f32 = R * 0.70710678; // `×` 대각선의 축 성분 (R/√2) — 끝점이 R 원 위
const CW: f32 = 0.30; // chevron 반너비
const CH: f32 = 0.34; // chevron 반높이 (폭 0.60 × 높이 0.68 — 살짝 세로 긴 꺾쇠)

/// 아이콘별 선분 정의 (정규화 [0,1]², 중심 0.5). 두께는 rasterize 의 stroke.
fn segsFor(icon: Icon) []const Seg {
    return switch (icon) {
        .plus => &[_]Seg{
            .{ .x0 = 0.5 - R, .y0 = 0.5, .x1 = 0.5 + R, .y1 = 0.5 },
            .{ .x0 = 0.5, .y0 = 0.5 - R, .x1 = 0.5, .y1 = 0.5 + R },
        },
        .close => &[_]Seg{
            .{ .x0 = 0.5 - D, .y0 = 0.5 - D, .x1 = 0.5 + D, .y1 = 0.5 + D },
            .{ .x0 = 0.5 - D, .y0 = 0.5 + D, .x1 = 0.5 + D, .y1 = 0.5 - D },
        },
        .chevron_left => &[_]Seg{
            .{ .x0 = 0.5 + CW, .y0 = 0.5 - CH, .x1 = 0.5 - CW, .y1 = 0.5 },
            .{ .x0 = 0.5 - CW, .y0 = 0.5, .x1 = 0.5 + CW, .y1 = 0.5 + CH },
        },
        .chevron_right => &[_]Seg{
            .{ .x0 = 0.5 - CW, .y0 = 0.5 - CH, .x1 = 0.5 + CW, .y1 = 0.5 },
            .{ .x0 = 0.5 + CW, .y0 = 0.5, .x1 = 0.5 - CW, .y1 = 0.5 + CH },
        },
    };
}

/// 점 (px,py) 에서 선분 (ax,ay)-(bx,by) 까지의 최단 거리. 선분 밖 투영은 끝점
/// 으로 clamp (둥근 cap). 모두 px 단위.
fn distToSeg(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 == 0.0) return std.math.hypot(px - ax, py - ay);
    var t = ((px - ax) * dx + (py - ay) * dy) / len2;
    t = std.math.clamp(t, 0.0, 1.0);
    const cx = ax + t * dx;
    const cy = ay + t * dy;
    return std.math.hypot(px - cx, py - cy);
}

/// `icon` 을 `size`×`size` 8-bit 알파 커버리지 비트맵으로 rasterize.
/// `out` 은 `size*size` 이상, `size` 는 `MAX_SIZE` 이하.
///
/// 각 픽셀의 커버리지 = 가장 가까운 선분까지 거리 기반 1px AA:
///   dist ≤ stroke/2       → 255 (선 안쪽)
///   dist ≥ stroke/2 + 1   → 0   (선 밖)
///   그 사이               → 선형 (경계 anti-alias)
/// 선분 좌표는 [0,1] → [stroke/2, size-stroke/2] 로 inset 해 두께가 box 안에
/// 온전히 들어가게 (끝단이 잘리지 않음).
pub fn rasterize(icon: Icon, size: u32, stroke_px: f32, out: []u8) void {
    std.debug.assert(size <= MAX_SIZE);
    std.debug.assert(out.len >= size * size);

    const segs = segsFor(icon);
    const stroke = @max(1.0, stroke_px);
    const half = stroke * 0.5;
    // 선분을 box 안쪽으로 half 만큼 inset — 두께가 [0,size] 를 벗어나지 않게.
    const span = @as(f32, @floatFromInt(size)) - stroke;
    const inset = half;

    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            var min_d: f32 = std.math.floatMax(f32);
            for (segs) |s| {
                const d = distToSeg(
                    px,
                    py,
                    inset + s.x0 * span,
                    inset + s.y0 * span,
                    inset + s.x1 * span,
                    inset + s.y1 * span,
                );
                if (d < min_d) min_d = d;
            }
            const cov = std.math.clamp(half + 0.5 - min_d, 0.0, 1.0);
            out[y * size + x] = @intFromFloat(cov * 255.0 + 0.5);
        }
    }
}

test "rasterize — 중심선이 채워지고 모서리는 비어야" {
    var buf: [MAX_SIZE * MAX_SIZE]u8 = undefined;
    const size: u32 = 20;
    rasterize(.plus, size, 2.0, &buf);
    // `+` 정중앙은 두 선 교차 → 완전 채움.
    const center = buf[(size / 2) * size + (size / 2)];
    try std.testing.expect(center > 250);
    // 좌상단 모서리는 어느 선에서도 멀어 비어 있어야.
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    // 수평선 위 (y=중앙, x=끝 근처) 는 채워짐.
    try std.testing.expect(buf[(size / 2) * size + (size - 2)] > 200);
}

test "rasterize — × 는 대각선, 축은 비어야" {
    var buf: [MAX_SIZE * MAX_SIZE]u8 = undefined;
    const size: u32 = 20;
    rasterize(.close, size, 2.0, &buf);
    // 대각선 중앙 = 완전 채움.
    try std.testing.expect(buf[(size / 2) * size + (size / 2)] > 250);
    // 수평 중앙선의 좌측 끝 (대각선에서 먼 곳) 은 비어야 — `+` 와 구분.
    try std.testing.expectEqual(@as(u8, 0), buf[(size / 2) * size + 1]);
}

test "rasterize — chevron 은 한쪽으로 열린 꺾쇠" {
    var buf: [MAX_SIZE * MAX_SIZE]u8 = undefined;
    const size: u32 = 20;
    rasterize(.chevron_left, size, 2.0, &buf);
    // `<` 의 꼭짓점은 좌측 중앙 (x≈0.3*span) → 채움.
    const apex_x: u32 = @intFromFloat(1.0 + 0.3 * (@as(f32, @floatFromInt(size)) - 2.0));
    try std.testing.expect(buf[(size / 2) * size + apex_x] > 150);
    // 우상단 모서리 안쪽(열린 쪽)은 비어야.
    try std.testing.expectEqual(@as(u8, 0), buf[(size / 2) * size + 1]);
}

test "rasterize — stroke 최소 1px 보장 (size 커도 안 사라짐)" {
    var buf: [MAX_SIZE * MAX_SIZE]u8 = undefined;
    const size: u32 = 16;
    rasterize(.plus, size, 0.0, &buf); // 0 → 1px 로 clamp
    // 1px 선은 정수 경계에 놓이면 AA 로 양옆 픽셀에 나뉘어 특정 픽셀 값은
    // 낮을 수 있음. "선이 사라지지 않았다" 는 전체 커버리지 합으로 검증
    // (`+` 두 선 ≈ 2×size 픽셀에 coverage 분포).
    var sum: u32 = 0;
    for (buf[0 .. size * size]) |v| sum += v;
    try std.testing.expect(sum > @as(u32, size) * 100);
}
