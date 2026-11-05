#!/usr/bin/env python3
"""zero-monitor-check 의 제어부 — nested mutter 에 가상 모니터 · 포인터 · 키를 넣는다 (#859).

`zero-monitor-check_linux.sh` 가 nested `gnome-shell` 의 세션 버스 안에서 띄운다. 명령은
<ctl>/cmd 에 한 줄로 쓰고 (원자적으로 — mv), 끝나면 <ctl>/ack 에 `<번호> <결과>` 를 적는다.

  <번호> start 1600x900 1280x720   가상 모니터를 크기마다 하나씩 만든다 (모두 생길 때까지 기다린다)
  <번호> stop                      모두 없앤다 → 모니터 0 개 (0 개가 될 때까지 기다린다)
  <번호> pointer <i> <x> <y>       i 번째 모니터 (start 순서) 의 좌표로 포인터를 옮긴다
  <번호> key <keysym>              키를 눌렀다 뗀다 (예: 0xffbe = F1)
  <번호> monitors                  지금 모니터 목록 (JSON)
  <번호> quit

mutter ScreenCast 의 `RecordVirtual` 은 스트림을 받는 쪽이 붙어야 모니터를 만든다. 받는 쪽은
`gst-launch-1.0 pipewiresrc` 인데, 자동 연결은 `target not found` 로 실패했다 (pipewire 1.6.10 ·
wireplumber 0.5.18). 그래서 `autoconnect=false` 로 띄우고 `pw-link` 로 포트를 직접 잇는다.
포인터 · 키는 같은 세션에 묶인 RemoteDesktop 으로 넣는다 — 그래서 커서 모니터가 실제로 바뀐다.
"""
import json
import os
import subprocess
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

CTL = sys.argv[1]
SINK = "tz-zmon-sink"
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
loop = GLib.MainLoop()
st = {"rd": None, "streams": [], "sizes": [], "gst": [], "linked": set(), "subs": []}


def log(msg):
    print(f"[vmon {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def call(dest, path, iface, method, args=None, rtype=None):
    return bus.call_sync(dest, path, iface, method, args,
                         GLib.VariantType(rtype) if rtype else None,
                         Gio.DBusCallFlags.NONE, 5000, None)


def monitors():
    """논리 모니터 목록 — connector · x · y · w · h · primary."""
    try:
        _serial, mons, logical, _props = call(
            "org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
            "org.gnome.Mutter.DisplayConfig", "GetCurrentState").unpack()
    except GLib.Error as e:
        return {"error": e.message}
    size = {}
    for spec, modes, _p in mons:
        for m in modes:
            if m[6].get("is-current"):
                size[spec[0]] = (m[1], m[2])
    out = []
    for x, y, scale, _t, primary, specs, _p in logical:
        w, h = size.get(specs[0][0], (0, 0))
        out.append({"connector": specs[0][0], "x": x, "y": y,
                    "w": round(w / scale), "h": round(h / scale), "primary": primary})
    return out


def link_ports():
    """아직 안 이은 gnome-shell 출력 포트와 우리 sink 입력 포트를 짝지어 잇는다. 짝은 아무렇게나 — sink 는 버린다."""
    def ports(flag, pat):
        out = subprocess.run(["pw-link", flag, "-I"], capture_output=True, text=True).stdout
        return [ln.split()[0] for ln in out.splitlines() if pat in ln and ln.split()[0] not in st["linked"]]
    outs, ins = ports("-o", "gnome-shell:output"), ports("-i", f"{SINK}")
    for o, i in zip(outs, ins):
        r = subprocess.run(["pw-link", o, i], capture_output=True, text=True)
        log(f"pw-link {o} -> {i} rc={r.returncode} {r.stderr.strip()}")
        if r.returncode == 0:
            st["linked"].update((o, i))
    return len(st["linked"]) // 2


def wait(pred, timeout=10.0):
    ctx = GLib.MainContext.default()
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        while ctx.pending():
            ctx.iteration(False)
        if pred():
            return True
        time.sleep(0.1)
    return False


def start(sizes):
    if st["rd"]:
        return "already started"
    (rd,) = call("org.gnome.Mutter.RemoteDesktop", "/org/gnome/Mutter/RemoteDesktop",
                 "org.gnome.Mutter.RemoteDesktop", "CreateSession", None, "(o)").unpack()
    sid = bus.call_sync("org.gnome.Mutter.RemoteDesktop", rd, "org.freedesktop.DBus.Properties", "Get",
                        GLib.Variant("(ss)", ("org.gnome.Mutter.RemoteDesktop.Session", "SessionId")),
                        GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
    (sc,) = call("org.gnome.Mutter.ScreenCast", "/org/gnome/Mutter/ScreenCast",
                 "org.gnome.Mutter.ScreenCast", "CreateSession",
                 GLib.Variant("(a{sv})", ({"remote-desktop-session-id": GLib.Variant("s", sid)},)), "(o)").unpack()
    st["streams"], st["sizes"], st["linked"] = [], [], set()
    for w, h in sizes:
        mode = {"size": GLib.Variant("(uu)", (w, h)), "is-preferred": GLib.Variant("b", True)}
        props = {"cursor-mode": GLib.Variant("u", 0), "is-platform": GLib.Variant("b", True),
                 "modes": GLib.Variant("aa{sv}", [mode])}
        (path,) = call("org.gnome.Mutter.ScreenCast", sc, "org.gnome.Mutter.ScreenCast.Session",
                       "RecordVirtual", GLib.Variant("(a{sv})", (props,)), "(o)").unpack()
        st["streams"].append(path)
        st["sizes"].append((w, h))
    for _ in sizes:
        st["gst"].append(subprocess.Popen(
            ["gst-launch-1.0", "pipewiresrc", "autoconnect=false", f"client-name={SINK}",
             "always-copy=true", "!", "fakesink"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    call("org.gnome.Mutter.RemoteDesktop", rd, "org.gnome.Mutter.RemoteDesktop.Session", "Start")
    st["rd"] = rd
    ok = wait(lambda: link_ports() >= len(sizes) and len(monitors()) == len(sizes))
    return f"{'ok' if ok else 'timeout'} {json.dumps(monitors())}"


def stop():
    if not st["rd"]:
        return "not started"
    try:
        call("org.gnome.Mutter.RemoteDesktop", st["rd"], "org.gnome.Mutter.RemoteDesktop.Session", "Stop")
    except GLib.Error as e:
        log(f"stop error: {e.message}")
    st["rd"] = None
    ok = wait(lambda: monitors() == [])
    for g in st["gst"]:
        g.terminate()
    st["gst"] = []
    return f"{'ok' if ok else 'timeout'} {json.dumps(monitors())}"


def pointer(i, x, y):
    # 세션을 연 직후의 이동은 버려질 때가 있다 (GNOME Shell 51.1 실측 — 확장이 본 포인터가 0,0 이었고,
    # 버릴 이동 하나를 먼저 보내도 다음 회차에 또 그랬다). 밖에서 포인터 위치를 읽을 길이 없어서 1 초
    # 동안 열 번 보내고 마지막을 목표 자리로 둔다. 같은 자리는 이동으로 치지 않을 수 있어 1 px 씩 흔든다.
    for k in range(10):
        dx = 0 if k == 9 else (1 if k % 2 else -1)
        call("org.gnome.Mutter.RemoteDesktop", st["rd"], "org.gnome.Mutter.RemoteDesktop.Session",
             "NotifyPointerMotionAbsolute", GLib.Variant("(sdd)", (st["streams"][i], x + dx, y)))
        time.sleep(0.1)
    return "ok"


def key(keysym):
    for down in (True, False):
        call("org.gnome.Mutter.RemoteDesktop", st["rd"], "org.gnome.Mutter.RemoteDesktop.Session",
             "NotifyKeyboardKeysym", GLib.Variant("(ub)", (keysym, down)))
        time.sleep(0.05)
    return "ok"


def handle(line):
    seq, cmd, *args = line.split()
    try:
        if cmd == "start":
            res = start([tuple(int(v) for v in a.split("x")) for a in args])
        elif cmd == "stop":
            res = stop()
        elif cmd == "pointer":
            res = pointer(int(args[0]), float(args[1]), float(args[2]))
        elif cmd == "key":
            res = key(int(args[0], 0))
        elif cmd == "monitors":
            res = json.dumps(monitors())
        elif cmd == "quit":
            stop()
            loop.quit()
            res = "ok"
        else:
            res = f"unknown {cmd}"
    except Exception as e:  # 도구 오류는 ack 로 돌려 셸 스크립트가 멈추게 한다
        res = f"error {e}"
    log(f"{cmd} {' '.join(args)} -> {res}")
    tmp = os.path.join(CTL, "ack.tmp")
    with open(tmp, "w") as f:
        f.write(f"{seq} {res}\n")
    os.replace(tmp, os.path.join(CTL, "ack"))


def poll():
    p = os.path.join(CTL, "cmd")
    if os.path.exists(p):
        line = open(p).read().strip()
        os.unlink(p)
        if line:
            handle(line)
    return True


GLib.timeout_add(100, poll)
log("ready")
loop.run()
