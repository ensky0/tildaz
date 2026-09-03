#!/usr/bin/env python3
"""Wayland 가상 키보드 (`zwp_virtual_keyboard_v1`) 를 **한 번 꽂고 유지**하며 FIFO 로 키를 넣는 데몬.

headless sway · nested Hyprland 같은 wlroots 계열 compositor 안에서 tildaz 에 합성 키를 보낼 때 쓴다
(#583 A7 · A8). 사용자 세션 (KWin) 의 실제 입력 장치를 건드리지 않는다 — `ydotool` (`/dev/uinput`) 은
**포커스된 사용자 창**으로 가지만, 이 도구는 `WAYLAND_DISPLAY` 가 가리키는 compositor 에만 붙는다.

    XDG_RUNTIME_DIR=/run/user/1000/tz583 WAYLAND_DISPLAY=wayland-1 \\
        python3 dist/linux/vkbd.py --fifo /run/user/1000/tz583/vkbd.fifo &     # 데몬 (먼저 띄운다)
    echo 'type touch /tmp/probe'   > /run/user/1000/tz583/vkbd.fifo            # 글자 · 기호 (us 배열)
    echo 'key Return'              > /run/user/1000/tz583/vkbd.fifo            # 키 하나
    echo 'key ctrl+shift+t'        > /run/user/1000/tz583/vkbd.fifo            # 조합 (ctrl · shift · alt · super)
    echo 'key alt+F4'              > /run/user/1000/tz583/vkbd.fifo
    echo 'quit'                    > /run/user/1000/tz583/vkbd.fifo

왜 `wtype` 이 아닌가 — 두 가지가 실측으로 걸렸다 (2026-09-03 · 미니PC Firebat ZY-A8 · headless sway 1.12).

1. `wtype` 은 **새 글자가 나올 때마다 keymap 을 다시 올린다.** keymap 이 바뀌는 사이의 키가 빠지거나 다른
   글자로 읽혀 `touch …` 가 `ouch …` 로 들어갔다.
2. `wtype` 은 호출마다 가상 키보드를 **꽂고 뽑는다.** 그래서 두 번째 호출부터는 seat 의 keyboard capability
   가 "빠졌다 다시 붙는" 왕복이 되는데, tildaz 가 그 왕복에서 `wl_keyboard` 를 다시 만들지 않아 키가 아예
   닿지 않았다 (앱 결함 후보 — #583 에 적었다). 이 도구는 한 번 꽂고 유지하므로 그 경로를 밟지 않는다.

keymap 은 `xkbcli compile-keymap --layout us` 로 만든 표준 us 배열을 **연결 직후 한 번** 올린다. 그래서
`type` 은 us 배열에서 칠 수 있는 ASCII 만 받는다 — 대문자 · 기호는 Shift 조합으로 낸다.

**modifier 는 `modifiers` 요청으로 직접 보낸다.** `zwp_virtual_keyboard_v1` 은 modifier · group 상태를 client
책임으로 두고, wlroots 는 가상 키보드의 key 이벤트로 xkb 상태를 갱신하지 않는다 (`update_state = false`).
Shift 키의 press 만 보내면 compositor 는 그 뒤 키를 **Shift 없이** 해석한다 — 첫 회차에서 `Ctrl+Shift+T` 가 `t`
로, `>` 가 `.` 로 들어갔다 (2026-09-03 실측). 그래서 modifier 키 press → `modifiers(mask)` → 키 → `modifiers(0)`
→ modifier 키 release 순서로 낸다 (실제 키보드에서 client 가 받는 순서와 같다). mask 비트는 xkb 의 real
modifier 순서다 — Shift 0 · Lock 1 · Control 2 · Mod1 (Alt) 3 · Mod4 (Super) 6.

FIFO 는 줄 단위다. 한 줄이 한 명령이고, 명령 사이에 `sleep <ms>` 를 둘 수 있다. 처리한 명령은 stdout 에
한 줄씩 남긴다 — 회차 로그로 쓴다.
"""
import argparse
import array
import os
import select
import socket
import struct
import subprocess
import sys
import time

# ── evdev keycode (linux/input-event-codes.h). Wayland 는 이 값을 그대로 쓰고 xkb 쪽이 +8 한다 ──
KEY = {
    "esc": 1, "escape": 1,
    "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
    "minus": 12, "equal": 13, "backspace": 14, "tab": 15,
    "q": 16, "w": 17, "e": 18, "r": 19, "t": 20, "y": 21, "u": 22, "i": 23, "o": 24, "p": 25,
    "bracketleft": 26, "bracketright": 27, "return": 28, "enter": 28, "ctrl": 29,
    "a": 30, "s": 31, "d": 32, "f": 33, "g": 34, "h": 35, "j": 36, "k": 37, "l": 38,
    "semicolon": 39, "apostrophe": 40, "grave": 41, "shift": 42, "backslash": 43,
    "z": 44, "x": 45, "c": 46, "v": 47, "b": 48, "n": 49, "m": 50,
    "comma": 51, "period": 52, "slash": 53, "alt": 56, "space": 57,
    "f1": 59, "f2": 60, "f3": 61, "f4": 62, "f5": 63, "f6": 64, "f7": 65, "f8": 66, "f9": 67, "f10": 68,
    "f11": 87, "f12": 88,
    "home": 102, "up": 103, "pageup": 104, "left": 105, "right": 106, "end": 107, "down": 108,
    "pagedown": 109, "insert": 110, "delete": 111, "super": 125, "logo": 125,
}
MOD_NAMES = {"ctrl", "shift", "alt", "super", "logo"}
# xkb real modifier 비트 — `modifiers(mods_depressed, …)` 에 넣는 값. keycode → mask.
MOD_MASK = {KEY["shift"]: 1 << 0, KEY["ctrl"]: 1 << 2, KEY["alt"]: 1 << 3, KEY["super"]: 1 << 6}

# ── us 배열 — 글자 → (keycode, shift 필요) ──
CHARS = {}
for ch, name in zip("abcdefghijklmnopqrstuvwxyz", "abcdefghijklmnopqrstuvwxyz"):
    CHARS[ch] = (KEY[name], False)
    CHARS[ch.upper()] = (KEY[name], True)
for ch in "1234567890":
    CHARS[ch] = (KEY[ch], False)
for ch, base in zip("!@#$%^&*()", "1234567890"):
    CHARS[ch] = (KEY[base], True)
for ch, name, shifted in [
    ("-", "minus", False), ("_", "minus", True), ("=", "equal", False), ("+", "equal", True),
    ("[", "bracketleft", False), ("{", "bracketleft", True), ("]", "bracketright", False), ("}", "bracketright", True),
    (";", "semicolon", False), (":", "semicolon", True), ("'", "apostrophe", False), ('"', "apostrophe", True),
    ("`", "grave", False), ("~", "grave", True), ("\\", "backslash", False), ("|", "backslash", True),
    (",", "comma", False), ("<", "comma", True), (".", "period", False), (">", "period", True),
    ("/", "slash", False), ("?", "slash", True), (" ", "space", False), ("\t", "tab", False), ("\n", "return", False),
]:
    CHARS[ch] = (KEY[name], shifted)


def wl_string(s):
    b = s.encode() + b"\0"
    pad = (-len(b)) % 4
    return struct.pack("<I", len(b)) + b + b"\0" * pad


class Wayland:
    """필요한 만큼만 구현한 Wayland wire client — registry · seat · virtual keyboard · sync."""

    def __init__(self):
        run_dir = os.environ.get("XDG_RUNTIME_DIR")
        display = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
        path = display if display.startswith("/") else os.path.join(run_dir or "", display)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.path = path
        self.next_id = 2
        self.buf = b""
        self.globals = {}      # interface → (name, version)
        self.done = set()      # callback ids that fired
        self.registry = self.alloc()
        self.send(1, 1, struct.pack("<I", self.registry))          # wl_display.get_registry
        self.roundtrip()

    def alloc(self):
        i = self.next_id
        self.next_id += 1
        return i

    def send(self, obj, opcode, payload=b"", fds=None):
        size = 8 + len(payload)
        data = struct.pack("<II", obj, (size << 16) | opcode) + payload
        if fds:
            self.sock.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))])
        else:
            self.sock.sendall(data)

    def roundtrip(self):
        cb = self.alloc()
        self.send(1, 0, struct.pack("<I", cb))                       # wl_display.sync
        deadline = time.monotonic() + 5.0
        while cb not in self.done:
            if time.monotonic() > deadline:
                raise SystemExit("vkbd: roundtrip timed out (compositor not answering)")
            self.pump(0.5)

    def pump(self, timeout=0.0):
        r, _, _ = select.select([self.sock], [], [], timeout)
        if r:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise SystemExit("vkbd: compositor closed the connection")
            self.buf += chunk
        while len(self.buf) >= 8:
            obj, word = struct.unpack_from("<II", self.buf, 0)
            size, opcode = word >> 16, word & 0xFFFF
            if len(self.buf) < size:
                break
            payload = self.buf[8:size]
            self.buf = self.buf[size:]
            self.handle(obj, opcode, payload)

    def handle(self, obj, opcode, payload):
        if obj == 1 and opcode == 0:                                  # wl_display.error
            bad, code = struct.unpack_from("<II", payload, 0)
            n = struct.unpack_from("<I", payload, 8)[0]
            msg = payload[12:12 + n - 1].decode(errors="replace")
            raise SystemExit(f"vkbd: wl_display.error object={bad} code={code}: {msg}")
        if obj == self.registry and opcode == 0:                      # wl_registry.global
            name = struct.unpack_from("<I", payload, 0)[0]
            n = struct.unpack_from("<I", payload, 4)[0]
            iface = payload[8:8 + n - 1].decode()
            off = 8 + n + ((-n) % 4)
            version = struct.unpack_from("<I", payload, off)[0]
            self.globals[iface] = (name, version)
            return
        if opcode == 0 and obj not in (1, self.registry):             # wl_callback.done (we only make callbacks besides seat/vk)
            self.done.add(obj)

    def bind(self, iface, want_version):
        if iface not in self.globals:
            raise SystemExit(f"vkbd: compositor does not advertise {iface}")
        name, version = self.globals[iface]
        v = min(version, want_version)
        new_id = self.alloc()
        self.send(self.registry, 0, struct.pack("<I", name) + wl_string(iface) + struct.pack("<II", v, new_id))
        return new_id, v


class VirtualKeyboard:
    def __init__(self, wl, layout):
        self.wl = wl
        self.seat, _ = wl.bind("wl_seat", 7)
        self.manager, _ = wl.bind("zwp_virtual_keyboard_manager_v1", 1)
        self.vk = wl.alloc()
        wl.send(self.manager, 0, struct.pack("<II", self.seat, self.vk))   # create_virtual_keyboard(seat, id)
        keymap = subprocess.run(["xkbcli", "compile-keymap", "--layout", layout], capture_output=True, check=True).stdout
        keymap += b"\0"
        fd = os.memfd_create("vkbd-keymap")
        os.write(fd, keymap)
        wl.send(self.vk, 0, struct.pack("<II", 1, len(keymap)), fds=[fd])   # keymap(format=xkb_v1, fd, size)
        os.close(fd)
        wl.roundtrip()
        self.t0 = time.monotonic()
        self.down = []

    def now_ms(self):
        return int((time.monotonic() - self.t0) * 1000) & 0xFFFFFFFF

    def key(self, code, pressed):
        self.wl.send(self.vk, 1, struct.pack("<III", self.now_ms(), code, 1 if pressed else 0))
        if pressed:
            self.down.append(code)
        elif code in self.down:
            self.down.remove(code)
        self.wl.pump(0.0)

    def modifiers(self, depressed):
        # modifiers(mods_depressed, mods_latched, mods_locked, group) — 프로토콜이 client 에게 맡긴 상태.
        self.wl.send(self.vk, 2, struct.pack("<IIII", depressed, 0, 0, 0))

    def tap(self, code, mods=(), hold_ms=8):
        mask = 0
        for m in mods:
            self.key(m, True)
            mask |= MOD_MASK[m]
            self.modifiers(mask)
            time.sleep(0.004)
        self.key(code, True)
        time.sleep(hold_ms / 1000.0)
        self.key(code, False)
        for m in reversed(mods):
            time.sleep(0.004)
            mask &= ~MOD_MASK[m]
            self.modifiers(mask)
            self.key(m, False)
        self.wl.roundtrip()

    def type_text(self, text, delay_ms):
        for ch in text:
            if ch not in CHARS:
                print(f"  ! skipped (not on us layout): {ch!r}", flush=True)
                continue
            code, shifted = CHARS[ch]
            self.tap(code, (KEY["shift"],) if shifted else ())
            time.sleep(delay_ms / 1000.0)

    def combo(self, spec):
        parts = [p.strip() for p in spec.split("+") if p.strip()]
        mods = [KEY[p.lower()] for p in parts[:-1]]
        for p in parts[:-1]:
            if p.lower() not in MOD_NAMES:
                raise ValueError(f"not a modifier: {p}")
        last = parts[-1]
        code = KEY.get(last.lower())
        if code is None and len(last) == 1 and last in CHARS:
            code, shifted = CHARS[last]
            if shifted and KEY["shift"] not in mods:
                mods.append(KEY["shift"])
        if code is None:
            raise ValueError(f"unknown key: {last}")
        self.tap(code, mods)

    def release_all(self):
        for code in list(reversed(self.down)):
            self.key(code, False)
        self.wl.roundtrip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fifo", required=True, help="명령을 읽을 FIFO 경로 (없으면 만든다)")
    ap.add_argument("--layout", default="us", help="올릴 xkb layout (기본 us — CHARS 표가 us 기준이다)")
    ap.add_argument("--delay", type=int, default=12, help="type 의 글자 사이 ms (기본 12)")
    args = ap.parse_args()

    wl = Wayland()
    vk = VirtualKeyboard(wl, args.layout)
    if not os.path.exists(args.fifo):
        os.mkfifo(args.fifo, 0o600)
    print(f"vkbd: attached to {wl.path} · seat={vk.seat} · keymap={args.layout} · fifo={args.fifo}", flush=True)

    while True:
        with open(args.fifo, "r") as f:
            for raw in f:
                line = raw.rstrip("\n")
                if not line:
                    continue
                cmd, _, rest = line.partition(" ")
                try:
                    if cmd == "type":
                        vk.type_text(rest, args.delay)
                    elif cmd == "key":
                        vk.combo(rest)
                    elif cmd == "sleep":
                        time.sleep(int(rest) / 1000.0)
                    elif cmd == "quit":
                        vk.release_all()
                        print("vkbd: quit", flush=True)
                        return
                    else:
                        print(f"  ! unknown command: {line}", flush=True)
                        continue
                    print(f"  {line}", flush=True)
                except Exception as e:  # noqa: BLE001 — 한 줄이 틀려도 데몬은 산다
                    print(f"  ! {line}: {e}", flush=True)
                wl.pump(0.0)


if __name__ == "__main__":
    main()
