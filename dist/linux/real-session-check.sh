#!/bin/bash
# 실제 (nested 아닌) Wayland 세션에서 돌리는 회차 둘 — #583 A5 (Hyprland 배율) · A2 / GNOME scale 소스.
#
#   dist/linux/real-session-check.sh hypr-scale [1.25 ...]   # 다른 TTY 에 뜬 실제 Hyprland 에 붙어 배율별 띠 화면 전이 행 (foot 대조 포함)
#   dist/linux/real-session-check.sh hypr-height 1.25 60 50 40   # 같은 배율 안에서 논리 높이만 바꿔 원인이 우리 산술인지 가린다 (#619 실험 ③)
#   dist/linux/real-session-check.sh no-layer-shell           # 실제 GNOME / Cinnamon (Wayland) 세션 안에서: fractional-scale 지원 통보 · 앱의 scale 소스 · #577 launcher fatal 다이얼로그
#
# hypr-scale 은 KDE 세션의 셸에서 그대로 돌릴 수 있다 — Hyprland 가 같은 uid 의 /run/user/<uid>/hypr/<sig>/ 를 만들므로
# 소켓과 서명을 거기서 읽는다. no-layer-shell 은 그 데스크톱 세션 **안**의 셸에서 돌린다 (user bus · 포털이 그 세션 것이어야 한다).
# 둘 다 tildaz 의 config · 로그는 임시 XDG 경로로 격리하고, 세션 배율은 회차가 끝나면 원래 값으로 되돌린다.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TILDAZ=${TILDAZ:-$ROOT/zig-out/bin/tildaz}
WORK=${TZRS_WORK:-${TMPDIR:-/tmp}/tildaz-real-session}
mkdir -p $WORK/xdg/config/tildaz $WORK/xdg/state/tildaz   # state/tildaz 까지 — 회차가 로그 파일을 비우려 할 때 앱이 아직 안 만들었다
die() { echo "$*" >&2; exit 1; }
[ -x "$TILDAZ" ] || die "빌드가 없다: $TILDAZ"
[ -f $WORK/xdg/config/tildaz/config_0.toml ] || sed 's|^auto_start  *= .*|auto_start       = false|; s|^width_percent *= .*|width_percent   = 100.0|; s|^height_percent *= .*|height_percent  = 60.0|' \
    ${XDG_CONFIG_HOME:-$HOME/.config}/tildaz/config_0.toml > $WORK/xdg/config/tildaz/config_0.toml
python3 "$ROOT/dist/screens/clusters.py" bands > $WORK/bands.sh && chmod +x $WORK/bands.sh

# 창 영역은 **캡처에서 찾는다** (`--locate`). 좌표를 밖에서 계산하면 안 된다 — 2026-09-04 에 Hyprland 의 타일
# 좌표를 배율로 곱해 crop 을 만들었더니 화면 밖 (`+3834` · 화면 폭 3840) 을 가리켜 전이 행 0 개가 "깨끗" 으로
# 오판됐고 회차 셋을 버렸다. 창 위치는 compositor · 타일링 · 배율 · 전체화면 여부로 다 달라진다.
measure() {   # $1 tag  $2 grim 출력 이름
    grim -o "$2" $WORK/$1.png || { echo "    grim 실패"; return; }
    python3 "$ROOT/dist/linux/bands-check.py" $WORK/$1.png --locate | sed 's/^/    /'
}

# Hyprland 0.56 의 Lua 설정 파서는 `hyprctl keyword` 를 거부한다 (`keyword can't work with non-legacy parsers. Use eval.`)
# — 그때는 `hyprctl eval 'hl.monitor({...})'` 로 같은 규칙을 넣는다. legacy (.conf) 세션은 keyword 그대로.
set_scale() {   # $1 output  $2 scale
    local r; r=$(hyprctl keyword monitor "$1,preferred,auto,$2" 2>&1)
    case "$r" in *non-legacy*|*eval*) hyprctl eval "hl.monitor({ output = \"$1\", mode = \"preferred\", position = \"auto\", scale = $2 })" >/dev/null ;; esac
}

hypr_attach() {   # 실제 Hyprland 에 붙고 MON_NAME · MON_SCALE0 · LOG 을 채운다
    # 살아 있는 인스턴스는 `hyprctl -j instances` 가 안다 — /run/user/<uid>/hypr/ 에는 죽은 세션의 서명 디렉터리가 남아
    # 있을 수 있어 그것을 고르면 안 된다. 여럿이면 가장 최근 것.
    local inst; inst=$(env -u HYPRLAND_INSTANCE_SIGNATURE hyprctl -j instances 2>/dev/null | python3 -c '
import json,sys
L=[i for i in json.load(sys.stdin) if i.get("wl_socket")]
L.sort(key=lambda i: i.get("time", 0))
print(L[-1]["instance"], L[-1]["wl_socket"]) if L else None' 2>/dev/null)
    [ -n "$inst" ] || die "실제 Hyprland 가 없다 — 다른 TTY 에서 로그인해 'Hyprland' 를 먼저 띄운다 (hyprctl -j instances 가 비어 있다)"
    local sig wl; read -r sig wl <<<"$inst"
    export HYPRLAND_INSTANCE_SIGNATURE=$sig WAYLAND_DISPLAY=$wl XDG_RUNTIME_DIR=/run/user/$(id -u) XDG_CURRENT_DESKTOP=Hyprland
    export XDG_CONFIG_HOME=$WORK/xdg/config XDG_STATE_HOME=$WORK/xdg/state
    unset SWAYSOCK
    local mon; mon=$(hyprctl -j monitors | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print(m["name"], m["width"], m["height"], m["scale"])')
    read -r MON_NAME MON_W MON_H MON_SCALE0 <<<"$mon"
    echo "Hyprland $(hyprctl version | head -1 | cut -c1-40) · 출력 $MON_NAME ${MON_W}x${MON_H} · 세션 배율 $MON_SCALE0 · socket $WAYLAND_DISPLAY"
    LOG=$XDG_STATE_HOME/tildaz/tildaz_stress.log
}

cmd_hypr_scale() {
    hypr_attach
    local name=$MON_NAME scale0=$MON_SCALE0
    for s in "$@"; do
        echo "===== scale $s"
        set_scale "$name" "$s"; sleep 3
        hyprctl -j monitors | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print("    출력 배율 →", m["scale"], "·", m["width"], "x", m["height"])'
        # ① tildaz (layer-shell dock · height 60 %)
        : > $LOG
        TILDAZ_VERBOSE=1 nohup "$TILDAZ" --instance 0 -e $WORK/bands.sh >/dev/null 2>&1 </dev/null & local pid=$!; sleep 5
        local line lw lh sc; line=$(grep -E 'layer-surface configure .*logical_w=' $LOG | tail -1)
        lw=$(sed -E 's/.*logical_w=([0-9]+).*/\1/' <<<"$line"); lh=$(sed -E 's/.*logical_h=([0-9]+).*/\1/' <<<"$line")
        sc=$(grep -E 'scale preferred=' $LOG | tail -1 | sed -E 's/.*preferred=([0-9]+)\/120.*/\1/'); [ -n "$sc" ] || sc=120
        if [ -n "$lh" ]; then
            local W H; W=$(python3 -c "print(round($lw*$sc/120))"); H=$(python3 -c "import math; print(math.floor($lh*$sc/120+0.5))")
            echo "    tildaz: logical ${lw}x${lh} scale=$sc/120 → buffer ${W}x${H} · 소수부 $(python3 -c "print(round(($lh*$sc/120)%1,3))")"
            measure tz-$s "$name"
        else echo "    tildaz: configure 로그 없음"; tail -3 $LOG; fi
        kill -TERM $pid 2>/dev/null; sleep 1
        # ② foot 대조군 — 같은 서명이 나오면 compositor 요인. 사용자 창을 건드리지 않게 (`dispatch fullscreen` 은
        #    포커스 창에 걸린다 — 첫 회차에 사용자의 kitty 가 그랬을 수 있다) 창 위치 · 크기를 `clients` 에서 읽어 crop 한다.
        foot sh $WORK/bands.sh >/dev/null 2>&1 & local fp=$!; sleep 4
        if hyprctl -j clients | grep -q '"class": "foot"'; then echo "    foot (대조군):"; measure foot-$s "$name"
        else echo "    foot 창을 clients 에서 못 찾았다"; fi
        kill $fp 2>/dev/null; sleep 1
    done
    set_scale "$name" "$scale0"; echo "세션 배율 복구 → $scale0"
}

# GNOME (mutter) · Cinnamon (muffin) — layer-shell 이 없어 다이얼로그가 #231 의 xdg_toplevel fallback 으로 가는 데스크톱.
# Cinnamon 은 **Wayland 세션** (`cinnamon-wayland.desktop`) 으로 로그인해야 한다 — 기본 세션은 X11 이라 tildaz 가 아예 안 뜬다.
cmd_no_layer_shell() {
    case "${XDG_CURRENT_DESKTOP:-}" in
        *GNOME*|*Cinnamon*|*X-Cinnamon*) ;;
        *) die "GNOME 또는 Cinnamon (Wayland) 세션 안에서 돌린다 (XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset})" ;;
    esac
    [ "${XDG_SESSION_TYPE:-}" = wayland ] || die "Wayland 세션이 아니다 (XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unset}) — Cinnamon 은 'Cinnamon (Wayland)' 로 로그인한다"
    echo "$XDG_CURRENT_DESKTOP · $(gnome-shell --version 2>/dev/null || cinnamon --version 2>/dev/null) · WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    echo "== ① fractional-scale 지원 통보 여부 (wayland-info)"
    wayland-info 2>/dev/null | grep -E "interface: '(wp_fractional_scale_manager_v1|wp_viewporter|zwlr_layer_shell_v1|wl_output)'" | sed 's/^/    /'
    echo "== ② 앱이 고른 scale 소스 (격리 config · -e 화면 5 초)"
    export XDG_CONFIG_HOME=$WORK/xdg/config XDG_STATE_HOME=$WORK/xdg/state
    local LOG=$XDG_STATE_HOME/tildaz/tildaz_stress.log; : > $LOG
    TILDAZ_VERBOSE=1 timeout 6 "$TILDAZ" --instance 0 -e $WORK/bands.sh >/dev/null 2>&1
    grep -E 'scale preferred|capabilities:|output mode|basis output' $LOG | sed -E 's/^\[[^]]+\] /    /; s/(capabilities: ).*(layer_shell=[a-z]+).*/\1\2/' | head -6
    echo "== ③ #577 — 깨진 config_9 + 인자 없는 launcher → 다이얼로그 (xdg_toplevel fallback) · 캡처"
    printf 'this is not toml [[[\n' > $XDG_CONFIG_HOME/tildaz/config_9.toml
    local L0=$XDG_STATE_HOME/tildaz/tildaz_0.log; : > $L0
    TILDAZ_VERBOSE=1 "$TILDAZ" >$WORK/launcher.out 2>&1 & local lp=$!; sleep 4
    grep -E 'fatal|dialog\] (open|configured|createDialogSurface)' $L0 | sed -E 's/^\[[^]]+\] /    /' | head -6
    # 캡처 — 포털이 유일하게 남는 자동 경로다 (GNOME 은 screencopy 미노출 · Shell D-Bus 는 AccessDenied).
    # GNOME 에서는 그 포털마저 `response=2` 로 끝났으니 (2026-09-03) 사용자가 PrtSc 로 찍어야 한다.
    # Cinnamon 은 XApp 포털 (`xdg-desktop-portal-xapp`) 이라 될 수 있다 — 되면 그대로 쓰고, 안 되면 안내만 남긴다.
    python3 "$ROOT/dist/linux/portal-screenshot.py" "$WORK/dialog.png" --timeout 90 2>&1 | sed 's/^/    /'
    if [ -f $WORK/dialog.png ]; then
        echo "    캡처: $WORK/dialog.png $(identify -format '%wx%h' $WORK/dialog.png 2>/dev/null) — 이슈에는 다이얼로그만 crop"
    else
        echo "    ⚠️ 자동 캡처 실패 — 다이얼로그를 띄워 둔 채 **사용자가 PrtSc** 로 찍는다 (아래 30 초 대기)"
        sleep 30
    fi
    kill -TERM $lp 2>/dev/null; rm -f $XDG_CONFIG_HOME/tildaz/config_9.toml
}

# #619 실험 ③ — **한 배율 안에서** 논리 높이만 바꾼다. 배율을 바꾸는 회차 (`hypr-scale`) 는 "배율이 원인" 까지만
# 말해 주고 우리 산술과 compositor 를 못 가른다. `height_percent` 를 바꾸면 배율 · compositor · 앱이 다 같은데
# **논리 높이 × 배율이 정수인지**만 달라진다 — 그 하나로 갈리면 원인은 우리가 고른 논리 크기다.
#
#   dist/linux/real-session-check.sh hypr-height 1.25 60 50 40
#
# 배율 1.25 (= 150/120 = 5/4) 면 논리 높이가 4 의 배수일 때만 물리 픽셀에 딱 맞는다. 논리 화면 1728 에서
# 60 % → 1037 (1296.25 ✗) · 50 % → 864 (1080 ✓) · 40 % → 691 (863.75 ✗).
cmd_hypr_height() {   # $1 배율  $2.. height_percent 들
    hypr_attach
    local s=$1; shift
    local name=$MON_NAME scale0=$MON_SCALE0
    set_scale "$name" "$s"; sleep 3
    hyprctl -j monitors | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print("출력 배율 →", m["scale"], "·", m["width"], "x", m["height"], "· 논리", round(m["width"]/m["scale"]), "x", round(m["height"]/m["scale"]))'
    for pct in "$@"; do
        echo "===== height_percent $pct (배율 $s)"
        sed -i "s|^height_percent *= .*|height_percent  = $pct|" $WORK/xdg/config/tildaz/config_0.toml
        : > $LOG
        TILDAZ_VERBOSE=1 nohup "$TILDAZ" --instance 0 -e $WORK/bands.sh >/dev/null 2>&1 </dev/null & local pid=$!; sleep 5
        local line lw lh sc; line=$(grep -E 'layer-surface configure .*logical_w=' $LOG | tail -1)
        lw=$(sed -E 's/.*logical_w=([0-9]+).*/\1/' <<<"$line"); lh=$(sed -E 's/.*logical_h=([0-9]+).*/\1/' <<<"$line")
        sc=$(grep -E 'scale preferred=' $LOG | tail -1 | sed -E 's/.*preferred=([0-9]+)\/120.*/\1/'); [ -n "$sc" ] || sc=120
        if [ -n "$lh" ]; then
            python3 -c "
lw, lh, sc = $lw, $lh, $sc
for tag, v in (('가로', lw), ('세로', lh)):
    px = v * sc / 120
    print(f'    논리 {tag} {v} × {sc}/120 = {px:g} px — {\"정수 ✓\" if px == int(px) else \"소수 ✗ (물리 픽셀 격자에서 벗어난다)\"}')"
            measure tz-h$pct "$name"
        else echo "    configure 로그 없음"; tail -3 $LOG; fi
        kill -TERM $pid 2>/dev/null; sleep 1
    done
    sed -i "s|^height_percent *= .*|height_percent  = 60.0|" $WORK/xdg/config/tildaz/config_0.toml
    set_scale "$name" "$scale0"; echo "세션 배율 복구 → $scale0"
}

case ${1:-} in
    hypr-scale) shift; cmd_hypr_scale "${@:-1.25}" ;;
    hypr-height) shift; cmd_hypr_height "${1:-1.25}" "${@:2}" ;;
    no-layer-shell|gnome|cinnamon) cmd_no_layer_shell ;;
    *) sed -n '2,10p' "$0"; exit 2 ;;
esac
