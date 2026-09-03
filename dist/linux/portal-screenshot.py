#!/usr/bin/env python3
"""xdg-desktop-portal 로 화면을 찍는다 — **GNOME 에서 유일하게 남는 자동 캡처 경로**.

GNOME (mutter) 은 다른 길을 전부 막아 둔다 (2026-09-03 · GNOME Shell 50.4 실측).

- `zwlr_screencopy_manager_v1` · `ext_image_copy_capture_manager_v1` 를 **client 에 노출하지 않는다** → `grim` 불가.
- `org.gnome.Shell.Screenshot` · `org.gnome.Shell.Introspect` 는 allowlist 밖 호출자에게 `AccessDenied` 다.
- `import` (ImageMagick) 는 X11 이라 Xwayland 창만 잡는다 — 네이티브 Wayland surface 는 못 찍는다.

포털은 **처음 한 번 사용자 확인 창**을 띄우고 (GNOME 은 "스크린샷을 찍도록 허용하시겠습니까"), 허용하면 permission
store 에 남아 다음부터는 조용히 찍힌다. 그래서 무인 회차에는 못 쓰고, 사용자가 자리에 있을 때 한 번 허용받아 두면
그 뒤로는 자동으로 돈다.

    python3 dist/linux/portal-screenshot.py out.png [--timeout 60] [--interactive]

`--interactive` 는 포털의 대화형 모드 (영역 선택 UI) 다. 기본은 전체 화면 즉시 촬영이다.
찍힌 파일은 포털이 자기 위치 (`~/Pictures/Screenshots/…`) 에 만들고, 이 스크립트가 `out.png` 로 복사한다.
"""
import argparse
import os
import shutil
import sys
import urllib.parse

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("--timeout", type=int, default=60, help="응답 대기 초 (기본 60 — 첫 회차의 권한 창을 기다린다)")
    ap.add_argument("--interactive", action="store_true", help="포털의 영역 선택 UI 를 띄운다")
    args = ap.parse_args()

    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    # Request 객체의 경로는 규칙으로 정해진다 — 응답 신호를 놓치지 않으려면 **호출 전에** 구독한다.
    token = "tildaz_%d" % os.getpid()
    sender = bus.get_unique_name()[1:].replace(".", "_")
    request_path = f"/org/freedesktop/portal/desktop/request/{sender}/{token}"

    loop = GLib.MainLoop()
    result = {}

    def on_response(_conn, _sender, _path, _iface, _signal, params):
        response, results = params.unpack()
        result["response"] = response
        result["uri"] = results.get("uri")
        loop.quit()

    bus.signal_subscribe(
        "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response",
        request_path, None, Gio.DBusSignalFlags.NONE, on_response,
    )
    bus.call_sync(
        "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Screenshot", "Screenshot",
        GLib.Variant("(sa{sv})", ("", {
            "handle_token": GLib.Variant("s", token),
            "interactive": GLib.Variant("b", args.interactive),
        })),
        # ⚠️ 기본 D-Bus 대기 (25 초) 로는 **메서드 호출 자체가** 끊긴다 — GNOME 포털은 권한 창이 닫힐 때까지
        # 핸들을 돌려주지 않기 때문이다 (2026-09-03 실측: `g-io-error-quark: Timeout was reached`).
        GLib.VariantType("(o)"), Gio.DBusCallFlags.NONE, args.timeout * 1000, None,
    )
    GLib.timeout_add_seconds(args.timeout, lambda: (loop.quit(), False)[1])
    loop.run()

    if "response" not in result:
        sys.exit(f"포털이 {args.timeout} 초 안에 답하지 않았다 (권한 창이 떠 있는지 확인)")
    if result["response"] != 0:
        sys.exit(f"포털이 거절했다 (response={result['response']}) — 권한 창에서 취소했거나 정책에 막혔다")
    src = urllib.parse.unquote(urllib.parse.urlparse(result["uri"]).path)
    shutil.copyfile(src, args.out)
    print(f"{args.out} ← {src}")


if __name__ == "__main__":
    main()
