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
// 대각선 ╱ ╲ ╳ (U+2571–2573) 도 여기서 그린다 — axis-aligned 사각형으로는 안 되지만
// 픽셀별 AA coverage (`Rect.cov`) 로 래스터한다. (이 주석은 "null 반환 → 폰트
// fallback" 이라고 적혀 있었는데 아래 코드와 어긋난 채였다. #534 에서 바로잡음.)
//
// powerline (U+E0B0–E0BF) 도 같은 이유로 여기서 그린다 (#534) — Nerd Font 계열에만
// 있는 PUA 대역이라 기본 폰트 묶음에 없으면 물음표 네모로 나왔다.
//
// Windows(d3d11) / macOS(Metal) / Linux(software) 세 renderer 가 공유. 좌표는
// "셀 좌상단 기준 픽셀" — renderer 는 cell origin 에 더해 그대로 그린다.

const std = @import("std");

/// 셀 좌상단(0,0) 기준 픽셀 사각형. cov = 0~1 coverage (anti-alias 용 알파).
/// 직선/모서리 등 axis-aligned 는 cov=1(crisp). 곡선(호)·대각선은 픽셀별 cov<1
/// 로 AA. renderer 는 cov 를 인스턴스 알파로 써서 배경과 blend 한다.
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32, cov: f32 = 1 };

/// 한 글자당 최대 사각형 수. 호·대각선 AA 는 픽셀별 사각형이라 큰 셀에서 수가
/// 늘어 넉넉히. (╳ 대각선 2개가 가장 많음.)
pub const MAX_RECTS = 384;

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
            buf[cnt.*] = .{ .x = x, .y = y, .w = w, .h = h, .cov = 1 };
            cnt.* += 1;
        }
    }.f;
    // 1px AA 픽셀 — coverage 알파. (호/대각선 edge 부드럽게)
    const pix = struct {
        fn f(buf: *[MAX_RECTS]Rect, cnt: *usize, px: f32, py: f32, cov: f32) void {
            if (cov <= 0.02 or cnt.* >= MAX_RECTS) return;
            buf[cnt.*] = .{ .x = px, .y = py, .w = 1, .h = 1, .cov = @min(1, cov) };
            cnt.* += 1;
        }
    }.f;

    // 선 두께 — WT BuiltinGlyphs 와 동일: 가는선 = max(1, round(셀너비/6)),
    // 굵은선 = 가는선 × 2. (이전엔 셀높이/14 기준이라 WT 보다 얇았음.)
    const lt = lightPx(cw);
    const ht = lt * 2;

    // 대각선 ╱ ╲ ╳ — corner-to-corner 직선을 픽셀별 AA coverage 로 래스터.
    // 무한직선까지의 수직거리로 coverage = saturate(hw + 0.5 - dist). 모서리에서
    // 모서리로 가 인접 대각선 셀과 이어진다.
    if (cp == 0x2571 or cp == 0x2572 or cp == 0x2573) {
        const hw = lt / 2; // half-width
        const bs = cp == 0x2572 or cp == 0x2573; // ╲ : (0,0)→(cw,ch)
        const sl = cp == 0x2571 or cp == 0x2573; // ╱ : (0,ch)→(cw,0)
        var py: f32 = 0;
        while (py < ch) : (py += 1) {
            var px: f32 = 0;
            while (px < cw) : (px += 1) {
                const qx = px + 0.5;
                const qy = py + 0.5;
                var cov: f32 = 0;
                if (bs) cov = @max(cov, lineCov(qx, qy, 0, 0, cw, ch, hw));
                if (sl) cov = @max(cov, lineCov(qx, qy, 0, ch, cw, 0, hw));
                pix(out, &n, px, py, cov);
            }
        }
        return n;
    }

    // powerline (U+E0B0–E0BF) — #534. 두 갈래로 나눠 그린다.
    //
    //   * **선 계열** (꺾쇠 E0B1·E0B3, 대각선 E0B9·E0BB·E0BD·E0BF) — 위 대각선과 같은
    //     픽셀별 AA. 선 주변만 emit 하므로 개수가 둘레에 비례한다.
    //   * **면 계열** (채움 삼각형 · 반타원, 그리고 호 E0B5·E0B7) — 행마다 덮이는 x 구간을
    //     구해 **속은 cov=1 사각형 하나**로, **가장자리만 AA 픽셀**로 낸다.
    //
    // 면을 픽셀별로 내면 안 되는 이유가 둘이다. (1) `MAX_RECTS` 를 넘는다 — 셀 20×40 이면
    // 채움 면적만 ~400 픽셀이다. (2) 속 사각형이 AA 픽셀을 덮으면 **한 픽셀이 두 번**
    // 그려진다. renderer 는 coverage 를 배경과 *미리* 합성하고 그것이 순차 blend 와 같다는
    // 전제로 도는데 (`software_terminal.zig` 의 emit 주석), 겹치면 그 픽셀만 진해진다.
    // 그래서 속 사각형은 AA 밴드 **앞에서 멈춘다.**
    if (cp >= 0xE0B0 and cp <= 0xE0BF) {
        const t = lightPx(cw);
        if (isPowerlineLine(cp)) {
            const hw = t / 2;
            var py: f32 = 0;
            while (py < ch) : (py += 1) {
                var px: f32 = 0;
                while (px < cw) : (px += 1) {
                    pix(out, &n, px, py, powerlineLineCov(cp, px + 0.5, py + 0.5, cw, ch, hw));
                }
            }
            return n;
        }
        const sub: f32 = 4; // 행당 세로 서브샘플. 가장자리가 가로에 가까울 때도 AA 가 성립한다.
        var py: f32 = 0;
        while (py < ch) : (py += 1) {
            // 이 행에서 좌·우 가장자리가 쓸고 지나가는 범위를 먼저 잡는다.
            var lmin: f32 = cw;
            var lmax: f32 = 0;
            var rmin: f32 = cw;
            var rmax: f32 = 0;
            var s: f32 = 0;
            while (s < sub) : (s += 1) {
                const sp = powerlineSpan(cp, py + (s + 0.5) / sub, cw, ch, t);
                const l = @max(0, @min(cw, sp.l));
                const r = @max(0, @min(cw, sp.r));
                lmin = @min(lmin, l);
                lmax = @max(lmax, l);
                rmin = @min(rmin, r);
                rmax = @max(rmax, r);
            }
            if (rmax <= lmin) continue; // 이 행은 비었다
            const b0 = @max(0, @floor(lmin));
            const b1 = @min(cw, @ceil(rmax));
            const sl = @ceil(lmax);
            const sr = @floor(rmin);
            // 속과 밴드가 **겹치지 않게** 열 범위를 나눈다. 속이 없으면 밴드 하나로 합친다.
            var ranges: [2][2]f32 = undefined;
            var range_n: usize = 0;
            if (sr > sl) {
                push(out, &n, sl, py, sr - sl, 1);
                ranges[0] = .{ b0, sl };
                ranges[1] = .{ sr, b1 };
                range_n = 2;
            } else {
                ranges[0] = .{ b0, b1 };
                range_n = 1;
            }
            for (ranges[0..range_n]) |rg| {
                var c: f32 = rg[0];
                while (c < rg[1]) : (c += 1) {
                    // 열 하나의 coverage = 서브행마다의 가로 겹침을 평균낸 값.
                    var acc: f32 = 0;
                    var s2: f32 = 0;
                    while (s2 < sub) : (s2 += 1) {
                        const sp = powerlineSpan(cp, py + (s2 + 0.5) / sub, cw, ch, t);
                        const l = @max(0, @min(cw, sp.l));
                        const r = @max(0, @min(cw, sp.r));
                        acc += @max(0, @min(c + 1, r) - @max(c, l));
                    }
                    pix(out, &n, c, py, acc / sub);
                }
            }
        }
        return n;
    }

    const d = descFor(cp) orelse return null;

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
            const gap = @round(cell / 3.0); // WT 식 dash:gap ≈ 2:1
            var i: f32 = 0;
            while (i < segs) : (i += 1) {
                const x0 = @round(i * cell + gap / 2);
                const x1 = @round((i + 1) * cell - gap / 2);
                push(out, &n, x0, y, x1 - x0, t);
            }
        } else {
            const x = @round(cx - t / 2);
            const cell = ch / segs;
            const gap = @round(cell / 3.0); // WT 식 dash:gap ≈ 2:1
            var i: f32 = 0;
            while (i < segs) : (i += 1) {
                const y0 = @round(i * cell + gap / 2);
                const y1 = @round((i + 1) * cell - gap / 2);
                push(out, &n, x, y0, t, y1 - y0);
            }
        }
        return n;
    }

    // 둥근 모서리 ╭╮╯╰ — WT 처럼 "직선 arm + 사분원 호 + 직선 arm" 을 **하나의
    // 연속 stroke** 로 그린다. 경로까지의 최소 거리로 픽셀별 coverage 를 구하므로
    // (arc 와 arm 을 따로 그릴 때 생기던) 이음새 뿔이 원천적으로 없다.
    // WT BuiltinGlyphs: DrawRoundedRectangle(중심→모서리, cornerRadius). 동등.
    if (d.rounded) {
        const hw = lt / 2; // stroke half-width
        const hx: f32 = if (d.right != .none) 1 else -1; // right=+1, left=-1
        const vy: f32 = if (d.down != .none) 1 else -1; // down=+1, up=-1
        var r = @min(lt * 5, @min(cw, ch) * 0.5);
        if (r < 1) r = 1;
        // 중심선을 *픽셀 중심*에 정렬 — crisp-rect 와 같은 위치(round(c-lt/2)+lt/2).
        // 정수 좌표에 두면 1px 선이 두 픽셀에 50%씩 걸쳐 흐려지므로(straddle) 필수.
        const xc = @round(cx - lt / 2) + lt / 2;
        const yc = @round(cy - lt / 2) + lt / 2;
        const acx = xc + hx * r; // 호 중심
        const acy = yc + vy * r;
        // 세로 arm: x=xc, y ∈ [v_lo,v_hi] (호 끝점에서 가장자리까지, tangent 연결).
        const v_lo = if (vy > 0) yc + r else 0;
        const v_hi = if (vy > 0) ch else yc - r;
        // 가로 arm: y=yc, x ∈ [h_lo,h_hi].
        const h_lo = if (hx > 0) xc + r else 0;
        const h_hi = if (hx > 0) cw else xc - r;

        var py: f32 = 0;
        while (py < ch) : (py += 1) {
            var px: f32 = 0;
            while (px < cw) : (px += 1) {
                const qx = px + 0.5;
                const qy = py + 0.5;
                // 세로 arm 까지 거리 (점-선분).
                const vyc = @max(v_lo, @min(v_hi, qy));
                const dV = @sqrt((qx - xc) * (qx - xc) + (qy - vyc) * (qy - vyc));
                // 가로 arm 까지 거리.
                const hxc = @max(h_lo, @min(h_hi, qx));
                const dH = @sqrt((qx - hxc) * (qx - hxc) + (qy - yc) * (qy - yc));
                // 호까지 거리 (elbow 사분면에서만; 밖은 arm 이 담당).
                const dx = qx - acx;
                const dy = qy - acy;
                var dA: f32 = 1e9;
                if (dx * hx <= 0 and dy * vy <= 0) {
                    dA = @abs(@sqrt(dx * dx + dy * dy) - r);
                }
                const dist = @min(dV, @min(dH, dA));
                pix(out, &n, px, py, hw + 0.5 - dist);
            }
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

/// 점 (qx,qy) 의 직선 (ax,ay)-(bx,by) 에 대한 AA coverage.
/// 무한직선까지 수직거리 dist → saturate(hw + 0.5 - dist). (대각선용)
fn lineCov(qx: f32, qy: f32, ax: f32, ay: f32, bx: f32, by: f32, hw: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.0001) return 0;
    const dist = @abs((qx - ax) * dy - (qy - ay) * dx) / len;
    return @max(0, @min(1, hw + 0.5 - dist));
}

/// 가는 선 두께(px). WT BuiltinGlyphs: max(1, round(cellWidth/6)). 굵은선은 호출처에서 ×2.
fn lightPx(w: f32) f32 {
    return @max(1, @round(w / 6));
}

// ── powerline (U+E0B0–E0BF) 기하 (#534) ────────────────────────────────────
//
// 모양은 추측하지 않고 `MesloLGS Nerd Font Mono` 를 크게 렌더해 잉크 범위 기준으로
// 확정했다 (#534 코멘트에 표가 있다). 요약하면:
//
//   E0B0 · E0B2   꼭짓점이 세로 중앙인 채움 삼각형 (→ · ←)
//   E0B1 · E0B3   그 꺾쇠 (선분 둘)
//   E0B4 · E0B6   채움 반타원 — 반지름 (cw, ch/2), 평평한 쪽이 반대편
//   E0B5 · E0B7   그 호 — 바깥 타원에서 안쪽 타원을 뺀 띠
//   E0B8·E0BA·E0BC·E0BE  네 모서리 채움 삼각형
//   E0B9·E0BB·E0BD·E0BF  그 빗변. 실측상 E0B9 ≡ E0BF, E0BB ≡ E0BD 로 방향이 같다

/// 선으로 그리는 powerline 인가 (면이 아니라).
fn isPowerlineLine(cp: u21) bool {
    return switch (cp) {
        0xE0B1, 0xE0B3, 0xE0B9, 0xE0BB, 0xE0BD, 0xE0BF => true,
        else => false,
    };
}

fn powerlineLineCov(cp: u21, qx: f32, qy: f32, cw: f32, ch: f32, hw: f32) f32 {
    const hy = ch / 2;
    return switch (cp) {
        // 꺾쇠 — 두 선분이 세로 중앙에서 만난다. 무한직선 거리를 쓰면 ✕ 가 되므로 선분 거리다.
        0xE0B1 => @max(segCov(qx, qy, 0, 0, cw, hy, hw), segCov(qx, qy, cw, hy, 0, ch, hw)),
        0xE0B3 => @max(segCov(qx, qy, cw, 0, 0, hy, hw), segCov(qx, qy, 0, hy, cw, ch, hw)),
        // 모서리 대각선 — 셀을 모서리에서 모서리로 가로지르므로 무한직선 거리로 충분하다
        // (위 U+2571–2573 과 같은 이유). 인접 셀의 대각선과 그대로 이어진다.
        0xE0B9, 0xE0BF => lineCov(qx, qy, 0, 0, cw, ch, hw),
        0xE0BB, 0xE0BD => lineCov(qx, qy, cw, 0, 0, ch, hw),
        else => 0,
    };
}

/// 선분(무한직선이 아님)까지의 거리로 coverage. 꺾쇠처럼 반쪽만 있는 선에 필요하다.
fn segCov(qx: f32, qy: f32, ax: f32, ay: f32, bx: f32, by: f32, hw: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 < 0.0001) return 0;
    const raw = ((qx - ax) * dx + (qy - ay) * dy) / len2;
    const tt = @max(0, @min(1, raw));
    const nx = qx - (ax + tt * dx);
    const ny = qy - (ay + tt * dy);
    return @max(0, @min(1, hw + 0.5 - @sqrt(nx * nx + ny * ny)));
}

/// 반지름 (a, b) 타원의 세로 y 에서의 가로 반폭. 중심은 (0, b).
fn ellipseHalfW(y: f32, a: f32, b: f32) f32 {
    if (a <= 0 or b <= 0) return 0;
    const dy = (y - b) / b;
    const q = 1 - dy * dy;
    return if (q <= 0) 0 else a * @sqrt(q);
}

const Span = struct { l: f32, r: f32 };

/// 면으로 그리는 powerline 글리프가 행 y 에서 덮는 x 구간. `l >= r` 이면 빈 행이다.
/// `t` 는 호(E0B5 · E0B7)의 선 두께 — 바깥 타원에서 그만큼 줄인 안쪽 타원을 빼 띠를 만든다.
fn powerlineSpan(cp: u21, y: f32, cw: f32, ch: f32, t: f32) Span {
    const hy = ch / 2;
    // 꼭짓점이 세로 중앙인 삼각형의 가로 폭.
    const wedge = cw * (1 - @abs(y - hy) / hy);
    const outer = ellipseHalfW(y, cw, hy);
    const inner = ellipseHalfW(y, cw - t, hy - t);
    return switch (cp) {
        0xE0B0 => .{ .l = 0, .r = wedge },
        0xE0B2 => .{ .l = cw - wedge, .r = cw },
        0xE0B4 => .{ .l = 0, .r = outer },
        0xE0B6 => .{ .l = cw - outer, .r = cw },
        0xE0B5 => .{ .l = inner, .r = outer },
        0xE0B7 => .{ .l = cw - outer, .r = cw - inner },
        0xE0B8 => .{ .l = 0, .r = cw * (y / ch) }, // 좌하
        0xE0BA => .{ .l = cw * (1 - y / ch), .r = cw }, // 우하
        0xE0BC => .{ .l = 0, .r = cw * (1 - y / ch) }, // 좌상
        0xE0BE => .{ .l = cw * (y / ch), .r = cw }, // 우상
        else => .{ .l = 0, .r = 0 },
    };
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

/// renderer 분기용 — `boxRects` 가 이 cp 를 그리는지. **세 renderer 가 이것을 부른다.**
///
/// 범위를 호출처에 인라인하지 않는다. 예전에는 세 renderer 가 `cp >= 0x2500 and
/// cp <= 0x257F` 를 각자 적어 두고 이 함수는 테스트에서만 쓰였는데, 그래서 powerline
/// 대역을 더할 때 고칠 자리가 네 곳이 됐다 (#534).
pub fn handles(cp: u21) bool {
    return isBoxDrawing(cp) or isPowerline(cp);
}

/// box-drawing 본래 범위 (대각선 포함 — 전 범위를 그린다).
pub fn isBoxDrawing(cp: u21) bool {
    return cp >= 0x2500 and cp <= 0x257F;
}

/// powerline 확장 (#534). Nerd Font 계열에만 있는 PUA 대역.
pub fn isPowerline(cp: u21) bool {
    return cp >= 0xE0B0 and cp <= 0xE0BF;
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

test "#534 powerline — 16 자 전부 그리고, MAX_RECTS 를 넘지 않으며, 픽셀을 두 번 덮지 않는다" {
    // 마지막 조건이 핵심이다. renderer 는 coverage 를 배경과 *미리* 합성하고 그것이
    // 순차 blend 와 같다고 전제하는데 (`software_terminal.zig` 의 emit 주석), 한 픽셀이
    // 두 번 그려지면 그 픽셀만 진해진다. 속 사각형이 AA 밴드를 덮으면 그렇게 된다.
    var buf: [MAX_RECTS]Rect = undefined;
    // 마지막 둘은 큰 폰트 쪽 여유를 지킨다. 선 계열 (꺾쇠 · 대각선) 은 개수가 셀 높이에
    // 비례해서 (둘레 ∝ ch), 여기서 새면 큰 폰트에서 글리프가 잘려 그려진다.
    const sizes = [_][2]f32{ .{ 8, 16 }, .{ 10, 20 }, .{ 20, 40 }, .{ 33, 66 }, .{ 13, 27 }, .{ 40, 80 }, .{ 60, 120 } };
    for (sizes) |sz| {
        const cw = sz[0];
        const ch = sz[1];
        var cp: u21 = 0xE0B0;
        while (cp <= 0xE0BF) : (cp += 1) {
            const n = boxRects(cp, cw, ch, &buf) orelse {
                std.debug.print("U+{X} 가 null 을 냈다\n", .{cp});
                return error.PowerlineNotDrawn;
            };
            try std.testing.expect(n > 0);
            try std.testing.expect(n <= MAX_RECTS);

            var hits: [122][62]u8 = .{.{0} ** 62} ** 122;
            for (buf[0..n]) |r| {
                try std.testing.expect(r.cov > 0 and r.cov <= 1);
                // 셀 밖으로 새면 이웃 셀을 침범한다.
                try std.testing.expect(r.x >= 0 and r.y >= 0);
                try std.testing.expect(r.x + r.w <= cw + 0.001);
                try std.testing.expect(r.y + r.h <= ch + 0.001);
                var yy: usize = @intFromFloat(r.y);
                const y_end: usize = @intFromFloat(r.y + r.h);
                while (yy < y_end) : (yy += 1) {
                    var xx: usize = @intFromFloat(r.x);
                    const x_end: usize = @intFromFloat(r.x + r.w);
                    while (xx < x_end) : (xx += 1) {
                        hits[yy][xx] += 1;
                        if (hits[yy][xx] > 1) {
                            std.debug.print("U+{X} {d}x{d}: 픽셀 ({d},{d}) 를 두 번 덮었다\n", .{ cp, cw, ch, xx, yy });
                            return error.PixelCoveredTwice;
                        }
                    }
                }
            }
        }
    }
}

test "#534 powerline — 채움 글리프의 면적이 기하 기대값과 맞는다" {
    // 모양이 뒤집히거나 절반만 그려지면 면적으로 드러난다. 참조 렌더로 확정한 기하는
    // 삼각형 = 셀의 1/2, 반타원 = π/4 (반지름 cw · ch/2 의 반타원 넓이 ÷ 셀 넓이) 다.
    var buf: [MAX_RECTS]Rect = undefined;
    const cw: f32 = 24;
    const ch: f32 = 48;
    const cell = cw * ch;
    const cases = [_]struct { cp: u21, ratio: f32 }{
        .{ .cp = 0xE0B0, .ratio = 0.5 }, // 채움 삼각형 →
        .{ .cp = 0xE0B2, .ratio = 0.5 }, // 채움 삼각형 ←
        .{ .cp = 0xE0B4, .ratio = std.math.pi / 4.0 }, // 채움 반타원 →
        .{ .cp = 0xE0B6, .ratio = std.math.pi / 4.0 }, // 채움 반타원 ←
        .{ .cp = 0xE0B8, .ratio = 0.5 }, // 좌하
        .{ .cp = 0xE0BA, .ratio = 0.5 }, // 우하
        .{ .cp = 0xE0BC, .ratio = 0.5 }, // 좌상
        .{ .cp = 0xE0BE, .ratio = 0.5 }, // 우상
    };
    for (cases) |c| {
        const n = boxRects(c.cp, cw, ch, &buf).?;
        var area: f32 = 0;
        for (buf[0..n]) |r| area += r.w * r.h * r.cov;
        const got = area / cell;
        if (@abs(got - c.ratio) > 0.03) {
            std.debug.print("U+{X}: 면적비 {d:.3}, 기대 {d:.3}\n", .{ c.cp, got, c.ratio });
            return error.PowerlineAreaMismatch;
        }
    }
}

test "#534 powerline — 채움 삼각형의 방향이 맞다 (행별 폭으로 판정)" {
    var buf: [MAX_RECTS]Rect = undefined;
    const cw: f32 = 24;
    const ch: f32 = 48;

    // E0B0 (→): 세로 중앙에서 가장 넓고 위아래 끝에서 가장 좁다.
    const n0 = boxRects(0xE0B0, cw, ch, &buf).?;
    var w_top: f32 = 0;
    var w_mid: f32 = 0;
    for (buf[0..n0]) |r| {
        if (r.y < 1) w_top += r.w * r.cov;
        if (r.y >= ch / 2 - 1 and r.y < ch / 2) w_mid += r.w * r.cov;
    }
    try std.testing.expect(w_mid > w_top * 4);

    // E0BC (좌상 채움): 맨 위 행이 거의 꽉 차고 맨 아래 행은 거의 비었다.
    const n1 = boxRects(0xE0BC, cw, ch, &buf).?;
    var top: f32 = 0;
    var bot: f32 = 0;
    for (buf[0..n1]) |r| {
        if (r.y < 1) top += r.w * r.cov;
        if (r.y >= ch - 1) bot += r.w * r.cov;
    }
    try std.testing.expect(top > cw * 0.9);
    try std.testing.expect(bot < cw * 0.1);

    // E0BE (우상 채움) 은 같은 세로 분포이되 왼쪽이 아니라 오른쪽에 붙는다.
    const n2 = boxRects(0xE0BE, cw, ch, &buf).?;
    var right_edge_hits: f32 = 0;
    for (buf[0..n2]) |r| {
        if (r.x + r.w >= cw - 0.001) right_edge_hits += 1;
    }
    try std.testing.expect(right_edge_hits > ch * 0.9);
}

test "handles covers box-drawing incl diagonals and powerline, excludes blocks" {
    try std.testing.expect(handles(0x2500));
    try std.testing.expect(handles(0x256D));
    try std.testing.expect(handles(0x2571)); // 대각선도 그린다
    try std.testing.expect(handles(0xE0B0)); // #534 powerline 시작
    try std.testing.expect(handles(0xE0BF)); // powerline 끝
    try std.testing.expect(!handles(0xE0AF)); // 그 바로 앞은 아니다
    try std.testing.expect(!handles(0xE0C0)); // 그 바로 뒤도 아니다
    try std.testing.expect(!handles(0x2588)); // 블록(block_element 담당)
    try std.testing.expect(!handles('A'));
}
