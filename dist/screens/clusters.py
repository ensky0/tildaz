#!/usr/bin/env python3
r"""atlas · cluster 렌더 검증용 화면을 만든다 — 세 platform 공용.

`tildaz -e` 는 실행 파일 하나만 받으므로, 이 생성기는 **stdout 에 실행 가능한 sh 스크립트**를 낸다.
받아서 파일로 저장하고 `chmod +x` 한 뒤 `-e` 에 넘긴다. 각 화면은 서로 다른 cluster 를 겹치지 않게
만들어 atlas 에 담기는 **종 수**가 예측 가능하다 (아래 표는 기본 인자 기준 · 실측은 #584 · #585 · #591).

    python3 dist/screens/clusters.py many     > /tmp/many.sh      # 2,938 종 · 88x33 · 일반 화면 (grow 0 이어야 한다)
    python3 dist/screens/clusters.py stack2   > /tmp/stack2.sh    # 6,000 종 · 150x40 · mark 둘 — 1024² 가 찬다 (안전망 검증)
    python3 dist/screens/clusters.py overflow > /tmp/overflow.sh  # 17 화면 · 96,768 종 누적 · 150x40 — 8192² 상한에 닿는다
    python3 dist/screens/clusters.py mini     > /tmp/mini.sh      # 1.5 s 뒤 한 줄 · 4 s 뒤 종료 — 렌더 프레임 수 계측용
    chmod +x /tmp/*.sh
    tildaz --instance 9 -e /tmp/many.sh -size 88x33

**Windows 는 `--cmd <본문.txt>` 를 준다** (#586). `sh` 가 없으므로 본문을 그 경로에 UTF-8 (BOM 없음) 로 쓰고
stdout 에는 그것을 `type` 하는 **`.cmd` 래퍼** (CRLF · `chcp 65001` · `timeout` 대기) 를 낸다. `-e` 가 `.cmd` 를
받는 것은 #584 Windows 계측에서 확인했다.

    python dist\screens\clusters.py stack2 --cmd $env:TEMP\stack2.txt > $env:TEMP\stack2.cmd
    tildaz --instance 9 -e $env:TEMP\stack2.cmd -size 150x40

| 화면 | 무엇 | 왜 |
|---|---|---|
| `many` | 소문자 26 × 결합 기호 (U+0300~U+036F) 한 겹 | 일반 화면 회귀 — atlas 가 커지지 않아야 한다 |
| `stack2` | base 8 종 × 위 mark × 아래 mark 두 겹 | 비트맵이 cell 보다 커서 좁은 atlas 를 빨리 채운다 — `MAX = INITIAL` 판으로 안전망만 돌린다 |
| `overflow` | 대문자 base × mark 세 겹, 화면마다 다른 조합 — 17 화면을 차례로 | 캐시가 누적되어 8192² 상한에 닿는다 (SPEC §12.6 ② "한 세션의 누적") |
| `mini` | 잠시 뒤 한 줄만 · 스스로 끝난다 | perf 종료 덤프의 `render calls` 를 읽어 프레임 수를 센다 (`pkill` 은 `atexit` 덤프를 못 남긴다) |

`sleep` 은 화면이 남아 있게 하는 것이다 — `-e` 로 띄운 프로세스가 끝나면 앱도 끝난다.
"""
import sys

# Windows 콘솔은 stdout 인코딩이 ANSI 코드페이지 (한국어는 cp949) 라 결합 기호에서 `UnicodeEncodeError` 로
# 죽는다 (2026-09-03 Windows 실기 — #586). 세 platform 이 같은 바이트를 내도록 UTF-8 로 고정한다.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")

ABOVE = [chr(c) for c in range(0x0300, 0x0315)] + [chr(c) for c in range(0x033D, 0x0345)]   # 위 mark 29
BELOW = [chr(c) for c in range(0x0316, 0x0334)]                                              # 아래 mark 30
ALL = [chr(c) for c in range(0x0300, 0x0370)]                                                # 112


CMD_TXT = None  # `--cmd <경로>` — Windows 용 .cmd 래퍼를 낼 때 본문을 쓸 텍스트 파일


def emit(lines, tail="sleep 3600", head=""):
    if CMD_TXT:
        with open(CMD_TXT, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        sys.stdout.write("@echo off\r\nchcp 65001>nul\r\ntype \"%s\"\r\ntimeout /t 3600 /nobreak >nul\r\n" % CMD_TXT)
        return
    out = ["#!/bin/sh", head] if head else ["#!/bin/sh"]
    out += ["cat <<'S'"] + lines + ["S", tail]
    sys.stdout.write("\n".join(out) + "\n")


def rows(items, per_line):
    return ["".join(items[i:i + per_line]) for i in range(0, len(items), per_line)]


def many(cols=88):
    items = [b + m for b in "abcdefghijklmnopqrstuvwxyz" for m in ALL]   # 26 × 112 = 2,912
    emit(rows(items, cols))


def stack2(cols=150):
    bases = ["a", "á", "â", "ã", "ā", "ă", "ȧ", "ä"]  # 8
    items = [b + a + w for b in bases for a in ABOVE for w in BELOW]                    # 8 × 29 × 30 = 6,960
    emit(rows(items[:6000], cols))


def overflow(cols=150, screens=17):
    # 화면마다 base 를 바꿔 조합이 겹치지 않게 한다. 각 화면 5,692 종 (= 4 base × 29 × 30 × ... 를 cols 줄로).
    bases_all = [chr(c) for c in range(0x0100, 0x0100 + 4 * screens)]   # Ā Ă Ą Ć … 화면마다 4 개
    lines = []
    for s in range(screens):
        bases = bases_all[s * 4:(s + 1) * 4]
        items = [b + a + w + x for b in bases for a in ABOVE for w in BELOW for x in ("̀", "́")][:5692]
        lines += rows(items, cols)
        lines.append("")  # 화면 사이 빈 줄 — 스크롤로 넘어간다
    emit(lines)


def mini():
    sys.stdout.write('#!/bin/sh\nsleep 1.5\nprintf "\\303\\240\\303\\241\\303\\242\\303\\243 a\\314\\205a\\314\\206a\\314\\207 \\303\\244\\341\\272\\243\\n"\nsleep 4\n')


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--cmd" in args:
        k = args.index("--cmd")
        if k + 1 >= len(args):
            sys.exit("--cmd 뒤에 본문을 쓸 .txt 경로가 필요하다")
        CMD_TXT = args[k + 1]
        del args[k:k + 2]
    which = args[0] if args else "many"
    cols = int(args[1]) if len(args) > 1 else None
    if which == "mini" and CMD_TXT:
        sys.exit("mini 는 sh 전용이다 (perf 종료 덤프 계측) — --cmd 와 함께 쓸 수 없다")
    if which == "many":
        many(cols or 88)
    elif which == "stack2":
        stack2(cols or 150)
    elif which == "overflow":
        overflow(cols or 150)
    elif which == "mini":
        mini()
    else:
        sys.exit("사용법: clusters.py many|stack2|overflow|mini [cols] [--cmd <본문.txt>]")
