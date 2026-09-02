#!/bin/bash
# 같은 바이너리를 여러 번 띄워 **실행마다 화면이 흔들리는지** 본다 (macOS).
#
# 회차 사이에 다른 것이 없으므로, 캡처가 회차마다 다르면 그 차이는 **실행 간 비결정**이다.
# [#529](https://github.com/ensky0/tildaz/issues/529) 에서 atlas 의 cluster 키가 일반 글리프와
# 자리를 나눠 쓰던 결함을 이 방법으로 잡았다 — 24 회 중 1 회에서 `a̸` 자리에 `U` 가 그려졌다.
#
# ```sh
# dist/macos/repeat-render-check.sh                       # render-test 화면 24 회
# dist/macos/repeat-render-check.sh 40                    # 회차만 바꿔서
# dist/macos/repeat-render-check.sh 24 6 /path/show.sh    # 다른 화면으로
# ```
#
# ⚠️ **A/B 는 반드시 같은 화면(디스플레이)에서 찍는다.** `color-capture` 가 출력 색공간을
# sRGB 로 잡아도 **디스플레이가 다르면 값이 갈린다** — 같은 화면인데 내장 120 Hz 캡처와 외장
# 60 Hz 캡처가 서로 `AE 168466` 이 나온 적이 있다 (#529 검증). 수정 전후를 견줄 때는 화면을
# 바꾸지 않는다.
#
# ⚠️ **재현이 관측된 조건과 같은 조건으로 잰다.** 이 종류의 결함은 회차당 확률이 낮아
# (#529 는 10.5%) 회차 수가 적으면 그냥 지나간다. 수정 전에 몇 회에서 몇 번 나왔는지를 적어
# 두고, 수정 뒤 **같은 회차 수**로 다시 잰다.
#
# 실기 검증이므로 `AGENTS.md` 의 `# 실행 환경` 대로 **시작 전에 사용자에게 알리고 동의를
# 받는다.** 창이 회차마다 떴다 사라져 화면이 깜빡이고, 그동안 사용자가 기기를 만지면 그
# 회차가 오염된다.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$REPO/zig-out/TildaZ.app/Contents/MacOS/tildaz"
CAP_SRC="$REPO/dist/macos/color-capture.m"

N="${1:-24}"
SETTLE="${2:-6}"                                  # 창이 뜨고 출력이 끝나기를 기다리는 시간
TARGET="${3:-$REPO/zig-out/bin/render-test}"      # `-e` 로 띄울 프로그램

OUT="${TMPDIR:-/tmp}/tildaz-repeat-render-check"
CAP="$OUT/color-capture"

if [ ! -x "$APP" ]; then
  echo "앱이 없다: $APP" >&2
  echo "  zig build -Doptimize=ReleaseFast -Dsimd=true" >&2
  exit 1
fi
if [ ! -x "$TARGET" ]; then
  echo "띄울 프로그램이 없다: $TARGET" >&2
  echo "  render-test 라면: zig build render-test" >&2
  exit 1
fi

mkdir -p "$OUT"
rm -f "$OUT"/run_*.png "$OUT"/diff_*.png

# 캡처 도구는 처음 한 번만 만든다 — 출력 색공간을 sRGB 로 잡아 준다 (#349).
if [ ! -x "$CAP" ] || [ "$CAP_SRC" -nt "$CAP" ]; then
  echo "== color-capture 빌드 =="
  clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit \
        -framework ImageIO -framework UniformTypeIdentifiers \
        -o "$CAP" "$CAP_SRC" || exit 1
fi

echo "== 반복 렌더 확인 — ${N} 회 · 회차마다 ${SETTLE}초 =="
echo "   앱   : $APP ($(stat -f '%Sm' "$APP"))"
echo "   화면 : $TARGET"
echo "   결과 : $OUT"
echo "   ⚠️ 도는 동안 기기를 만지지 않는다. 창이 회차마다 떴다 사라진다."
echo

# 사용자의 일상 인스턴스를 건드리지 않도록 `--instance 9` 로만 띄우고, 내릴 때도 그 인스턴스만 잡는다
# (`pkill -x tildaz` 는 instance 0 도 죽였다 — #583 A12).
for i in $(seq 1 "$N"); do
  printf "  회차 %2d/%d ... " "$i" "$N"
  pkill -f "tildaz --instance 9" 2>/dev/null
  sleep 0.5

  # `disown` 은 아래 `pkill` 로 내릴 때 셸이 "Terminated: 15" 를 찍는 것을 막는다.
  "$APP" --instance 9 -e "$TARGET" -size 88x33 >/dev/null 2>&1 &
  disown
  sleep "$SETTLE"

  # 창 id 는 회차마다 달라진다 — 매번 새로 찾는다.
  wid=$("$CAP" --list 2>/dev/null | awk '$2 ~ /tildaz/ {print $1; exit}')
  if [ -z "$wid" ]; then
    echo "창 못 찾음 (앱이 죽었을 수 있다)"
  elif "$CAP" --window "$wid" "$OUT/run_$i.png" >/dev/null 2>&1; then
    echo "캡처 $(magick identify -format '%wx%h' "$OUT/run_$i.png" 2>/dev/null)"
  else
    echo "캡처 실패 (화면이 잠겼는지 확인한다)"
  fi

  pkill -f "tildaz --instance 9" 2>/dev/null
  sleep 0.5
done

echo
echo "== 대조 — 회차 1 을 기준으로 =="
base=""
for f in "$OUT"/run_*.png; do [ -f "$f" ] && { base="$f"; break; }; done
if [ -z "$base" ]; then
  echo "  캡처가 하나도 없다 — 앱이 뜨지 못했는지 확인한다."
  exit 1
fi

diff_n=0
for f in "$OUT"/run_*.png; do
  [ "$f" = "$base" ] && continue
  bs=$(magick identify -format '%wx%h' "$base")
  fs=$(magick identify -format '%wx%h' "$f")
  if [ "$bs" != "$fs" ]; then
    echo "  $(basename "$f"): 크기 다름 ($fs vs $bs) — 화면이 바뀌었다. 대조 제외"
    continue
  fi
  # `AE` 는 "12.34 (0.0001)" 처럼 나오므로 앞의 수만 본다. 0 이 아니면 갈린 회차다.
  ae=$(magick compare -metric AE "$base" "$f" "$OUT/diff_$(basename "$f")" 2>&1 >/dev/null | awk '{print $1}')
  case "$ae" in
    0|0.0|"") rm -f "$OUT/diff_$(basename "$f")" ;;
    *)
      diff_n=$((diff_n + 1))
      echo "  ★ $(basename "$f"): AE $ae"
      box=$(magick compare -compose src "$base" "$f" png:- 2>/dev/null |
            magick - -trim -format '%wx%h%O' info: 2>/dev/null)
      echo "      차이 영역: ${box:-(측정 실패)}  ·  diff_$(basename "$f")"
      ;;
  esac
done

echo
if [ "$diff_n" -eq 0 ]; then
  echo "  전 회차 동일 — 이 회차 수에서는 흔들림이 안 잡혔다."
  echo "  (확률이 낮은 결함은 회차를 늘려야 나온다. 안 나온 것이 없다는 뜻은 아니다.)"
else
  echo "  ★ ${diff_n} 개 회차가 갈렸다 — 실행 간 비결정이다."
  echo "  차이 영역을 잘라서 눈으로 본다 (AE 숫자만으로는 '사라짐' 과 '다른 것으로 바뀜' 을 못 가른다):"
  echo "      magick $OUT/run_1.png -crop <WxH+X+Y> +repage -resize 400% a.png"
fi

echo
echo "== 정리 =="
pkill -f "tildaz --instance 9" 2>/dev/null
rm -f "$HOME/.config/tildaz/config_9.toml"   # 안 지우면 로그온 때 그 인스턴스가 같이 뜬다
echo "  tildaz 프로세스 $(pgrep -x tildaz | wc -l | tr -d ' ') 개 · config_9.toml 제거"
echo "  캡처는 $OUT 에 남겼다 (판정이 끝나면 지운다)."
