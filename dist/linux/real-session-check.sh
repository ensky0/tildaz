#!/bin/bash
# 실제 (nested 아닌) Wayland 세션에서 돌리는 회차 둘 — #583 A5 (Hyprland 배율) · A2 / GNOME scale 소스.
#
#   dist/linux/real-session-check.sh hypr-scale [1.25 ...]   # 다른 TTY 에 뜬 실제 Hyprland 에 붙어 배율별 띠 화면 전이 행 (foot 대조 포함)
#   dist/linux/real-session-check.sh gnome                    # 실제 GNOME 세션 안에서: fractional-scale 광고 · 앱의 scale 소스 · #577 launcher fatal 다이얼로그 캡처
#
# hypr-scale 은 KDE 세션의 셸에서 그대로 돌릴 수 있다 — Hyprland 가 같은 uid 의 /run/user/<uid>/hypr/<sig>/ 를 만들므로
# 소켓과 서명을 거기서 읽는다. gnome 은 GNOME 세션 **안**의 셸에서 돌린다 (user bus · 스크린샷 D-Bus 가 그 세션 것이어야 한다).
# 둘 다 tildaz 의 config · 로그는 임시 XDG 경로로 격리하고, 세션 배율은 회차가 끝나면 원래 값으로 되돌린다.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TILDAZ=${TILDAZ:-$ROOT/zig-out/bin/tildaz}
WORK=${TZRS_WORK:-${TMPDIR:-/tmp}/tildaz-real-session}
mkdir -p $WORK/xdg/config/tildaz $WORK/xdg/state
die() { echo "$*" >&2; exit 1; }
[ -x "$TILDAZ" ] || die "빌드가 없다: $TILDAZ"
[ -f $WORK/xdg/config/tildaz/config_0.toml ] || sed 's|^auto_start  *= .*|auto_start       = false|; s|^width_percent *= .*|width_percent   = 100.0|; s|^height_percent *= .*|height_percent  = 60.0|' \
    ${XDG_CONFIG_HOME:-$HOME/.config}/tildaz/config_0.toml > $WORK/xdg/config/tildaz/config_0.toml
python3 "$ROOT/dist/screens/clusters.py" bands > $WORK/bands.sh && chmod +x $WORK/bands.sh

measure() {   # $1 tag  $2 grim 출력 이름  $3 crop geometry (빈 문자열이면 전체)  $4 단면 x
    grim -o "$2" $WORK/$1.png || { echo "    grim 실패"; return; }
    if [ -n "$3" ]; then python3 "$ROOT/dist/linux/bands-check.py" $WORK/$1.png "$3" --x $4 --w 100 | sed 's/^/    /'
    else python3 "$ROOT/dist/linux/bands-check.py" $WORK/$1.png --x $4 --w 100 | sed 's/^/    /'; fi
}

cmd_hypr_scale() {
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
    read -r name w h scale0 <<<"$mon"
    echo "Hyprland $(hyprctl version | head -1 | cut -c1-40) · 출력 $name ${w}x${h} · 세션 배율 $scale0 · socket $WAYLAND_DISPLAY"
    local LOG=$XDG_STATE_HOME/tildaz/tildaz_stress.log
    for s in "$@"; do
        echo "===== scale $s"
        hyprctl keyword monitor "$name,preferred,auto,$s" >/dev/null; sleep 3
        hyprctl -j monitors | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print("    출력 배율 →", m["scale"], "·", m["width"], "x", m["height"])'
        # ① tildaz (layer-shell dock · height 60 %)
        : > $LOG
        TILDAZ_VERBOSE=1 nohup "$TILDAZ" --instance 0 -e $WORK/bands.sh >/dev/null 2>&1 </dev/null & local pid=$!; sleep 5
        local line lw lh sc; line=$(grep -E 'layer-surface configure .*logical_w=' $LOG | tail -1)
        lw=$(sed -E 's/.*logical_w=([0-9]+).*/\1/' <<<"$line"); lh=$(sed -E 's/.*logical_h=([0-9]+).*/\1/' <<<"$line")
        sc=$(grep -E 'scale preferred=' $LOG | tail -1 | sed -E 's/.*preferred=([0-9]+)\/120.*/\1/'); [ -n "$sc" ] || sc=120
        if [ -n "$lh" ]; then
            local W H px; W=$(python3 -c "print(round($lw*$sc/120))"); H=$(python3 -c "import math; print(math.floor($lh*$sc/120+0.5))"); px=$(python3 -c "print(round($W/2)-50)")
            echo "    tildaz: logical ${lw}x${lh} scale=$sc/120 → buffer ${W}x${H} · 소수부 $(python3 -c "print(round(($lh*$sc/120)%1,3))")"
            measure tz-$s "$name" "${W}x${H}+0+0" $px
        else echo "    tildaz: configure 로그 없음"; tail -3 $LOG; fi
        kill -TERM $pid 2>/dev/null; sleep 1
        # ② foot 대조군 (전체 화면 창) — 같은 서명이 나오면 compositor 요인
        foot sh $WORK/bands.sh >/dev/null 2>&1 & local fp=$!; sleep 1; hyprctl dispatch fullscreen 1 >/dev/null; sleep 4
        echo "    foot (대조군):"; measure foot-$s "$name" "" $(python3 -c "print(round($w/2)-50)")
        kill $fp 2>/dev/null; sleep 1
    done
    hyprctl keyword monitor "$name,preferred,auto,$scale0" >/dev/null; echo "세션 배율 복구 → $scale0"
}

cmd_gnome() {
    [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] || die "GNOME 세션 안에서 돌린다 (XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP)"
    echo "GNOME Shell $(gnome-shell --version 2>/dev/null) · WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    echo "== ① fractional-scale 광고 여부 (wayland-info)"
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
    # GNOME 의 스크린샷 D-Bus — 세션 안이라 사용자 버스가 맞다. 실패하면 gnome-screenshot.
    gdbus call --session --dest org.gnome.Shell.Screenshot --object-path /org/gnome/Shell/Screenshot \
        --method org.gnome.Shell.Screenshot.Screenshot false false "$WORK/gnome-577.png" >/dev/null 2>&1 \
        || gnome-screenshot -f $WORK/gnome-577.png 2>/dev/null || echo "    스크린샷 실패 — 손으로 (PrtSc) 찍어 $WORK/gnome-577.png 로"
    [ -f $WORK/gnome-577.png ] && echo "    캡처: $WORK/gnome-577.png $(identify -format '%wx%h' $WORK/gnome-577.png 2>/dev/null) — 다이얼로그가 보이는지 눈으로 · 이슈에는 crop 만"
    kill -TERM $lp 2>/dev/null; rm -f $XDG_CONFIG_HOME/tildaz/config_9.toml
}

case ${1:-} in
    hypr-scale) shift; cmd_hypr_scale "${@:-1.25}" ;;
    gnome) cmd_gnome ;;
    *) sed -n '2,10p' "$0"; exit 2 ;;
esac
