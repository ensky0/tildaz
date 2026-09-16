#!/usr/bin/env python3
"""Wayland 가상 포인터 (`zwlr_virtual_pointer_v1`) 를 **한 번 꽂고 유지**하며 FIFO 로 마우스를 넣는 데몬.

[`vkbd_linux.py`](vkbd_linux.py) 의 포인터 몫이다 (#647). headless sway · nested Hyprland 같은 wlroots 계열
compositor 안에서 tildaz 에 합성 hover · 클릭 · 드래그를 보낸다.

    XDG_RUNTIME_DIR=/run/user/1000/tz647 WAYLAND_DISPLAY=wayland-1 \\
        python3 tool/vptr_linux.py --fifo /run/user/1000/tz647/vptr.fifo &   # 데몬 (앱보다 먼저 띄운다)
    echo 'move 300 120'  > /run/user/1000/tz647/vptr.fifo    # 절대 좌표 (출력 픽셀)
    echo 'moveby 3 0'    > /run/user/1000/tz647/vptr.fifo    # 마지막 자리에서 상대 — 가속이 없다 (아래)
    echo 'down left'     > /run/user/1000/tz647/vptr.fifo    # 누름 · 뗌을 따로 (드래그 · 미끄러짐 회차)
    echo 'up left'       > /run/user/1000/tz647/vptr.fifo
    echo 'click left'    > /run/user/1000/tz647/vptr.fifo    # 누름 + 뗌
    echo 'scroll -3'     > /run/user/1000/tz647/vptr.fifo    # 휠 세 칸 위로 (양수 = 아래로)
    echo 'quit'          > /run/user/1000/tz647/vptr.fifo

**`ydotool` 을 쓰지 않는 이유 두 가지.** ① `ydotool mousemove -a` (절대 좌표) 는 조용히 아무 일도 하지
않는다 — `ydotoold` 의 가상 장치가 `EV=7` (SYN · KEY · REL) 이라 `ABS` 축이 없어 이벤트가 버려지는데 오류도
로그도 없다 (AGENTS.md `# 전역 hotkey` 절의 실측). ② `/dev/uinput` 장치는 **그 순간 포커스된 사용자 창**으로
가지만, 이 도구는 `WAYLAND_DISPLAY` 가 가리키는 compositor 에만 붙는다 — 사용자 세션을 건드리지 않는다.

**절대 좌표가 그대로 출력 픽셀이 된다.** `motion_absolute(time, x, y, x_extent, y_extent)` 는 compositor 에서
`x / x_extent` 로 정규화되므로, extent 를 출력 해상도로 주면 x 가 곧 픽셀이다. 포인터 **가속도 없다** —
상대 이동 (`ydotool mousemove` 기본) 으로 버티면 libinput 가속에 왜곡되는데 (같은 AGENTS.md 항목), 이
도구는 `moveby` 도 마지막 절대 좌표에 더해 다시 `motion_absolute` 로 낸다.

**extent 는 `wl_output.mode` 에서 읽는다.** 밖에서 계산해 넘기지 않는다 — AGENTS.md 의 *"창 영역을 좌표로
계산하지 말고 캡처에서 찾아요"* 와 같은 방향이고, 출력 크기를 잘못 주면 좌표가 통째로 어긋나는데 오류가
안 난다. `--extent WxH` 로 덮어쓸 수 있다 (출력이 여럿일 때).

FIFO 는 줄 단위다. 한 줄이 한 명령이고 `sleep <ms>` 를 사이에 둘 수 있다. 처리한 명령은 stdout 에 한 줄씩
남긴다 — 회차 로그로 쓴다.
"""
import argparse
import os
import select
import socket
import struct
import sys
import time

# ── evdev 버튼 코드 (linux/input-event-codes.h). Wayland 는 이 값을 그대로 쓴다 ──
BTN = {"left": 0x110, "right": 0x111, "middle": 0x112}
BTN_RELEASED, BTN_PRESSED = 0, 1


def wl_string(s):
    b = s.encode() + b"\0"
    pad = (-len(b)) % 4
    return struct.pack("<I", len(b)) + b + b"\0" * pad


class Wayland:
    """필요한 만큼만 구현한 Wayland wire client — registry · seat · output · virtual pointer · sync.

    `vkbd_linux.py` 의 같은 이름 클래스와 뼈대가 같지만 **콜백 판정이 다르다.** 그쪽은 "opcode 0 이면
    `wl_callback.done`" 으로 줄여 놨는데, 여기서는 `wl_output.geometry` 도 opcode 0 이라 그 규칙이 깨진다.
    그래서 sync 콜백 id 를 따로 들고 본다.
    """

    def __init__(self):
        run_dir = os.environ.get("XDG_RUNTIME_DIR")
        display = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
        path = display if display.startswith("/") else os.path.join(run_dir or "", display)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.path = path
        self.next_id = 2
        self.buf = b""
        self.globals = {}       # interface → (name, version)
        self.callbacks = set()  # 내가 만든 wl_callback id — done 이 오면 뺀다
        self.outputs = {}       # wl_output object id → (width, height)
        self.registry = self.alloc()
        self.send(1, 1, struct.pack("<I", self.registry))          # wl_display.get_registry
        self.roundtrip()

    def alloc(self):
        i = self.next_id
        self.next_id += 1
        return i

    def send(self, obj, opcode, payload=b""):
        size = 8 + len(payload)
        self.sock.sendall(struct.pack("<II", obj, (size << 16) | opcode) + payload)

    def roundtrip(self):
        cb = self.alloc()
        self.callbacks.add(cb)
        self.send(1, 0, struct.pack("<I", cb))                       # wl_display.sync
        deadline = time.monotonic() + 5.0
        while cb in self.callbacks:
            if time.monotonic() > deadline:
                raise SystemExit("vptr: roundtrip timed out (compositor not answering)")
            self.pump(0.5)

    def pump(self, timeout=0.0):
        r, _, _ = select.select([self.sock], [], [], timeout)
        if r:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise SystemExit("vptr: compositor closed the connection")
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
            raise SystemExit(f"vptr: wl_display.error object={bad} code={code}: {msg}")
        if obj in self.callbacks and opcode == 0:                     # wl_callback.done
            self.callbacks.discard(obj)
            return
        if obj == self.registry and opcode == 0:                      # wl_registry.global
            name = struct.unpack_from("<I", payload, 0)[0]
            n = struct.unpack_from("<I", payload, 4)[0]
            iface = payload[8:8 + n - 1].decode()
            off = 8 + n + ((-n) % 4)
            version = struct.unpack_from("<I", payload, off)[0]
            self.globals[iface] = (name, version)
            return
        if obj in self.outputs and opcode == 1:                       # wl_output.mode
            flags, w, h, _refresh = struct.unpack_from("<iiii", payload, 0)
            if flags & 1:                                             # WL_OUTPUT_MODE_CURRENT
                self.outputs[obj] = (w, h)
            return

    def bind(self, iface, want_version):
        if iface not in self.globals:
            raise SystemExit(f"vptr: compositor does not advertise {iface}")
        name, version = self.globals[iface]
        v = min(version, want_version)
        new_id = self.alloc()
        self.send(self.registry, 0, struct.pack("<I", name) + wl_string(iface) + struct.pack("<II", v, new_id))
        return new_id, v

    def output_extent(self):
        """첫 출력의 현재 mode 크기. `motion_absolute` 의 extent 로 쓴다."""
        if "wl_output" not in self.globals:
            raise SystemExit("vptr: compositor does not advertise wl_output")
        oid, _ = self.bind("wl_output", 2)
        self.outputs[oid] = None
        self.roundtrip()
        size = self.outputs.get(oid)
        if not size:
            raise SystemExit("vptr: wl_output did not report a current mode")
        return size


class VirtualPointer:
    # zwlr_virtual_pointer_v1 요청 opcode (wlr-virtual-pointer-unstable-v1.xml)
    MOTION, MOTION_ABS, BUTTON, AXIS, FRAME = 0, 1, 2, 3, 4
    AXIS_SOURCE, AXIS_STOP, AXIS_DISCRETE = 5, 6, 7
    AXIS_VERTICAL, AXIS_SOURCE_WHEEL = 0, 0
    #: 휠 한 칸이 싣는 `value`. libinput 이 실제 휠에 쓰는 값이고, 이것이 있어야
    #: `axis_discrete` 를 안 보는 client 도 같은 양을 본다.
    WHEEL_STEP = 10.0

    def __init__(self, wl, extent):
        self.wl = wl
        self.extent = extent
        self.seat, _ = wl.bind("wl_seat", 7)
        self.manager, _ = wl.bind("zwlr_virtual_pointer_manager_v1", 1)
        self.vp = wl.alloc()
        wl.send(self.manager, 0, struct.pack("<II", self.seat, self.vp))   # create_virtual_pointer(seat, id)
        wl.roundtrip()
        self.t0 = time.monotonic()
        self.x, self.y = extent[0] // 2, extent[1] // 2
        self.down_buttons = []

    def now_ms(self):
        return int((time.monotonic() - self.t0) * 1000) & 0xFFFFFFFF

    def frame(self):
        self.wl.send(self.vp, self.FRAME)
        self.wl.roundtrip()

    def move_to(self, x, y):
        """절대 좌표. compositor 가 `x / x_extent` 로 정규화하므로 extent = 출력 크기면 x 가 곧 픽셀이다."""
        ex, ey = self.extent
        self.x = max(0, min(ex - 1, int(x)))
        self.y = max(0, min(ey - 1, int(y)))
        self.wl.send(self.vp, self.MOTION_ABS,
                     struct.pack("<IIIII", self.now_ms(), self.x, self.y, ex, ey))
        self.frame()

    def move_by(self, dx, dy):
        """마지막 절대 좌표에 더해 **다시 절대로** 낸다 — 포인터 가속에 왜곡되지 않는다."""
        self.move_to(self.x + int(dx), self.y + int(dy))

    def button(self, name, pressed):
        code = BTN.get(name)
        if code is None:
            raise ValueError(f"unknown button: {name}")
        self.wl.send(self.vp, self.BUTTON,
                     struct.pack("<III", self.now_ms(), code, BTN_PRESSED if pressed else BTN_RELEASED))
        self.frame()
        if pressed:
            self.down_buttons.append(name)
        elif name in self.down_buttons:
            self.down_buttons.remove(name)

    def click(self, name, hold_ms=40):
        self.button(name, True)
        time.sleep(hold_ms / 1000.0)
        self.button(name, False)

    def scroll(self, clicks):
        """휠 `clicks` 칸. **양수 = 아래로** (Wayland 의 positive axis 와 같다).

        한 칸은 `axis_source` (wheel) → `axis_discrete` → `frame` 으로 낸다. `axis_discrete`
        하나가 연속값 (`value`) 과 칸 수 (`discrete`) 를 함께 실으므로 `axis` 를 따로 보내지
        않는다 — 둘 다 보내면 client 가 두 배로 센다. `fixed` 는 24.8 이라 `value * 256` 이다.
        """
        n = int(clicks)
        if n == 0:
            return
        step = 1 if n > 0 else -1
        value = int(self.WHEEL_STEP * 256) * step
        for _ in range(abs(n)):
            self.wl.send(self.vp, self.AXIS_SOURCE, struct.pack("<I", self.AXIS_SOURCE_WHEEL))
            self.wl.send(self.vp, self.AXIS_DISCRETE,
                         struct.pack("<IIii", self.now_ms(), self.AXIS_VERTICAL, value, step))
            self.frame()

    def release_all(self):
        for name in list(reversed(self.down_buttons)):
            self.button(name, False)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fifo", required=True, help="명령을 읽을 FIFO 경로 (없으면 만든다)")
    ap.add_argument("--extent", default=None, metavar="WxH",
                    help="절대 좌표의 기준 크기. 기본은 wl_output 의 현재 mode")
    ap.add_argument("--hold", type=int, default=40, help="click 의 누름 유지 ms (기본 40)")
    args = ap.parse_args()

    wl = Wayland()
    if args.extent:
        w, _, h = args.extent.partition("x")
        extent = (int(w), int(h))
    else:
        extent = wl.output_extent()
    vp = VirtualPointer(wl, extent)
    if not os.path.exists(args.fifo):
        os.mkfifo(args.fifo, 0o600)
    print(f"vptr: attached to {wl.path} · seat={vp.seat} · extent={extent[0]}x{extent[1]} · fifo={args.fifo}",
          flush=True)

    while True:
        with open(args.fifo, "r") as f:
            for raw in f:
                line = raw.rstrip("\n")
                if not line:
                    continue
                cmd, _, rest = line.partition(" ")
                try:
                    if cmd == "move":
                        x, y = rest.split()
                        vp.move_to(x, y)
                    elif cmd == "moveby":
                        dx, dy = rest.split()
                        vp.move_by(dx, dy)
                    elif cmd == "down":
                        vp.button(rest.strip() or "left", True)
                    elif cmd == "up":
                        vp.button(rest.strip() or "left", False)
                    elif cmd == "click":
                        vp.click(rest.strip() or "left", args.hold)
                    elif cmd == "scroll":
                        vp.scroll(rest.strip() or "1")
                    elif cmd == "sleep":
                        time.sleep(int(rest) / 1000.0)
                    elif cmd == "where":
                        print(f"  at {vp.x} {vp.y}", flush=True)
                    elif cmd == "quit":
                        vp.release_all()
                        print("vptr: quit", flush=True)
                        return
                    else:
                        print(f"  ! unknown command: {line}", flush=True)
                        continue
                    print(f"  {line}", flush=True)
                except Exception as e:  # noqa: BLE001 — 한 줄이 틀려도 데몬은 산다
                    print(f"  ! {line}: {e}", flush=True)
                wl.pump(0.0)


if __name__ == "__main__":
    sys.exit(main())
