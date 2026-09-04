#!/usr/bin/env python3
"""#539 — 띠 화면 캡처의 세로 단면에서 **리샘플 서명**을 읽는다.

`dist/screens/clusters.py bands` 화면 (밝은 230 / 어두운 20 띠가 3 줄씩) 을 띄운 창을 캡처해 넘긴다.
창 안 x 구간의 행별 평균 밝기를 내고, 두 띠 값 사이에 있는 행 (= 전이 행) 의 밝기를 모은다.

    python3 dist/linux/bands-check.py shot.png            # 캡처 전체가 창일 때
    python3 dist/linux/bands-check.py shot.png 2136x1261+744+0   # 창 영역 (ImageMagick geometry)
    python3 dist/linux/bands-check.py shot.png --x 400 --w 100     # 단면 x 구간 (기본 창 폭의 중앙 100 px)

판정 (#539 마감 댓글의 방법 그대로):

- 전이 행 밝기가 **한 종류** (또는 0 행) 이면 리샘플 없음 — 앱이 그리는 셀 경계의 고유값 하나만 남는다.
- 여러 종류이고 창 위→아래로 **단조 증가 뒤 wrap** 이면 창 전체에 걸친 1 px 선형 리샘플이다.

두 띠의 기준값은 화면이 칠하는 값 그대로 230 / 20 이다 (`--lo` · `--hi` 로 바꿀 수 있다). 캡처에서 가장 흔한 두 밝기로
자동 추정하는 방식 (`--auto`) 은 창이 출력을 다 덮지 않아 배경 행이 많으면 배경을 띠로 오인한다 — 2026-09-03 headless
sway 회차에서 그렇게 어두운 띠 (20) 전체가 "전이 행" 으로 잡혔다.
"""
import argparse
import collections
import re
import sys

from PIL import Image


def parse_geometry(g):
    m = re.fullmatch(r"(\d+)x(\d+)\+(\d+)\+(\d+)", g)
    if not m:
        raise SystemExit(f"geometry 형식이 아니다: {g} (예: 2136x1261+744+0)")
    w, h, x, y = map(int, m.groups())
    return x, y, w, h


def locate_bands(im, lo, hi, width=100, tol=8, gap=8):
    """띠 화면이 있는 창 영역을 캡처에서 직접 찾는다 — 창 좌표를 밖에서 계산하지 않아도 되게.

    2026-09-04 에 이 탐색이 없어서 회차 셋을 버렸다. Hyprland 의 타일 좌표를 배율로 곱해 crop 을 만들었는데
    그 값이 화면 밖을 가리켜 (`+3834` · 화면 폭 3840) **전이 행 0 개가 "깨끗" 으로 오판**됐다. 창 위치는
    compositor · 타일링 · 배율 · (전체화면이 걸렸는지) 에 따라 달라지므로 캡처에서 찾는 것이 유일하게 안전하다.

    열은 **두 띠를 다 보는 정도** (`min(어두운 행 수, 밝은 행 수)`) 로 고른다. 단순히 "띠 색 픽셀이 가장 많은 열" 로
    고르면 안 된다 — 어두운 띠 (20) 와 창 여백 · 테두리 · 검은 배경이 같은 밝기라서, 띠가 하나도 없는 여백 열이
    점수를 독식하고 그 단면은 전이 행 0 개를 낸다. 즉 **또 거짓 "깨끗"** 이다. 두 띠를 다 보는 열만 통과시키면
    여백 · 벽지 · 창 밖이 전부 걸러진다.

    행은 그 열의 띠 색 행을 **간격 `gap` 까지 이어 붙여 묶고 가장 긴 덩어리**를 창으로 삼는다. 두 극단이 다 틀린다.
    "연속 구간" 은 셀 경계의 전이 행 하나에서 끊겨 창의 일부만 잡고 (1296 행 창에서 232 행), "첫 행 ~ 끝 행" 은
    띠와 밝기가 겹치는 벽지까지 삼켜 화면 전체를 잡는다 (2134 행 · 띠 아닌 행 935 개).
    """
    W, H = im.size
    m_lo = im.point(lambda v: 255 if abs(v - lo) <= tol else 0)
    m_hi = im.point(lambda v: 255 if abs(v - hi) <= tol else 0)
    c_lo = list(m_lo.resize((W, 1), Image.BOX).tobytes())
    c_hi = list(m_hi.resize((W, 1), Image.BOX).tobytes())
    score = [min(a, b) for a, b in zip(c_lo, c_hi)]
    best = max(score)
    if best == 0:
        return None
    cx = max(range(W), key=lambda i: score[i])

    # 점수가 최고의 절반 이상인 열까지 좌우로 넓혀 창의 가로 범위를 잡고, 그 안에서 단면을 가운데에 둔다.
    need = best * 0.5
    lx = cx
    while lx > 0 and score[lx - 1] >= need:
        lx -= 1
    rx = cx
    while rx + 1 < W and score[rx + 1] >= need:
        rx += 1
    span = rx - lx + 1
    if span <= width:
        sx0, sx1 = lx, rx + 1
    else:
        sx0 = lx + (span - width) // 2
        sx1 = sx0 + width

    strip = im.crop((sx0, 0, sx1, H))
    rows = [sum(strip.crop((0, y, sx1 - sx0, y + 1)).tobytes()) / (sx1 - sx0) for y in range(H)]
    band = [y for y, v in enumerate(rows) if abs(v - lo) <= tol or abs(v - hi) <= tol]
    if not band:
        return None
    groups, cur = [], [band[0]]
    for prev, y in zip(band, band[1:]):
        if y - prev > gap:
            groups.append(cur)
            cur = [y]
        else:
            cur.append(y)
    groups.append(cur)
    pick = max(groups, key=len)
    return (sx0, pick[0], sx1, pick[-1] + 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("png")
    ap.add_argument("geometry", nargs="?", help="창 영역 WxH+X+Y (없으면 캡처 전체)")
    ap.add_argument("--x", type=int, help="단면 x 시작 (창 기준)")
    ap.add_argument("--w", type=int, default=100, help="단면 폭 (기본 100)")
    ap.add_argument("--top", type=int, default=0, help="위에서 건너뛸 행 (탭바 등)")
    ap.add_argument("--dump", action="store_true", help="행별 밝기를 전부 찍는다")
    ap.add_argument("--lo", type=int, default=20, help="어두운 띠의 밝기 (기본 20 — bands 화면이 칠하는 값)")
    ap.add_argument("--hi", type=int, default=230, help="밝은 띠의 밝기 (기본 230)")
    ap.add_argument("--auto", action="store_true", help="기준값을 캡처에서 가장 흔한 두 밝기로 추정 (배경 행이 많으면 틀린다)")
    ap.add_argument("--locate", action="store_true",
                    help="띠 화면이 있는 **창 영역을 캡처에서 직접 찾는다** — 창 좌표를 계산하지 않아도 된다 (권장)")
    args = ap.parse_args()

    im = Image.open(args.png).convert("L")
    if args.locate:
        box = locate_bands(im, args.lo, args.hi)
        if box is None:
            raise SystemExit("띠 영역을 못 찾았다 — 화면에 띠 화면이 없거나 색이 다르다 (--lo/--hi 확인)")
        x0, y0, x1, y1 = box
        print(f"찾은 창 영역: {x1 - x0}x{y1 - y0}+{x0}+{y0}")
        im = im.crop(box)
        args.geometry = None
    if args.geometry:
        x, y, w, h = parse_geometry(args.geometry)
        im = im.crop((x, y, x + w, y + h))
    W, H = im.size
    x0 = args.x if args.x is not None else max(0, W // 2 - args.w // 2)
    strip = im.crop((x0, args.top, x0 + args.w, H))
    px = strip.load()
    rows = []
    for yy in range(strip.size[1]):
        s = 0
        for xx in range(strip.size[0]):
            s += px[xx, yy]
        rows.append(s / strip.size[0])

    hist = collections.Counter(round(v) for v in rows)
    if args.auto:
        common = [v for v, _ in hist.most_common(2)]
        if len(common) < 2:
            raise SystemExit(f"띠가 둘로 안 갈린다 — 밝기 분포 {hist.most_common(5)}")
        lo, hi = sorted(common)
    else:
        lo, hi = args.lo, args.hi
    margin = max(3, (hi - lo) // 20)
    band_rows = sum(c for v, c in hist.items() if abs(v - lo) <= margin or abs(v - hi) <= margin)
    other_rows = len(rows) - band_rows

    transitions = []   # (row, brightness)
    for yy, v in enumerate(rows):
        if lo + margin < v < hi - margin:
            transitions.append((yy + args.top, round(v, 1)))

    print(f"창 {W}x{H} · 단면 x={x0}..{x0 + args.w - 1} · 띠 기준 어두움={lo} 밝음={hi} · 행 {len(rows)} (띠 {band_rows} · 그 밖 {other_rows})")
    if other_rows > len(rows) // 4:
        print(f"⚠️ 띠가 아닌 행이 {other_rows} 개 — 화면이 창을 다 채우지 않았거나 단면이 창 밖이다. 판정을 믿지 말 것")
    if args.dump:
        for yy, v in enumerate(rows):
            print(f"  y={yy + args.top:5d} {v:7.1f}")
    kinds = sorted({round(v) for _, v in transitions})
    print(f"전이 행 {len(transitions)} 개 · 밝기 종류 {len(kinds)} 종: {kinds}")
    if transitions:
        print("위→아래 순서: " + " ".join(f"{round(v)}" for _, v in transitions))
    if len(kinds) <= 1:
        print("판정: 리샘플 없음 (전이 행 밝기가 한 종류 이하)")
    else:
        print("판정: 전이 행 밝기가 여러 종류 — 창 위→아래 단조 변화 + wrap 이면 1 px 리샘플 서명")
    return 0


if __name__ == "__main__":
    sys.exit(main())
