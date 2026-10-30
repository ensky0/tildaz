#!/usr/bin/env python3
"""KWin 에 물어 프로세스의 창 위치를 찍는다 — KDE Plasma 전용 (#756).

    tool/kwin-window_linux.py --child-pid <터미널 안 프로그램의 pid> [--activate]
    tool/kwin-window_linux.py --child-pid <pid> --click          # 창 가운데를 한 번 누른다
    tool/kwin-window_linux.py --child-pid <pid> --check-active   # 활성 창이 그 창이면 0, 아니면 3
    tool/kwin-window_linux.py --active-output                    # → name=eDP-1 (새 창이 뜰 화면)
    → rect=X,Y,W,H output=OW,OH dpr=S  (논리 좌표 · 창 영역은 그 화면 기준 · S 는 화면 배율)

- **창은 터미널 안에서 도는 프로그램의 조상 pid 로 찾는다.** 띄운 프로세스와 창 주인이 다른 대상이 있다 —
  kitty `--detach` 는 띄운 부모가 바로 끝나고, GNOME Terminal 은 D-Bus 로 뜬 `gnome-terminal-server` 가 창을
  그린다. 어느 쪽이든 터미널 안 프로그램의 조상 사슬에는 창 주인이 있다.
- 결과는 KWin 스크립트가 `callDBus` 로 이 프로세스에 돌려준다 — KWin 스크립트는 값을 반환할 통로가 없다.
  `callDBus` 는 KWin 6.7.5 `scripting.cpp` 에 있다.
- 영역은 `clientGeometry` (창 장식을 뺀 본문) 다. 장식 (제목 막대) 의 hover · 포커스 표시가 키의 결과로
  잡히지 않게.
- `--activate` 는 그 창을 활성 창으로 만든다 (`hygiene.sh` 의 창 올리기와 같은 방식). layer-shell 창은 이것만으로
  키보드 포커스를 못 받을 수 있어서 측정기가 따로 창을 누른다.
- `--click` 은 창 가운데를 절대좌표 uinput 포인터로 한 번 누른다. 포커스가 있는지에 따라 커서 깜빡임 같은
  유휴 동작이 달라져서 (`compare-memory.sh` 머리 주석) 모든 대상을 같게 둔다. 축 0..32767 을 libinput 이
  화면 전체에 펼치므로 화면이 하나라고 본다 (`tool/key-to-screen_linux.c` 와 같은 방식).
- `--check-active` 는 KWin 의 지금 활성 창이 그 창인지 본다 (#826). 합성 키는 포커스를 가진 창으로 가서, 아니면
  사용자가 쓰던 창에 들어간다 — 2026-10-28 KDE 회차에서 측정기의 `a` 가 VS Code 에 들어갔다. 측정기는 키를
  보내기 전마다 이것을 부르고, 아니면 키를 보내지 않는다.
- `--active-output` 은 KWin 의 활성 화면 (`workspace.activeScreen`) 이름을 찍는다 (#838). 새 창은 우선순위
  (주 화면) 가 아니라 이 화면에 뜬다 — 2026-10-31 화면 둘 (내장 · DELL U2723QE) 에서 foot 과 TildaZ 측정 창이
  모두 포인터가 있는 화면에 떴다. `hygiene.sh` 가 이 화면의 주사율을 본다.
"""

import argparse
import fcntl
import os
import struct
import sys
import tempfile
import time

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

IFACE = "me.ensky0.TildazBench"

# `linux/uinput.h` · `linux/input-event-codes.h`. 앞 넷은 `tool/ukbd_linux.py` 와 같다.
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UI_DEV_SETUP = 0x405C5503  # sizeof(struct uinput_setup) = 92
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_ABS_SETUP = 0x401C5504  # sizeof(struct uinput_abs_setup) = 28 (u16 + 채움 2 + input_absinfo 24)
UI_SET_ABSBIT = 0x40045567
UI_SET_PROPBIT = 0x4004556E
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
ABS_X, ABS_Y, BTN_LEFT, INPUT_PROP_POINTER, BUS_VIRTUAL = 0, 1, 0x110, 0, 6


def click(x, y, out_w, out_h):
    """화면 물리 px (x, y) 를 한 번 누른다. 장치는 만들고 바로 치운다."""
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    try:
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
        fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_ABS)
        fcntl.ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER)
        for axis in (ABS_X, ABS_Y):
            fcntl.ioctl(fd, UI_SET_ABSBIT, axis)
            fcntl.ioctl(fd, UI_ABS_SETUP, struct.pack("Hxx6i", axis, 0, 0, 32767, 0, 0, 0))
        fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("HHHH80sI", BUS_VIRTUAL, 0, 0, 1, b"tildaz-bench pointer", 0))
        fcntl.ioctl(fd, UI_DEV_CREATE)
        time.sleep(0.5)  # compositor 가 새 장치를 붙일 때까지

        def ev(t, c, v):
            os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))

        ev(EV_ABS, ABS_X, int(x * 32767 / max(out_w - 1, 1)))
        ev(EV_ABS, ABS_Y, int(y * 32767 / max(out_h - 1, 1)))
        ev(EV_SYN, 0, 0)
        time.sleep(0.06)
        ev(EV_KEY, BTN_LEFT, 1)
        ev(EV_SYN, 0, 0)
        time.sleep(0.03)
        ev(EV_KEY, BTN_LEFT, 0)
        ev(EV_SYN, 0, 0)
        time.sleep(0.1)
        fcntl.ioctl(fd, UI_DEV_DESTROY)
    finally:
        os.close(fd)


def ancestors(pid):
    out = []
    while pid > 1:
        out.append(pid)
        try:
            with open(f"/proc/{pid}/stat") as f:
                # comm 에 공백 · 괄호가 들어갈 수 있어 마지막 ')' 뒤에서 자른다.
                pid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return out


class Receiver(dbus.service.Object):
    def __init__(self, bus, loop):
        super().__init__(bus, "/")
        self.loop = loop
        self.value = None

    @dbus.service.method(IFACE, in_signature="s", out_signature="")
    def Report(self, value):
        self.value = str(value)
        self.loop.quit()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--child-pid", type=int)
    ap.add_argument("--active-output", action="store_true")
    ap.add_argument("--activate", action="store_true")
    ap.add_argument("--click", action="store_true")
    ap.add_argument("--check-active", action="store_true")
    ap.add_argument("--timeout", type=float, default=3.0)
    a = ap.parse_args()
    if a.active_output:
        pids = []
    elif a.child_pid is None:
        ap.error("--child-pid 나 --active-output 중 하나가 필요해요")
    else:
        pids = ancestors(a.child_pid)
    if not a.active_output and not pids:
        print(f"pid {a.child_pid} 가 없어요", file=sys.stderr)
        return 2

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = f"{IFACE}.P{os.getpid()}"
    held = dbus.service.BusName(name, bus)  # noqa: F841 — 쥐고 있어야 이름이 산다
    loop = GLib.MainLoop()
    rx = Receiver(bus, loop)

    # `activeWindow` 는 Plasma 6, `activeClient` 는 5 다 (`hygiene.sh` 와 같은 갈림).
    if a.active_output:
        js = f"""
var o = workspace.activeScreen;
callDBus("{name}", "/", "{IFACE}", "Report", o ? "name=" + o.name : "none");
"""
    else:
        js = f"""
var pids = {pids};
var list = workspace.windowList ? workspace.windowList() : workspace.clientList();
var best = null;
for (var i = 0; i < list.length; i++) {{
    var w = list[i];
    var k = pids.indexOf(w.pid);
    if (k >= 0 && w.clientGeometry.width > 0 && (best === null || k < best.k)) best = {{w: w, k: k}};
}}
var msg = "none";
if (best !== null) {{
    var w = best.w, g = w.clientGeometry, o = w.output.geometry;
    if ({str(a.activate).lower()}) {{
        w.minimized = false;
        if (workspace.windowList) {{ workspace.activeWindow = w; }} else {{ workspace.activeClient = w; }}
    }}
    msg = "rect=" + (g.x - o.x) + "," + (g.y - o.y) + "," + g.width + "," + g.height
        + " output=" + o.width + "," + o.height + " dpr=" + w.output.devicePixelRatio
        + " pid=" + w.pid + " class=" + w.resourceClass;
    var act = workspace.windowList ? workspace.activeWindow : workspace.activeClient;
    msg += " active=" + (act === w ? "yes" : "no") + " active_pid=" + (act ? act.pid : 0)
        + " active_class=" + (act ? act.resourceClass : "-")
        + " active_caption=" + (act ? String(act.caption).replace(/\\s+/g, "_") || "-" : "-");
}}
callDBus("{name}", "/", "{IFACE}", "Report", msg);
"""
    plugin = f"tildazbenchwin{os.getpid()}"
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(js)
        path = f.name
    kwin = bus.get_object("org.kde.KWin", "/Scripting")
    scripting = dbus.Interface(kwin, "org.kde.kwin.Scripting")
    try:
        # `loadScript` 는 `(s)` · `(ss)` 두 판이 있어서 introspection 이 앞의 것을 고른다 — 시그니처를 준다.
        sid = int(bus.call_blocking("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "loadScript",
                                    "ss", [path, plugin]))
        script = dbus.Interface(bus.get_object("org.kde.KWin", f"/Scripting/Script{sid}"), "org.kde.kwin.Script")
        GLib.timeout_add(int(a.timeout * 1000), loop.quit)
        script.run()
        loop.run()
    finally:
        try:
            scripting.unloadScript(plugin)
        except dbus.DBusException:
            pass
        os.unlink(path)

    if rx.value is None:
        print("KWin 이 답하지 않았어요", file=sys.stderr)
        return 2
    if rx.value == "none":
        print("KWin 에 활성 화면이 없어요" if a.active_output else f"조상 pid {pids} 의 창이 없어요", file=sys.stderr)
        return 1
    print(rx.value)
    if a.check_active and " active=yes" not in rx.value:
        # 측정기의 `round.err` 에 남아 어느 창이 포커스를 가졌는지 보인다.
        print("활성 창이 대상이 아니에요: " + " ".join(kv for kv in rx.value.split() if kv.startswith("active")),
              file=sys.stderr)
        return 3
    if a.click:
        f = dict(kv.split("=", 1) for kv in rx.value.split())
        rx_, ry_, rw_, rh_ = (float(v) for v in f["rect"].split(","))
        ow, oh = (float(v) for v in f["output"].split(","))
        dpr = float(f["dpr"])
        click((rx_ + rw_ / 2) * dpr, (ry_ + rh_ / 2) * dpr, round(ow * dpr), round(oh * dpr))
    return 0


if __name__ == "__main__":
    sys.exit(main())
