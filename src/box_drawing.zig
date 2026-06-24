// Unicode box-drawing (U+2500–U+257F) → cell 을 정확히 채우는 fg-색 사각형
// 집합. block_element.zig 와 같은 철학 — 폰트 글리프는 cell 너비/높이에 딱
// 안 맞아 인접 셀 사이 갭("울퉁불퉁")이 생기므로 폰트 fallback 대신 코드로
// 직접 그린다. (#258)
//
// 각 코드포인트를 상/하/좌/우 4 arm 으로 분해한다. arm 굵기는 light / heavy /
// double. 추가로 점선(dash 2/3/4) 과 둥근 모서리(rounded) 플래그. 모든 arm 은
// 중앙에서 셀 가장자리까지 뻗고, 중앙 교차부를 ext 만큼 겹쳐 채워 junction 에
// 구멍이 안 생기게 한다. 인접 셀이 같은 thickness / 중앙 정렬을 쓰므로 선이
// 셀 경계를 넘어 연속으로 이어진다.
//
// 대각선 ╱ ╲ ╳ (U+2571–2573) 는 axis-aligned 사각형으로 표현 못 해 null 반환
// → renderer 가 폰트 글리프로 fallback.
//
// Windows(d3d11) / macOS(Metal) / Linux(software) 세 renderer 가 공유. 좌표는
// "셀 좌상단 기준 픽셀" — renderer 는 cell origin 에 더해 그대로 그린다.

const std = @import("std");

/// 셀 좌상단(0,0) 기준 픽셀 사각형.
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// 한 글자당 최대 사각형 수. 둥근 모서리 호(arc) / 대각선은 작은 사각형
/// staircase 라 여유 있게. ╳(대각선 2개)는 각 절반 예산으로 적응형 step.
pub const MAX_RECTS = 64;

const W = enum { none, light, heavy, double };

const Desc = struct {
    up: W = .none,
    down: W = .none,
    left: W = .none,
    right: W = .none,
    /// 0 = solid, 2/3/4 = 점선 dash 개수. dash 는 직선(─/│)에만 적용.
    dash: u8 = 0,
    /// 둥근 모서리 ╭╮╯╰. 현재는 각진 모서리로 근사(연결은 정확). 시각 차이 미미.
    rounded: bool = false,
};

/// cp 가 box-drawing 으로 직접 그릴 수 있는 글자면 사각형들을 out 에 채우고
/// 개수를 반환. box-drawing 이 아니거나(대각선 포함) 표현 불가면 null →
/// renderer 가 폰트 글리프로 처리.
pub fn boxRects(cp: u21, cw: f32, ch: f32, out: *[MAX_RECTS]Rect) ?usize {
    var n: usize = 0;
    const push = struct {
        fn f(buf: *[MAX_RECTS]Rect, cnt: *usize, x: f32, y: f32, w: f32, h: f32) void {
            if (w <= 0 or h <= 0 or cnt.* >= MAX_RECTS) return;
            buf[cnt.*] = .{ .x = x, .y = y, .w = w, .h = h };
            cnt.* += 1;
        }
    }.f;

    // 대각선 ╱ ╲ ╳ — corner-to-corner 직선을 작은 사각형 staircase 로 근사.
    // (WT 는 stroked 직선; axis-aligned 사각형만 그리는 우리는 계단.) 모서리에서
    // 모서리로 가므로 인접 대각선 셀과 이어진다. 큰 셀에서도 MAX_RECTS 안에
    // 맞도록 row step 을 적응형으로.
    if (cp == 0x2571 or cp == 0x2572 or cp == 0x2573) {
        const t = lightPx(ch);
        const both = cp == 0x2573;
        const budget: f32 = if (both) @floatFromInt(MAX_RECTS / 2) else @floatFromInt(MAX_RECTS);
        const step = @max(1, @ceil(ch / budget));
        var y: f32 = 0;
        while (y < ch) : (y += step) {
            const frac = y / ch;
            const h = @min(step, ch - y);
            if (cp == 0x2572 or both) { // ╲ : (0,0)→(cw,ch)
                push(out, &n, @round(frac * cw - t / 2), @round(y), t, h);
            }
            if (cp == 0x2571 or both) { // ╱ : (0,ch)→(cw,0)
                push(out, &n, @round((1 - frac) * cw - t / 2), @round(y), t, h);
            }
        }
        return n;
    }

    const d = descFor(cp) orelse return null;

    const lt = lightPx(ch);
    const ht = heavyPx(ch);
    const cx = @round(cw / 2);
    const cy = @round(ch / 2);

    // 점선: 직선 한 방향에만 존재. 별도 처리 후 종료.
    if (d.dash >= 2) {
        const t = if (d.right == .heavy or d.down == .heavy) ht else lt;
        const horiz = d.left != .none or d.right != .none;
        const segs: f32 = @floatFromInt(d.dash);
        if (horiz) {
            const y = @round(cy - t / 2);
            const cell = cw / segs;
            const gap = @round(cell * 0.45);
            var i: f32 = 0;
            while (i < segs) : (i += 1) {
                const x0 = @round(i * cell + gap / 2);
                const x1 = @round((i + 1) * cell - gap / 2);
                push(out, &n, x0, y, x1 - x0, t);
            }
        } else {
            const x = @round(cx - t / 2);
            const cell = ch / segs;
            const gap = @round(cell * 0.45);
            var i: f32 = 0;
            while (i < segs) : (i += 1) {
                const y0 = @round(i * cell + gap / 2);
                const y1 = @round((i + 1) * cell - gap / 2);
                push(out, &n, x, y0, t, y1 - y0);
            }
        }
        return n;
    }

    // 둥근 모서리 ╭╮╯╰ — 사분원 호(arc). WT BuiltinGlyphs 와 동일 의도:
    // 두 arm 을 잇는 quarter-circle. 우리 파이프라인은 사각형만 그리므로 호를
    // 작은 사각형 staircase 로 근사한다. 반지름은 WT 식 r=min(lt*4, min(cw,ch)*0.4).
    if (d.rounded) {
        const t = lt;
        const hx: f32 = if (d.right != .none) 1 else -1; // right=+1, left=-1
        const vy: f32 = if (d.down != .none) 1 else -1; // down=+1, up=-1
        var r = @min(lt * 3, @min(cw, ch) * 0.32);
        if (r < 1) r = 1;
        const acx = cx + hx * r; // 호 중심
        const acy = cy + vy * r;

        // 세로 arm (x=cx 중앙), 호 끝점 (cx, cy+vy*r) 부터 edge 까지.
        {
            const ax = @round(cx - t / 2);
            if (vy > 0) {
                const y0 = @round(cy + r - t / 2);
                push(out, &n, ax, y0, t, ch - y0);
            } else {
                const y1 = @round(cy - r + t / 2);
                push(out, &n, ax, 0, t, y1);
            }
        }
        // 가로 arm (y=cy 중앙), 호 끝점 (cx+hx*r, cy) 부터 edge 까지.
        {
            const ay = @round(cy - t / 2);
            if (hx > 0) {
                const x0 = @round(cx + r - t / 2);
                push(out, &n, x0, ay, cw - x0, t);
            } else {
                const x1 = @round(cx - r + t / 2);
                push(out, &n, 0, ay, x1, t);
            }
        }
        // 호 staircase: a0(세로 join) → a1(가로 join), 90° sweep.
        const pi = std.math.pi;
        const a0: f32 = if (hx > 0) pi else 0;
        var a1: f32 = if (vy > 0) -(pi / 2.0) else (pi / 2.0);
        while (a1 - a0 > pi) a1 -= 2 * pi;
        while (a1 - a0 < -pi) a1 += 2 * pi;
        const steps: usize = @intFromFloat(@max(3, @round(r * 1.8)));
        var k: usize = 0;
        while (k <= steps) : (k += 1) {
            const f = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
            const th = a0 + (a1 - a0) * f;
            const px = acx + r * @cos(th);
            const py = acy + r * @sin(th);
            push(out, &n, @round(px - t / 2), @round(py - t / 2), t, t);
        }
        return n;
    }

    // 가로/세로선이 차지하는 폭(겹침 계산용): light=lt, heavy=ht, double=두 선+간격(3*lt).
    // 가로 arm 은 중앙에서 "세로선 폭의 절반(cross_h)"만큼만 넘어가 junction 을
    // 정확히 채운다. 그 이상 넘지 않으므로 모서리(┌)에서 빈 방향으로 삐져나오는
    // 뿔/1px 틈이 안 생긴다. (이전 ext 방식 버그 수정 — #258)
    const v_span = @max(spanOf(d.up, lt, ht), spanOf(d.down, lt, ht));
    const h_span = @max(spanOf(d.left, lt, ht), spanOf(d.right, lt, ht));
    const cross_h = v_span / 2; // 가로 arm 이 중앙을 넘는 양 (세로선 덮기)
    const cross_v = h_span / 2; // 세로 arm 이 중앙을 넘는 양 (가로선 덮기)

    // 가로 arm. double 이면 중앙 위/아래로 lt 만큼 떨어진 두 줄(가운데 lt 간격).
    if (d.right != .none) {
        const th = if (d.right == .heavy) ht else lt;
        const offs: []const f32 = if (d.right == .double) &.{ -lt, lt } else &.{0};
        for (offs) |oy| {
            const x0 = @round(cx - cross_h);
            push(out, &n, x0, @round(cy + oy - th / 2), cw - x0, th);
        }
    }
    if (d.left != .none) {
        const th = if (d.left == .heavy) ht else lt;
        const offs: []const f32 = if (d.left == .double) &.{ -lt, lt } else &.{0};
        for (offs) |oy| {
            push(out, &n, 0, @round(cy + oy - th / 2), @round(cx + cross_h), th);
        }
    }
    // 세로 arm.
    if (d.down != .none) {
        const th = if (d.down == .heavy) ht else lt;
        const offs: []const f32 = if (d.down == .double) &.{ -lt, lt } else &.{0};
        for (offs) |ox| {
            const y0 = @round(cy - cross_v);
            push(out, &n, @round(cx + ox - th / 2), y0, th, ch - y0);
        }
    }
    if (d.up != .none) {
        const th = if (d.up == .heavy) ht else lt;
        const offs: []const f32 = if (d.up == .double) &.{ -lt, lt } else &.{0};
        for (offs) |ox| {
            push(out, &n, @round(cx + ox - th / 2), 0, th, @round(cy + cross_v));
        }
    }

    return n;
}

fn spanOf(w: W, lt: f32, ht: f32) f32 {
    return switch (w) {
        .none => 0,
        .light => lt,
        .heavy => ht,
        .double => 3 * lt, // 두 선(각 lt) + 가운데 간격(lt)
    };
}

fn lightPx(ch: f32) f32 {
    return @max(1, @round(ch / 14));
}
fn heavyPx(ch: f32) f32 {
    return @max(2, @round(ch / 7));
}

/// U+2500–U+257F 의 arm 분해 테이블. 대각선(2571–2573) 은 null.
fn descFor(cp: u21) ?Desc {
    const L = W.light;
    const H = W.heavy;
    const D = W.double;
    return switch (cp) {
        // ── 직선 ──
        0x2500 => .{ .left = L, .right = L }, // ─
        0x2501 => .{ .left = H, .right = H }, // ━
        0x2502 => .{ .up = L, .down = L }, // │
        0x2503 => .{ .up = H, .down = H }, // ┃
        // ── 점선 가로/세로 ──
        0x2504 => .{ .left = L, .right = L, .dash = 3 }, // ┄
        0x2505 => .{ .left = H, .right = H, .dash = 3 }, // ┅
        0x2506 => .{ .up = L, .down = L, .dash = 3 }, // ┆
        0x2507 => .{ .up = H, .down = H, .dash = 3 }, // ┇
        0x2508 => .{ .left = L, .right = L, .dash = 4 }, // ┈
        0x2509 => .{ .left = H, .right = H, .dash = 4 }, // ┉
        0x250A => .{ .up = L, .down = L, .dash = 4 }, // ┊
        0x250B => .{ .up = H, .down = H, .dash = 4 }, // ┋
        // ── 모서리 (down+right / down+left / up+right / up+left), 굵기 4조합 ──
        0x250C => .{ .down = L, .right = L }, // ┌
        0x250D => .{ .down = L, .right = H }, // ┍
        0x250E => .{ .down = H, .right = L }, // ┎
        0x250F => .{ .down = H, .right = H }, // ┏
        0x2510 => .{ .down = L, .left = L }, // ┐
        0x2511 => .{ .down = L, .left = H }, // ┑
        0x2512 => .{ .down = H, .left = L }, // ┒
        0x2513 => .{ .down = H, .left = H }, // ┓
        0x2514 => .{ .up = L, .right = L }, // └
        0x2515 => .{ .up = L, .right = H }, // ┕
        0x2516 => .{ .up = H, .right = L }, // ┖
        0x2517 => .{ .up = H, .right = H }, // ┗
        0x2518 => .{ .up = L, .left = L }, // ┘
        0x2519 => .{ .up = L, .left = H }, // ┙
        0x251A => .{ .up = H, .left = L }, // ┚
        0x251B => .{ .up = H, .left = H }, // ┛
        // ── T (vertical + right) ┝ 계열 ──
        0x251C => .{ .up = L, .down = L, .right = L }, // ├
        0x251D => .{ .up = L, .down = L, .right = H }, // ┝
        0x251E => .{ .up = H, .down = L, .right = L }, // ┞
        0x251F => .{ .up = L, .down = H, .right = L }, // ┟
        0x2520 => .{ .up = H, .down = H, .right = L }, // ┠
        0x2521 => .{ .up = H, .down = L, .right = H }, // ┡
        0x2522 => .{ .up = L, .down = H, .right = H }, // ┢
        0x2523 => .{ .up = H, .down = H, .right = H }, // ┣
        // ── T (vertical + left) ┤ 계열 ──
        0x2524 => .{ .up = L, .down = L, .left = L }, // ┤
        0x2525 => .{ .up = L, .down = L, .left = H }, // ┥
        0x2526 => .{ .up = H, .down = L, .left = L }, // ┦
        0x2527 => .{ .up = L, .down = H, .left = L }, // ┧
        0x2528 => .{ .up = H, .down = H, .left = L }, // ┨
        0x2529 => .{ .up = H, .down = L, .left = H }, // ┩
        0x252A => .{ .up = L, .down = H, .left = H }, // ┪
        0x252B => .{ .up = H, .down = H, .left = H }, // ┫
        // ── T (horizontal + down) ┬ 계열 ──
        0x252C => .{ .left = L, .right = L, .down = L }, // ┬
        0x252D => .{ .left = H, .right = L, .down = L }, // ┭
        0x252E => .{ .left = L, .right = H, .down = L }, // ┮
        0x252F => .{ .left = H, .right = H, .down = L }, // ┯
        0x2530 => .{ .left = L, .right = L, .down = H }, // ┰
        0x2531 => .{ .left = H, .right = L, .down = H }, // ┱
        0x2532 => .{ .left = L, .right = H, .down = H }, // ┲
        0x2533 => .{ .left = H, .right = H, .down = H }, // ┳
        // ── T (horizontal + up) ┴ 계열 ──
        0x2534 => .{ .left = L, .right = L, .up = L }, // ┴
        0x2535 => .{ .left = H, .right = L, .up = L }, // ┵
        0x2536 => .{ .left = L, .right = H, .up = L }, // ┶
        0x2537 => .{ .left = H, .right = H, .up = L }, // ┷
        0x2538 => .{ .left = L, .right = L, .up = H }, // ┸
        0x2539 => .{ .left = H, .right = L, .up = H }, // ┹
        0x253A => .{ .left = L, .right = H, .up = H }, // ┺
        0x253B => .{ .left = H, .right = H, .up = H }, // ┻
        // ── 십자 ┼ 계열 ──
        0x253C => .{ .up = L, .down = L, .left = L, .right = L }, // ┼
        0x253D => .{ .up = L, .down = L, .left = H, .right = L }, // ┽
        0x253E => .{ .up = L, .down = L, .left = L, .right = H }, // ┾
        0x253F => .{ .up = L, .down = L, .left = H, .right = H }, // ┿
        0x2540 => .{ .up = H, .down = L, .left = L, .right = L }, // ╀
        0x2541 => .{ .up = L, .down = H, .left = L, .right = L }, // ╁
        0x2542 => .{ .up = H, .down = H, .left = L, .right = L }, // ╂
        0x2543 => .{ .up = H, .down = L, .left = H, .right = L }, // ╃
        0x2544 => .{ .up = H, .down = L, .left = L, .right = H }, // ╄
        0x2545 => .{ .up = L, .down = H, .left = H, .right = L }, // ╅
        0x2546 => .{ .up = L, .down = H, .left = L, .right = H }, // ╆
        0x2547 => .{ .up = H, .down = L, .left = H, .right = H }, // ╇
        0x2548 => .{ .up = L, .down = H, .left = H, .right = H }, // ╈
        0x2549 => .{ .up = H, .down = H, .left = H, .right = L }, // ╉
        0x254A => .{ .up = H, .down = H, .left = L, .right = H }, // ╊
        0x254B => .{ .up = H, .down = H, .left = H, .right = H }, // ╋
        // ── 2-dash 가로/세로 ──
        0x254C => .{ .left = L, .right = L, .dash = 2 }, // ╌
        0x254D => .{ .left = H, .right = H, .dash = 2 }, // ╍
        0x254E => .{ .up = L, .down = L, .dash = 2 }, // ╎
        0x254F => .{ .up = H, .down = H, .dash = 2 }, // ╏
        // ── 이중선 ──
        0x2550 => .{ .left = D, .right = D }, // ═
        0x2551 => .{ .up = D, .down = D }, // ║
        0x2552 => .{ .down = L, .right = D }, // ╒
        0x2553 => .{ .down = D, .right = L }, // ╓
        0x2554 => .{ .down = D, .right = D }, // ╔
        0x2555 => .{ .down = L, .left = D }, // ╕
        0x2556 => .{ .down = D, .left = L }, // ╖
        0x2557 => .{ .down = D, .left = D }, // ╗
        0x2558 => .{ .up = L, .right = D }, // ╘
        0x2559 => .{ .up = D, .right = L }, // ╙
        0x255A => .{ .up = D, .right = D }, // ╚
        0x255B => .{ .up = L, .left = D }, // ╛
        0x255C => .{ .up = D, .left = L }, // ╜
        0x255D => .{ .up = D, .left = D }, // ╝
        0x255E => .{ .up = L, .down = L, .right = D }, // ╞
        0x255F => .{ .up = D, .down = D, .right = L }, // ╟
        0x2560 => .{ .up = D, .down = D, .right = D }, // ╠
        0x2561 => .{ .up = L, .down = L, .left = D }, // ╡
        0x2562 => .{ .up = D, .down = D, .left = L }, // ╢
        0x2563 => .{ .up = D, .down = D, .left = D }, // ╣
        0x2564 => .{ .left = D, .right = D, .down = L }, // ╤
        0x2565 => .{ .left = L, .right = L, .down = D }, // ╥
        0x2566 => .{ .left = D, .right = D, .down = D }, // ╦
        0x2567 => .{ .left = D, .right = D, .up = L }, // ╧
        0x2568 => .{ .left = L, .right = L, .up = D }, // ╨
        0x2569 => .{ .left = D, .right = D, .up = D }, // ╩
        0x256A => .{ .up = L, .down = L, .left = D, .right = D }, // ╪
        0x256B => .{ .up = D, .down = D, .left = L, .right = L }, // ╫
        0x256C => .{ .up = D, .down = D, .left = D, .right = D }, // ╬
        // ── 둥근 모서리 (각진 근사) ──
        0x256D => .{ .down = L, .right = L, .rounded = true }, // ╭
        0x256E => .{ .down = L, .left = L, .rounded = true }, // ╮
        0x256F => .{ .up = L, .left = L, .rounded = true }, // ╯
        0x2570 => .{ .up = L, .right = L, .rounded = true }, // ╰
        // ── 대각선: boxRects 상단에서 staircase 로 별도 처리 (여기 도달 안 함) ──
        0x2571, 0x2572, 0x2573 => null, // ╱ ╲ ╳
        // ── 짧은 stub (한 방향) ──
        0x2574 => .{ .left = L }, // ╴
        0x2575 => .{ .up = L }, // ╵
        0x2576 => .{ .right = L }, // ╶
        0x2577 => .{ .down = L }, // ╷
        0x2578 => .{ .left = H }, // ╸
        0x2579 => .{ .up = H }, // ╹
        0x257A => .{ .right = H }, // ╺
        0x257B => .{ .down = H }, // ╻
        // ── 혼합 굵기 직선 ──
        0x257C => .{ .left = L, .right = H }, // ╼
        0x257D => .{ .up = L, .down = H }, // ╽
        0x257E => .{ .left = H, .right = L }, // ╾
        0x257F => .{ .up = H, .down = L }, // ╿
        else => null,
    };
}

/// renderer 분기용 — cp 가 box-drawing 범위인지. 대각선 포함 전 범위 그린다.
pub fn isBoxDrawing(cp: u21) bool {
    return cp >= 0x2500 and cp <= 0x257F;
}

// ───────────────────────── tests ─────────────────────────

test "straight horizontal fills full width, connects across cells" {
    var buf: [MAX_RECTS]Rect = undefined;
    const n = boxRects(0x2500, 10, 20, &buf).?; // ─
    try std.testing.expect(n >= 1);
    // 좌/우 arm 합쳐 x=0 부터 x=cw 까지 덮여야 (셀 경계 연속).
    var min_x: f32 = 999;
    var max_x: f32 = -999;
    for (buf[0..n]) |r| {
        min_x = @min(min_x, r.x);
        max_x = @max(max_x, r.x + r.w);
    }
    try std.testing.expectEqual(@as(f32, 0), min_x);
    try std.testing.expectEqual(@as(f32, 10), max_x);
}

test "straight vertical fills full height" {
    var buf: [MAX_RECTS]Rect = undefined;
    const n = boxRects(0x2502, 10, 20, &buf).?; // │
    var min_y: f32 = 999;
    var max_y: f32 = -999;
    for (buf[0..n]) |r| {
        min_y = @min(min_y, r.y);
        max_y = @max(max_y, r.y + r.h);
    }
    try std.testing.expectEqual(@as(f32, 0), min_y);
    try std.testing.expectEqual(@as(f32, 20), max_y);
}

test "corner has both arms reaching their edges" {
    var buf: [MAX_RECTS]Rect = undefined;
    const n = boxRects(0x250C, 10, 20, &buf).?; // ┌ down+right
    var reaches_right = false;
    var reaches_bottom = false;
    for (buf[0..n]) |r| {
        if (r.x + r.w >= 10) reaches_right = true;
        if (r.y + r.h >= 20) reaches_bottom = true;
    }
    try std.testing.expect(reaches_right);
    try std.testing.expect(reaches_bottom);
}

test "cross emits 4 arms spanning full width and height" {
    var buf: [MAX_RECTS]Rect = undefined;
    const n = boxRects(0x253C, 10, 20, &buf).?; // ┼
    try std.testing.expectEqual(@as(usize, 4), n);
}

test "double horizontal emits two parallel lines" {
    var buf: [MAX_RECTS]Rect = undefined;
    const n = boxRects(0x2550, 10, 20, &buf).?; // ═
    try std.testing.expectEqual(@as(usize, 4), n); // 좌2 + 우2
}

test "triple dash emits 3 segments" {
    var buf: [MAX_RECTS]Rect = undefined;
    const n = boxRects(0x2504, 30, 20, &buf).?; // ┄
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "diagonals are drawn as staircase, corner to corner, within MAX_RECTS" {
    var buf: [MAX_RECTS]Rect = undefined;
    for ([_]u21{ 0x2571, 0x2572, 0x2573 }) |cp| {
        const n = boxRects(cp, 10, 20, &buf).?;
        try std.testing.expect(n > 3 and n <= MAX_RECTS);
    }
    // ╲ 는 (0,0) 근처에서 시작해 (cw,ch) 근처에서 끝나야 (corner-to-corner).
    const n = boxRects(0x2572, 10, 20, &buf).?;
    var near_tl = false;
    var near_br = false;
    for (buf[0..n]) |r| {
        if (r.x <= 2 and r.y <= 2) near_tl = true;
        if (r.x + r.w >= 8 and r.y + r.h >= 18) near_br = true;
    }
    try std.testing.expect(near_tl and near_br);
}

test "huge cell diagonals stay within MAX_RECTS (adaptive step)" {
    var buf: [MAX_RECTS]Rect = undefined;
    const n = boxRects(0x2573, 80, 200, &buf).?; // ╳ 큰 셀
    try std.testing.expect(n <= MAX_RECTS);
}

test "non box-drawing returns null" {
    var buf: [MAX_RECTS]Rect = undefined;
    try std.testing.expect(boxRects('A', 10, 20, &buf) == null);
    try std.testing.expect(boxRects(0x2588, 10, 20, &buf) == null); // 블록(block_element 담당)
}

test "rounded corner draws an arc (more than 2 rects) and reaches both edges" {
    var buf: [MAX_RECTS]Rect = undefined;
    const n = boxRects(0x256D, 10, 20, &buf).?; // ╭ down+right
    // arm 2개 + 호 여러 조각 → 각진 모서리(2개)보다 많아야 한다.
    try std.testing.expect(n > 3);
    var reaches_right = false;
    var reaches_bottom = false;
    for (buf[0..n]) |r| {
        if (r.x + r.w >= 10) reaches_right = true;
        if (r.y + r.h >= 20) reaches_bottom = true;
    }
    try std.testing.expect(reaches_right and reaches_bottom);
}

test "all four rounded corners produce an arc" {
    var buf: [MAX_RECTS]Rect = undefined;
    for ([_]u21{ 0x256D, 0x256E, 0x256F, 0x2570 }) |cp| {
        const n = boxRects(cp, 16, 16, &buf).?;
        try std.testing.expect(n > 3);
    }
}

test "isBoxDrawing covers full range incl diagonals, excludes blocks" {
    try std.testing.expect(isBoxDrawing(0x2500));
    try std.testing.expect(isBoxDrawing(0x256D));
    try std.testing.expect(isBoxDrawing(0x2571)); // 대각선도 그린다
    try std.testing.expect(!isBoxDrawing(0x2588)); // 블록(block_element 담당)
    try std.testing.expect(!isBoxDrawing('A'));
}
