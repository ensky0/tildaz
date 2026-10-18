#!/bin/bash
# #760 — Shift 와 기호를 함께 적은 전역 hotkey (`ctrl+shift+]`) 가 **실제 키를 누르면** 이 데스크톱에서
# 토글되는지 잰다. 데스크톱마다 키를 맞추는 기준이 달라서 (키 자리 · 키 이름 · Shift 로 나오는 글자)
# 직접 눌러 봐야 안다 — KDE 는 `Ctrl+Shift+]` 로 등록하면 안 맞고 `Ctrl+}` 여야 했다 (2026-10-18 실측).
#
#   tool/shift-hotkey-check_linux.sh                          # 기본 — 대조군 하나 + 세 키
#   tool/shift-hotkey-check_linux.sh 'ctrl+shift+]'           # 하나만
#   VKBD_FIFO=/run/user/$UID/tzhl/vkbd.fifo tool/shift-hotkey-check_linux.sh   # nested 의 가상 키보드로 누를 때
#
# 지금 로그인한 세션에서 돌린다. 실제 데스크톱 등록을 재야 하므로 config 는 **실제 dev 폴더**에
# `config_9.toml` 하나만 두고, 끝나면 그 config · 로그 · KDE 등록 · COSMIC 항목을 지운다.
# 키는 uinput 으로 누른다 (`tool/ukbd_linux.py`). 데스크톱이 키를 안 잡으면 그 키는 **지금 포커스된
# 창**으로 간다 — `Ctrl+Shift+]` 같은 무해한 키만 쓴다. 시작 전에 사용자에게 알린다 (AGENTS.md `# 실행 환경`).
#
# 판정은 앱 로그다. 앱이 토글하면 `[toggle]`, GNOME · Cinnamon 은 확장이 창을 접으므로
# `drainSurfaceOutputs entered=[]` (worker 를 TILDAZ_VERBOSE=1 로 띄운다).
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TILDAZ=${TILDAZ:-$ROOT/zig-out/bin/tildaz}
APP=tildaz-dev            # dev 판 (#654). 릴리즈 판은 재지 않는다 — 사용자의 일상 판이다.
INSTANCE=9
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/$APP
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/$APP
CONFIG=$CONFIG_DIR/config_$INSTANCE.toml
LOG=$STATE_DIR/tildaz_$INSTANCE.log
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tz-shift.XXXXXX")
UFIFO=$XDG_RUNTIME_DIR/tz-shift-ukbd.fifo
HOTKEYS=("$@")
# 맨 앞의 `ctrl+alt+]` 는 대조군이다 — Shift 가 없어 어느 데스크톱에서든 토글돼야 한다. 이게 실패하면
# 뒤의 "반응 없음" 은 도구 · 세션 문제다 (포커스 · uinput · 등록 경로).
[ ${#HOTKEYS[@]} -gt 0 ] || HOTKEYS=('ctrl+alt+]' 'ctrl+shift+]' 'ctrl+shift+1' 'ctrl+shift+`')

die() { echo "$*" >&2; exit 1; }
[ -x "$TILDAZ" ] || die "빌드가 없다: $TILDAZ"
[ -n "${XDG_CURRENT_DESKTOP:-}" ] || die "XDG_CURRENT_DESKTOP 이 없다 — 데스크톱 세션의 터미널에서 돌린다"
[ -e "$CONFIG" ] && die "이미 있다: $CONFIG — 다른 회차가 남긴 것인지 보고 지운다"
DE=$XDG_CURRENT_DESKTOP
echo "데스크톱: $DE · 빌드: $TILDAZ"

# config 이름 → uinput 키 이름 (`tool/ukbd_linux.py` 의 표).
press_name() {
    local k=${1##*+} mods=${1%+*}
    case "$k" in
        ']') k=bracketright ;; '[') k=bracketleft ;; '`') k=grave ;;
    esac
    echo "$mods+$k"
}

# 이 판의 완전한 config 를 만든다 — 키가 빠진 config 는 시작 안내 다이얼로그를 띄우고, 그 다이얼로그가
# 키보드를 독점해 (layer-shell `exclusive`) 회차를 망친다 (2026-10-18 KDE 회차에서 겪었다).
# 격리 폴더에서 worker 를 잠깐 띄워 만들게 한다. 데스크톱 · D-Bus 를 빼서 등록은 하지 않는다.
make_template() {
    local iso=$WORK/iso; mkdir -p $iso/config $iso/state $iso/run $iso/home; chmod 700 $iso/run
    env -i PATH=$PATH HOME=$iso/home XDG_CONFIG_HOME=$iso/config XDG_STATE_HOME=$iso/state XDG_RUNTIME_DIR=$iso/run \
        WAYLAND_DISPLAY=${WAYLAND_DISPLAY:+$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY} \
        setsid "$TILDAZ" --instance $INSTANCE >/dev/null 2>&1 </dev/null &
    local pid=$! i
    for i in $(seq 20); do [ -s $iso/config/$APP/config_$INSTANCE.toml ] && break; sleep 0.3; done
    kill -TERM $pid 2>/dev/null; sleep 1; kill -KILL $pid 2>/dev/null
    [ -s $iso/config/$APP/config_$INSTANCE.toml ] || die "템플릿을 못 만들었다"
    cp $iso/config/$APP/config_$INSTANCE.toml $WORK/template.toml
}

worker_pids() {
    for p in $(pgrep -x "$(basename "$TILDAZ")"); do
        tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q -- "$TILDAZ --instance $INSTANCE" && echo $p
    done
}
stop_worker() { for p in $(worker_pids); do kill -TERM $p; done; sleep 1.5; }

press() {
    if [ -n "${VKBD_FIFO:-}" ]; then echo "key $1" > "$VKBD_FIFO"; else echo "key $1" > "$UFIFO"; fi
}

# Hyprland · COSMIC 은 launcher 쪽 동기화 (`shortcut_sync`) 가 등록한다 — worker 만 띄우면 등록이 없다.
# 그 동기화는 **모든** dev config 를 다시 맞추므로 (예: dev `config_0` 의 `F10`) 회차 전 상태를 저장했다가
# 끝나면 되돌린다. 2026-10-18 Hyprland 회차에서 저장 없이 돌려 dev `F10` 바인딩이 남았다.
# KDE · sway 는 worker 가, GNOME · Cinnamon 은 확장이 등록한다 — 동기화를 부르지 않는다.
NEEDS_SYNC=0
case "$DE" in *Hyprland*|*COSMIC*) NEEDS_SYNC=1 ;; esac
COSMIC_RON=${XDG_CONFIG_HOME:-$HOME/.config}/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom

hypr_tildaz_binds() {   # tildaz 바인딩의 description (`<명령> · <키>`) 을 한 줄씩
    hyprctl binds -j 2>/dev/null | python3 -c 'import json,sys
for b in json.load(sys.stdin):
    d=b.get("description","")
    if "tildaz" in d and " · " in d: print(d)'
}
save_desktop_state() {
    case "$DE" in
        *Hyprland*) hypr_tildaz_binds > $WORK/hypr.before ;;
        *COSMIC*) if [ -f "$COSMIC_RON" ]; then cp "$COSMIC_RON" $WORK/cosmic.before; else : > $WORK/cosmic.absent; fi ;;
    esac
}
restore_desktop_state() {
    case "$DE" in
        *Hyprland*)
            # 회차 전에 없던 tildaz 바인딩만 푼다. 키는 description 의 ` · ` 뒤다 (`shortcut_sync` 의 규칙).
            hypr_tildaz_binds | while IFS= read -r d; do
                grep -qxF -- "$d" $WORK/hypr.before 2>/dev/null && continue
                keys=${d##* · }
                hyprctl eval "hl.unbind(\"$keys\")" >/dev/null 2>&1 || hyprctl keyword unbind "$keys" >/dev/null 2>&1
            done ;;
        *COSMIC*)
            if [ -f $WORK/cosmic.before ]; then cp $WORK/cosmic.before "$COSMIC_RON"
            elif [ -f $WORK/cosmic.absent ]; then rm -f "$COSMIC_RON"; fi ;;
    esac
}

cleanup() {
    stop_worker
    rm -f "$CONFIG" "$LOG"
    [ -f $WORK/template.toml ] && restore_desktop_state
    case "$DE" in *KDE*)
        gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
            --method org.kde.KGlobalAccel.unregister "$APP.instance$INSTANCE" "toggle-$INSTANCE" >/dev/null 2>&1 ;;
    esac
    [ -p "$UFIFO" ] && echo quit > "$UFIFO"
    rm -rf "$WORK"
}
trap cleanup EXIT

make_template
save_desktop_state
if [ -z "${VKBD_FIFO:-}" ]; then
    setsid python3 "$ROOT/tool/ukbd_linux.py" --fifo "$UFIFO" >$WORK/ukbd.log 2>&1 </dev/null &
    sleep 6; grep -q ready $WORK/ukbd.log || die "uinput 장치를 못 만들었다 — $(cat $WORK/ukbd.log)"
fi

declare -A RESULT
for hk in "${HOTKEYS[@]}"; do
    stop_worker
    sed -e "s|^hotkey  *= .*|hotkey           = \"$hk\"|" -e 's|^auto_start  *= .*|auto_start       = false|' \
        -e 's|^hidden_start  *= .*|hidden_start     = false|' $WORK/template.toml > "$CONFIG"
    [ "$NEEDS_SYNC" = 1 ] && "$TILDAZ" --desktop cleanup >/dev/null 2>&1
    : > "$LOG"
    TILDAZ_VERBOSE=1 setsid "$TILDAZ" --instance $INSTANCE >/dev/null 2>&1 </dev/null &
    sleep 5
    [ -n "$(worker_pids)" ] || { RESULT[$hk]="worker 가 안 떴다"; continue; }
    grep -q "\[fatal\]\|notice shown" "$LOG" && echo "  ⚠️  $hk: 시작 안내 · fatal 로그가 있다 — 회차가 섞였을 수 있다"
    reg=$(grep -h -E "hotkey registered|bindcode|bind.*toggle|grab" "$LOG" | tail -1 | cut -c1-160)
    case "$DE" in *Hyprland*) reg=$(hypr_tildaz_binds | grep -- "--toggle $INSTANCE " | head -1) ;; esac
    mark=$(wc -l < "$LOG")
    press "$(press_name "$hk")"
    sleep 2.5
    if tail -n +$((mark+1)) "$LOG" | grep -q -E "\[toggle\]|drainSurfaceOutputs entered=\[\]"; then
        RESULT[$hk]="✅ 토글됨"
    else
        RESULT[$hk]="❌ 반응 없음"
    fi
    echo "  $hk → ${RESULT[$hk]}   (등록 로그: ${reg:-없음})"
done

echo "RESULT $DE:"
for hk in "${HOTKEYS[@]}"; do echo "  $hk  ${RESULT[$hk]}"; done
