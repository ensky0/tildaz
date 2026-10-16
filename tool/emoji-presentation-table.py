#!/usr/bin/env python3
"""`src/font/emoji_presentation_table.zig` 를 만든다 (#771).

선택자 (VS15 · VS16) 가 없는 글자의 기본 모양이 이모지인지 (Unicode 의
Emoji_Presentation 속성) 를 범위 표로 만든다. 세 OS 의 글꼴 코드가 이 표로
"컬러 글꼴을 먼저 찾을지" 를 정한다 (`src/font/presentation.zig`).

표의 출처는 **ghostty 가 셀 폭을 정할 때 쓰는 uucode 판**이다. 판이 같아야 두 칸
글자와 이모지 모양이 맞는다. 우리 `build.zig.zon` 이 가리키는 ghostty 부터 따라간다 —
`zig-pkg` 에는 옛 pin 의 ghostty 와 그쪽 uucode 가 남아 있어서 디렉터리 이름으로 고르면
둘이 잡힌다 (`tool/emoji-presentation-probe_macos.m` 과 같은 방법이다).

    python3 tool/emoji-presentation-table.py           # 표를 다시 쓴다
    python3 tool/emoji-presentation-table.py --check   # 지금 pin 과 맞는지만 (다르면 종료 코드 1)

`zig-pkg` 는 `zig build` 가 의존성을 받을 때 생긴다. ghostty pin 을 올렸으면
(`dist/update-ghostty.sh`) 빌드한 뒤 `--check` 를 돌린다.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "src" / "font" / "emoji_presentation_table.zig"


def zon_hash(zon: pathlib.Path, name: str) -> str:
    text = zon.read_text(encoding="utf-8")
    m = re.search(r"\." + re.escape(name) + r"\s*=\s*\.\{.*?\.hash\s*=\s*\"([^\"]+)\"", text, re.S)
    if not m:
        sys.exit(f"{zon} 에서 .{name} 의 hash 를 못 찾았어요")
    return m.group(1)


def source() -> tuple[pathlib.Path, str]:
    ghostty = ROOT / "zig-pkg" / zon_hash(ROOT / "build.zig.zon", "ghostty")
    if not ghostty.is_dir():
        sys.exit(f"{ghostty} 가 없어요 — 먼저 zig build 로 의존성을 받아요")
    uucode = zon_hash(ghostty / "build.zig.zon", "uucode")
    data = ROOT / "zig-pkg" / uucode / "ucd" / "emoji" / "emoji-data.txt"
    if not data.is_file():
        sys.exit(f"{data} 가 없어요 — 먼저 zig build 로 의존성을 받아요")
    return data, uucode


def ranges(data: pathlib.Path) -> tuple[list[tuple[int, int]], str]:
    version = ""
    out: list[tuple[int, int]] = []
    for line in data.read_text(encoding="utf-8").splitlines():
        if line.startswith("# Version:"):
            version = line.split(":", 1)[1].strip()
        body = line.split("#", 1)[0].strip()
        if not body:
            continue
        cps, prop = (x.strip() for x in body.split(";", 1))
        if prop != "Emoji_Presentation":
            continue
        lo, _, hi = cps.partition("..")
        out.append((int(lo, 16), int(hi or lo, 16)))
    out.sort()
    # 이어지는 범위는 하나로 합친다 — 표가 짧아져 이진 탐색이 그만큼 덜 돈다.
    merged: list[tuple[int, int]] = []
    for lo, hi in out:
        if merged and lo <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], hi))
        else:
            merged.append((lo, hi))
    if not version:
        sys.exit(f"{data} 에서 Version 줄을 못 찾았어요")
    return merged, version


def render(rs: list[tuple[int, int]], version: str, uucode: str) -> str:
    lines = [
        "//! 생성 파일 — 손으로 고치지 않는다. `python3 tool/emoji-presentation-table.py` 로 다시 만든다 (#771).",
        "//!",
        "//! Unicode `emoji-data.txt` 의 `Emoji_Presentation` (선택자가 없을 때 기본 모양이 이모지인 글자) 를",
        "//! 이어지는 범위로 합친 표다. 출처는 ghostty 가 셀 폭을 정할 때 쓰는 uucode 판이다 —",
        "//! 판이 같아야 두 칸 글자와 이모지 모양이 맞는다.",
        "",
        f'pub const unicode_version = "{version}";',
        f'pub const uucode = "{uucode}";',
        "",
        "pub const Range = struct { lo: u21, hi: u21 };",
        "",
        "/// 오름차순 · 겹치지 않음 · 이웃끼리 붙어 있지 않음 (생성기가 합친다).",
        "pub const emoji_presentation = [_]Range{",
    ]
    for lo, hi in rs:
        lines.append(f"    .{{ .lo = 0x{lo:X}, .hi = 0x{hi:X} }},")
    lines.append("};")
    return "\n".join(lines) + "\n"


def main() -> None:
    check = sys.argv[1:] == ["--check"]
    if sys.argv[1:] and not check:
        sys.exit("사용법: emoji-presentation-table.py [--check]")
    data, uucode = source()
    rs, version = ranges(data)
    text = render(rs, version, uucode)
    if check:
        current = OUT.read_text(encoding="utf-8") if OUT.is_file() else ""
        if current != text:
            print(f"{OUT.relative_to(ROOT)} 가 지금 pin 의 uucode ({uucode}) 와 달라요 — 인자 없이 다시 돌려요")
            sys.exit(1)
        print(f"맞아요 — Unicode {version} · 범위 {len(rs)} 개 · {uucode}")
        return
    OUT.write_text(text, encoding="utf-8")
    print(f"{OUT.relative_to(ROOT)} — Unicode {version} · 범위 {len(rs)} 개")


if __name__ == "__main__":
    main()
