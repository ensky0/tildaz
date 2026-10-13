#!/bin/sh
# 여러 터미널의 **시작 시간** — 실행부터 그 안의 프로그램이 그린 표식이 화면에 처음 보일 때까지 (#756).
#
#   tool/stress/compare-startup.sh --repeat 5
#
# - 앱은 **LaunchServices (`open`)** 로 띄운다 — 사용자가 Dock · Spotlight 로 여는 길이다
#   (`terminals.sh` 의 `terminals_open_all`). 각 앱의 기본 설정으로 연다.
# - 터미널 안 프로그램은 화면을 마젠타 (256 색 201 번) 로 칠한다. `tool/startup-to-screen_macos.m` 이 명령을
#   스스로 띄우고, 화면 전체 캡처에서 마젠타가 처음 보인 프레임까지를 잰다. 그 도구 머리 주석 참고.
# - **warm** 이다 — 회차마다 앱을 완전히 종료하고 다시 띄운다. 디스크 캐시는 데워진 상태다 (cold 는
#   `sudo purge` 가 필요하고 값이 크게 흔들려서 재지 않는다 — 2026-10-13 사용자 결정).
# - TildaZ 의 "단축키 → 창 표시" 는 이것과 별도다 (TildaZ 는 보통 떠 있다가 내려온다).
# - **지금은 macOS 만** 된다.

set -eu

REPEAT=5
TIMEOUT_MS=10000
IGNORE_HYGIENE=0
ONLY=""
# 표식 판정 넓이 (point²). 120x30 창이 40 만 남짓이라 그 2.5 % 쯤이다.
MIN_PIXELS=10000
COLS=120
ROWS=40
SCROLLBACK=32767

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO_ROOT/tool/stress/hygiene.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        --repeat) REPEAT="$2"; shift 2 ;;
        --timeout-ms) TIMEOUT_MS="$2"; shift 2 ;;
        --min-pixels) MIN_PIXELS="$2"; shift 2 ;;
        --ignore-hygiene) IGNORE_HYGIENE=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$REPEAT" in ''|*[!0-9]*|0) echo "--repeat 은 1 이상의 정수여야 해요: $REPEAT" >&2; exit 2 ;; esac

. "$REPO_ROOT/tool/stress/terminals.sh"

if [ "$IS_MACOS" != 1 ]; then
    echo "지금은 macOS 만 돼요 — Linux · Windows 의 시작 시간 측정은 아직 없어요 (#756)." >&2
    exit 2
fi
command -v clang >/dev/null 2>&1 || { echo "clang 없음 — Xcode Command Line Tools 가 필요해요." >&2; exit 1; }

terminals_init
RESULTS="$WORK_DIR/results"
: > "$RESULTS"

S2S="$WORK_DIR/startup-to-screen"
PROC_USAGE="$WORK_DIR/proc-usage"
MAC_INPUT="$WORK_DIR/mac-input"
clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
      -o "$S2S" "$REPO_ROOT/tool/startup-to-screen_macos.m" || { echo "startup-to-screen 컴파일 실패." >&2; exit 1; }
clang -O2 -o "$PROC_USAGE" "$REPO_ROOT/tool/proc-usage_macos.c" || { echo "proc-usage 컴파일 실패." >&2; exit 1; }
clang -O2 -Wno-deprecated-declarations -framework ApplicationServices -framework Carbon \
      -o "$MAC_INPUT" "$REPO_ROOT/tool/input_macos.m" || { echo "mac-input 컴파일 실패." >&2; exit 1; }

cleanup() {
    terminals_cleanup_all || true
    hygiene_end || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# 화면을 마젠타로 칠하고 가만히 있는다. BCE (배경색 지우기) 를 안 하는 터미널도 칠해지게 공백 줄도 낸다.
PRODUCER="$WORK_DIR/startup-child.sh"
cat > "$PRODUCER" << 'EOF'
#!/bin/sh
printf '\033[?25l\033[48;5;201m\033[2J\033[H'
_i=0
while [ "$_i" -lt 60 ]; do printf '%240s\n' ''; _i=$((_i + 1)); done
while :; do sleep 60; done
EOF
chmod +x "$PRODUCER"

terminal_skip() {
    [ -n "$ONLY" ] || return 1
    case ",$ONLY," in *",$1,"*) return 1 ;; esac
    return 0
}

# 회차가 끝나면 그 대상을 **완전히** 내린다 — 다음 회차가 새 프로세스로 뜨게.
stop_target() {
    _st_name="$1"
    cleanup_terminals "$_st_name"
    case "$_st_name" in
        terminal|iterm2)
            mac_app_quit_woken || true
            ;;
        *)
            _st_pid=$("$PROC_USAGE" find "$(mac_proc_path_of "$_st_name")" "$WORK_DIR/before" 2>/dev/null || true)
            if [ -n "$_st_pid" ]; then
                kill "$_st_pid" 2>/dev/null || true
                _q=0
                while kill -0 "$_st_pid" 2>/dev/null && [ "$_q" -lt 20 ]; do sleep 0.25; _q=$((_q + 1)); done
                kill -9 "$_st_pid" 2>/dev/null || true
            fi
            ;;
    esac
}

run_terminal() {
    _name="$1"
    shift
    _samples="$WORK_DIR/$_name.samples"
    : > "$_samples"
    printf '%-14s ' "$_name"
    _run=1
    while [ "$_run" -le "$REPEAT" ]; do
        ps -axo pid= > "$WORK_DIR/before"
        _out=$("$S2S" --timeout-ms "$TIMEOUT_MS" --min-pixels "$MIN_PIXELS" -- "$@" 2>&1 || true)
        _ms=$(printf '%s\n' "$_out" | sed -n 's/^startup_ms=\([0-9.]*\)$/\1/p')
        if [ -n "$_ms" ]; then
            echo "$_ms" >> "$_samples"
            printf '.'
        else
            printf 'x'
            printf '%s\n' "$_out" | sed 's/^/    /' >&2
        fi
        sleep 1
        stop_target "$_name"
        sleep 2
        _run=$((_run + 1))
    done
    printf '\n'
    echo "$_name" >> "$RESULTS"
}

echo "=== 터미널 시작 시간 비교 (#756) ==="
echo "회차       ${REPEAT} 회 (warm · 회차마다 앱 종료) · 실행 경로 LaunchServices (open)"
echo ""
hygiene_check || {
    [ "$IGNORE_HYGIENE" = 1 ] || {
        echo "측정 위생 점검에 걸렸어요. 고치거나 --ignore-hygiene 로 강행해요." >&2
        exit 1
    }
}
hygiene_begin
HYG_REFRESH=$("$MAC_INPUT" refresh 2>/dev/null || echo "?")
echo "위생   $(hygiene_status)"
echo ""

terminals_open_all

echo ""
printf '%-14s %8s %8s %8s %8s %6s\n' terminal median mean min max n
printf '%s\n' "------------------------------------------------------------"
while read -r name; do
    _s="$WORK_DIR/$name.samples"
    if [ ! -s "$_s" ]; then
        printf '%-14s %8s %8s %8s %8s %6s  %s\n' "$name" - - - - 0 "측정 실패"
        continue
    fi
    sort -n "$_s" | awk -v name="$name" '
        { v[NR] = $1; sum += $1 }
        END {
            n = NR
            med = (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
            printf "%-14s %8.1f %8.1f %8.1f %8.1f %6d\n", name, med, sum / n, v[1], v[n], n
        }'
done < "$RESULTS"
echo ""
echo "단위 ms. 실행 (open) → 터미널 안 프로그램이 칠한 마젠타가 화면에 처음 보인 프레임의 표시 시각."
