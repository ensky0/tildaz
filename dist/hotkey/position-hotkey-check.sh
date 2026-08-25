#!/bin/sh
# #496 1-c — 전역 hotkey 의 **위치 표기** 가 이 데스크톱에서 실제로 등록되는지 재는 도구.
#
# 데스크톱마다 받는 것이 달라서 (자리 · 글자 · VK) 한 환경에서 통과해도 다른 환경을
# 보장하지 못한다. 그래서 어느 머신에서든 같은 절차로 돌릴 수 있게 만들어 둔다.
#
#   ./dist/hotkey/position-hotkey-check.sh                     # 기본 ctrl+[Backquote]
#   ./dist/hotkey/position-hotkey-check.sh --hotkey 'ctrl+[KeyT]'
#   ./dist/hotkey/position-hotkey-check.sh --keep              # 끝나고 안 지움 (직접 눌러 볼 때)
#
# 끝나면 만든 것을 전부 지운다 — 테스트 config · 로그 · KDE 등록.
set -eu

INSTANCE=9
HOTKEY='ctrl+[Backquote]'
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --instance) INSTANCE="$2"; shift 2 ;;
        --hotkey)   HOTKEY="$2";   shift 2 ;;
        --keep)     KEEP=1;        shift ;;
        -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "모르는 인자: $1" >&2; exit 2 ;;
    esac
done

# instance 0 은 사용자가 매일 쓰는 것이다. 그것으로 테스트하면 config 와 등록을 덮는다.
[ "$INSTANCE" = "0" ] && { echo "instance 0 으로는 테스트하지 않는다 (사용자의 일상 인스턴스)" >&2; exit 2; }

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TILDAZ=${TILDAZ:-$ROOT/zig-out/bin/tildaz}
[ -x "$TILDAZ" ] || { echo "빌드가 없다: $TILDAZ  (zig build -Doptimize=ReleaseSafe)" >&2; exit 1; }

CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/tildaz
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/tildaz
CONFIG=$CONFIG_DIR/config_$INSTANCE.toml
LOG=$STATE_DIR/tildaz_$INSTANCE.log

# ── 함정 ① — `XDG_CURRENT_DESKTOP` 이 없으면 데스크톱 경로를 통째로 건너뛴다 ──────────
# tty · ssh 셸에는 대개 비어 있고, 그러면 로그가 `de=(unset)` 이 되며 아무 데도 등록하지
# 않는다. "등록이 안 됐다" 로 오해하기 딱 좋아서 먼저 막는다.
if [ -z "${XDG_CURRENT_DESKTOP:-}" ]; then
    cat >&2 <<'MSG'
XDG_CURRENT_DESKTOP 이 비어 있다. 이대로 돌리면 어느 데스크톱 경로도 타지 않는다.
데스크톱 세션의 터미널에서 돌리거나, 그 값을 명시해서 돌린다:

    XDG_CURRENT_DESKTOP=KDE ./dist/hotkey/position-hotkey-check.sh
MSG
    exit 2
fi
DE=$XDG_CURRENT_DESKTOP

# ── 함정 ③ — `pkill -f 'instance 9'` 는 **자기 명령줄**을 매치해 셸을 죽인다 ───────────
# 그 문자열이 스크립트 명령줄에도 들어 있기 때문이다. 프로세스 이름으로 좁힌 뒤
# /proc 에서 인자를 직접 확인한다.
kill_instance() {
    for p in $(pgrep -x tildaz 2>/dev/null || true); do
        args=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)
        case "$args" in *"--instance $INSTANCE"*) kill "$p" 2>/dev/null || true ;; esac
    done
}

cleanup() {
    [ "$KEEP" = "1" ] && { echo; echo "--keep — 남겨 둔다: $CONFIG"; return; }
    kill_instance
    sleep 1
    rm -f "$CONFIG" "$LOG"
    # KDE 는 등록이 사용자 설정 파일에 남으므로 명시적으로 거둔다.
    command -v gdbus >/dev/null 2>&1 && gdbus call --session \
        --dest org.kde.kglobalaccel --object-path /kglobalaccel \
        --method org.kde.KGlobalAccel.unregister \
        "tildaz.instance$INSTANCE" "toggle-$INSTANCE" >/dev/null 2>&1 || true
    echo; echo "정리 완료 — config · 로그 · KDE 등록"
}
trap cleanup EXIT INT TERM

echo "데스크톱 : $DE"
echo "hotkey   : $HOTKEY"
echo "인스턴스 : $INSTANCE"
echo

# ── 함정 ② — config 를 만들려고 그냥 띄우면 **기본값 F1 이 instance 0 과 충돌**한다 ────
# 그 충돌 다이얼로그는 모달이라 부팅을 막고, 로그가 빈 채로 남아 원인이 안 보인다.
# 데스크톱 환경을 지운 채 한 번 띄우면 등록 경로를 안 타므로 충돌 없이 config 만 생긴다.
kill_instance; sleep 1; rm -f "$CONFIG"
echo "① 테스트 config 생성 (등록 경로를 타지 않는 환경에서)"
env -u XDG_CURRENT_DESKTOP setsid "$TILDAZ" --instance "$INSTANCE" >/dev/null 2>&1 </dev/null &
sleep 5
kill_instance; sleep 2
[ -f "$CONFIG" ] || { echo "config 가 생성되지 않았다: $CONFIG" >&2; exit 1; }

sed -i "s|^hotkey  *= .*|hotkey           = \"$HOTKEY\"|; s|^auto_start  *= .*|auto_start       = false|" "$CONFIG"
grep -E '^hotkey|^auto_start' "$CONFIG" | sed 's/^/   /'

echo
echo "② 이 데스크톱에서 기동"
: > "$LOG" 2>/dev/null || true
setsid "$TILDAZ" --instance "$INSTANCE" >/dev/null 2>&1 </dev/null &
sleep 6

echo
echo "③ 등록 결과"
grep -iE '\[(kglobalaccel|sway|hyprland|cosmic|gsettings)\]' "$LOG" 2>/dev/null | sed 's/^/   /' || true

case "$DE" in
    *KDE*|*kde*|*plasma*|*Plasma*)
        echo "   --- kglobalshortcutsrc ---"
        grep -A 2 "tildaz.instance$INSTANCE" "${XDG_CONFIG_HOME:-$HOME/.config}/kglobalshortcutsrc" 2>/dev/null | sed 's/^/   /' \
            || echo "   (항목 없음)"
        ;;
    *GNOME*|*gnome*|*ubuntu*)
        echo "   --- GSettings (GNOME) ---"
        gsettings get org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/tildaz/ binding 2>&1 | sed 's/^/   /'
        ;;
    *Cinnamon*|*cinnamon*|*X-Cinnamon*)
        echo "   --- GSettings (Cinnamon) ---"
        gsettings get org.cinnamon.desktop.keybindings.custom-keybinding:/org/cinnamon/desktop/keybindings/custom-keybindings/tildaz/ binding 2>&1 | sed 's/^/   /'
        ;;
    *Hyprland*|*hyprland*)
        echo "   --- hyprctl binds ---"
        hyprctl -j binds 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("   (파싱 실패)"); raise SystemExit
for b in d:
    if "tildaz" in (b.get("arg") or ""):
        print("   key=%r keycode=%s modmask=%s -> %s" % (b.get("key"), b.get("keycode"), b.get("modmask"), b.get("arg")))
' || echo "   (hyprctl 실패)"
        ;;
    *sway*)
        echo "   --- sway 는 IPC 로 걸고 조회 API 가 없다. 위 로그의 bindcode 줄이 근거다 ---"
        ;;
    *COSMIC*|*cosmic*)
        echo "   --- COSMIC RON ---"
        grep -n 'TildaZ_' "${XDG_CONFIG_HOME:-$HOME/.config}/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom" 2>/dev/null | sed 's/^/   /' \
            || echo "   (항목 없음 — 워커가 keymap 을 받은 뒤에 쓴다)"
        ;;
esac

cat <<'MSG'

④ 기대값
   `[Backquote]` 자리는 layout 마다 다른 글자를 낸다. 자리를 그대로 받는 데스크톱은
   숫자 49 (= evdev 41 + 8) 로, 글자만 받는 데스크톱은 그 자리가 지금 내는 글자로 등록된다.

   sway            bindcode ... Ctrl+49
   Hyprland        keycode=49, key 는 빈 값
   GNOME/Cinnamon  <Control>0x31       (0x31 = 49)
   KDE             us: Ctrl+`   fr: Ctrl+²   ru: Ctrl+Ё   de: 등록 안 됨 (dead key)
   COSMIC          key: "grave" / "twosuperior" / "Cyrillic_io" / de 는 안 씀

   layout 을 바꿔 가며 보려면 KDE 에서는 아래로 전환할 수 있다 (배열을 먼저 추가해 둔다).
   전환은 **창을 띄우지 않고** 해야 D-Bus 통지 경로가 검증된다.

     gdbus call --session --dest org.kde.keyboard --object-path /Layouts \
       --method org.kde.KeyboardLayouts.setLayout 1

   실제로 눌러 보려면 --keep 으로 남겨 두고 그 조합을 눌러 본다.
MSG
