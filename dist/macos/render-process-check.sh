#!/bin/bash
# 그리는 **과정**을 본다 (macOS) — 기동 직후부터 촘촘히 찍어 (1) 이웃 프레임 차이, (2) 최종 프레임
# 대비 차이를 **픽셀 수**로 낸다. (2) 가 첫 장부터 0 이면 첫 프레임에 이미 최종 그림이다.
#
# 최종 그림 한 장만 견주면 "그리는 도중 단계적으로 채워지는" 이상을 못 잡는다 — #585 에서 사용자가
# 눈으로 본 "아랫부분이 지지직" 을 정적 대조 `0 px` 가 놓쳤다. 렌더 경로를 바꾸면 이걸로 과정도 본다.
#
# ```sh
# dist/macos/render-process-check.sh <앱.app> <화면.sh> <격자> [장수=30] [간격초=0.03] [태그]
# dist/macos/render-process-check.sh zig-out/TildaZ.app /tmp/many.sh 88x33
# ```
#
# - 첫 장이 최종과 크게 다르면 **"present 전 투명 창"** 인지 먼저 가른다 — 배경색이 `srgba(0,0,0,0)`
#   이고 배경 아닌 픽셀이 0 이면 아직 아무것도 안 그린 것이다 (안전망이 GPU 를 여러 번 기다리는
#   판은 첫 present 가 늦어 그렇게 잡힌다). 이상이 아니다.
# - 캡처 간격은 20~50 ms 라 60 Hz 한 프레임 (16 ms) 을 직접 가르지는 못한다 — "한 프레임 늦음" 은
#   perf 종료 덤프의 `render calls` 로 본다 (`dist/screens/clusters.py mini`).
# - 화면이 잠겨 있으면 캡처가 전부 실패한다 — 시작 전에 확인하고, 사용자에게 알린다.
set -u
APP="${1:?앱 .app 경로}"; TARGET="${2:?화면 스크립트}"; SIZE="${3:?격자 예 88x33}"
N="${4:-30}"; GAP="${5:-0.03}"; TAG="${6:-$(basename "$APP" .app)}"
BIN="$APP/Contents/MacOS/tildaz"; [ -x "$BIN" ] || { echo "앱 없음: $BIN"; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP="${TMPDIR:-/tmp}/tildaz-frame-check/color-capture"
if [ ! -x "$CAP" ] || [ "$HERE/color-capture.m" -nt "$CAP" ]; then
  mkdir -p "$(dirname "$CAP")"
  clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework ImageIO \
        -framework UniformTypeIdentifiers -o "$CAP" "$HERE/color-capture.m" || exit 1
fi
if [ "$(ioreg -n Root -d1 -r 2>/dev/null | grep -c CGSSessionScreenIsLocked)" != "0" ]; then
  echo "화면이 잠겨 있다 — 캡처가 안 된다"; exit 1
fi
OUT="${TMPDIR:-/tmp}/tildaz-process-check/$TAG"; rm -rf "$OUT"; mkdir -p "$OUT"
pkill -f "tildaz --instance 9" 2>/dev/null; sleep 0.5
"$BIN" --instance 9 -e "$TARGET" -size "$SIZE" >/dev/null 2>&1 & disown
wid=""
for _ in $(seq 1 100); do wid=$("$CAP" --list 2>/dev/null | awk '$2 ~ /tildaz/ {print $1; exit}'); [ -n "$wid" ] && break; sleep 0.02; done
[ -z "$wid" ] && { echo "창 못 찾음"; pkill -f "tildaz --instance 9"; exit 1; }
for i in $(seq 1 "$N"); do "$CAP" --window "$wid" "$OUT/f_$(printf '%02d' "$i").png" >/dev/null 2>&1; sleep "$GAP"; done
sleep 1.5; "$CAP" --window "$wid" "$OUT/final.png" >/dev/null 2>&1
pkill -f "tildaz --instance 9" 2>/dev/null
px() { magick "$1" "$2" -compose difference -composite -colorspace Gray -threshold 0 -format '%[fx:mean*w*h]' info: 2>/dev/null | python3 -c "print(int(round(float(input() or 0))))"; }
tot=$(magick identify -format '%[fx:w*h]' "$OUT/final.png" | python3 -c "print(int(float(input())))")
echo "[$TAG] $(magick identify -format '%wx%h' "$OUT/final.png")  총 $tot px  ($OUT)"
prev=""; line_n=""; line_f=""; first=""
for f in "$OUT"/f_*.png; do
  d=$(px "$f" "$OUT/final.png"); [ -z "$first" ] && first=$d; line_f="$line_f $d"
  [ -n "$prev" ] && line_n="$line_n $(px "$prev" "$f")"; prev="$f"
done
echo "  최종 대비:$line_f"; echo "  이웃 차이:$line_n"; echo "  첫 장 vs 최종: $first px"
if [ "$first" != "0" ]; then
  bg=$(magick "$OUT/f_01.png" -format '%[pixel:p{10,300}]' info:)
  echo "  첫 장 배경색 $bg — srgba(0,0,0,0) 이면 present 전 투명 창 (이상 아님)"
fi
