#!/bin/bash
# #656 · #657 — 마우스 선택 · 오른쪽 클릭 · 가운데 클릭이 CLIPBOARD · PRIMARY · 앱에 무엇을 남기는지
# **자동으로** 재는 Linux 몫. headless sway 를 격리 경로에 띄우므로 사용자 세션을 건드리지 않는다.
#
# ```sh
# tool/selection-check/selection-check_linux.sh                         # zig-out/install-dev/bin/tildaz
# tool/selection-check/selection-check_linux.sh --bin ./zig-out/bin/tildaz
# ```
#
# macOS 기기에서는 lima VM (`tildaz-linux`) 에서 같은 명령으로 돈다 — 크로스빌드한 바이너리와 `tool/` 을
# 복사해 넘긴다 (AGENTS.md `# Linux — 이 macOS 머신에서 lima VM …`).
#
# 무엇을 하나 —
# 1. headless sway 를 띄우고 `tool/vptr_linux.py` 가상 포인터를 꽂는다. 판정은 같은 sway 에 붙은
#    `wl-paste` (CLIPBOARD) · `wl-paste --primary` (PRIMARY) 와, 측정 창의 수신자 (`tool/key-bytes.py`) 가
#    받은 바이트다. 수신자는 0 행에 `COPYME word2` 를 찍어 둔다.
# 2. 세 회차 — 기본값 (`copy_on_select = false`) · 마우스를 켠 앱 (`DECSET 1000`) · `copy_on_select = true`.
#
# 전제 — `sway` · `wl-clipboard` (`wl-copy` · `wl-paste`) · `python3`. 사용자 세션의 클립보드는 건드리지
# 않는다 (다른 compositor 다). 실기라서 시작 전에 알리고 동의를 받는다 — 측정 창이 회차마다 한 번 뜬다.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN=$ROOT/zig-out/install-dev/bin/tildaz
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --bin) BIN="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;   # 끝나도 임시 디렉터리 (앱 로그 · 수신 바이트 · 캡처) 를 남긴다
        *) echo "모르는 옵션: $1" >&2; exit 2 ;;
    esac
done
[ -x "$BIN" ] || { echo "바이너리 없음: $BIN (--bin 으로 준다)" >&2; exit 2; }
for c in sway wl-copy wl-paste python3; do command -v $c >/dev/null || { echo "$c 가 없다" >&2; exit 2; }; done

# sun_path 는 108 바이트다 — 격리 runtime dir 은 짧아야 sway 가 IPC 소켓을 만든다 (AGENTS.md).
T=/tmp/tz-selcheck-$$; mkdir -p $T/run $T/home $T/xdg $T/state; chmod 700 $T/run
export XDG_RUNTIME_DIR=$T/run HOME=$T/home XDG_CONFIG_HOME=$T/xdg XDG_STATE_HOME=$T/state
unset XDG_CURRENT_DESKTOP SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE DBUS_SESSION_BUS_ADDRESS
printf 'output HEADLESS-1 resolution 1280x800\n' > $T/sway.conf
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 sway -c $T/sway.conf > $T/sway.log 2>&1 &
SWAY_PID=$!
for _ in $(seq 40); do [ -S $T/run/wayland-1 ] && break; sleep 0.25; done
[ -S $T/run/wayland-1 ] || { echo "sway 가 뜨지 않았다 — $T/sway.log" >&2; exit 2; }
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls $T/run/sway-ipc.*.sock 2>/dev/null | head -1)
python3 "$ROOT/tool/vptr_linux.py" --fifo $T/run/vptr.fifo > $T/vptr.log 2>&1 &
sleep 1.5

cleanup() {
    echo quit > $T/run/vptr.fifo 2>/dev/null
    for p in $(pgrep -f "$T/child"); do kill $p 2>/dev/null; done
    pkill -f "instance 1 -e $T" 2>/dev/null
    kill $SWAY_PID 2>/dev/null; sleep 0.5
    if [ $KEEP = 1 ]; then echo "남김: $T"; else rm -rf $T; fi
}
trap cleanup EXIT

P() { echo "$1" > $T/run/vptr.fifo; sleep "${2:-0.3}"; }
hexof() { printf '%s' "$1" | od -An -tx1 | tr -s ' \n' ' ' | sed 's/^ //;s/ $//'; }
hex_since() { tail -n +$(($1 + 1)) "$OUT" | tr -d '\r' | grep -oE '^[0-9a-f]{2}( [0-9a-f]{2})*' | tr '\n' ' ' | sed 's/ *$//'; }
clip() { timeout 2 wl-paste -n 2>/dev/null; }
prim() { timeout 2 wl-paste -n --primary 2>/dev/null; }
fail=0
verdict() {   # 이름 · 기대 CLIPBOARD (-=안 봄) · 기대 PRIMARY (-=안 봄) · 기대 앱 hex (-=안 봄, ''=없음) · 앞 줄 수
    local name=$1 wc=$2 wp=$3 wa=$4 n=$5 gc gp ga ok=OK
    gc=$(clip); gp=$(prim); ga=$(hex_since $n)
    [ "$wc" = - ] || [ "$gc" = "$wc" ] || ok=FAIL
    [ "$wp" = - ] || [ "$gp" = "$wp" ] || ok=FAIL
    if [ "$wa" = MOUSE ]; then case "$ga" in "1b 5b 4d"*) ;; *) ok=FAIL ;; esac
    elif [ "$wa" != - ] && [ "$ga" != "$wa" ]; then ok=FAIL; fi
    [ $ok = OK ] || fail=1
    printf '%-4s %-38s CLIPBOARD=[%s] PRIMARY=[%s] 앱=[%s]\n' $ok "$name" "$gc" "$gp" "$ga"
}

launch() {   # $1 = 회차 이름 · $2 = 수신자가 먼저 쓸 escape (없으면 '')
    OUT=$T/recv_$1.txt; rm -f $OUT
    printf '#!/bin/sh\nprintf "COPYME word2\\n%s"\nexec python3 "%s" legacy > %s 2>&1\n' "$2" "$ROOT/tool/key-bytes.py" "$OUT" > $T/child_$1.sh
    chmod +x $T/child_$1.sh
    # 앱에는 `SWAYSOCK` 을 넘기지 않는다 — layer-shell 경로로 뜬다. 창이 화면 위에 바로 붙어서 아래 좌표
    # 계산이 간단하다. sway 일반 창이면 맨 위에 sway 제목 막대가 있어 "창 위에서 14 px" 이 그 막대를 끈다 (#656).
    env -u SWAYSOCK TILDAZ_VERBOSE=1 "$BIN" --instance 1 -e $T/child_$1.sh > $T/app_$1.out 2>&1 &
    for _ in $(seq 60); do grep -q '^\[legacy\]' $OUT 2>/dev/null && break; sleep 0.25; done
    sleep 1
    # layer surface 는 `swaymsg` 트리에 없다. 논리 크기는 앱 로그에서 읽고, 기본 config 가 화면 끝
    # (`offset_percent = 100`) · 위 (`dock_position = "top"`) 에 붙이므로 x = 화면 폭 − 창 폭, y = 0.
    local LOGF; LOGF=$(ls $T/state/*/tildaz_*.log 2>/dev/null | head -1)
    WW=$(grep -o 'layer-surface configure serial=[0-9]* logical_w=[0-9]*' "$LOGF" 2>/dev/null | tail -1 | sed 's/.*logical_w=//')
    [ -n "${WW:-}" ] || { echo "layer-surface configure 줄을 못 찾았다 — $LOGF" >&2; exit 2; }
    WX=$((1280 - WW)); WY=0
    # 배율 1 이라 여백 6 px. 0 행은 창 위에서 14 px — 셀 높이와 무관하게 첫 줄이다.
    Y=$((WY + 14)); X0=$((WX + 7)); X1=$((WX + WW * 6 / 10)); XM=$((WX + 120)); YM=$((WY + 300))
    echo "     창 ${WX},${WY} 폭 ${WW} · 0 행 y=$Y x=$X0..$X1"
}
drag_row0() { P "move $X0 $Y"; P "down left"; P "moveby 30 0"; P "move $X1 $Y"; P "up left" 0.8; }
stop_app() { pkill -f "instance 1 -e $T" 2>/dev/null; sleep 0.8; }
SEL="COPYME word2"

echo "===== 기본값 (copy_on_select = false)"
printf ORIG | wl-copy; printf PRIM0 | wl-copy --primary; sleep 0.5
launch default ''
P "move $XM $YM"
n=$(wc -l < $OUT); drag_row0;                    verdict "① 끌어 선택" ORIG "$SEL" '' $n
n=$(wc -l < $OUT); P "click right" 0.8;          verdict "② 선택 있는 채 오른쪽 클릭" "$SEL" - '' $n
n=$(wc -l < $OUT); P "click right" 0.8;          verdict "③ 선택 없이 오른쪽 클릭" - - "$(hexof "$SEL")" $n
printf FROMOUT | wl-copy --primary; sleep 0.5
n=$(wc -l < $OUT); P "move $XM $YM"; P "click middle" 0.8; verdict "④ 남이 쓴 PRIMARY 를 가운데 클릭" - FROMOUT "$(hexof FROMOUT)" $n
n=$(wc -l < $OUT); drag_row0; P "move $XM $YM"; P "click middle" 0.8; verdict "⑤ 내 선택을 가운데 클릭" - "$SEL" "$(hexof "$SEL")" $n
L=$(ls $T/state/*/tildaz_*.log 2>/dev/null | head -1)
echo "     지원 로그: $(grep -o 'primary_selection=[a-z]*' "$L" | head -1)"
stop_app

echo "===== 마우스를 켠 앱 (DECSET 1000)"
printf FROMOUT | wl-copy --primary; sleep 0.5
launch report '\\033[?1000h'
n=$(wc -l < $OUT); P "move $XM $YM"; P "click middle" 0.8; verdict "⑥ 가운데 클릭은 앱에 간다" - - MOUSE $n
stop_app

echo "===== copy_on_select = true"
# `-e` 회차도 `config_N.toml` 이 있으면 읽는다 (만들지만 않는다). 빠진 키는 기본값이다 (#655) — 그래서
# `[input]` 한 줄만 적는다. 디렉터리는 앞 회차가 만든 로그 디렉터리 이름과 같다 (dev 판 `tildaz-dev`).
APPDIR=$(basename "$(ls -d $T/state/*/ | head -1)")
[ -n "$APPDIR" ] || { echo "로그 디렉터리를 못 찾아 config 자리를 모른다" >&2; exit 2; }
mkdir -p "$T/xdg/$APPDIR"
printf '[input]\ncopy_on_select = true\n' > "$T/xdg/$APPDIR/config_1.toml"
printf ORIG | wl-copy; sleep 0.3
launch on ''
n=$(wc -l < $OUT); drag_row0;                    verdict "⑦ 끌어 선택" "$SEL" "$SEL" '' $n
n=$(wc -l < $OUT); P "click right" 0.8;          verdict "⑧ 선택 있는 채 오른쪽 클릭 (늘 붙임)" - - "$(hexof "$SEL")" $n
stop_app

echo "결과: $([ $fail = 0 ] && echo 전부 OK || echo 기대와 다른 칸 있음)"
exit $fail
