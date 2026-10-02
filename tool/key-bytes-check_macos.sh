#!/bin/bash
# #684 — Ctrl + 기호 · 숫자 · Space 가 PTY 로 내는 바이트를 **자동으로** 재는 macOS 몫.
# 칠 키와 기대값은 세 OS 공용 표 `tool/key-bytes-cases.tsv` 에 있다 (Linux `headless-check_linux.sh
# key-bytes` · Windows `key-bytes-check_windows.ps1` 이 같은 표를 읽는다).
#
# ```sh
# tool/key-bytes-check_macos.sh                              # /Applications/TildaZ-dev.app · legacy + mok2
# tool/key-bytes-check_macos.sh --app zig-out/TildaZ-dev.app --mode mok2
# ```
#
# 무엇을 하나 —
# 1. `--instance 9 -e <수신자>` 로 앱을 띄운다. 수신자는 모드의 enable 시퀀스를 터미널에 쓰고
#    `tool/key-bytes.py` 를 돌려 **stdout 을 파일로** 받는다 (Windows 도구와 같은 수).
#    `-e` 는 측정 인스턴스라 config 도 전역 hotkey 등록도 만들지 않는다.
# 2. `tool/input_macos.m` (`mac-input`) 으로 키를 keyCode + flags 로 하나씩 보낸다.
# 3. **키마다** 그 뒤에 새로 생긴 줄만 읽어 기대와 견준다. 순서로 맞추지 않는다 — 한 키가 예상과 달리
#    0 바이트면 뒤가 전부 밀려서, 수정 전 판의 결과를 읽을 수 없게 된다.
#
# 시스템 단축키로 켜진 조합은 **보내지 않고 SKIP** 한다 — `⌃Space` (입력 소스 전환) 를 보내면 사용자의
# 입력 소스가 바뀐다. `com.apple.symbolichotkeys` 를 읽고, 항목이 없으면 macOS 기본값을 쓴다 (60 번
# `⌃Space` 는 기본으로 켜져 있다).
#
# 전제 — `mouse-auto-check_macos.sh` · `deadkey-check_macos.sh` 와 같다.
#   - 이 스크립트를 띄운 터미널 앱에 손쉬운 사용 권한 (`mac-input check` 가 본다).
#   - 화면이 잠겨 있지 않을 것. 입력 소스는 ASCII 배열 (ABC · U.S. 등) — 한국어 입력기면 멈춘다.
#   - 에이전트 셸이면 **샌드박스 밖에서** 돌린다 (AGENTS.md 의 macOS `open` 절 — 안에서는 권한이 빠진다).
#   - 실기라서 시작 전에 알리고 동의를 받는다 — 창이 모드마다 한 번 뜨고 합성 키가 나간다.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=/Applications/TildaZ-dev.app
MODES="legacy mok2"
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --mode) MODES="$2"; shift 2 ;;
        *) echo "모르는 옵션: $1" >&2; exit 2 ;;
    esac
done
# `open -a` 는 상대 경로를 앱 *이름*으로 해석한다 — 절대 경로로 바꾼다.
APP="$(cd "$(dirname "$APP")" 2>/dev/null && pwd)/$(basename "$APP")"
[ -x "$APP/Contents/MacOS/tildaz" ] || { echo "앱 없음: $APP" >&2; exit 2; }
CASES=$ROOT/tool/key-bytes-cases.tsv
PY=$ROOT/tool/key-bytes.py

W=${TMPDIR:-/tmp}/tildaz-key-bytes
mkdir -p "$W"
MI=$W/mac-input
if [ ! -x "$MI" ] || [ "$ROOT/tool/input_macos.m" -nt "$MI" ]; then
    clang -O2 -Wno-deprecated-declarations -framework ApplicationServices -framework Carbon \
          -o "$MI" "$ROOT/tool/input_macos.m" || exit 2
fi

if [ "$(ioreg -n Root -d1 -r 2>/dev/null | grep -c CGSSessionScreenIsLocked)" != "0" ]; then
    echo "화면이 잠겨 있다 — 키가 잠금 화면으로 간다" >&2; exit 2
fi
"$MI" check || exit 2
src=$("$MI" ime-get)
case "$src" in
    com.apple.keylayout.*) ;;
    *) echo "입력 소스가 $src — ASCII 배열 (ABC 등) 로 바꾸고 다시 돌린다" >&2; exit 2 ;;
esac

# 켜진 시스템 단축키의 "keyCode flags" 목록. 항목이 없으면 기본값 (60 = ⌃Space 켜짐) 을 쓴다.
SYS_HOTKEYS=$(defaults export com.apple.symbolichotkeys - 2>/dev/null | plutil -convert json -o - - 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin).get("AppleSymbolicHotKeys", {})
except Exception:
    d = {}
if "60" not in d:
    d["60"] = {"enabled": True, "value": {"parameters": [32, 49, 262144]}}
mask = 0x20000 | 0x40000 | 0x80000 | 0x100000          # shift · ctrl · opt · cmd
for v in d.values():
    p = v.get("value", {}).get("parameters", [])
    if v.get("enabled") and len(p) == 3:
        print(p[1], p[2] & mask)
')

stop_tz() { pkill -f "tildaz --instance 9" 2>/dev/null; sleep 0.5; }
hex_since() {   # $1 파일 · $2 줄 수 — 그 뒤에 생긴 줄들의 hex 를 한 줄로
    tail -n +$(($2 + 1)) "$1" 2>/dev/null | tr -d '\r' \
        | grep -oE '^[0-9a-f]{2}( [0-9a-f]{2})*' | tr '\n' ' ' | sed 's/ *$//'
}

echo "앱: $APP · 입력 소스: $src"
fail=0
for mode in $MODES; do
    case "$mode" in
        legacy) enable='' ;;
        mok2) enable='\033[>4;2m' ;;
        *) echo "모르는 모드: $mode" >&2; exit 2 ;;
    esac
    echo "===== $mode"
    OUT=$W/received_$mode.txt; rm -f "$OUT"
    # `-e` 는 인자를 못 넘기므로 수신자를 스크립트 파일로 둔다. enable 은 터미널에 먼저 쓰고,
    # python 은 legacy (아무것도 안 켜는 모드) 로 돌려 stdout 을 파일로 받는다.
    WRAP=$W/child_$mode.sh
    printf '#!/bin/sh\nprintf '\''%s'\''\nexec python3 "%s" legacy > "%s" 2>&1\n' "$enable" "$PY" "$OUT" > "$WRAP"
    chmod +x "$WRAP"

    stop_tz
    open -n -a "$APP" --args --instance 9 -e "$WRAP" -size 60x12
    pid=""
    for _ in $(seq 40); do
        sleep 0.25
        pid=$(pgrep -f "tildaz --instance 9" | head -1)
        [ -n "$pid" ] && grep -q "^\[legacy\]" "$OUT" 2>/dev/null && break
    done
    if [ -z "$pid" ] || ! grep -q "^\[legacy\]" "$OUT" 2>/dev/null; then
        echo "❌ 앱이 뜨지 않았거나 수신자가 준비되지 않았다 — $OUT"; fail=1; stop_tz; continue
    fi
    "$MI" focus "$pid" || { echo "❌ 창을 못 잡았다"; fail=1; stop_tz; continue; }
    sleep 0.5
    "$MI" send right; sleep 0.7          # 첫 키는 창을 깨우는 데 쓰일 수 있다 — 판정에 넣지 않는다

    while IFS=$'\t' read -r m name expect key; do
        case "$m" in ''|\#*) continue ;; esac
        [ "$m" = "$mode" ] || continue
        kc=$("$MI" keycode "$key") || { echo "❌ 모르는 키: $key"; fail=1; continue; }
        if printf '%s\n' "$SYS_HOTKEYS" | grep -qx "$kc"; then
            printf 'SKIP %-14s 시스템 단축키로 켜져 있다 (%s)\n' "$name" "$key"; continue
        fi
        before=$(wc -l < "$OUT")
        "$MI" send "$key"; sleep 0.7
        got=$(hex_since "$OUT" "$before")
        want=$expect; [ "$want" = "-" ] && want=""
        if [ "$got" = "$want" ]; then mark="OK  "; else mark="FAIL"; fail=1; fi
        printf '%s %-14s 기대 [%s]  받음 [%s]\n' "$mark" "$name" "${want:-(없음)}" "${got:-(없음)}"
    done < "$CASES"
    stop_tz
    kill -0 "$pid" 2>/dev/null && echo "⚠️ 앱이 아직 떠 있다 (pid $pid)"
done
echo "결과: $([ $fail = 0 ] && echo 전부 OK || echo 기대와 다른 칸 있음)  (수신 원본: $W/received_*.txt)"
exit $fail
