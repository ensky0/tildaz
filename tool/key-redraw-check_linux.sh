#!/bin/bash
# #763 — 키가 화면을 바꾸는 장면을 두 앱 판에 똑같이 보내 캡처를 견준다 (Linux 몫).
# Windows 의 `key-redraw-check_windows.ps1` 과 짝이다. 그쪽은 "150 ms 에 이미 바뀌었나" 를 한 판으로 보고,
# 이쪽은 **기준판과 픽셀이 같은가** 를 본다. 그리기가 빠지면 다음 이벤트까지 화면이 안 바뀌어서, 키 뒤 1 초
# 캡처가 기준판과 갈린다.
#
#   tool/key-redraw-check_linux.sh up [--no-ime]     # headless sway + 가상 키보드 (US-International) · 포인터 + 격리 fcitx5
#   tool/key-redraw-check_linux.sh ab <기준판> <수정판> [회차=2]   # 번갈아 돌리고 장면별로 견준다
#   tool/key-redraw-check_linux.sh run <이름> <tildaz>              # 한 판만 한 번 (장면 캡처만)
#   tool/key-redraw-check_linux.sh down
#
# 장면 (AGENTS.md `# Linux — headless sway …` 절):
#   스크롤백을 올린 채 글자 · 에코 없는 글자 (`stty -echo`) · Ctrl+C · 붙여넣기 · dead key (`'` → `é`, 에코 없을 때 · Esc) ·
#   탭 (`Ctrl+Shift+T` · `Alt+1` · `Ctrl+PgDn/PgUp`) · 명령 메뉴 (`⋯` 클릭 · `Down` · `Esc`) · 한글 조합 (격리 fcitx5 가 있을 때)
#
# 판정 — `RESULT` 줄:
#   ① 장면마다 기준판 ↔ 수정판이 회차마다 0 px 인가.
#   ② **거짓 통과 검사** — 수정판의 장면이 바로 앞 장면과 달라야 한다. 도구가 아무것도 못 찍어도 ① 은 0 이 나온다.
#
# 사용자 세션을 건드리지 않는다: 격리 runtime dir · 격리 XDG · 격리 D-Bus 의 fcitx5 (config 는 사본).
# 가상 키보드는 headless sway 로만 간다. 키 배열이 US-International 이라 셸에 치는 명령에 `'` `"` `` ` `` `~` `^` 를 쓰지 않는다
# (dead key 가 된다).
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${TZKR_WORK:-${TMPDIR:-/tmp}/tildaz-key-redraw}
# ⚠️ sway 의 IPC 소켓 경로는 sun_path (108 바이트) 를 넘으면 세그폴트 — runtime dir 은 짧게.
R=/run/user/$(id -u)/tzkr
XDG=$WORK/xdg
FIFO=$R/vkbd.fifo
PFIFO=$R/vptr.fifo
APP=${TZKR_APP:-tildaz-dev}
LOG=$XDG/state/$APP/tildaz_0.log

die() { echo "$*" >&2; exit 1; }
env_sway() {
    export XDG_RUNTIME_DIR=$R WAYLAND_DISPLAY=wayland-1 XDG_CURRENT_DESKTOP=sway
    export XDG_CONFIG_HOME=$XDG/config XDG_STATE_HOME=$XDG/state
    SWAYSOCK=$(ls $R/sway-ipc.*.sock 2>/dev/null | head -1); export SWAYSOCK
    unset HYPRLAND_INSTANCE_SIGNATURE DBUS_SESSION_BUS_ADDRESS
    [ -S "$R/wayland-1" ] || die "headless sway 가 없다 — 먼저 'up'"
}
snd() { for a in "$@"; do printf '%s\n' "$a" > $FIFO; done; }
ptr() { printf '%s\n' "$1" > $PFIFO; }
fx() { env DBUS_SESSION_BUS_ADDRESS="$(cat $WORK/fx/addr)" fcitx5-remote "$@"; }
have_ime() { [ -f $WORK/fx/addr ] && fx >/dev/null 2>&1; }
# 이 runtime dir 에서 뜬 것만 — 사용자 instance · 사용자 fcitx5 와 절대 겹치지 않는다 (빌드가 바이너리를 바꿔도).
mine() { for p in $(pgrep -x "$1"); do grep -qz "XDG_RUNTIME_DIR=$R" /proc/$p/environ 2>/dev/null && echo $p; done; }
px() {   # 두 PNG 의 다른 픽셀 수 — 채널 중 하나라도 다르면 1
    magick "$1" "$2" -compose difference -composite -alpha off -separate -evaluate-sequence max \
        -threshold 0 -format '%[fx:int(mean*w*h+0.5)]' info: 2>/dev/null || echo ERR
}

cmd_up() {
    local ime=1; [ "${1:-}" = --no-ime ] && ime=0
    mkdir -m 700 -p $R; mkdir -p $WORK $XDG/config/$APP $XDG/state
    # 사용자 config 를 복사하되 auto_start · hidden_start 는 끈다 — hidden_start 면 창이 핫키를 기다리며 안 뜬다.
    local src=$HOME/.config/$APP/config_0.toml
    [ -f "$src" ] || src=$HOME/.config/tildaz/config_0.toml
    if [ -f "$src" ]; then
        sed -e 's|^auto_start  *= .*|auto_start       = false|' -e 's|^hidden_start *= .*|hidden_start = false|' "$src" \
            > $XDG/config/$APP/config_0.toml
    fi
    if [ ! -S $R/wayland-1 ]; then
        printf 'output HEADLESS-1 resolution 1600x1000\ndefault_border none\nfocus_follows_mouse no\n' > $WORK/sway.conf
        env -u XDG_CURRENT_DESKTOP -u SWAYSOCK -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR=$R \
            WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 setsid nohup timeout 7200 sway -c $WORK/sway.conf \
            >$WORK/sway.log 2>&1 </dev/null &
        sleep 2; [ -S $R/wayland-1 ] || die "sway 가 뜨지 않았다 — $WORK/sway.log"
    fi
    env_sway
    setsid nohup python3 $ROOT/tool/vkbd_linux.py --fifo $FIFO --variant intl >$WORK/vkbd.log 2>&1 </dev/null &
    setsid nohup python3 $ROOT/tool/vptr_linux.py --fifo $PFIFO >$WORK/vptr.log 2>&1 </dev/null &
    sleep 1.5; head -1 $WORK/vkbd.log; head -1 $WORK/vptr.log
    [ $ime = 1 ] || return 0
    if ! command -v fcitx5 >/dev/null || [ ! -d $HOME/.config/fcitx5 ]; then
        echo "fcitx5 없음 — 한글 조합 장면은 건너뛴다"; return 0
    fi
    # 격리 fcitx5 — D-Bus 도 config 도 따로. fcitx5 는 끝날 때 profile 을 덮어쓰니 (AGENTS.md) 사본을 쓴다.
    mkdir -p $WORK/fx/config $WORK/fx/data; rm -rf $WORK/fx/config/fcitx5; cp -r $HOME/.config/fcitx5 $WORK/fx/config/
    dbus-daemon --session --fork --print-address=3 --print-pid=4 3>$WORK/fx/addr 4>$WORK/fx/pid
    env -u DISPLAY -u XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS="$(cat $WORK/fx/addr)" \
        XDG_CONFIG_HOME=$WORK/fx/config XDG_DATA_HOME=$WORK/fx/data XDG_RUNTIME_DIR=$R WAYLAND_DISPLAY=wayland-1 \
        setsid nohup fcitx5 --disable=kimpanel,notificationitem,dbusfrontend,xim,ibusfrontend \
        >$WORK/fx/fcitx5.log 2>&1 </dev/null &
    sleep 3
    if have_ime && grep -q 'Loaded addon hangul' $WORK/fx/fcitx5.log; then echo "fcitx5: 격리 · hangul"
    else echo "fcitx5 가 hangul 로 안 떴다 — 한글 조합 장면은 건너뛴다 ($WORK/fx/fcitx5.log)"; fi
}

cmd_down() {
    [ -S $R/wayland-1 ] && env_sway
    for p in $(mine tildaz); do kill -TERM $p; done
    for p in $(mine fcitx5); do kill -TERM $p; done
    [ -f $WORK/fx/pid ] && kill -TERM "$(cat $WORK/fx/pid)" 2>/dev/null
    rm -f $WORK/fx/addr $WORK/fx/pid
    [ -p $FIFO ] && echo quit > $FIFO
    [ -p $PFIFO ] && echo quit > $PFIFO
    sleep 0.5
    [ -n "${SWAYSOCK:-}" ] && swaymsg exit >/dev/null 2>&1
    sleep 1; rm -rf $R
    echo "남은 격리 tildaz: $(mine tildaz | tr '\n' ' ')"
}

shot() { sleep 1; grim $OUT/$1.png; }

cmd_run() {
    local name=$1 bin=$2
    env_sway; OUT=$WORK/$name; rm -rf $OUT; mkdir -p $OUT
    [ -x "$bin" ] || die "앱이 없다: $bin"
    [ -z "$(mine tildaz)" ] || die "격리 tildaz 가 이미 떠 있다 — 'down' 뒤 다시 'up'"
    local mark=$(( $(wc -l < $LOG 2>/dev/null || echo 0) + 1 ))
    TILDAZ_VERBOSE=1 nohup "$bin" --instance 0 >$OUT/stdout.txt 2>&1 </dev/null &
    sleep 4
    [ -n "$(mine tildaz)" ] || die "앱이 안 떴다 — $OUT/stdout.txt"
    have_ime && fx -c
    # 가상 포인터를 화면 구석까지 크게 움직여 enter 를 만든다 (같은 좌표면 enter 가 안 온다 — AGENTS.md).
    ptr "move 0 0"; ptr "move 1599 999"; ptr "move 5 500"
    rm -f $WORK/probe; snd "type touch $WORK/probe" "key Return"
    for i in $(seq 16); do sleep 0.5; [ -f $WORK/probe ] && break; done
    [ -f $WORK/probe ] || die "가상 키보드가 앱에 닿지 않는다 — $WORK/vkbd.log"
    snd "type PS1=\\\$\\ ; clear" "key Return"; sleep 1
    snd "type seq 1 300" "key Return"; shot s00_bottom
    # 스크롤백을 올린 채 글자 (에코 있음)
    snd "key shift+pageup"; shot s01_scrolled
    snd "type x"; shot s02_type_x
    snd "key ctrl+c"; shot s03_ctrlc_bottom
    # 에코 없음 — 출력이 없어도 맨 아래로 와야 한다
    snd "type stty -echo" "key Return"; sleep 0.5
    snd "key shift+pageup"; shot s04_scrolled
    snd "type y"; shot s05_noecho_y
    snd "key shift+pageup"; shot s06_scrolled
    snd "key ctrl+c"; shot s07_noecho_ctrlc
    snd "type stty echo" "key Return"; sleep 0.5
    # 붙여넣기
    printf 'pasted' | wl-copy; sleep 0.5
    snd "key shift+pageup"; shot s08_scrolled
    snd "key ctrl+shift+v"; shot s09_paste
    snd "key ctrl+c"; sleep 0.5
    # dead key — 표시가 떴다가 é 로, 에코가 없으면 표시만 사라진다
    snd "type '"; shot s10_dead_preview
    snd "type e"; shot s11_dead_e
    snd "key ctrl+c" "type stty -echo" "key Return"; sleep 0.5
    snd "type '"; shot s12_dead_preview_noecho
    snd "type e"; shot s13_dead_e_noecho
    snd "type '"; shot s14_dead_preview2
    snd "key Escape"; shot s15_dead_escape
    snd "key ctrl+c" "type stty echo" "key Return"; sleep 0.5
    # 탭
    snd "key ctrl+shift+t"; sleep 2; shot s16_newtab
    snd "key alt+1"; shot s17_alt1
    snd "key ctrl+pagedown"; shot s18_ctrl_pgdn
    snd "key ctrl+pageup"; shot s19_ctrl_pgup
    # 명령 메뉴 — ⋯ 는 창 오른쪽 위 끝 (sway 트리의 창 사각형에서 계산 · 배율 1)
    local xy
    xy=$(swaymsg -t get_tree | python3 -c '
import json, sys
def walk(n):
    if str(n.get("app_id") or "").startswith("tildaz"):
        r = n["rect"]; print(r["x"] + r["width"] - 12, r["y"] + 14); sys.exit()
    for c in n.get("nodes", []) + n.get("floating_nodes", []): walk(c)
walk(json.load(sys.stdin))')
    if [ -n "$xy" ]; then
        ptr "move $xy"; sleep 0.3; ptr "click left"; shot s20_menu_open
        ptr "move 5 900"; sleep 0.5
        snd "key Down"; shot s21_menu_down
        snd "key Down"; shot s22_menu_down2
        snd "key Escape"; shot s23_menu_esc
    else
        echo "창을 sway 트리에서 못 찾았다 — 메뉴 장면을 건너뛴다"
    fi
    # 한글 조합 — 격리 fcitx5 (hangul) 가 있을 때만
    if have_ime; then
        # 셸 명령은 영문으로 치고 (fx -c), 장면만 한글 모드 (fx -o) 로 친다.
        snd "type clear" "key Return"; sleep 0.5
        fx -o; sleep 0.5
        if [ "$(fx -n)" = hangul ]; then
            snd "type g"; shot s30_hangul_g
            snd "type k"; shot s31_hangul_gk
            snd "type s"; shot s32_hangul_gks
            snd "key right"; shot s33_hangul_right
            snd "type gk"; shot s34_hangul_gk
            snd "key Return"; shot s35_hangul_return
            fx -c; sleep 0.3; snd "type seq 1 300" "key Return"; sleep 1; fx -o; sleep 0.3
            snd "key shift+pageup"; shot s36_scrolled
            snd "type g"; shot s37_hangul_scrolled_g
            snd "key Escape"; shot s38_hangul_escape
        else
            echo "fcitx5 가 hangul 로 안 바뀌었다 ($(fx -n)) — 한글 조합 장면을 건너뛴다"
        fi
        fx -c; sleep 0.3
    fi
    snd "key ctrl+c" "type exit" "key Return"; sleep 1
    for p in $(mine tildaz); do kill -TERM $p; done; sleep 1
    tail -n +$mark $LOG > $OUT/app.log
    echo "$name: 장면 $(ls $OUT/*.png | wc -l) 개 · text_input preedit=$(grep -c 'text_input preedit' $OUT/app.log) commit=$(grep -c 'text_input commit' $OUT/app.log)"
}

cmd_ab() {
    local base=$1 fix=$2 rounds=${3:-2} r
    for r in $(seq $rounds); do
        cmd_run base$r "$base" || exit 1
        cmd_run fix$r "$fix" || exit 1
    done
    local bad=0 same=0 n=0 s f prev d
    printf '%-26s' scene; for r in $(seq $rounds); do printf ' %8s' "b$r-f$r"; done; printf ' %8s\n' prev
    for f in $WORK/fix1/*.png; do
        s=$(basename $f .png); n=$((n+1)); printf '%-26s' $s
        for r in $(seq $rounds); do
            d=$(px $WORK/base$r/$s.png $WORK/fix$r/$s.png); printf ' %8s' $d
            [ "$d" = 0 ] || bad=$((bad+1))
        done
        if [ -n "${prev:-}" ]; then
            d=$(px $WORK/fix1/$prev.png $f); printf ' %8s' $d; [ "$d" = 0 ] && same=$((same+1))
        else printf ' %8s' -; fi
        echo; prev=$s
    done
    echo "RESULT ab: 장면 $n 개 × $rounds 회 · 기준판과 다른 칸 $bad · 앞 장면과 같은 장면 (거짓 통과 의심) $same"
}

case "${1:-}" in
    up) shift; cmd_up "$@" ;;
    run) shift; [ $# = 2 ] || die "run <이름> <tildaz>"; cmd_run "$@" ;;
    ab) shift; [ $# -ge 2 ] || die "ab <기준판> <수정판> [회차]"; env_sway; cmd_ab "$@" ;;
    down) cmd_down ;;
    *) sed -n '2,25p' "$0" ;;
esac
