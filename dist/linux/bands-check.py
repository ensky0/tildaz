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
    args = ap.parse_args()

    im = Image.open(args.png).convert("L")
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
