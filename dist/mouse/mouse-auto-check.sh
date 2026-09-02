#!/bin/bash
# mouse reporting **자동** 검증 (macOS) — 프로브를 띄우고 합성 클릭을 보내 받은 바이트를 형식별
# 기대와 대조한다 (#502 · #583 A4). 사람 손 없이 `?1005` · `?1015` · `?1016` 같은 안 쓰는 형식을
# 돌릴 수 있다. 프로브는 `mouse-probe.sh --log` 그대로다 — 사람 검증과 같은 것을 본다.
#
# ```sh
# dist/mouse/mouse-auto-check.sh zig-out/TildaZ.app 1000 1015      # tracking 1000 · format 1015
# dist/mouse/mouse-auto-check.sh zig-out/TildaZ.app 1000 1005 1006 1015 1016   # 형식 여럿
# ```
#
# 판정 (press 뒤 release 한 번 — 셀 (C,R) 은 창 위치 · cell 크기에 딸려 가므로 값이 아니라 **형태**만):
#   1006  ^[[<0;C;RM  ^[[<0;C;Rm            (뗌은 소문자 m)
#   1016  ^[[<0;X;YM  ^[[<0;X;Ym            (픽셀 좌표 — 1006 보다 큰 수)
#   1015  ^[[32;C;RM  ^[[35;C;RM            (10진 · Cb+32 · 뗌도 M — 35 = 3+32)
#   1005  ^[[M + 3 글자  (`32+Cb` · 좌표는 v+33 을 UTF-8 로) — press ' ' (0x20) · release '#' (0x23)
#
# 전제 — 이 셸을 띄운 앱 (터미널 · 에디터) 에 **손쉬운 사용 권한**이 있어야 `cliclick` 이 닿는다.
# 없으면 `CGEventPost` 는 성공을 돌려주면서 아무 일도 하지 않는다 (README 의 같은 주의). 그리고
# **화면이 잠겨 있으면 클릭이 잠금 화면으로 간다** — 프로브는 떠 있고 로그만 비어 있어 원인을 못
# 짚는다 (2026-09-02 실측 — 회차 하나를 통째로 버렸다). 둘 다 시작 전에 확인한다.
set -u
APP="${1:?앱 .app}"; TRACKING="${2:?tracking 예 1000}"; shift 2
[ $# -ge 1 ] || { echo "format 을 하나 이상"; exit 1; }
# `open -a` 는 상대 경로를 앱 *이름*으로 해석해 못 찾는다 — 절대 경로로 바꾼다.
APP="$(cd "$(dirname "$APP")" 2>/dev/null && pwd)/$(basename "$APP")"
BIN="$APP/Contents/MacOS/tildaz"; [ -x "$BIN" ] || { echo "앱 없음: $BIN"; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
CAP="${TMPDIR:-/tmp}/tildaz-frame-check/color-capture"
if [ ! -x "$CAP" ] || [ "$REPO/dist/macos/color-capture.m" -nt "$CAP" ]; then
  mkdir -p "$(dirname "$CAP")"
  clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework ImageIO \
        -framework UniformTypeIdentifiers -o "$CAP" "$REPO/dist/macos/color-capture.m" || exit 1
fi
command -v cliclick >/dev/null || { echo "cliclick 이 없다 (brew install cliclick)"; exit 1; }
if [ "$(ioreg -n Root -d1 -r 2>/dev/null | grep -c CGSSessionScreenIsLocked)" != "0" ]; then echo "화면이 잠겨 있다"; exit 1; fi
p0=$(cliclick p); cliclick m:600,400; sleep 0.2; [ "$(cliclick p)" = "600,400" ] || { echo "합성 입력이 전달되지 않는다 — 이 셸의 앱에 손쉬운 사용 권한이 없다"; exit 1; }
cliclick m:"$p0"
fail=0
for FMT in "$@"; do
  LOG="${TMPDIR:-/tmp}/tildaz-mouse-auto-$FMT.log"; rm -f "$LOG"
  WRAP="${TMPDIR:-/tmp}/tildaz-mouse-auto-wrap-$FMT.sh"
  printf '#!/usr/bin/env bash\nexec bash %s/dist/mouse/mouse-probe.sh %s %s --log %s\n' "$REPO" "$TRACKING" "$FMT" "$LOG" > "$WRAP"; chmod +x "$WRAP"
  pkill -f "tildaz --instance 9" 2>/dev/null; sleep 0.5
  open -n -a "$APP" --args --instance 9 -e "$WRAP" -size 88x33
  geom=""; for _ in $(seq 1 40); do sleep 0.2; geom=$("$CAP" --list 2>/dev/null | awk '$2 ~ /tildaz/ {print $4, $5; exit}'); [ -n "$geom" ] && break; done
  [ -z "$geom" ] && { echo "[?$FMT] 창 못 찾음"; fail=1; pkill -f "tildaz --instance 9"; continue; }
  sleep 1.2
  read -r sz pos <<<"$geom"; X=${pos%,*}; Y=${pos#*,}
  # 첫 클릭은 비활성 창을 깨우는 데 쓰일 수 있어 (acceptsFirstMouse) 두 번 누른다 — 두 번째가 판정 대상.
  CX=$((X + 120)); CY=$((Y + 220))
  cliclick c:$CX,$CY; sleep 0.5; cliclick c:$((CX + 40)),$((CY + 60)); sleep 0.7
  bytes=$(cat -v "$LOG" 2>/dev/null | tr -d '\n')
  pkill -f "tildaz --instance 9" 2>/dev/null; sleep 0.3
  case "$FMT" in
    1006) re='\^\[\[<0;[0-9]+;[0-9]+M\^\[\[<0;[0-9]+;[0-9]+m$' ;;
    1016) re='\^\[\[<0;[0-9]+;[0-9]+M\^\[\[<0;[0-9]+;[0-9]+m$' ;;
    1015) re='\^\[\[32;[0-9]+;[0-9]+M\^\[\[35;[0-9]+;[0-9]+M$' ;;
    1005) re='\^\[\[M .{2,8}\^\[\[M#' ;;
    *)    re='.' ;;
  esac
  if [ -n "$bytes" ] && printf '%s' "$bytes" | grep -Eq "$re"; then verdict="OK"; else verdict="**FAIL**"; fail=1; fi
  echo "[?$TRACKING;$FMT] $verdict  창 $sz @ ($X,$Y)  받은 바이트: ${bytes:-(없음)}"
  [ "$FMT" = 1016 ] && echo "        (1016 은 좌표가 픽셀 — 같은 클릭의 1006 값보다 커야 한다)"
done
rm -f "$HOME/.config/tildaz/config_9.toml"
exit $fail
