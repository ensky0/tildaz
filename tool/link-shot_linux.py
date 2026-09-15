#!/usr/bin/env python3
"""링크 회차 (#647) 의 캡처 판정 — 격자 찾기 · 밑줄 픽셀 · 커서 모양.

[`link-click-check_linux.sh`](link-click-check_linux.sh) 가 부르는 판정기다. 세 가지를 판정한다.

    link-shot_linux.py grid   <neutral.png> --cell-w N            # 격자 원점 · 셀 크기를 캡처에서 찾는다
    link-shot_linux.py diff   <base.png> <shot.png>               # 밑줄 — 두 캡처의 다른 픽셀과 경계 상자
    link-shot_linux.py cursor <shot.png> <x> <y> [--theme PATH]   # 커서 모양 — 테마 비트맵과 맞대 본다

**커서는 캡처에 이미 들어 있다** — headless sway 는 커서를 소프트웨어로 합성하므로 `grim` 과 `grim -c` 가
같다 (2026-09-15 실측). 그래서 `diff` 로 밑줄을 볼 때 **커서가 섞이지 않게** 포인터 주변을 빼야 하는데,
밑줄은 셀 행 전체에 걸친 가로선이고 커서는 24x24 라 경계 상자로 갈린다 (`--ignore-box`).

**커서 판정은 픽셀 일치율이다.** XCursor 테마 파일 (`/usr/share/icons/<theme>/cursors/<name>`) 에서 24 px
판을 꺼내 **알파가 255 인 픽셀만** 캡처의 같은 자리 (hotspot 보정) 와 비교한다. 배경이 무엇이든 불투명
픽셀은 그대로 덮이므로, 맞는 모양은 100 % 가 나오고 나머지는 크게 떨어진다 (실측: `pointer` 148/148 100 %
대 `text` 14 % · `default` 53 %). 밝기 차이나 경계 상자 크기로 어림하지 않는 이유가 이것이다 — 세 모양이
서로 겹치는 자리가 있어 크기만으로는 안 갈린다.

기대하는 세 모양은 tildaz 의 `cursorShapeForSurface` 가 내는 것과 1:1 이다 — `.other`→`default` ·
`.cell`→`text` · `.link`→`pointer` (CSS 이름. `wp_cursor_shape_v1` 의 enum 이 그 이름을 쓴다).
"""
import argparse
import json
import struct
import sys

from PIL import Image

XCURSOR_IMAGE_CHUNK = 0xFFFD0002


# ── XCursor (문서: xcursor(3) · 파일 포맷은 헤더 + TOC + 청크) ──────────────────
def load_cursor(path, want=24):
    """테마 파일에서 `want` px 에 가장 가까운 판 하나를 꺼낸다 → (RGBA Image, (hot_x, hot_y))."""
    d = open(path, "rb").read()
    magic, header_size, _ver, ntoc = struct.unpack_from("<4sIII", d, 0)
    if magic != b"Xcur":
        raise SystemExit(f"{path}: XCursor 파일이 아니다 (magic={magic!r})")
    best = None
    for i in range(ntoc):
        typ, _sub, pos = struct.unpack_from("<III", d, header_size + i * 12)
        if typ != XCURSOR_IMAGE_CHUNK:
            continue
        w, h, hx, hy, _delay = struct.unpack_from("<IIIII", d, pos + 16)
        if best is None or abs(w - want) < abs(best[0] - want):
            best = (w, h, hx, hy, pos + 36)
    if best is None:
        raise SystemExit(f"{path}: image 청크가 없다")
    w, h, hx, hy, off = best
    return Image.frombytes("RGBA", (w, h), d[off:off + w * h * 4], "raw", "BGRA"), (hx, hy)


def cmd_cursor(args):
    shots = Image.open(args.shot).convert("RGB")
    px = shots.load()
    W, H = shots.size
    scores = {}
    for name in args.shapes:
        ref, (hx, hy) = load_cursor(f"{args.theme}/{name}", args.size)
        rp = ref.load()
        ok = tot = 0
        for j in range(ref.size[1]):
            for i in range(ref.size[0]):
                r, g, b, a = rp[i, j]
                if a != 255:          # 반투명 (그림자 · 안티에일리어스) 는 배경과 섞여서 못 쓴다
                    continue
                x, y = args.x - hx + i, args.y - hy + j
                if not (0 <= x < W and 0 <= y < H):
                    continue
                tot += 1
                if px[x, y] == (r, g, b):
                    ok += 1
        scores[name] = {"matched": ok, "opaque": tot, "ratio": (ok / tot) if tot else 0.0}
    best = max(scores, key=lambda k: scores[k]["ratio"])
    out = {"shape": best, "ratio": scores[best]["ratio"], "scores": scores}
    if scores[best]["ratio"] < args.min_ratio:
        out["shape"] = "unknown"
    print(json.dumps(out) if args.json else
          f"{best} ({scores[best]['ratio'] * 100:.0f}%)  " +
          "  ".join(f"{k}={v['matched']}/{v['opaque']}" for k, v in scores.items()))
    return 0


def cmd_diff(args):
    a = Image.open(args.base).convert("RGB")
    b = Image.open(args.shot).convert("RGB")
    if a.size != b.size:
        raise SystemExit(f"크기가 다르다: {a.size} vs {b.size}")
    ap, bp = a.load(), b.load()
    boxes = args.ignore_box or []
    rg = args.region or (0, 0, a.size[0] - 1, a.size[1] - 1)
    pts = []
    for y in range(max(0, rg[1]), min(a.size[1], rg[3] + 1)):
        for x in range(max(0, rg[0]), min(a.size[0], rg[2] + 1)):
            if any(bx[0] <= x <= bx[2] and bx[1] <= y <= bx[3] for bx in boxes):
                continue
            if ap[x, y] != bp[x, y]:
                pts.append((x, y))
    if not pts:
        res = {"px": 0}
    else:
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        res = {"px": len(pts), "x0": min(xs), "x1": max(xs), "y0": min(ys), "y1": max(ys),
               "w": max(xs) - min(xs) + 1, "h": max(ys) - min(ys) + 1}
    print(json.dumps(res) if args.json else
          (f"{res['px']} px" if not res["px"] else
           f"{res['px']} px  bbox x {res['x0']}-{res['x1']} y {res['y0']}-{res['y1']} ({res['w']}x{res['h']})"))
    return 0


def cmd_grid(args):
    """격자 원점 · 셀 크기를 **캡처에서** 찾는다 — 밖에서 계산해 넘기지 않는다 (AGENTS.md).

    화면 스크립트가 만든 배치를 전제한다 — 빈 줄 · `osc8:` 줄 · 빈 줄 · `text:` 줄 · 빈 줄 · **커서**.
    마지막 커서 블록이 col 0 · row 5 라, 그 x 가 격자 원점이고 그 높이가 셀 높이다. 셀 폭은 `--cell-w`
    (앱 로그의 `applied ratios cell_w=`) 로 받고, `text:` 줄의 URL 잉크가 예측한 칸 범위와 맞는지로
    **검산**한다 — 어긋나면 좌표를 쓰지 않고 실패한다.
    """
    im = Image.open(args.neutral).convert("RGB")
    px = im.load()
    W, H = im.size
    lit = lambda x, y: sum(px[x, y]) > args.threshold  # noqa: E731

    xlo, xhi = args.area[0], args.area[2]
    bands, cur = [], None
    for y in range(args.area[1], args.area[3] + 1):
        has = any(lit(x, y) for x in range(xlo, xhi + 1))
        if has:
            cur = (cur[0], y) if cur else (y, y)
        elif cur:
            bands.append(cur)
            cur = None
    if cur:
        bands.append(cur)
    if len(bands) < 3:
        raise SystemExit(f"글자 행을 못 찾았다 (밴드 {len(bands)} 개) — 화면 스크립트가 떴는지 확인")

    osc_band, text_band, cursor_band = bands[0], bands[1], bands[2]
    cxs = [x for x in range(xlo, xhi + 1)
           for y in range(cursor_band[0], cursor_band[1] + 1) if lit(x, y)]
    grid_x = min(cxs)                               # 커서 블록은 col 0 에 있다
    cell_h = cursor_band[1] - cursor_band[0] + 1
    grid_y = cursor_band[0] - 5 * cell_h            # 커서는 row 5 (화면 스크립트의 배치)

    def ink(band):
        xs = [x for x in range(xlo, xhi + 1) for y in range(band[0], band[1] + 1) if lit(x, y)]
        return min(xs), max(xs)

    # ── 셀 폭도 캡처에서 잰다 ──────────────────────────────────────────────────
    # 앱 로그의 `applied ratios cell_w=` 를 그냥 믿으면 안 된다 — 그 줄은 **두 번** 찍히고
    # (터미널 폰트와 UI 폰트) 마지막 것을 집으면 8, 실제 격자는 9 다 (2026-09-15 실측).
    # 두 글자 줄의 잉크 폭으로 각각 재서 서로 맞는지 본다.
    #   `  osc8:  CLICK-OSC8`  → 잉크는 col 2 부터 col 18 끝까지 = 17 칸
    #   `  text:  https://…/A` → 잉크는 col 2 부터 col 32 끝까지 = 31 칸
    osc_lo, osc_hi = ink(osc_band)
    txt_lo, txt_hi = ink(text_band)
    cw_osc = round((osc_hi - osc_lo + 1) / 17)
    cw_txt = round((txt_hi - txt_lo + 1) / 31)
    if cw_osc != cw_txt:
        raise SystemExit(f"셀 폭이 두 줄에서 다르게 나온다 — osc8 줄 {cw_osc} · text 줄 {cw_txt}")
    cell_w = cw_txt
    if args.cell_w and args.cell_w != cell_w:
        print(f"  ! 로그의 cell_w={args.cell_w} 와 캡처에서 잰 {cell_w} 가 다르다 — 캡처를 쓴다",
              file=sys.stderr)

    # ── 검산 — 글자 줄은 col 2 에서 시작한다. 예측한 칸 시작과 잉크 시작이 2 px 안이어야 한다 ──
    predicted = grid_x + 2 * cell_w
    if abs(txt_lo - predicted) > 2:
        raise SystemExit(f"격자 검산 실패 — 글자는 col 2 라 x≈{predicted} 여야 하는데 잉크가 {txt_lo} 다 "
                         f"(grid_x={grid_x} cell_w={cell_w})")

    res = {"grid_x": grid_x, "grid_y": grid_y, "cell_w": cell_w, "cell_h": cell_h,
           "osc8_row": 1, "text_row": 3, "url_col0": 9, "url_cols": 24, "osc8_cols": 10,
           "text_ink": [txt_lo, txt_hi], "osc8_ink": [osc_lo, osc_hi]}
    print(json.dumps(res) if args.json else
          f"grid=({grid_x},{grid_y}) cell={cell_w}x{cell_h}  검산 OK (글자 잉크 {txt_lo}, 예측 {predicted})")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true", help="결과를 JSON 한 줄로")
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("grid", help="격자 원점 · 셀 크기를 캡처에서 찾는다")
    g.add_argument("neutral")
    g.add_argument("--cell-w", type=int, default=0,
                   help="앱 로그의 `applied ratios cell_w=` — **참고용 대조**다. 값은 캡처에서 잰다")
    g.add_argument("--area", type=int, nargs=4, metavar=("X0", "Y0", "X1", "Y1"), required=True,
                   help="창 안에서 볼 범위 — 컨트롤 스트립 (+ × ⋯) 은 빼고 준다")
    g.add_argument("--threshold", type=int, default=90, help="글자로 칠 RGB 합 (기본 90)")
    g.set_defaults(func=cmd_grid)

    d = sub.add_parser("diff", help="두 캡처의 다른 픽셀 (밑줄 판정)")
    d.add_argument("base")
    d.add_argument("shot")
    d.add_argument("--ignore-box", type=int, nargs=4, action="append", metavar=("X0", "Y0", "X1", "Y1"),
                   help="이 상자 안은 세지 않는다 — 커서가 캡처에 합성되므로 그 자리를 뺀다. "
                        "여러 번 줄 수 있다 (지금 포인터 자리 + 중립 캡처의 포인터 자리)")
    d.add_argument("--region", type=int, nargs=4, metavar=("X0", "Y0", "X1", "Y1"),
                   help="이 안만 본다. 격자 영역을 주면 **중립 캡처의 포인터 자국** (창 밖에 세워 둔 것) 이 안 섞인다")
    d.set_defaults(func=cmd_diff)

    c = sub.add_parser("cursor", help="커서 모양 — 테마 비트맵과 픽셀로 맞대 본다")
    c.add_argument("shot")
    c.add_argument("x", type=int)
    c.add_argument("y", type=int)
    c.add_argument("--theme", default="/usr/share/icons/Adwaita/cursors")
    c.add_argument("--size", type=int, default=24, help="쓸 판의 px (기본 24 — XCURSOR_SIZE 와 맞춘다)")
    c.add_argument("--shapes", nargs="+", default=["default", "text", "pointer"])
    c.add_argument("--min-ratio", type=float, default=0.9, help="이보다 낮으면 unknown (기본 0.9)")
    c.set_defaults(func=cmd_cursor)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
