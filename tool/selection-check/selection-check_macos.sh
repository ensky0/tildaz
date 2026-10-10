#!/bin/bash
# #656 — 마우스 선택 · 오른쪽 클릭 · 더블 클릭이 클립보드와 앱에 무엇을 남기는지 **자동으로** 재는 macOS 몫.
# macOS 에는 PRIMARY 가 없어 `copy_on_select` 와 오른쪽 클릭만 본다 (Linux 판은 같은 디렉터리).
#
# ```sh
# tool/selection-check/selection-check_macos.sh                              # /Applications/TildaZ-dev.app
# tool/selection-check/selection-check_macos.sh --app zig-out/TildaZ-dev.app
# ```
#
# 무엇을 하나 —
# 1. `--instance 9 -e <수신자>` 로 측정 창을 띄운다. 수신자는 0 행에 `COPYME word2` 를 찍고
#    `tool/key-bytes.py` 로 받은 바이트를 파일에 남긴다.
# 2. `cliclick` 으로 끌어 선택 · 오른쪽 클릭 · 더블 클릭을 하고 `pbpaste` 와 받은 바이트로 판정한다.
# 3. 기본값 회차 뒤 `copy_on_select = true` 회차. 그 회차만 `config_9.toml` 을 잠깐 만들고 지운다.
#
# 좌표는 앱 로그의 `renderer init: … scale= cell= pad=` 와 창 목록 (`tool/color-capture_macos.m`) 에서
# 읽는다 — 기기 · 폰트마다 달라서 고정 값을 쓰지 않는다.
#
# 전제 — `cliclick` (brew). 화면이 잠겨 있지 않을 것. 에이전트 셸이면 샌드박스 밖에서 돌린다 (AGENTS.md
# 의 macOS `open` 절). **클립보드를 잠깐 바꾼다** — 시작 때 글자를 저장하고 끝나면 되돌린다. 글자가 아닌
# 것 (이미지 · 파일) 이 들어 있으면 되돌릴 수 없어서 손대지 않고 멈춘다. 실기라서 시작 전에 알리고 동의를
# 받는다 — 측정 창이 두 번 뜨고 합성 클릭이 나간다.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP=/Applications/TildaZ-dev.app
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        *) echo "모르는 옵션: $1" >&2; exit 2 ;;
    esac
done
APP="$(cd "$(dirname "$APP")" 2>/dev/null && pwd)/$(basename "$APP")"
[ -x "$APP/Contents/MacOS/tildaz" ] || { echo "앱 없음: $APP" >&2; exit 2; }
command -v cliclick >/dev/null || { echo "cliclick 이 없다 (brew install cliclick)" >&2; exit 2; }
BUNDLE=$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)
case "$BUNDLE" in *.dev) APPDIR=tildaz-dev ;; *) APPDIR=tildaz ;; esac
C9=$HOME/.config/$APPDIR/config_9.toml
LOG=$HOME/Library/Logs/$APPDIR/tildaz_stress.log
[ -e "$C9" ] && { echo "$C9 가 이미 있다 — 덮지 않고 멈춘다" >&2; exit 2; }
if [ "$(ioreg -n Root -d1 -r 2>/dev/null | grep -c CGSSessionScreenIsLocked)" != "0" ]; then
    echo "화면이 잠겨 있다 — 클릭이 잠금 화면으로 간다" >&2; exit 2
fi

# 클립보드 — 글자만 있거나 비어 있을 때만 진행한다.
info=$(osascript -e 'clipboard info' 2>/dev/null)
if printf '%s' "$info" | grep -q -v -E '^$' && ! printf '%s' "$info" | grep -q -E 'string|utf8|Unicode text'; then
    echo "클립보드에 글자가 아닌 것이 있다 ($info) — 되돌릴 수 없어서 멈춘다" >&2; exit 2
fi
if printf '%s' "$info" | grep -q -E 'PNGf|TIFF|furl|JPEG|PDF'; then
    echo "클립보드에 글자 말고 다른 형식도 있다 ($info) — 되돌릴 수 없어서 멈춘다" >&2; exit 2
fi

W=${TMPDIR:-/tmp}/tildaz-selection-check; mkdir -p "$W"
CC=$W/color-capture
if [ ! -x "$CC" ] || [ "$ROOT/tool/color-capture_macos.m" -nt "$CC" ]; then
    clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework ImageIO \
          -framework UniformTypeIdentifiers -o "$CC" "$ROOT/tool/color-capture_macos.m" || exit 2
fi
pbpaste > "$W/clip.bak"
stop_tz() { pkill -f "tildaz --instance 9" 2>/dev/null; sleep 0.6; }
cleanup() { stop_tz; rm -f "$C9"; pbcopy < "$W/clip.bak"; }
trap cleanup EXIT

hexof() { printf '%s' "$1" | od -An -tx1 | tr -s ' \n' ' ' | sed 's/^ //;s/ $//'; }
hex_since() { tail -n +$(($1 + 1)) "$OUT" 2>/dev/null | tr -d '\r' | grep -oE '^[0-9a-f]{2}( [0-9a-f]{2})*' | tr '\n' ' ' | sed 's/ *$//'; }
fail=0
verdict() {   # 이름 · 기대 클립보드 (-=안 봄) · 기대 앱 hex (-=안 봄, ''=없음) · 앞 줄 수
    local gc ga ok=OK
    gc=$(pbpaste); ga=$(hex_since "$4")
    [ "$2" = - ] || [ "$gc" = "$2" ] || ok=FAIL
    [ "$3" = - ] || [ "$ga" = "$3" ] || ok=FAIL
    [ $ok = OK ] || fail=1
    printf '%-4s %-36s 클립보드=[%s]  앱=[%s]\n' $ok "$1" "$gc" "$ga"
}

launch() {   # $1 = 회차 이름
    OUT=$W/recv_$1.txt; rm -f "$OUT"
    printf '#!/bin/sh\nprintf "COPYME word2\\n"\nexec python3 "%s" legacy > "%s" 2>&1\n' "$ROOT/tool/key-bytes.py" "$OUT" > "$W/child.sh"
    chmod +x "$W/child.sh"
    local m; m=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    stop_tz; open -n -a "$APP" --args --instance 9 -e "$W/child.sh" -size 60x12
    for _ in $(seq 40); do sleep 0.25; grep -q '^\[legacy\]' "$OUT" 2>/dev/null && break; done
    sleep 0.8
    # 셀 · 여백은 px 로 남는다. pt = px / scale.
    read -r SC CW CH PD < <(tail -n +$((m + 1)) "$LOG" | grep 'renderer init' | tail -1 |
        sed -E 's/.*scale=([0-9.]+) cell=([0-9]+)x([0-9]+)px pad=([0-9]+)px.*/\1 \2 \3 \4/')
    read -r WX WY < <("$CC" --list 2>/dev/null | awk -v b="$BUNDLE" '$2==b {split($6,a,","); print a[1], a[2]; exit}')
    [ -n "${SC:-}" ] && [ -n "${WX:-}" ] || { echo "창이나 renderer init 줄을 못 찾았다 — $LOG" >&2; exit 2; }
    read -r Y X0 X5 XW < <(python3 -c "
s=$SC; cw=$CW/s; ch=$CH/s; pd=$PD/s
print(int($WY+pd+ch/2), int($WX+pd+cw/2), int($WX+pd+cw*5.5), int($WX+pd+cw*8.5))")
}
drag_row0() { cliclick dd:$X0,$Y dm:$((X0 + 20)),$Y du:$X5,$Y; sleep 0.6; }
SEL=COPYME

echo "앱: $APP"
echo "===== 기본값 (copy_on_select = false)"
launch default
printf ORIG | pbcopy
n=$(wc -l < "$OUT"); drag_row0;                      verdict "① 끌어 선택" ORIG '' $n
n=$(wc -l < "$OUT"); cliclick rc:$X0,$Y; sleep 0.8; verdict "② 선택 있는 채 오른쪽 클릭" "$SEL" '' $n
n=$(wc -l < "$OUT"); cliclick rc:$X0,$Y; sleep 0.8; verdict "③ 선택 없이 오른쪽 클릭" - "$(hexof "$SEL")" $n
printf ORIG2 | pbcopy
n=$(wc -l < "$OUT"); cliclick dc:$XW,$Y; sleep 0.8; verdict "④ 더블 클릭 (word2)" ORIG2 '' $n
stop_tz

echo "===== copy_on_select = true (임시 config_9.toml)"
mkdir -p "$(dirname "$C9")"
printf 'auto_start = false\n\n[input]\ncopy_on_select = true\n' > "$C9"
launch on
printf ORIG | pbcopy
n=$(wc -l < "$OUT"); drag_row0;                      verdict "⑤ 끌어 선택" "$SEL" '' $n
n=$(wc -l < "$OUT"); cliclick rc:$X0,$Y; sleep 0.8; verdict "⑥ 선택 있는 채 오른쪽 클릭 (늘 붙임)" - "$(hexof "$SEL")" $n

echo "결과: $([ $fail = 0 ] && echo 전부 OK || echo 기대와 다른 칸 있음)  (클립보드 · config_9 는 끝나며 되돌린다)"
exit $fail
