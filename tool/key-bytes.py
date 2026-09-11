#!/usr/bin/env python3
"""터미널이 PTY 로 보낸 바이트를 그대로 찍는다.  종료는 Ctrl+]

    python3 tool/key-bytes.py           # legacy (기본) — 어떤 프로토콜도 켜지 않는다
    python3 tool/key-bytes.py kitty     # kitty keyboard 를 켠 앱 흉내 (CSI > 1 u)
    python3 tool/key-bytes.py mok2      # xterm modifyOtherKeys=2 를 켠 앱 흉내 (CSI > 4 ; 2 m)

tildaz 안에서 실행한다 (탭에서 그냥 치면 된다). raw 모드라 Ctrl+C 는 SIGINT 가 아니라
바이트 `03` 으로 보인다 — 그게 정상이다.
"""
import os, sys

mode = sys.argv[1] if len(sys.argv) > 1 else "legacy"
enable = {"kitty": b"\x1b[>1u", "mok2": b"\x1b[>4;2m"}.get(mode, b"")
disable = {"kitty": b"\x1b[<u", "mok2": b"\x1b[>4;0m"}.get(mode, b"")

if os.name == "nt":
    import ctypes
    k = ctypes.windll.kernel32
    h = k.GetStdHandle(-10)                     # STD_INPUT_HANDLE
    old = ctypes.c_uint32()
    k.GetConsoleMode(h, ctypes.byref(old))
    k.SetConsoleMode(h, 0x0200)                 # ENABLE_VIRTUAL_TERMINAL_INPUT 만
    restore = lambda: k.SetConsoleMode(h, old)
else:
    import termios, tty
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)                              # 에코 · 라인 편집 · ICRNL 끔
    restore = lambda: termios.tcsetattr(fd, termios.TCSADRAIN, saved)

out = sys.stdout.buffer
out.write(enable); out.flush()
print(f"[{mode}] 키를 누르세요. Ctrl+] 로 종료.", end="\r\n", flush=True)
try:
    buf = sys.stdin.buffer
    while True:
        b = buf.read1(64)
        if not b or b == b"\x1d":               # Ctrl+]
            break
        print(" ".join(f"{c:02x}" for c in b), "  ", repr(bytes(b)), end="\r\n", flush=True)
finally:
    out.write(disable); out.flush()
    restore()
