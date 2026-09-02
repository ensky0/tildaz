#!/bin/bash
# 두 앱 판을 **같은 화면**으로 찍어 최종 그림을 픽셀로 견준다 (macOS) — 기준판 vs 수정판.
#
# ```sh
# dist/macos/render-ab-shot.sh <화면.sh> <격자> <대기초> <A.app> <B.app>
# dist/macos/render-ab-shot.sh /tmp/many.sh 88x33 5 /tmp/main.app zig-out/TildaZ.app
# ```
#
# - 기준판은 main 을 **별도 worktree** 에서 빌드한다 (`.zig-cache` 가 갈려야 한다 — 캐시를 나누지
#   않으면 두 판의 바이너리가 같아져 "0 차이" 가짜 통과가 난다). 판정 전에 md5 가 다른지 본다.
# - 픽셀 수는 `-compose difference` 로 센다. `magick compare -metric AE` 는 소수 · 지수 표기를 낸다.
# - atlas 안전망 경로를 강제로 돌리려면 `MAX_ATLAS_SIZE = INITIAL_ATLAS_SIZE` (예 1024) 로 빌드한 판을
#   `INITIAL = 4096` 판 (안 넘침) 과 견준다 — 안전망이 정확하면 `0 px` 다. **픽셀 대조에는 로그의
#   `atlas full` 회수도 같이 본다** — 잔재 코드가 우연히 그림을 지키고 있어도 `0 px` 가 나온다 (#585).
set -u
TARGET="${1:?화면}"; SIZE="${2:?격자}"; WAIT="${3:-6}"; A="${4:?A.app}"; B="${5:?B.app}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP="${TMPDIR:-/tmp}/tildaz-frame-check/color-capture"
if [ ! -x "$CAP" ] || [ "$HERE/color-capture.m" -nt "$CAP" ]; then
  mkdir -p "$(dirname "$CAP")"
  clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework ImageIO \
        -framework UniformTypeIdentifiers -o "$CAP" "$HERE/color-capture.m" || exit 1
fi
OUT="${TMPDIR:-/tmp}/tildaz-ab-shot"; mkdir -p "$OUT"
echo "md5  A $(md5 -q "$A/Contents/MacOS/tildaz")  B $(md5 -q "$B/Contents/MacOS/tildaz")"
i=0
for app in "$A" "$B"; do
  i=$((i+1)); bin="$app/Contents/MacOS/tildaz"; [ -x "$bin" ] || { echo "앱 없음: $bin"; exit 1; }
  pkill -f "tildaz --instance 9" 2>/dev/null; sleep 0.5
  "$bin" --instance 9 -e "$TARGET" -size "$SIZE" >/dev/null 2>&1 & disown
  wid=""; for _ in $(seq 1 40); do sleep 0.2; wid=$("$CAP" --list 2>/dev/null | awk '$2 ~ /tildaz/ {print $1; exit}'); [ -n "$wid" ] && break; done
  [ -z "$wid" ] && { echo "창 못 찾음 ($app)"; pkill -f "tildaz --instance 9"; exit 1; }
  sleep "$WAIT"; "$CAP" --window "$wid" "$OUT/shot_$i.png" >/dev/null 2>&1
  pkill -f "tildaz --instance 9" 2>/dev/null; sleep 0.3
done
n=$(magick "$OUT/shot_1.png" "$OUT/shot_2.png" -compose difference -composite -colorspace Gray -threshold 0 -format '%[fx:mean*w*h]' info: | python3 -c "print(int(round(float(input()))))")
tot=$(magick identify -format '%[fx:w*h]' "$OUT/shot_1.png" | python3 -c "print(int(float(input())))")
echo "A vs B: $n / $tot px  ($OUT/shot_1.png · shot_2.png)"
