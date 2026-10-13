#!/usr/bin/env python3
"""GNOME 의 지금 화면 크기를 찍는다 — `tool/kwin-window_linux.py` 의 `output=` · `dpr=` 와 같은 형식 (#756).

    tool/gnome-screen_linux.py
    → output=W,H dpr=1        (W · H 는 물리 px)

- GNOME 은 창 위치를 다른 프로세스에 알려 주지 않는다 (`org.gnome.Shell.Introspect.GetWindows` 가
  `AccessDenied`). 그래서 측정기가 창 영역을 캡처에서 직접 찾고 (`key-to-screen_linux.c` 의 `--find-marker`),
  여기서는 화면 크기만 준다. 측정기는 그 값으로 받은 스트림이 화면 전체인지 보고, 클릭 좌표를 절대축에 펼친다.
- 물리 px 를 `output=` 에 넣고 `dpr=1` 로 둔다 — 측정기는 `output × dpr` 을 물리 크기로 쓴다.
- 값은 `org.gnome.Mutter.DisplayConfig.GetCurrentState` 의 지금 모드 (`is-current`) 다. 화면이 둘 이상이면
  멈춘다 — 절대좌표 포인터가 화면 전체에 펼쳐지므로 하나여야 한다.
"""

import sys

import dbus


def main():
    bus = dbus.SessionBus()
    dc = dbus.Interface(bus.get_object("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig"),
                        "org.gnome.Mutter.DisplayConfig")
    _serial, monitors, logical, _props = dc.GetCurrentState()
    if len(logical) != 1:
        print(f"논리 화면이 {len(logical)} 개예요 — 하나여야 해요", file=sys.stderr)
        return 2
    for _spec, modes, _mprops in monitors:
        for mode in modes:
            if bool(mode[6].get("is-current", False)):
                print(f"output={int(mode[1])},{int(mode[2])} dpr=1")
                return 0
    print("지금 모드를 못 찾았어요", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
