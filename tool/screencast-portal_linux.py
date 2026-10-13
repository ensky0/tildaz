#!/usr/bin/env python3
"""xdg-desktop-portal ScreenCast 를 열고 PipeWire fd 를 넘겨 명령 하나를 실행한다 (#756).

    tool/screencast-portal_linux.py [--token-file F] -- <명령> … {fd} … {node} …

화면 하나를 커서 없이 연다. 명령 인자의 `{fd}` · `{node}` 를 받은 값으로 바꿔 실행하고, 명령이 끝날 때까지
세션을 쥐고 있다 (세션은 이 프로세스의 D-Bus 연결에 묶여 있어서 먼저 끝나면 스트림도 끊긴다). 종료 코드는
명령의 것을 그대로 돌려준다.

- **권한 창은 처음 한 번만 뜬다.** `persist_mode = 2` (권한을 거둘 때까지) 로 받은 `restore_token` 을
  `--token-file` (기본 `$XDG_STATE_HOME/tildaz-bench/screencast.token`) 에 두고 다음 실행에 준다. 토큰은
  한 번 쓰면 바뀌므로 매번 새 값으로 덮어쓴다 (portal 문서의 `restore_token`).
- **창이 아니라 화면을 고른다.** 비교 측정은 회차마다 새 창을 띄워서, 창 단위로 고르면 매번 권한 창이 뜬다.
  창 영역은 측정기가 따로 받는다 (`tool/kwin-window_linux.py`).
- 순서와 옵션 키는 OBS `plugins/linux-pipewire/screencast-portal.c` 와 같다 —
  `CreateSession` → `SelectSources` (`types` · `multiple` · `cursor_mode` · `persist_mode` · `restore_token`)
  → `Start` → `OpenPipeWireRemote`.
"""

import argparse
import os
import secrets
import subprocess
import sys

import dbus
import dbus.mainloop.glib
from gi.repository import GLib

PORTAL = "org.freedesktop.portal.Desktop"
PATH = "/org/freedesktop/portal/desktop"
SC = "org.freedesktop.portal.ScreenCast"
MONITOR = 1
CURSOR_HIDDEN = 1


def default_token_file():
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "tildaz-bench", "screencast.token")


class Portal:
    def __init__(self):
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SessionBus()
        self.obj = self.bus.get_object(PORTAL, PATH)
        self.sc = dbus.Interface(self.obj, SC)
        self.sender = self.bus.get_unique_name()[1:].replace(".", "_")
        self.loop = GLib.MainLoop()

    def call(self, method, *args, options):
        """요청을 보내고 `Response` 신호를 기다린다. (응답 코드, 결과) 를 돌려준다."""
        token = "tz" + secrets.token_hex(6)
        options["handle_token"] = token
        path = f"{PATH}/request/{self.sender}/{token}"
        got = {}

        def on_response(code, results):
            got["code"], got["results"] = int(code), results
            self.loop.quit()

        # 신호를 먼저 구독한다 — 응답이 호출 반환보다 먼저 올 수 있다 (portal 문서의 Request 절).
        match = self.bus.add_signal_receiver(on_response, "Response", "org.freedesktop.portal.Request", PORTAL, path)
        getattr(self.sc, method)(*args, dbus.Dictionary(options, signature="sv"))
        self.loop.run()
        match.remove()
        return got["code"], got["results"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--token-file", default=default_token_file())
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
    if not cmd:
        ap.error("실행할 명령이 없어요 (-- 뒤에 적어요)")

    p = Portal()
    props = dbus.Interface(p.obj, "org.freedesktop.DBus.Properties")
    if not int(props.Get(SC, "AvailableCursorModes")) & CURSOR_HIDDEN:
        print("이 포털은 커서를 숨긴 캡처를 못 해요 — 커서 움직임이 변화로 잡혀요.", file=sys.stderr)
        return 2

    code, res = p.call("CreateSession", options={"session_handle_token": "tz" + secrets.token_hex(6)})
    if code != 0:
        print(f"CreateSession 실패 (응답 {code})", file=sys.stderr)
        return 2
    session = res["session_handle"]

    opts = {
        "types": dbus.UInt32(MONITOR),
        "multiple": dbus.Boolean(False),
        "cursor_mode": dbus.UInt32(CURSOR_HIDDEN),
        "persist_mode": dbus.UInt32(2),
    }
    try:
        with open(a.token_file) as f:
            tok = f.read().strip()
        if tok:
            opts["restore_token"] = tok
    except FileNotFoundError:
        pass
    code, _ = p.call("SelectSources", dbus.ObjectPath(session), options=opts)
    if code != 0:
        print(f"SelectSources 실패 (응답 {code})", file=sys.stderr)
        return 2
    code, res = p.call("Start", dbus.ObjectPath(session), "", options={})
    if code != 0:
        print(f"Start 실패 (응답 {code} — 1 이면 권한 창에서 취소)", file=sys.stderr)
        return 2
    streams = res.get("streams", [])
    if len(streams) != 1:
        print(f"스트림이 {len(streams)} 개예요 — 화면 하나를 골라야 해요", file=sys.stderr)
        return 2
    node = int(streams[0][0])
    if "restore_token" in res:
        os.makedirs(os.path.dirname(a.token_file), exist_ok=True)
        with open(a.token_file, "w") as f:
            f.write(str(res["restore_token"]))

    fd = p.sc.OpenPipeWireRemote(dbus.ObjectPath(session), dbus.Dictionary({}, signature="sv")).take()
    argv = [s.replace("{fd}", str(fd)).replace("{node}", str(node)) for s in cmd]
    rc = subprocess.call(argv, pass_fds=[fd])
    os.close(fd)
    try:
        dbus.Interface(p.bus.get_object(PORTAL, session), "org.freedesktop.portal.Session").Close()
    except dbus.DBusException:
        pass
    return rc


if __name__ == "__main__":
    sys.exit(main())
