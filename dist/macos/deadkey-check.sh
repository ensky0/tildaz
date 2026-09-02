#!/bin/bash
# dead key **자동** 검증 (macOS · #494 · #583 A3) — 입력 소스 ABC 에서 Option+e 뒤 e 가 `é` 로
# 들어오는지. `-e` 로 `cat >> 로그` 를 띄우고 `cliclick` 으로 키를 보내 받은 바이트를 본다.
#
# ```sh
# dist/macos/deadkey-check.sh zig-out/TildaZ.app          # 기대: c3 a9 ('é') 뒤 'x' 78
# ```
#
# - 입력 소스가 ABC / U.S. 가 아니면 Option+e 가 dead key 가 아니다 — 스크립트가 확인하고 멈춘다
#   (사용자 입력 소스를 바꾸지 않는다).
# - 창을 먼저 클릭해 key window 로 만든다 (Accessory 앱은 frontmost 가 못 되어 `osascript keystroke`
#   가 안 닿는다 — `cliclick` 키 이벤트는 key window 로 간다). 첫 키는 레이아웃 동기화에 먹힐 수
#   있어 무해한 `arrow-right` 를 먼저 보낸다.
# - `mouse-auto-check.sh` 와 같은 전제 — 손쉬운 사용 권한 · 화면 잠금 아님.
set -u
APP="${1:?앱 .app}"; # `open -a` 는 상대 경로를 앱 *이름*으로 해석해 못 찾는다 — 절대 경로로 바꾼다.
APP="$(cd "$(dirname "$APP")" 2>/dev/null && pwd)/$(basename "$APP")"
BIN="$APP/Contents/MacOS/tildaz"; [ -x "$BIN" ] || { echo "앱 없음: $BIN"; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP="${TMPDIR:-/tmp}/tildaz-frame-check/color-capture"
if [ ! -x "$CAP" ] || [ "$HERE/color-capture.m" -nt "$CAP" ]; then
  mkdir -p "$(dirname "$CAP")"
  clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework ImageIO \
        -framework UniformTypeIdentifiers -o "$CAP" "$HERE/color-capture.m" || exit 1
fi
src=$(defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null)
case "$src" in *ABC|*US|*U.S.) ;; *) echo "입력 소스가 $src — ABC/U.S. 에서만 Option+e 가 dead key 다"; exit 1;; esac
if [ "$(ioreg -n Root -d1 -r 2>/dev/null | grep -c CGSSessionScreenIsLocked)" != "0" ]; then echo "화면이 잠겨 있다"; exit 1; fi
LOG="${TMPDIR:-/tmp}/tildaz-deadkey.log"; rm -f "$LOG"
# `stty -icanon` — 줄 단위가 아니라 **바이트가 오는 즉시** 파일에 쓴다. Enter 에 의존하면 합성 Enter 가
# 안 닿았을 때 (2026-09-03 실측 — 화면에는 `abcéx` 가 찍혔는데 파일은 비었다) 판정을 못 한다.
WRAP="${TMPDIR:-/tmp}/tildaz-deadkey-wrap.sh"; printf '#!/bin/sh\nstty -icanon\ncat >> %s\n' "$LOG" > "$WRAP"; chmod +x "$WRAP"
pkill -f "tildaz --instance 9" 2>/dev/null; sleep 0.5
open -n -a "$APP" --args --instance 9 -e "$WRAP" -size 60x12
geom=""; for _ in $(seq 1 40); do sleep 0.2; geom=$("$CAP" --list 2>/dev/null | awk '$2 ~ /tildaz/ {print $4, $5; exit}'); [ -n "$geom" ] && break; done
[ -z "$geom" ] && { echo "창 못 찾음"; pkill -f "tildaz --instance 9"; exit 1; }
sleep 1.2; read -r sz pos <<<"$geom"; X=${pos%,*}; Y=${pos#*,}
cliclick c:$((X + 150)),$((Y + 150)); sleep 0.5
cliclick kp:arrow-right; sleep 0.5
cliclick kd:alt t:e ku:alt; sleep 0.5      # dead key — 조합 중 표시 (preedit) 가 뜬다
cliclick t:e; sleep 0.3                    # → é
cliclick t:x; sleep 0.8
hex=$(od -An -tx1 "$LOG" 2>/dev/null | tr -s ' \n' ' ')
pkill -f "tildaz --instance 9" 2>/dev/null; rm -f "$HOME/.config/tildaz/config_9.toml"
echo "창 $sz @ ($X,$Y) · 입력 소스 $src"
echo "받은 바이트: ${hex:-(없음)}   텍스트: $(cat "$LOG" 2>/dev/null)"
case "$hex" in *"c3 a9 78"*) echo "OK — Option+e, e → é (c3 a9), 그 뒤 x"; exit 0;; *) echo "**FAIL** — 기대 'c3 a9 78' (é x)"; exit 1;; esac
