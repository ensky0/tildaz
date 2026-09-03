#!/bin/bash
# #583 — headless sway · nested compositor 로 Linux 몫을 자동 검증하는 회차 모음 (AGENTS.md `# Linux — headless sway …` 절).
# 사용자 세션 (KWin) 을 건드리지 않는다: 격리 runtime dir · 격리 XDG config/state · 가상 키보드는 headless sway 로만 간다.
#
#   dist/linux/headless-check.sh up                  # headless sway 1600x1000 + vkbd 데몬 (한 번)
#   dist/linux/headless-check.sh tabs                # A8  — Alt+1~9 탭 전환 (탭마다 cat > tab_N.txt · 파일로 판정)
#   dist/linux/headless-check.sh confirm             # A7  — Alt+F4 확인 다이얼로그 펌프 중 SIGTERM (#521)
#   dist/linux/headless-check.sh prompt              # A7  — 새 instance 핫키 캡처 다이얼로그 펌프 중 SIGTERM (#521)
#   dist/linux/headless-check.sh scale               # A5  — 배율 1.25 · 1.5 · 2.0 · 1.7 의 띠 화면 전이 행 (#539)
#   dist/linux/headless-check.sh launcher-fatal gnome|cinnamon   # A2 — nested GNOME / Cinnamon 의 xdg_toplevel fatal 다이얼로그 (#577)
#   dist/linux/headless-check.sh down                # 앱 · vkbd · sway 정리
#
# 환경변수: TILDAZ (기본 zig-out/bin/tildaz) · TZHL_WORK (작업 디렉터리 · 기본 ${TMPDIR:-/tmp}/tildaz-headless).
# 결과는 stdout + $TZHL_WORK/<회차>/ (캡처 · 파일 · 로그). 판정 줄은 `RESULT <회차>: …` 로 시작한다.
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TILDAZ=${TILDAZ:-$ROOT/zig-out/bin/tildaz}
WORK=${TZHL_WORK:-${TMPDIR:-/tmp}/tildaz-headless}
# ⚠️ sway 의 IPC 소켓 경로는 sun_path (108 바이트) 를 넘으면 세그폴트 — runtime dir 은 짧게.
R=/run/user/$(id -u)/tzhl
FIFO=$R/vkbd.fifo
XDG=$WORK/xdg
LOG=$XDG/state/tildaz/tildaz_0.log
SLOG=$XDG/state/tildaz/tildaz_stress.log
CFG=$XDG/config/tildaz/config_0.toml

die() { echo "$*" >&2; exit 1; }
[ -x "$TILDAZ" ] || die "빌드가 없다: $TILDAZ  (zig build -Doptimize=ReleaseFast -Dsimd=true)"

env_sway() {
    export XDG_RUNTIME_DIR=$R WAYLAND_DISPLAY=wayland-1 XDG_CURRENT_DESKTOP=sway
    export XDG_CONFIG_HOME=$XDG/config XDG_STATE_HOME=$XDG/state
    SWAYSOCK=$(ls $R/sway-ipc.*.sock 2>/dev/null | head -1); export SWAYSOCK
    unset HYPRLAND_INSTANCE_SIGNATURE
    [ -S "$R/wayland-1" ] || die "headless sway 가 없다 — 먼저 'up'"
}
snd() { printf '%s\n' "$@" > $FIFO; }
# 격리 앱만 잡는다 — 사용자의 /usr/bin/tildaz instance 0 은 cmdline 이 다르다. `pkill -f` 는 자기 명령줄을 매치하니 쓰지 않는다.
tz_pids() { for p in $(pgrep -x "$(basename "$TILDAZ")" 2>/dev/null); do tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q -- "$TILDAZ" && echo $p; done; }
kill_tz() { for p in $(tz_pids); do kill -TERM $p 2>/dev/null; done; sleep 1; }
wait_exit() {   # $1 pid — 3 초 안에 끝나면 ms 를 찍는다
    for i in 1 2 3 4 5 6; do sleep 0.5; kill -0 $1 2>/dev/null || { echo "exited after ~$((i*500)) ms"; return 0; }; done
    echo "STILL ALIVE after 3 s"; return 1
}
start_worker() {   # 격리 instance 0 · 로그 verbose
    TILDAZ_VERBOSE=1 nohup "$TILDAZ" --instance 0 >/dev/null 2>&1 </dev/null &
    WPID=$!; sleep 4
    kill -0 $WPID 2>/dev/null || die "worker 가 뜨지 않았다 — $LOG"
    echo "worker pid=$WPID"
}
focus_probe() {   # 가상 키보드가 앱에 닿는지 — 파일이 생겨야 회차를 시작한다
    # vkbd 는 글자당 ~25 ms 라 긴 경로는 2 초를 넘긴다 — 파일이 생길 때까지 최대 8 초 기다린다 (2 초로 잡아 거짓 실패한 적 있다).
    rm -f $WORK/probe; snd "type touch $WORK/probe" "key Return"
    for i in $(seq 16); do sleep 0.5; [ -f $WORK/probe ] && return 0; done
    die "가상 키보드가 앱에 닿지 않는다 (probe 파일 없음) — $WORK/vkbd.log · 포커스를 확인"
}

cmd_up() {
    mkdir -m 700 -p $R; mkdir -p $WORK $XDG/config/tildaz $XDG/state
    [ -f "$CFG" ] || {
        src=${XDG_CONFIG_HOME:-$HOME/.config}/tildaz/config_0.toml
        [ -f "$src" ] || die "복사할 config_0.toml 이 없다: $src"
        sed 's|^auto_start  *= .*|auto_start       = false|' "$src" > "$CFG"
        echo "config: $CFG (auto_start=false · 나머지는 사용자 config_0 그대로)"
    }
    if [ ! -S $R/wayland-1 ]; then
        printf 'output HEADLESS-1 resolution 1600x1000\ndefault_border none\nfocus_follows_mouse no\n' > $WORK/sway.conf
        env -u XDG_CURRENT_DESKTOP -u HYPRLAND_INSTANCE_SIGNATURE -u SWAYSOCK XDG_RUNTIME_DIR=$R \
            WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 setsid nohup timeout 14400 sway -c $WORK/sway.conf >$WORK/sway.log 2>&1 </dev/null &
        sleep 2
        [ -S $R/wayland-1 ] || die "sway 가 뜨지 않았다 — $WORK/sway.log"
        echo "sway: headless 1600x1000 · $R/wayland-1 (timeout 4 h)"
    fi
    env_sway
    if ! pgrep -f "vkbd.py --fifo $FIFO" >/dev/null; then
        rm -f $FIFO
        setsid nohup python3 "$ROOT/dist/linux/vkbd.py" --fifo $FIFO >$WORK/vkbd.log 2>&1 </dev/null &
        sleep 1.5; head -1 $WORK/vkbd.log
    fi
    echo "환경: XDG_RUNTIME_DIR=$R WAYLAND_DISPLAY=wayland-1 XDG_CONFIG_HOME=$XDG/config"
}

cmd_down() {
    env_sway 2>/dev/null || true
    kill_tz
    [ -p $FIFO ] && echo quit > $FIFO
    pkill -f "vkbd.py --fifo $FIFO" 2>/dev/null
    [ -n "${SWAYSOCK:-}" ] && swaymsg exit >/dev/null 2>&1
    sleep 1; rm -rf $R
    echo "남은 tildaz: $(pgrep -a tildaz | tr '\n' ';')"
}

cmd_tabs() {
    env_sway; OUT=$WORK/tabs; rm -rf $OUT; mkdir -p $OUT
    kill_tz; start_worker; focus_probe
    snd "type cat > $OUT/tab_1.txt" "key Return"; sleep 2
    for n in 2 3 4 5 6 7 8 9; do
        snd "key ctrl+shift+t"; sleep 2.5
        snd "type cat > $OUT/tab_$n.txt" "key Return"; sleep 2
    done
    grim $OUT/tabs9.png
    for n in 1 5 9 3 7 2 8 4 6; do
        snd "key alt+$n"; sleep 1
        snd "type T$n" "key Return"; sleep 1
    done
    ok=0; bad=0
    for n in 1 2 3 4 5 6 7 8 9; do
        got=$(tr '\n' '|' < $OUT/tab_$n.txt 2>/dev/null)
        if [ "$got" = "T$n|" ]; then ok=$((ok+1)); else echo "tab $n: FAIL (got '$got')"; bad=$((bad+1)); fi
    done
    echo "RESULT tabs: ok=$ok bad=$bad (Alt+1~9 → 각 탭의 cat 에 T<n> 이 들어갔는지)"
    kill -TERM $WPID; wait_exit $WPID >/dev/null
}

cmd_confirm() {
    env_sway; OUT=$WORK/confirm; rm -rf $OUT; mkdir -p $OUT
    kill_tz; start_worker; focus_probe
    mark=$(wc -l < $LOG)
    snd "key alt+F4"; sleep 2
    grim $OUT/confirm.png
    tail -n +$((mark+1)) $LOG | grep -E '\[dialog\] open confirm' || echo "confirm 다이얼로그 로그 없음"
    kill -TERM $WPID; r=$(wait_exit $WPID)
    if tail -n +$((mark+1)) $LOG | grep -q 'SIGTERM received while a dialog pump was running'; then
        echo "RESULT confirm: OK — 펌프에서 SIGTERM 으로 빠짐 · $r"
    else
        echo "RESULT confirm: FAIL — 'leaving the pump' 로그 없음 · $r"; tail -n +$((mark+1)) $LOG | tail -6
    fi
}

cmd_prompt() {
    env_sway; OUT=$WORK/prompt; rm -rf $OUT; mkdir -p $OUT
    kill_tz; start_worker
    mark=$(wc -l < $LOG)
    "$TILDAZ" >$OUT/launcher.out 2>&1; echo "launcher exit=$?"     # worker 0 이 떠 있으면 new-instance 요청이 간다
    sleep 3; grim $OUT/prompt.png
    tail -n +$((mark+1)) $LOG | grep -E '\[dialog\] open prompt' || echo "prompt 다이얼로그 로그 없음"
    kill -TERM $WPID; r=$(wait_exit $WPID)
    if tail -n +$((mark+1)) $LOG | grep -q 'SIGTERM received while a dialog pump was running'; then
        echo "RESULT prompt: OK — 펌프에서 SIGTERM 으로 빠짐 · $r"
    else
        echo "RESULT prompt: FAIL — 'leaving the pump' 로그 없음 · $r"; tail -n +$((mark+1)) $LOG | tail -6
    fi
}

scale_case() {   # $1 scale  $2 출력 WxH (scale 로 나눠지는 값)  $3 논리 높이 H  $4 tag — 창은 floating 800xH (논리)
    local s=$1 res=$2 H=$3 tag=$4
    # ⚠️ 출력 물리 해상도는 scale 로 정확히 나눠져야 한다 — 아니면 sway 가 출력 논리 크기를 내림하고 프레임 전체를 늘려
    # 그려 **모든 client** 가 리샘플된다 (foot 도 같았다 · 2026-09-03). 1.5 → 1500x999 · 1.7 → 1700x1020.
    swaymsg output HEADLESS-1 resolution ${res%x*} ${res#*x} scale $s >/dev/null; sleep 1
    : > $SLOG
    TILDAZ_VERBOSE=1 nohup "$TILDAZ" --instance 0 -e $WORK/bands.sh >/dev/null 2>&1 </dev/null &
    local pid=$! i
    for i in $(seq 20); do swaymsg -t get_tree | grep -q '"app_id": "tildaz' && break; sleep 0.3; done
    sleep 0.5    # 앱 자신의 `move position 50 ppt` IPC 뒤에 우리 배치가 와야 한다
    # ⚠️ tiling 컨테이너는 논리 높이가 소수 (1000/1.5 = 666.67) 라 sway 가 창을 그 크기에 맞춰 **늘린다** — 우리 buffer 가
    # 스펙대로여도 리샘플이 난다. floating 으로 정수 논리 크기를 주면 목적지 = round(H × scale) 이라 검증이 성립한다.
    # `-e` 측정 인스턴스의 app_id 는 `tildaz.instance0` 이 아니다 (역할별 이름) — 접두어로 잡는다.
    swaymsg "[app_id=\"^tildaz\"] floating enable, resize set width 800 px height $H px, move position 0 px 0 px" > $OUT/$tag.sway 2>&1
    sleep 4
    grim $OUT/$tag.png
    local rect; rect=$(swaymsg -t get_tree | python3 -c '
import json,sys
def walk(n):
    if str(n.get("app_id") or "").startswith("tildaz"): print(n["rect"]["x"], n["rect"]["y"], n["rect"]["width"], n["rect"]["height"]); return True
    return any(walk(c) for c in n.get("nodes",[])+n.get("floating_nodes",[]))
walk(json.load(sys.stdin))')
    kill -TERM $pid 2>/dev/null
    [ -n "$rect" ] || { echo "--- [$tag] scale=$s output=$res H=$H · 앱 창이 없다 ($SLOG)"; sleep 1; return; }
    local scl; scl=$(grep -E 'scale preferred' $SLOG | tail -1 | sed -E 's/.*preferred=([0-9]+)\/120.*/\1/')
    read rx ry rw rh <<<"$rect"
    [ "$rh" = "$H" ] || echo "    ⚠️ floating 크기가 요청과 다르다 (rect ${rw}x${rh}) — $(tr -d '\n ' < $OUT/$tag.sway | head -c 120)"
    local info px
    info=$(python3 -c "
import math; s=$scl/120; h=$rh
v=h*s; ra=math.floor(v+0.5)
print(f'logical {$rw}x{h} × {s:.4f} = {v:.2f} → buffer 반올림 {ra} / 내림 {int(v)} · 소수부 {round(v%1,3)}')")
    px=$(python3 -c "print(round(($rx + $rw/2) * $scl/120) - 50)")
    echo "--- [$tag] scale=$s output=$res H=$H · $info"
    python3 "$ROOT/dist/linux/bands-check.py" $OUT/$tag.png --x $px --w 100 | sed 's/^/    /'
    sleep 1
}

cmd_scale() {
    env_sway; OUT=$WORK/scale; rm -rf $OUT; mkdir -p $OUT $XDG/state/tildaz
    kill_tz
    python3 "$ROOT/dist/screens/clusters.py" bands > $WORK/bands.sh && chmod +x $WORK/bands.sh
    # 논리 높이 H 를 골라 H × scale 의 소수부가 .5 이상인 회차 (내림과 반올림이 갈리는 곳) 와 0 인 대조 회차를 나란히 둔다.
    scale_case 1.25 1600x1000 800 a-125-h800    # 1000.0 · 대조
    scale_case 1.25 1600x1000 798 b-125-h798    # 997.5  → 반올림 998 / 내림 997
    scale_case 1.25 1600x1000 799 c-125-h799    # 998.75 → 999 / 998
    scale_case 1.5  1500x999  666 d-150-h666    # 999.0  · 대조
    scale_case 1.5  1500x999  665 e-150-h665    # 997.5  → 998 / 997
    scale_case 2.0  1600x1000 500 f-200-h500    # 1000 · 정수 배율
    scale_case 1.7  1700x1020 600 g-170-h600    # 1020.0 · 대조
    scale_case 1.7  1700x1020 588 h-170-h588    # 999.6  → 1000 / 999
    scale_case 1.7  1700x1020 585 i-170-h585    # 994.5  → 995 / 994 (#539 의 .5 꼴)
    scale_case 1.7  1700x1020 587 j-170-h587    # 997.9  → 998 / 997
    swaymsg output HEADLESS-1 resolution 1600 1000 scale 1 >/dev/null
    echo "RESULT scale: 위 회차의 '판정:' 줄이 전부 '리샘플 없음' 이어야 한다 (⚠️ 줄이 있으면 그 회차는 무효)"
}

cmd_launcher_fatal() {   # $1 gnome|cinnamon — 실제 runtime dir (mutter devkit 은 pipewire 가 필요해 격리 불가) · 자기 세션 버스
    local de=$1 XCD COMP WD=wayland-77
    case $de in
        gnome)    XCD=GNOME;      COMP=(gnome-shell --devkit --wayland --wayland-display=$WD) ;;
        cinnamon) XCD=X-Cinnamon; COMP=(cinnamon --nested --wayland) ;;
        *) die "launcher-fatal gnome|cinnamon" ;;
    esac
    OUT=$WORK/launcher-fatal-$de; rm -rf $OUT; mkdir -p $OUT $WORK/xdg-$de/config/tildaz $WORK/xdg-$de/state
    printf 'this is not toml [[[\n' > $WORK/xdg-$de/config/tildaz/config_9.toml      # launcher 단독 실패 (#577)
    # spectacle 은 사용자 세션 버스로 KWin 과 말하므로 dbus-run-session 안에서는 실패 — 바깥에서 타이머로 찍는다.
    # (전체 화면이라 사용자의 다른 창이 담긴다 — 이슈에는 nested 창만 crop. mutter devkit 뷰어는 검게 나올 수 있다 — 2026-09-03 실측.)
    ( sleep 14; spectacle -b -n -f -o $OUT/full.png >/dev/null 2>&1 && echo "spectacle: $OUT/full.png" ) &
    env -u SWAYSOCK -u HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=$XCD \
        TZ_BIN="$TILDAZ" TZ_CFG=$WORK/xdg-$de/config TZ_STATE=$WORK/xdg-$de/state \
        dbus-run-session -- bash -c '
        set -u
        OUT=$1; WD=$2; DE=$3; shift 3
        "$@" >$OUT/comp.log 2>&1 &
        CPID=$!; sleep 9
        kill -0 $CPID 2>/dev/null || { echo "compositor died:"; tail -5 $OUT/comp.log; exit 1; }
        if [ "$DE" = cinnamon ]; then
            # muffin 은 어느 wayland-N 을 잡았는지 로그에 안 남기고 (AGENTS.md), 기존 소켓 파일을 재사용하기도 해서 목록
            # 비교로는 못 찾는다 — LISTEN 소켓의 소유 pid 로 찾는다.
            WD=$(ss -xlp 2>/dev/null | grep "pid=$CPID," | grep -oE "wayland-[0-9]+" | head -1)
            [ -n "$WD" ] || { echo "RESULT launcher-fatal $DE: FAIL — cinnamon 의 wayland 소켓을 찾지 못했다"; kill $CPID; exit 1; }
        fi
        echo "compositor pid=$CPID · WAYLAND_DISPLAY=$WD"
        WAYLAND_DISPLAY=$WD XDG_CONFIG_HOME=$TZ_CFG XDG_STATE_HOME=$TZ_STATE TILDAZ_VERBOSE=1 "$TZ_BIN" >$OUT/launcher.out 2>&1 &
        LPID=$!; sleep 6
        LOG=$TZ_STATE/tildaz/tildaz_0.log
        if kill -0 $LPID 2>/dev/null && grep -q "\[dialog\] configured logical=" $LOG; then
            echo "RESULT launcher-fatal $DE: OK — $(grep -E "layer_shell=(true|false)" $LOG | sed -E "s/.*(layer_shell=[a-z]+).*/\1/" | tail -1) · $(grep "\[dialog\] configured" $LOG | tail -1 | sed -E "s/.*(logical=[0-9x]+ physical=[0-9x]+).*/\1/")"
        else
            echo "RESULT launcher-fatal $DE: FAIL — 다이얼로그 configure 로그 없음 (launcher alive=$(kill -0 $LPID 2>/dev/null && echo yes || echo no))"; tail -4 $LOG
        fi
        kill -TERM $LPID 2>/dev/null
        for i in 1 2 3 4 5 6; do sleep 0.5; kill -0 $LPID 2>/dev/null || { echo "launcher exited after ~$((i*500)) ms (fatal 펌프의 SIGTERM · #521)"; break; }; done
        grep -q "leaving the pump" $LOG && echo "  leaving the pump: yes"
        kill -TERM $CPID; sleep 2; kill -0 $CPID 2>/dev/null && kill -KILL $CPID
    ' _ $OUT $WD $de "${COMP[@]}"
    wait
}

case ${1:-} in
    up) cmd_up ;;
    down) cmd_down ;;
    tabs) cmd_tabs ;;
    confirm) cmd_confirm ;;
    prompt) cmd_prompt ;;
    scale) cmd_scale ;;
    launcher-fatal) cmd_launcher_fatal "${2:-}" ;;
    *) sed -n '2,16p' "$0"; exit 2 ;;
esac
