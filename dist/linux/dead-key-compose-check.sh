#!/bin/bash
# dead-key-compose-check.sh — #494 dead key (Compose) 조합 자동 검증.
#
# headless sway 를 격리된 XDG 경로로 띄우고, tildaz 를 `--instance 9 -e <수신자>` 로 실행한 뒤
# wtype 으로 keysym 을 직접 주입한다 (layout 무관 — 가상 키보드가 자기 keymap 을 올린다).
# 판정은 PTY 로 실제 흘러간 바이트 (raw tty · 바이트 단위 기록) 와 앱 로그의 compose 줄이다.
#
#   ./dist/linux/dead-key-compose-check.sh --bin ./zig-out/bin/tildaz                     # LANG 은 현재 값
#   ./dist/linux/dead-key-compose-check.sh --bin ./zig-out/bin/tildaz --lang xx_XX.UTF-8  # 없는 locale → en_US.UTF-8 fallback
#   ./dist/linux/dead-key-compose-check.sh --bin ./zig-out/bin/tildaz --strace            # tildaz 의 write() 까지 기록
#
# 필요: sway · wtype · python3 · xxd (grim 은 있으면 스크린샷). 사용자의 세션은 건드리지 않는다 —
# headless 백엔드라 화면이 없고, XDG_RUNTIME_DIR 을 /tmp 아래로 돌려 lock · 소켓을 격리한다.
# 실행 중인 sway 세션이 있어도 죽이지 않는다 (자기 sway 는 timeout 으로 끝난다).
#
# 함정 (실측 — #494 댓글):
#   - 수신자를 bash `read -rN1` 로 두면 PTY 가 raw 여도 CR 이 LF 로 오고 0x03 이 사라진다 →
#     python `tty.setraw` + `os.read` 로 받는다.
#   - wtype 은 세션당 첫 프로세스만 유효하다 → 입력 전체를 단일 호출의 -s 타임라인에 넣는다.
#   - cat 은 파일 출력 시 버퍼링한다 → 수신자는 무버퍼로 쓴다.
#   - `-e` 인스턴스는 로그를 `tildaz_stress.log` 에 쓴다 → `*.log` 로 찾는다.
#   - text-input-v3 IME (fcitx5 등) 가 떠 있으면 키가 앱의 xkb 경로로 오지 않고 IME 가 자기 Compose 로
#     조합해 commit 한다 — 그러면 재는 것이 앱 코드가 아니다 (실기: 케이스 1~3 은 결과가 같아 구별이
#     안 되고 `^`+`x` 만 `^x` 로 갈린다). nested headless sway 에는 IME 가 없다는 것이 이 스크립트의
#     전제이고, 그 전제를 앱 로그의 `text_input preedit/commit` 줄 수 == 0 으로 판정에 넣는다.
set -uo pipefail

BIN=""
LANG_VALUE="${LANG:-C.UTF-8}"
USE_STRACE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin) BIN="$2"; shift 2 ;;
        --lang) LANG_VALUE="$2"; shift 2 ;;
        --strace) USE_STRACE=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$BIN" && -x "$BIN" ]] || { echo "--bin <tildaz 실행 파일> 이 필요해요 (예: --bin ./zig-out/bin/tildaz)" >&2; exit 2; }
BIN="$(realpath "$BIN")"
for tool in sway wtype python3 xxd; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool 이 없어요 — 설치 후 다시 실행해요" >&2; exit 2; }
done
if [[ $USE_STRACE = 1 ]] && ! command -v strace >/dev/null 2>&1; then echo "strace 가 없어요" >&2; exit 2; fi

T=/tmp/tildaz-compose-check
rm -rf "$T"
mkdir -p "$T/home" "$T/xdg" "$T/state" "$T/run"
chmod 700 "$T/run"

# ── 수신자 (python): raw 로 두고 바이트 단위로 기록. termios 플래그를 시점별로 남긴다 ──
cat > "$T/rec.sh" <<EOF
#!/bin/bash
exec python3 $T/rec.py
EOF
chmod +x "$T/rec.sh"
cat > "$T/rec.py" <<EOF
import os, termios, threading, time, tty
T = "$T"
def flags(tag):
    a = termios.tcgetattr(0)
    with open(T + "/rec.diag", "a") as d:
        d.write(f"{tag}: ICRNL={bool(a[0] & termios.ICRNL)} ISIG={bool(a[3] & termios.ISIG)} ICANON={bool(a[3] & termios.ICANON)}\\n")
with open(T + "/rec.diag", "w") as d:
    d.write(f"tty={os.ttyname(0)}\\n")
flags("before  ")
tty.setraw(0)
flags("after   ")
threading.Thread(target=lambda: (time.sleep(3), flags("t+3s    ")), daemon=True).start()
out = open(T + "/pty.bin", "wb", buffering=0)
first = True
while True:
    b = os.read(0, 1)
    if not b:
        break
    out.write(b)
    if first:
        first = False
        flags("1st-byte")
EOF

# ── 드라이버: sway 가 exec 한다 (WAYLAND_DISPLAY 상속). tildaz 를 띄우고 키를 넣고 sway 를 끝낸다 ──
STRACE_PREFIX=""
[[ $USE_STRACE = 1 ]] && STRACE_PREFIX="strace -f -e trace=write -xx -s 64 -o $T/strace.log"
cat > "$T/drive.sh" <<EOF
#!/bin/bash
set -u
exec > "$T/drive.log" 2>&1
echo "drive start: WAYLAND_DISPLAY=\${WAYLAND_DISPLAY:-} LANG=\${LANG:-}"
# XDG_CURRENT_DESKTOP 을 비워 전역 hotkey 등록 경로를 건너뛴다 (비면 어디에도 등록하지 않는다).
env -u XDG_CURRENT_DESKTOP TILDAZ_VERBOSE=1 HOME=$T/home XDG_CONFIG_HOME=$T/xdg XDG_STATE_HOME=$T/state \\
    $STRACE_PREFIX "$BIN" --instance 9 -e $T/rec.sh &
TZ_PID=\$!
sleep 4
echo "tildaz pid=\$TZ_PID alive=\$(kill -0 \$TZ_PID 2>/dev/null && echo yes || echo no)"
# 단일 wtype 타임라인 — 기대 바이트는 아래 EXPECT.
#   Ctrl+C (기준선) · ^e · ^space · ^^ · ^x (버림) · a · ^ Enter e (조합 버림) · ^ Ctrl+C e (조합 버림, 03 보존)
#   dead_grave space · dead_acute e · dead_diaeresis u · Enter
wtype -s 500 \\
  -M ctrl -k c -m ctrl -s 300 \\
  -k dead_circumflex -k e -s 300 \\
  -k dead_circumflex -k space -s 300 \\
  -k dead_circumflex -k dead_circumflex -s 300 \\
  -k dead_circumflex -k x -s 300 \\
  -k a -s 300 \\
  -k dead_circumflex -k Return -k e -s 300 \\
  -k dead_circumflex -M ctrl -k c -m ctrl -k e -s 300 \\
  -k dead_grave -k space -s 300 \\
  -k dead_acute -k e -s 300 \\
  -k dead_diaeresis -k u -s 300 \\
  -k Return
echo "wtype exit=\$?"
sleep 2
command -v grim >/dev/null 2>&1 && { grim "$T/shot.png" && echo "grim ok" || echo "grim failed"; }
sleep 1
swaymsg exit
EOF
chmod +x "$T/drive.sh"
printf 'exec %s/drive.sh\n' "$T" > "$T/sway.cfg"

echo "=== LANG=$LANG_VALUE bin=$BIN — headless sway 시작 (최대 40 s)"
env -i PATH="$PATH" HOME="$T/home" LANG="$LANG_VALUE" \
    XDG_RUNTIME_DIR="$T/run" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
    timeout 40 sway -c "$T/sway.cfg" > "$T/sway.log" 2>&1
echo "sway exit=$?"

echo "--- drive.log"; cat "$T/drive.log" 2>/dev/null
echo "--- rec.diag (PTY termios)"; cat "$T/rec.diag" 2>/dev/null || echo "(no rec.diag — 수신자가 뜨지 않았어요)"
if [[ $USE_STRACE = 1 ]]; then
    echo "--- strace: tildaz write() of key bytes"
    grep -E 'write\([0-9]+, "(\\x03|\\x0d|\\xc3|\\x5e|\\x61|\\x60|\\x65)' "$T/strace.log" 2>/dev/null | sed 's/^[0-9]* *//' | head -24
fi
echo "--- compose lines in app log"
grep -h -i 'compose\|keyboard keymap loaded' "$T"/state/tildaz/*.log 2>/dev/null || echo "(no compose line — 앱 로그가 없거나 compose 초기화 전에 끝났어요)"
echo "--- composition owner (text_input lines in app log — must be 0: an IME in the path means we did not measure tildaz)"
IME_LINES=$(grep -h 'text_input \(preedit\|commit\)' "$T"/state/tildaz/*.log 2>/dev/null | wc -l | tr -d ' ')
echo "text_input preedit/commit lines: $IME_LINES"
echo "--- PTY bytes (hex)"
GOT=$(xxd -p "$T/pty.bin" 2>/dev/null | tr -d '\n')
EXPECT="03c3aa5e5e610d65036560c3a9c3bc0d"
echo "EXPECT $EXPECT"
echo "GOT    ${GOT:-(empty)}"
if [[ "$GOT" == "$EXPECT" && "$IME_LINES" == "0" ]]; then
    echo "##### PASS #####"
    exit 0
else
    [[ "$IME_LINES" != "0" ]] && echo "an IME composed instead of tildaz (text_input lines=$IME_LINES) — this run does not measure the app path"
    echo "##### FAIL ##### (산출물: $T — drive.log · rec.diag · sway.log · pty.bin)"
    exit 1
fi
