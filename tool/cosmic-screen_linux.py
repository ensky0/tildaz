#!/usr/bin/env python3
"""COSMIC 의 지금 화면 크기를 찍는다 — `tool/gnome-screen_linux.py` 와 같은 형식 (#756).

    tool/cosmic-screen_linux.py
    → output=W,H dpr=1        (W · H 는 물리 px)

- COSMIC 도 GNOME 처럼 창 위치를 KWin 스크립트 같은 길로 알려 주지 않아서, 측정기가 창 영역을 캡처에서
  직접 찾는다 (`key-to-screen_linux.c` 의 `--find-marker`). 여기서는 화면 크기만 준다. 측정기는 그 값으로
  받은 스트림이 화면 전체인지 보고, 클릭 좌표를 절대축에 펼친다.
- 값은 `cosmic-randr list --kdl` 의 켜진 화면 (`enabled=#true`, 다른 화면을 복제하지 않는 것) 의 지금 모드
  (`current=#true`) 다. 형식은 cosmic-randr 1.9.0 (`epoch-1.9.0`) 의 `cli/src/main.rs` `list_kdl` 이다:

      output "eDP-1" enabled=#true {
        ...
        mirroring "HDMI-A-1"          ← 복제하는 화면에만 있다
        modes {
          mode 2880 1800 120000 current=#true preferred=#true
        }
      }

- 화면이 둘 이상이면 멈춘다 — 절대좌표 포인터가 화면 전체에 펼쳐지므로 하나여야 한다.
- 화면을 돌려 둔 경우 (`transform`) 는 보지 않는다. 그 기기에서 쓰게 되면 확인한다.
"""

import re
import subprocess
import sys


def main():
    try:
        text = subprocess.run(["cosmic-randr", "list", "--kdl"], check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError) as err:
        print(f"cosmic-randr 를 못 돌렸어요: {err}", file=sys.stderr)
        return 2

    found = []
    for block in re.split(r'(?m)^output "', text)[1:]:
        if not re.match(r'[^"]*" enabled=#true', block) or re.search(r'(?m)^\s*mirroring ', block):
            continue
        mode = re.search(r'(?m)^\s*mode (\d+) (\d+) \d+ current=#true', block)
        if mode:
            found.append((int(mode.group(1)), int(mode.group(2))))

    if len(found) != 1:
        print(f"켜진 화면이 {len(found)} 개예요 — 하나여야 해요", file=sys.stderr)
        return 2
    w, h = found[0]
    print(f"output={w},{h} dpr=1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
