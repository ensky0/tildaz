#!/usr/bin/env python3
"""uinput 가상 키보드 — 실제 세션의 전역 hotkey 를 사람 손 없이 누른다 (#654 GNOME 실기).

`vkbd_linux.py` 의 짝이다. 그쪽은 `zwp_virtual_keyboard_v1` 이라 headless sway 안에서만
쓰고 (GNOME 은 그 프로토콜을 client 에 내주지 않는다), 이쪽은 `/dev/uinput` 이라 **커널 입력
장치**로 들어가 compositor 가 실제 키보드처럼 본다 — 그래서 GNOME · KDE 의 전역 hotkey
grab 이 그대로 발화한다. 대가는 **키가 그때 포커스를 가진 창으로 간다**는 것이라 (AGENTS.md
`# 전역 hotkey` 절의 같은 경고) 사용자에게 알리고 돌린다.

장치는 **한 번 꽂고 유지**하며 FIFO 로 명령을 받는다 — 명령마다 add/remove 하면 compositor 의
keymap 이 잠깐 흔들려 (cosmic-comp 실측) 그 사이의 키가 발화하지 않는다. 꽂은 뒤 5 초를
기다린다 (`SETTLE`).

    python3 tool/ukbd_linux.py --fifo /run/user/$(id -u)/ukbd.fifo &
    echo "key F10" > /run/user/$(id -u)/ukbd.fifo        # 누르고 뗀다
    echo "quit"    > /run/user/$(id -u)/ukbd.fifo        # UI_DEV_DESTROY 뒤 종료

권한: `/dev/uinput` 에 ACL 이 있으면 sudo 없이 열린다 (`getfacl /dev/uinput`). 커널을 올리고
재부팅하지 않았으면 모듈이 없어 열리지 않는다 (AGENTS.md `# Linux — 실제 KDE 세션에서 …`).
"""
import argparse
import fcntl
import os
import struct
import sys
import time

# <linux/uinput.h> — _IOW('U', n, T). 값은 x86_64 · aarch64 공통이다.
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UI_DEV_SETUP = 0x405C5503      # sizeof(struct uinput_setup) = 92 = 0x5c
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565

EV_SYN, EV_KEY = 0, 1
BUS_USB = 0x03

# <linux/input-event-codes.h> — 실기에 쓰는 것만. 필요하면 더한다.
KEYS = {
    "F1": 59, "F2": 60, "F3": 61, "F4": 62, "F5": 63, "F6": 64,
    "F7": 65, "F8": 66, "F9": 67, "F10": 68, "F11": 87, "F12": 88,
    "Escape": 1, "Return": 28, "Space": 57, "Tab": 15,
    "LeftCtrl": 29, "LeftShift": 42, "LeftAlt": 56, "LeftMeta": 125,
    "a": 30, "t": 20, "w": 17, "q": 16,
}

SETTLE = 5.0


def emit(fd: int, ev_type: int, code: int, value: int) -> None:
    # struct input_event { struct timeval time; __u16 type; __u16 code; __s32 value; }
    os.write(fd, struct.pack("llHHi", 0, 0, ev_type, code, value))


def tap(fd: int, names: list[str]) -> None:
    """`ctrl+shift+t` 처럼 `+` 로 이은 조합 — 앞의 것부터 누르고 뒤의 것부터 뗀다."""
    codes = [KEYS[n] for n in names]
    for c in codes:
        emit(fd, EV_KEY, c, 1)
        emit(fd, EV_SYN, 0, 0)
        time.sleep(0.02)
    time.sleep(0.05)
    for c in reversed(codes):
        emit(fd, EV_KEY, c, 0)
        emit(fd, EV_SYN, 0, 0)
        time.sleep(0.02)


def parse_combo(text: str) -> list[str]:
    alias = {"ctrl": "LeftCtrl", "shift": "LeftShift", "alt": "LeftAlt", "super": "LeftMeta", "meta": "LeftMeta"}
    out = []
    for part in text.split("+"):
        p = part.strip()
        p = alias.get(p.lower(), p)
        if p not in KEYS:
            raise KeyError(p)
        out.append(p)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fifo", required=True, help="명령을 받을 FIFO 경로 (없으면 만든다)")
    ap.add_argument("--name", default="tildaz-654-ukbd", help="장치 이름 (/proc/bus/input/devices 에 보인다)")
    args = ap.parse_args()

    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for code in KEYS.values():
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    # struct uinput_setup { struct input_id id; char name[80]; __u32 ff_effects_max; }
    setup = struct.pack("HHHH80sI", BUS_USB, 0x1234, 0x5678, 1, args.name.encode(), 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, setup)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    print(f"[ukbd] device created ({args.name}); settling {SETTLE:.0f}s", flush=True)
    time.sleep(SETTLE)

    if not os.path.exists(args.fifo):
        os.mkfifo(args.fifo, 0o600)
    print(f"[ukbd] ready — fifo {args.fifo}", flush=True)

    try:
        while True:
            with open(args.fifo) as f:
                for line in f:
                    cmd = line.strip()
                    if not cmd:
                        continue
                    if cmd == "quit":
                        return 0
                    if cmd.startswith("key "):
                        try:
                            names = parse_combo(cmd[4:])
                        except KeyError as e:
                            print(f"[ukbd] unknown key {e}", flush=True)
                            continue
                        tap(fd, names)
                        print(f"[ukbd] tapped {'+'.join(names)}", flush=True)
                        continue
                    print(f"[ukbd] unknown command: {cmd}", flush=True)
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)
        try:
            os.unlink(args.fifo)
        except FileNotFoundError:
            pass
        print("[ukbd] device destroyed", flush=True)


if __name__ == "__main__":
    sys.exit(main())
