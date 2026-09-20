#!/bin/bash
# 링크 클릭 (#647 · 요청 #643) 을 합성 마우스 · 키 입력으로 자동 검증한다 (Linux · headless sway).
# [`link-click-check_windows.ps1`](link-click-check_windows.ps1) 의 Linux 몫이고 회차 이름 (A · B · C · D) 이 같다.
#
#   tool/link-click-check_linux.sh up       # headless sway + 가상 포인터 · 키보드 (한 번)
#   tool/link-click-check_linux.sh probe    # 창을 띄우고 격자를 캡처에서 찾아 좌표를 찍는다
#   tool/link-click-check_linux.sh A        # 평소 셸 — hover 밑줄 · 손 커서 · 수식키 없는 클릭
#   tool/link-click-check_linux.sh B        # 앱이 마우스를 잡음 (DECSET 1000) — Ctrl 을 눌러야 보이고 열린다
#   tool/link-click-check_linux.sh C        # 클릭이 앱으로 간 뒤에도 수식키 재판정이 사는지
#   tool/link-click-check_linux.sh D        # 미끄러진 클릭 (6350d99) — 칸이 바뀌어도 문턱 안이면 열린다
#   tool/link-click-check_linux.sh enter    # 포인터가 창에 **들어오고 나가는** 순간의 판정
#   tool/link-click-check_linux.sh down     # 앱 · 데몬 · sway 정리
#
# **사용자 세션을 건드리지 않는다.** 합성 입력은 `/dev/uinput` (ydotool) 이 아니라 headless sway 안의
# `zwlr_virtual_pointer_v1` · `zwp_virtual_keyboard_v1` 이라 그 compositor 로만 간다. XDG config · state ·
# runtime dir 도 전부 격리한다. `-e` 로만 띄우므로 `config_9.toml` 이 생기지 않고 (#382) 사용자의 instance 0
# 핫키와 부딪히지 않는다.
#
# **판정 셋을 함께 본다** (Windows 판과 같은 구조).
#   ① 밑줄 — `grim` 캡처를 중립 상태와 픽셀로 견준다. 커서는 headless sway 가 캡처에 **합성하므로**
#      (`grim` 과 `grim -c` 가 같다 — 2026-09-15 실측) 포인터 주변 상자를 빼고 센다.
#   ② 커서 모양 — XCursor 테마의 `default` · `text` · `pointer` 비트맵과 불투명 픽셀을 맞대 본다
#      ([`link-shot_linux.py`](link-shot_linux.py) `cursor`). 맞는 모양은 100 % 가 나온다.
#   ③ 열림 — `tildaz_stress.log` 의 `[link] opening link:` 줄이 케이스마다 **정확히 한 줄** 느는지.
#
# 환경변수: TILDAZ (기본 zig-out/bin/tildaz) · TZL_WORK (작업 디렉터리).
# 판정 줄은 `RESULT <회차>: …`, 케이스 줄은 `  [A1] PASS …` 로 시작한다.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TILDAZ=${TILDAZ:-$ROOT/zig-out/bin/tildaz}
WORK=${TZL_WORK:-${TMPDIR:-/tmp}/tildaz-link}
# ⚠️ sway IPC 소켓은 sun_path (108 바이트) 를 넘으면 세그폴트 — runtime dir 은 짧게.
R=/run/user/$(id -u)/tz647
VPTR=$R/vptr.fifo
VKBD=$R/vkbd.fifo
XDG=$WORK/xdg
SLOG=$XDG/state/tildaz-dev/tildaz_stress.log
SHOT=$ROOT/tool/link-shot_linux.py
# ⚠️ sway 에서는 `-size` 를 쓸 수 없다 — tildaz 가 sway 에서 layer-shell 대신 scratchpad 를 쓰므로
# (#454) 창 크기를 우리가 못 정하고, 앱이 그 인자를 거부하며 부팅을 멈춘다 (실측 2026-09-15:
# *"-size cannot be used on this desktop"*). 창은 타일링으로 출력 전체가 되고, 격자 칸 수는
# 로그의 `terminal session created cols= rows=` 에서 읽는다.
OUTW=1600
OUTH=1000

die() { echo "$*" >&2; exit 1; }
[ -x "$TILDAZ" ] || die "빌드가 없다: $TILDAZ  (zig build -Doptimize=ReleaseFast -Dsimd=true)"

env_sway() {
    export XDG_RUNTIME_DIR=$R WAYLAND_DISPLAY=wayland-1 XDG_CURRENT_DESKTOP=sway
    export XDG_CONFIG_HOME=$XDG/config XDG_STATE_HOME=$XDG/state
    SWAYSOCK=$(ls $R/sway-ipc.*.sock 2>/dev/null | head -1); export SWAYSOCK
    unset HYPRLAND_INSTANCE_SIGNATURE
    [ -S "$R/wayland-1" ] || die "headless sway 가 없다 — 먼저 'up'"
}
ptr() { printf '%s\n' "$@" > $VPTR; }
kbd() { printf '%s\n' "$@" > $VKBD; }
# 격리 앱만 잡는다 — `pkill -f` 는 자기 명령줄을 매치하니 쓰지 않는다 (AGENTS.md).
#
# **`/proc/PID/exe` 로 본다.** cmdline 을 문자열로 견주면 같은 바이너리를 상대 경로 (`./zig-out/bin/tildaz`)
# 로 띄운 회차가 안 잡힌다 — 2026-09-15 에 그 때문에 앞 회차의 창이 살아남아 새 창과 **겹쳐 찍혔고**
# 격자 검산이 깨졌다 (AGENTS.md 의 *"캡처에는 다른 창이 그 자리에 있을 수 있어요"* 와 같은 함정이다).
tz_pids() {
    local real=$(readlink -f "$TILDAZ")
    for p in $(pgrep -x "$(basename "$TILDAZ")" 2>/dev/null); do
        [ "$(readlink -f /proc/$p/exe 2>/dev/null)" = "$real" ] && echo $p
    done
}
kill_tz() { for p in $(tz_pids); do kill -TERM $p 2>/dev/null; done; sleep 1; }

# ── 화면 스크립트 — 이슈 #647 절차의 것 그대로 (A · B 는 태그와 DECSET 만 다르다) ──
write_screens() {
    cat > $WORK/tz-a.sh <<'EOF'
#!/bin/sh
printf '\n'
printf '  osc8:  \033]8;;x-tildaz-test://probe/A\033\\CLICK-OSC8\033]8;;\033\\\n'
printf '\n'
printf '  text:  https://example.com/pr/A\n'
printf '\n'
while :; do sleep 1; done
EOF
    cat > $WORK/tz-b.sh <<'EOF'
#!/bin/sh
printf '\n'
printf '  osc8:  \033]8;;x-tildaz-test://probe/B\033\\CLICK-OSC8\033]8;;\033\\\n'
printf '\n'
printf '  text:  https://example.com/pr/B\n'
printf '\n'
printf '\033[?1000h'
while :; do sleep 1; done
EOF
    chmod +x $WORK/tz-a.sh $WORK/tz-b.sh
}

cmd_up() {
    mkdir -m 700 -p $R; mkdir -p $WORK $XDG/config $XDG/state
    write_screens
    if [ ! -S $R/wayland-1 ]; then
        printf 'output HEADLESS-1 resolution %dx%d\ndefault_border none\nfocus_follows_mouse no\n' $OUTW $OUTH > $WORK/sway.conf
        # XCURSOR 테마 · 크기를 **못 박는다** — 판정기가 맞대 보는 비트맵과 같아야 한다.
        env -u XDG_CURRENT_DESKTOP -u HYPRLAND_INSTANCE_SIGNATURE -u SWAYSOCK XDG_RUNTIME_DIR=$R \
            XCURSOR_THEME=Adwaita XCURSOR_SIZE=24 WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
            setsid nohup timeout 14400 sway -c $WORK/sway.conf >$WORK/sway.log 2>&1 </dev/null &
        sleep 2
        [ -S $R/wayland-1 ] || die "sway 가 뜨지 않았다 — $WORK/sway.log"
        echo "sway: headless ${OUTW}x${OUTH} · $R/wayland-1 (timeout 4 h)"
    fi
    env_sway
    if ! pgrep -f "vptr_linux.py --fifo $VPTR" >/dev/null; then
        rm -f $VPTR
        setsid nohup python3 "$ROOT/tool/vptr_linux.py" --fifo $VPTR >$WORK/vptr.log 2>&1 </dev/null &
        sleep 1.5; head -1 $WORK/vptr.log
    fi
    if ! pgrep -f "vkbd_linux.py --fifo $VKBD" >/dev/null; then
        rm -f $VKBD
        setsid nohup python3 "$ROOT/tool/vkbd_linux.py" --fifo $VKBD >$WORK/vkbd.log 2>&1 </dev/null &
        sleep 1.5; head -1 $WORK/vkbd.log
    fi
    echo "환경: XDG_RUNTIME_DIR=$R WAYLAND_DISPLAY=wayland-1 작업=$WORK"
}

cmd_down() {
    env_sway 2>/dev/null || true
    kill_tz
    [ -p $VPTR ] && echo quit > $VPTR
    [ -p $VKBD ] && echo quit > $VKBD
    sleep 0.5
    pkill -f "vptr_linux.py --fifo $VPTR" 2>/dev/null
    pkill -f "vkbd_linux.py --fifo $VKBD" 2>/dev/null
    [ -n "${SWAYSOCK:-}" ] && swaymsg exit >/dev/null 2>&1
    sleep 1; rm -rf $R
    echo "남은 tildaz: $(pgrep -x tildaz | tr '\n' ' ')"
    echo "config_9.toml: $([ -f $XDG/config/tildaz/config_9.toml ] && echo '⚠️ 생겼다' || echo '없음 (-e 회차라 정상)')"
}

# ── 회차 공통 ────────────────────────────────────────────────────────────────
start_app() {   # $1 = a|b
    kill_tz
    rm -f $SLOG
    TILDAZ_VERBOSE=1 setsid nohup "$TILDAZ" --instance 9 -e $WORK/tz-$1.sh >$OUT/app.log 2>&1 </dev/null &
    sleep 4
    [ -n "$(tz_pids)" ] || die "앱이 뜨지 않았다 — $OUT/app.log · $SLOG"
    grep -q "shell exited" $SLOG && die "화면 스크립트가 바로 끝났다 — \`-e\` 는 실행 파일 경로를 받는다"
    CELL_W=$(grep -o "applied ratios cell_w=[0-9]*" $SLOG | tail -1 | grep -o '[0-9]*')
    [ -n "$CELL_W" ] || die "로그에서 cell_w 를 못 읽었다 — TILDAZ_VERBOSE=1 로 떴는지 확인"
    local grid=$(grep -oE "terminal (session created|resized) cols=[0-9]+ rows=[0-9]+" $SLOG | tail -1)
    COLS=$(echo "$grid" | grep -o 'cols=[0-9]*' | grep -o '[0-9]*')
    ROWS=$(echo "$grid" | grep -o 'rows=[0-9]*' | grep -o '[0-9]*')
    [ -n "$COLS" ] && [ -n "$ROWS" ] || die "로그에서 cols/rows 를 못 읽었다"
    echo "창: ${COLS}x${ROWS} 칸 · 셀 폭 ${CELL_W} px"
}

# 중립 캡처용 자리 — 창이 출력 전체라 "창 밖" 이 없으므로 **글자가 없는 먼 칸**에 세운다.
# 그 자리의 커서는 중립 캡처에도 찍히므로 `diffbox` 가 이 상자도 함께 뺀다.
park() { ptr "move $PARK_X $PARK_Y"; sleep 0.6; }

shot() { grim $OUT/$1.png; }

# 격자를 캡처에서 찾는다. 창 안에서 컨트롤 스트립 (+ × ⋯) 은 빼고 본다.
find_grid() {
    # 창 영역만 본다 — 옆에 다른 창 (밝은 배경) 이 있으면 행 탐색이 통째로 한 덩어리가 된다.
    local r=$(tz_rect); local ax0=0 ay0=0 ax1=$((OUTW - 130)) ay1=$((OUTH - 1))
    if [ -n "$r" ]; then set -- $r; ax0=$1; ay0=$2; ax1=$(( $3 - 130 )); ay1=$4; fi
    # 1 차 — 격자를 아직 모르니 창에서 먼 자리 (글자가 없는 곳) 에 세우고 찍는다.
    PARK_X=$((OUTW - 60)); PARK_Y=$((OUTH - 60)); park; shot neutral
    G=$(python3 "$SHOT" --json grid $OUT/neutral.png --cell-w $CELL_W --area $ax0 $ay0 $ax1 $ay1) \
        || die "격자를 못 찾았다"
    CELL_W=$(echo "$G" | python3 -c "import json,sys;print(json.load(sys.stdin)['cell_w'])" )
    GRID_X=$(echo "$G" | python3 -c "import json,sys;print(json.load(sys.stdin)['grid_x'])" )
    GRID_Y=$(echo "$G" | python3 -c "import json,sys;print(json.load(sys.stdin)['grid_y'])" )
    CELL_H=$(echo "$G" | python3 -c "import json,sys;print(json.load(sys.stdin)['cell_h'])" )
    # 케이스 좌표 — 칸 중앙
    URL_X=$((GRID_X + 20 * CELL_W + CELL_W / 2)); URL_Y=$((GRID_Y + 3 * CELL_H + CELL_H / 2))
    OSC_X=$((GRID_X + 13 * CELL_W + CELL_W / 2)); OSC_Y=$((GRID_Y + 1 * CELL_H + CELL_H / 2))
    LBL_X=$((GRID_X + 4 * CELL_W + CELL_W / 2));  LBL_Y=$URL_Y
    echo "격자: 원점=($GRID_X,$GRID_Y) 셀=${CELL_W}x${CELL_H}  URL=($URL_X,$URL_Y) OSC8=($OSC_X,$OSC_Y) 라벨=($LBL_X,$LBL_Y)"
}

# 중립 캡처와의 픽셀 차이 — `<폭> <픽셀수> <설명>` 을 찍는다. $1 캡처 이름 · $2,$3 포인터 좌표
#
# **격자 영역만 본다** — 중립 캡처는 포인터를 창 밖에 세워 두고 찍으므로, 영역을 안 좁히면 그 자리의
# 커서 자국이 통째로 차이로 잡힌다. **포인터 주변 상자는 뺀다** — 커서가 캡처에 합성되기 때문이다
# (세 모양 중 가장 큰 `default` 가 hotspot 기준 -3..+20 이라 -20..+28 이면 셋 다 덮는다).
# 밑줄은 링크 전체에 걸친 가로선이라 그 상자가 가운데를 지워도 **경계 상자 폭은 그대로**다.
diffbox() {
    # 가리킨 **행 하나**만 본다. 밑줄은 그 행에 그려지고, 다른 행의 변화 (셸이 에코한 마우스
    # 리포트 등) 가 경계 상자를 늘려 폭 판정을 깨뜨리기 때문이다 (2026-09-15 회차 C 에서 걸렸다).
    local row=$(( ($3 - GRID_Y) / CELL_H ))
    python3 "$SHOT" --json diff $OUT/neutral.png $OUT/$1.png \
        --region $GRID_X $((GRID_Y + row * CELL_H)) $((GRID_X + COLS * CELL_W)) $((GRID_Y + (row + 1) * CELL_H - 1)) \
        --ignore-box $(( $2 - 20 )) $(( $3 - 20 )) $(( $2 + 28 )) $(( $3 + 28 )) \
        --ignore-box $((PARK_X - 20)) $((PARK_Y - 20)) $((PARK_X + 28)) $((PARK_Y + 28)) \
        | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('w',0), d['px'], 'x%d-%d,y%d' % (d.get('x0',0), d.get('x1',0), d.get('y0',0)))"
}
uw_of() { diffbox "$1" "$2" "$3" | cut -d' ' -f1; }
# 격자 전체에서 두 캡처의 차이 픽셀 수 — 행 제한이 없다.
gridpx() { python3 "$SHOT" --json diff $OUT/$1.png $OUT/$2.png \
        --region $GRID_X $GRID_Y $((GRID_X + COLS * CELL_W)) $((GRID_Y + ROWS * CELL_H)) \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['px'])"; }
upx_of() { diffbox "$1" "$2" "$3" | cut -d' ' -f2; }
cursor_of() { python3 "$SHOT" --json cursor $OUT/$1.png $2 $3 | python3 -c "import json,sys;print(json.load(sys.stdin)['shape'])"; }
# 커서를 못 재는 회차에서는 기대값을 그대로 돌려준다 — 판정에서 빠지고 보고에 `n/a` 로 남는다.
cursor_or_skip() { [ "$CURSOR_OK" = 1 ] && cursor_of "$1" "$2" "$3" || echo "n/a"; }
# `grep -c` 는 0 건일 때 exit 1 이라 `|| echo 0` 을 붙이면 **0 이 두 줄** 나온다 (산술 확장이 깨진다).
# 개수는 어차피 stdout 에 찍히므로 exit code 를 삼키기만 한다.
opens() { local n; n=$(grep -c 'opening link' $SLOG 2>/dev/null); echo "${n:-0}"; }
# 이 headless sway 안의 **xdg_toplevel 창** 목록. tildaz 는 layer-shell 이라 여기 안 나온다 —
# 그래서 이 목록이 비어 있지 않다는 것이 곧 "브라우저가 실제로 떴다" 는 증거이고, `kill_toplevels`
# 가 tildaz 를 건드리지 않는 근거이기도 하다.
# 이 headless sway 안의 **tildaz 아닌 xdg_toplevel 창** 목록.
#
# ⚠️ tildaz 도 여기 나온다 — sway 에서는 layer-shell 이 아니라 scratchpad 경로라 `app_id` 가
# `tildaz.stress` 인 toplevel 이다 (2026-09-15 실측). 그래서 `[app_id=".*"] kill` 로 뒷정리하면
# **앱까지 죽는다.** tildaz 를 이름으로 빼고, 남은 것이 곧 "브라우저가 실제로 떴다" 는 증거다.
toplevels() { swaymsg -t get_tree 2>/dev/null | python3 -c 'import json,sys
def w(n,o):
    a=n.get("app_id")
    if a and not a.startswith("tildaz"): o.append(a)
    for c in n.get("nodes",[])+n.get("floating_nodes",[]): w(c,o)
o=[]; w(json.load(sys.stdin),o); print(" ".join(o))'; }
# tildaz 창의 rect — sway 에서는 layer-shell 이 아니라 app_id `tildaz.*` 인 toplevel 이라 트리에 있다.
tz_rect() { swaymsg -t get_tree 2>/dev/null | python3 -c 'import json,sys
def w(n,o):
    a=n.get("app_id")
    if a and a.startswith("tildaz"):
        r=n["rect"]; o.append("%d %d %d %d" % (r["x"], r["y"], r["x"]+r["width"]-1, r["y"]+r["height"]-1))
    for c in n.get("nodes",[])+n.get("floating_nodes",[]): w(c,o)
o=[]; w(json.load(sys.stdin),o); print(o[0] if o else "")'; }
kill_toplevels() {
    for a in $(toplevels); do swaymsg "[app_id=\"^$a$\"] kill" >/dev/null 2>&1; done
    sleep 1.5
}
last_open() { grep 'opening link' $SLOG 2>/dev/null | tail -1 | sed 's/.*opening link: //'; }

PASS=0; FAIL=0
rec() {  # $1 id · $2 기대 · $3 실제 · $4 ok(0/1)
    if [ "$4" = 1 ]; then PASS=$((PASS+1)); echo "  [$1] PASS  기대: $2 · 실제: $3"
    else FAIL=$((FAIL+1)); echo "  [$1] FAIL  기대: $2 · 실제: $3"; fi
}

# hover 한 자리의 밑줄 · 커서를 재서 케이스 하나를 판정한다.
# $1 id · $2 x · $3 y · $4 기대 밑줄 폭 px (0 이면 없어야) · $5 기대 커서
hover_case() {
    ptr "move $2 $3"; sleep 0.8; shot "$1"
    local d uw upx c
    d=$(diffbox "$1" "$2" "$3"); uw=$(echo $d | cut -d' ' -f1); upx=$(echo $d | cut -d' ' -f2)
    c=$(cursor_or_skip "$1" "$2" "$3")
    [ "$CURSOR_OK" = 1 ] || set -- "$1" "$2" "$3" "$4" "n/a"
    if [ "$4" = 0 ]; then
        { [ "$upx" = 0 ] && [ "$c" = "$5" ]; } \
            && rec "$1" "밑줄 없음 · $5" "0 px · $c" 1 || rec "$1" "밑줄 없음 · $5" "$d · $c" 0
    else
        { [ "$uw" = "$4" ] && [ "$c" = "$5" ]; } \
            && rec "$1" "밑줄 폭 $4 px · $5" "$d · $c" 1 || rec "$1" "밑줄 폭 $4 px · $5" "$d · $c" 0
    fi
}

UNDER_URL=$((24 * 9))     # 자동 검출 URL 24 칸 — find_grid 뒤에 셀 폭으로 다시 잡는다
UNDER_OSC=$((10 * 9))

# ⚠️ **커서가 실제로 그려지는지 먼저 확인한다.** sway 가 커서를 화면에 아예 안 그리는 구간이 있다
# (2026-09-15 실측 — 같은 sway·같은 tildaz 인데 회차에 따라 갈렸고, 대조군 `foot` 위에서도 똑같이
# 안 나와 compositor 쪽 상태로 판정했다. `XCURSOR_THEME` · `seat * xcursor_theme` · sway 재기동 모두
# 무효였다). 그 상태로 커서를 판정하면 판정기가 배경을 긁어 70 % 대 점수를 내는데, `--min-ratio` 가
# 그것을 `unknown` 으로 돌려준다 — **틀린 PASS 가 아니라 측정 불가로 다뤄야 한다.**
# 그래서 여기서 걸러서 `CURSOR_OK` 로 남기고, 밑줄 · 열림 판정은 그대로 돌린다.
CURSOR_OK=0
cursor_ready() {
    local blank_x=$((GRID_X + 60 * CELL_W)) blank_y=$((GRID_Y + 30 * CELL_H)) c
    for i in 1 2 3; do
        ptr "move $blank_x $blank_y" "moveby 1 0" "moveby -1 0"; sleep 1
        shot _curwarm; c=$(cursor_of _curwarm $blank_x $blank_y)
        [ "$c" = text ] && { CURSOR_OK=1; echo "커서 판정 사용 가능 (빈 칸 → $c)"; return 0; }
    done
    CURSOR_OK=0
    echo "⚠️ 커서가 화면에 안 그려진다 (빈 칸에서 '$c') — 이 회차는 **커서 판정을 건너뛴다** (밑줄 · 열림은 그대로)"
}

setup_round() {  # $1 = a|b · $2 = 회차 이름
    env_sway; OUT=$WORK/$2; rm -rf $OUT; mkdir -p $OUT
    # 앞 회차가 띄운 브라우저가 남아 있으면 화면을 덮어 격자 탐색이 실패한다 (2026-09-15 실측).
    kill_toplevels
    start_app "$1"; find_grid; cursor_ready; park; shot neutral
    UNDER_URL=$((24 * CELL_W)); UNDER_OSC=$((10 * CELL_W))
    PASS=0; FAIL=0
}

finish_round() {
    echo "RESULT $1: pass=$PASS fail=$FAIL  (캡처 · 로그: $OUT)"
    kill_tz
}

cmd_A() {
    setup_round a A
    hover_case A1 $URL_X $URL_Y $UNDER_URL pointer
    # A3 · A4 · A5 를 먼저 하고 **A2 를 마지막에** 한다 — A2 만 진짜 브라우저를 띄우는데, 그 창이
    # 뒤늦게 map 되면 tildaz 를 가려 뒤 케이스의 캡처를 오염시킨다.
    hover_case A3h $OSC_X $OSC_Y $UNDER_OSC pointer
    local n0=$(opens); ptr "click left"; sleep 1.5; local n1=$(opens)
    # ⚠️ **`x-tildaz-test://` 가 "창이 안 뜬다" 는 것은 데스크톱에 달렸다** (2026-09-15 Linux 실측).
    # `xdg-open` 은 환경이 KDE 로 보이면 (`KDE_FULL_SESSION=true`) `kde-open` 으로 넘기는데, 그쪽은
    # 등록된 앱이 없는 scheme 에 **KIO 오류 다이얼로그**를 띄운다 (*"… 파일에서 읽을 수 없습니다"*).
    # 일반 · sway 환경에서는 조용히 끝난다. 우리 판정선은 **로그 줄**이므로 창 유무는 기록만 한다.
    local win="$(toplevels)"
    { [ $((n1 - n0)) = 1 ] && [ "$(last_open)" = "x-tildaz-test://probe/A" ]; } \
        && rec A3 "로그 +1 · x-tildaz-test://probe/A" "+$((n1-n0)) · $(last_open) · 창 [${win:-없음}]" 1 \
        || rec A3 "로그 +1 · x-tildaz-test://probe/A" "+$((n1-n0)) · $(last_open) · 창 [${win:-없음}]" 0
    kill_toplevels
    hover_case A4h $LBL_X $LBL_Y 0 text
    n0=$(opens); ptr "click left"; sleep 1.5; n1=$(opens)
    [ $((n1 - n0)) = 0 ] && rec A4 "로그 +0" "+$((n1-n0))" 1 || rec A4 "로그 +0" "+$((n1-n0))" 0
    # A5 — URL 위에서 드래그. 문턱을 한참 넘게 끈다.
    n0=$(opens)
    ptr "move $URL_X $URL_Y" "down left" "moveby 20 0" "moveby 20 0" "moveby 20 0" "up left"; sleep 1.5
    n1=$(opens); shot A5
    local sel=$(upx_of A5 $((URL_X + 60)) $URL_Y)
    { [ $((n1 - n0)) = 0 ] && [ "${sel:-0}" -gt 200 ]; } \
        && rec A5 "로그 +0 · 선택이 그려짐" "+$((n1-n0)) · 바뀐 픽셀 $sel" 1 \
        || rec A5 "로그 +0 · 선택이 그려짐" "+$((n1-n0)) · 바뀐 픽셀 $sel" 0
    # A2 — 자동 검출 URL 을 수식키 없이 클릭. **이 회차에서만 진짜 브라우저가 뜬다.**
    ptr "move $((GRID_X + 60 * CELL_W)) $((GRID_Y + 10 * CELL_H))"; sleep 0.5   # 선택 해제
    hover_case A2h $URL_X $URL_Y $UNDER_URL pointer
    n0=$(opens); ptr "click left"; sleep 2; n1=$(opens)
    local browser=""
    for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1.5; browser=$(toplevels); [ -n "$browser" ] && break; done
    { [ $((n1 - n0)) = 1 ] && [ -n "$browser" ]; } \
        && rec A2 "로그 +1 · 브라우저 창이 실제로 뜸" "+$((n1-n0)) · $(last_open) · 창 [$browser]" 1 \
        || rec A2 "로그 +1 · 브라우저 창" "+$((n1-n0)) · $(last_open) · 창 [${browser:-없음}]" 0
    kill_toplevels
    finish_round A
}

cmd_B() {
    setup_round b B
    hover_case B1 $URL_X $URL_Y 0 text
    kbd "hold ctrl"; sleep 1.0; shot B2
    local u=$(diffbox B2 $URL_X $URL_Y); local uw=$(echo $u | cut -d' ' -f1)
    local c=$(cursor_or_skip B2 $URL_X $URL_Y); local want_c=pointer; [ "$CURSOR_OK" = 1 ] || want_c=n/a
    { [ "$uw" = "$UNDER_URL" ] && [ "$c" = "$want_c" ]; } \
        && rec B2 "마우스를 안 움직여도 밑줄 $UNDER_URL px · $want_c" "$u · $c" 1 \
        || rec B2 "밑줄 $UNDER_URL px · $want_c" "$u · $c" 0
    kbd "release ctrl"; sleep 1.0; shot B3
    u=$(diffbox B3 $URL_X $URL_Y); local upx=$(echo $u | cut -d' ' -f2)
    c=$(cursor_or_skip B3 $URL_X $URL_Y); want_c=text; [ "$CURSOR_OK" = 1 ] || want_c=n/a
    { [ "$upx" = 0 ] && [ "$c" = "$want_c" ]; } \
        && rec B3 "떼면 즉시 원상복구 · $want_c" "0 px · $c" 1 || rec B3 "밑줄 없음 · $want_c" "$u · $c" 0
    # B4 · B5 는 **OSC 8** 링크에서 본다 — 등록된 앱이 없는 scheme 이라 브라우저가 안 뜬다.
    # 진짜 브라우저가 열리는 것은 회차 A2 에서 한 번 확인했다.
    kbd "hold ctrl"; ptr "move $OSC_X $OSC_Y"; sleep 1.0
    local n0=$(opens); ptr "click left"; sleep 1.5; local n1=$(opens)
    { [ $((n1 - n0)) = 1 ] && [ "$(last_open)" = "x-tildaz-test://probe/B" ]; } \
        && rec B4 "Ctrl+클릭 → 로그 +1 · x-tildaz-test://probe/B" "+$((n1-n0)) · $(last_open)" 1 \
        || rec B4 "로그 +1 · x-tildaz-test://probe/B" "+$((n1-n0)) · $(last_open)" 0
    kbd "release ctrl"; sleep 1.0
    shot B5pre
    n0=$(opens); ptr "click left"; sleep 1.5; n1=$(opens); shot B5post
    # **클릭이 앱으로 갔다는 양의 증거** — 자식 (`sh`) 이 받은 `CSI M …` 바이트를 PTY 에코가
    # 화면에 찍는다. Windows 회차는 이것을 못 재서 *"안 열린다"* 까지만 적었던 자리다.
    local echoed=$(gridpx B5pre B5post)
    { [ $((n1 - n0)) = 0 ] && [ "${echoed:-0}" -gt 0 ]; } \
        && rec B5 "Ctrl 없이 클릭 → 로그 +0 이고 **앱이 받는다**" "+$((n1-n0)) · 화면에 에코된 픽셀 $echoed" 1 \
        || rec B5 "로그 +0 · 앱이 받음 (에코)" "+$((n1-n0)) · 에코 $echoed" 0
    finish_round B
}

cmd_C() {   # 클릭이 앱으로 라우팅된 뒤에도 수식키 재판정이 사는지 (Windows 판의 회차 C)
    setup_round b C
    hover_case C1 $URL_X $URL_Y 0 text
    ptr "click left"; sleep 1.0                        # 클릭은 앱으로 간다
    kbd "hold ctrl"; sleep 1.0; shot C2
    local u=$(diffbox C2 $URL_X $URL_Y); local uw=$(echo $u | cut -d' ' -f1); local c=$(cursor_or_skip C2 $URL_X $URL_Y); local want_c=pointer; [ "$CURSOR_OK" = 1 ] || want_c=n/a
    [ "$uw" = "$UNDER_URL" ] && [ "$c" = "$want_c" ] \
        && rec C2 "클릭 뒤에도 Ctrl 로 밑줄 $UNDER_URL px · pointer" "$u · $c" 1 \
        || rec C2 "밑줄 $UNDER_URL px · pointer" "$u · $c" 0
    ptr "move $OSC_X $OSC_Y"; sleep 1.0
    local n0=$(opens); ptr "click left"; sleep 1.5; local n1=$(opens)
    [ $((n1 - n0)) = 1 ] && rec C3 "로그 +1 · $(last_open)" "+$((n1-n0)) · $(last_open)" 1 || rec C3 "로그 +1" "+$((n1-n0))" 0
    kbd "release ctrl"
    finish_round C
}

cmd_D() {   # 6350d99 — 링크 위에서 누르면 칸이 바뀌어도 문턱 안이면 클릭이다
    setup_round a D
    # 문턱 = min(4 pt × scale, 셀 폭 / 2). 칸 **경계 바로 앞**을 눌러 3 px 만 밀면 칸이 바뀌고 문턱은 안 넘는다.
    local edge_x=$((GRID_X + 21 * CELL_W - 1))
    local n0=$(opens)
    ptr "move $edge_x $URL_Y" "down left" "moveby 3 0" "up left"; sleep 1.5
    local n1=$(opens)
    [ $((n1 - n0)) = 1 ] && rec D1 "3 px 밀어도 열림 (로그 +1)" "+$((n1-n0)) · $(last_open)" 1 \
        || rec D1 "로그 +1" "+$((n1-n0))" 0
    kill_toplevels
    n0=$(opens)
    ptr "move $URL_X $URL_Y" "down left" "moveby 30 0" "moveby 30 0" "up left"; sleep 1.5
    n1=$(opens); shot D2
    local sel=$(upx_of D2 $((URL_X + 60)) $URL_Y)
    [ $((n1 - n0)) = 0 ] && [ "$sel" -gt 200 ] \
        && rec D2 "60 px 끌면 안 열리고 선택 (로그 +0)" "+$((n1-n0)) · 바뀐 픽셀 $sel" 1 \
        || rec D2 "로그 +0 · 선택" "+$((n1-n0)) · 바뀐 픽셀 $sel" 0
    finish_round D
}

cmd_enter() {   # 포인터가 창에 **들어오고 나가는** 순간의 판정 (#647 · 2026-09-15 리눅스에서 발견)
    setup_round a enter
    # sway 에서 tildaz 는 출력 전체를 차지해 **"창 밖" 이 없다.** 옆에 대조 창 (foot) 을 띄워
    # 타일링으로 반을 넘기면, 그 반이 곧 tildaz surface 밖이 되어 `wl_pointer` 의 enter · leave 가 난다.
    setsid nohup foot -- sh -c 'while :; do sleep 1; done' >$OUT/foot.log 2>&1 </dev/null &
    sleep 3
    [ -n "$(toplevels)" ] || die "대조 창 (foot) 이 뜨지 않았다 — $OUT/foot.log"
    local grid=$(grep -oE "terminal (session created|resized) cols=[0-9]+ rows=[0-9]+" $SLOG | tail -1)
    COLS=$(echo "$grid" | grep -o 'cols=[0-9]*' | grep -o '[0-9]*')
    ROWS=$(echo "$grid" | grep -o 'rows=[0-9]*' | grep -o '[0-9]*')
    find_grid                      # 분할 뒤 좌표를 다시 잡는다 (park 은 foot 쪽 = 창 밖이다)
    echo "분할: tildaz ${COLS}x${ROWS} 칸 · 창 밖 기준점=($PARK_X,$PARK_Y)"
    park; shot neutral

    hover_case E0 $LBL_X $LBL_Y 0 text                      # 링크 아닌 칸 — hover 를 비워 둔다
    park                                                     # tildaz surface 밖 (foot 위)
    ptr "move $URL_X $URL_Y"; sleep 1.2; shot E1             # 창 밖 → 링크 위로 **직행** (motion 없이 enter)
    local u=$(diffbox E1 $URL_X $URL_Y); local uw=$(echo $u | cut -d' ' -f1)
    local c=$(cursor_or_skip E1 $URL_X $URL_Y); local want_c=pointer; [ "$CURSOR_OK" = 1 ] || want_c=n/a
    { [ "$uw" = "$UNDER_URL" ] && [ "$c" = "$want_c" ]; } \
        && rec E1 "들어오자마자 밑줄 $UNDER_URL px · $want_c" "$u · $c" 1 \
        || rec E1 "들어오자마자 밑줄 $UNDER_URL px · $want_c" "$u · $c" 0
    ptr "moveby 1 0"; sleep 0.8; shot E2                     # 같은 칸 안에서 1 px 만
    u=$(diffbox E2 $URL_X $URL_Y); uw=$(echo $u | cut -d' ' -f1)
    [ "$uw" = "$UNDER_URL" ] && rec E2 "1 px 움직이면 밑줄" "$u" 1 || rec E2 "밑줄 $UNDER_URL px" "$u" 0
    park; shot E3                                            # 링크를 가리킨 채 창 밖으로
    local left=$(gridpx neutral E3)
    [ "${left:-0}" = 0 ] && rec E3 "창을 떠나면 밑줄이 사라짐" "0 px" 1 \
        || rec E3 "창을 떠나면 밑줄이 사라짐" "$left px 남음" 0
    kill_toplevels
    finish_round enter
}

case "${1:-}" in
    up) cmd_up ;;
    down) cmd_down ;;
    probe) env_sway; OUT=$WORK/probe; rm -rf $OUT; mkdir -p $OUT; start_app a; find_grid; echo "캡처: $OUT/neutral.png" ;;
    A) cmd_A ;;
    B) cmd_B ;;
    C) cmd_C ;;
    D) cmd_D ;;
    enter) cmd_enter ;;
    *) sed -n '2,30p' "$0"; exit 1 ;;
esac
