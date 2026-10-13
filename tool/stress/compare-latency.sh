#!/bin/sh
# 여러 터미널의 **키 → 화면 지연**을 같은 잣대로 견준다 (#756).
#
# 대상마다 창을 띄우고, 합성 키 (`a`) 를 보낸 순간부터 그 창의 그림이 처음 바뀐 프레임이 화면에
# 표시된 순간까지를 **앱 밖에서** 잰다 (`tool/key-to-screen_macos.m`). 앱 내부 계측과 무관해서
# 어느 터미널이든 같은 잣대다. 관례로는 Typometer 와 같은 방식 (캡처로 화면 변화를 본다) 이다.
#
#   tool/stress/compare-latency.sh --repeat 5 --presses 30
#
# - **유휴 지연**이다 — 키를 기다리는 터미널에 키 하나를 보낸다. 출력이 쏟아지는 동안의 지연은
#   재지 않는다.
# - 대상을 띄우고 닫는 코드는 처리량 비교와 같다 (`terminals.sh`). 격자 · scrollback 도 같다.
# - **지금은 macOS 만** 된다. Linux · Windows 의 측정기는 아직 없다 (#756 의 순서 ⑤).
#
# 터미널 안에서 도는 프로그램은 아래 `latency-child.sh` 하나다. 모든 대상에서 같다.
#   1. 커서를 숨긴다 (`CSI ?25l`). **커서가 깜빡이면 그 변화를 키의 결과로 잘못 잰다** — 깜빡임
#      기본값이 터미널마다 달라서 숨겨서 맞춘다.
#   2. 격자를 timing 파일에 적는다 (`wait_for` 가 이 파일로 준비를 안다).
#   3. 키를 받기만 한다. 화면의 글자는 **tty echo** 가 그린다 — 커널의 같은 경로다.
#      `cat` 대신 셸의 `read` 로 받는 이유: 이 셸의 명령줄에 이 실행의 `WORK_DIR` 이 남아야
#      `cleanup_terminals` 가 찾아 끝낸다. Terminal.app 은 창에 프로세스가 남으면 닫기 확인 시트가
#      떠서 창이 안 닫힌다 (`terminals.sh` 의 `terminal_app_close` 주석).
#
# 판정 함정:
#   - **입력 소스가 한글이면 `a` 가 IME 로 간다.** 터미널마다 IME 처리가 달라 같은 잣대가 깨진다.
#     ABC 로 잠깐 바꾸고 끝나면 되돌린다 (`measure-input-latency.sh` 와 같은 처리).
#   - 키가 그 창에 안 닿으면 화면이 안 바뀌어 `miss` 로 드러난다. 회차의 절반 넘게 miss 면 그
#     회차를 버린다.
#   - ScreenCaptureKit 자체의 지연이 섞인다. 절대값보다 **같은 실행 안의 대상끼리** 견준다.

set -eu

REPEAT=5
PRESSES=30
GAP_MS=250
COLS=120
ROWS=40
SCROLLBACK=32767
TIMEOUT=60
IGNORE_HYGIENE=0
# `--only kitty,terminal` — 일부 대상만 돈다 (진단용). 비우면 전부.
ONLY=""
# `--verbose` — 고른 창과 같은 앱의 창 목록 (제목 · 위치) 을 찍는다 (진단용).
VERBOSE=0
# `--shots <디렉터리>` — 키를 보내기 직전 · 직후에 화면 전체를 찍는다 (진단용. 화면 기록 권한).
SHOT_DIR=""

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO_ROOT/tool/stress/hygiene.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        --repeat) REPEAT="$2"; shift 2 ;;
        --presses) PRESSES="$2"; shift 2 ;;
        --gap-ms) GAP_MS="$2"; shift 2 ;;
        --cols) COLS="$2"; shift 2 ;;
        --rows) ROWS="$2"; shift 2 ;;
        --scrollback) SCROLLBACK="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --ignore-hygiene) IGNORE_HYGIENE=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        --shots) SHOT_DIR="$2"; mkdir -p "$SHOT_DIR"; shift 2 ;;
        # Terminal.app 측정 탭의 프로필 — 비우면 사용자 기본 (`terminals.sh` 의 `TERMINAL_APP_SETTINGS`).
        --terminal-settings) TERMINAL_APP_SETTINGS="$2"; export TERMINAL_APP_SETTINGS; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

for _n in "$REPEAT" "$PRESSES" "$GAP_MS"; do
    case "$_n" in ''|*[!0-9]*|0) echo "--repeat · --presses · --gap-ms 는 1 이상의 정수여야 해요: $_n" >&2; exit 2 ;; esac
done

. "$REPO_ROOT/tool/stress/terminals.sh"

if [ "$IS_MACOS" != 1 ]; then
    echo "지금은 macOS 만 돼요 — Linux · Windows 의 키 → 화면 측정기는 아직 없어요 (#756)." >&2
    exit 2
fi
command -v clang >/dev/null 2>&1 || { echo "clang 없음 — Xcode Command Line Tools 가 필요해요." >&2; exit 1; }

terminals_init
RESULTS="$WORK_DIR/results"
: > "$RESULTS"

# --- 도구 빌드 (저장소에 바이너리를 두지 않는다 — `color-capture_macos.m` 과 같은 방식) ---
K2S="$WORK_DIR/key-to-screen"
LISTER="$WORK_DIR/color-capture"
MAC_INPUT="$WORK_DIR/mac-input"
clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework CoreMedia \
      -framework CoreVideo -o "$K2S" "$REPO_ROOT/tool/key-to-screen_macos.m" ||
    { echo "key-to-screen 컴파일 실패." >&2; exit 1; }
clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework ImageIO \
      -framework UniformTypeIdentifiers -o "$LISTER" "$REPO_ROOT/tool/color-capture_macos.m" ||
    { echo "color-capture 컴파일 실패." >&2; exit 1; }
clang -O2 -Wno-deprecated-declarations -framework ApplicationServices -framework Carbon \
      -o "$MAC_INPUT" "$REPO_ROOT/tool/input_macos.m" ||
    { echo "mac-input 컴파일 실패." >&2; exit 1; }

IME_RESTORE_ID=""
cleanup() {
    terminals_cleanup_all || true
    [ -n "$IME_RESTORE_ID" ] && "$MAC_INPUT" ime-set "$IME_RESTORE_ID" >/dev/null 2>&1 || true
    hygiene_end || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# CGEvent 는 권한이 없어도 성공을 반환한다 — 키를 보내는 쪽에서 미리 본다 (`input_macos.m` 머리 주석).
"$MAC_INPUT" check || exit 1

# --- 터미널 안에서 도는 프로그램 (머리 주석 참고) ---
PRODUCER="$WORK_DIR/latency-child.sh"
cat > "$PRODUCER" << 'EOF'
#!/bin/sh
printf '\033[?25l'
# 목표 격자가 될 때까지 (최대 5 초) 기다린다 — `compare-memory.sh` 의 같은 자리 주석 참고.
_i=0
while [ "$_i" -lt 50 ]; do
    set -- $(stty size 2>/dev/null)
    [ "${2:-0}x${1:-0}" = "$TILDAZ_STRESS_GRID" ] && break
    sleep 0.1; _i=$((_i + 1))
done
printf 'cols=%s\nrows=%s\n' "${2:-0}" "${1:-0}" > "$TILDAZ_STRESS_TIMING_FILE"
while IFS= read -r _line; do :; done
EOF
chmod +x "$PRODUCER"
PRODUCER_ENV=""

# `terminals.sh` 의 훅 — `--only` 에 없는 대상을 건너뛴다.
terminal_skip() {
    [ -n "$ONLY" ] || return 1
    case ",$ONLY," in *",$1,"*) return 1 ;; esac
    return 0
}

wait_ready() {
    _w=0
    while ! grep -q '^rows=' "$1" 2>/dev/null; do
        sleep 1
        _w=$((_w + 1))
        [ "$_w" -ge "$TIMEOUT" ] && return 1
    done
    return 0
}

# 대상 하나를 `REPEAT` 번 띄워 잰다. 회차마다 창을 새로 띄운다 — 처리량 비교와 같은 구조다.
run_terminal() {
    _name="$1"
    shift
    _timing="$WORK_DIR/$_name.timing"
    _samples="$WORK_DIR/$_name.samples"
    : > "$_samples"
    printf '%-14s ' "$_name"
    _cols=0; _rows=0; _miss=0; _bad=0
    _run=1
    while [ "$_run" -le "$REPEAT" ]; do
        rm -f "$_timing"
        "$LISTER" --list 2>/dev/null | awk 'NR > 1 { print $1 }' > "$WORK_DIR/before"
        "$@" >/dev/null 2>&1 &
        _pid=$!
        _mark=x
        if wait_ready "$_timing"; then
            _cols=$(sed -n 's/^cols=//p' "$_timing")
            _rows=$(sed -n 's/^rows=//p' "$_timing")
            # 깨운 앱의 기본 창이 측정 창을 가리지 않게 닫는다 (Terminal.app · iTerm2).
            mac_close_woken_extras "$_name"
            # 창이 목록에 올라올 때까지 (ScreenCaptureKit 은 화면에 올라온 창만 낸다).
            _wid=""
            _t=0
            while [ -z "$_wid" ] && [ "$_t" -lt 20 ]; do
                _wid=$(mac_window_of "$_name" "$LISTER" "$WORK_DIR/before" 1)
                [ -n "$_wid" ] || { sleep 0.25; _t=$((_t + 1)); }
            done
            if [ "$VERBOSE" = 1 ]; then
                echo "" >&2
                echo "  [$_name] 고른 창: ${_wid:-(없음)} · 지금 화면의 창 전부 (앞에 있는 창이 위):" >&2
                "$LISTER" --list 2>/dev/null | sed 's/^/    /' >&2
                case "$_name" in
                    iterm2) echo "    AppleScript (id · name): $(osascript -e 'tell application "iTerm" to get {id, name} of every window' 2>&1)" >&2 ;;
                    terminal) echo "    AppleScript (id · name): $(osascript -e 'tell application "Terminal" to get {id, name} of every window' 2>&1)" >&2 ;;
                esac
            fi
            if [ -z "$_wid" ]; then
                _mark='?'
            else
                # 셸이 뜬 직후의 첫 그림 (프롬프트 · 격자 조정) 이 가라앉을 때까지.
                sleep 1
                [ -n "$SHOT_DIR" ] && screencapture -x "$SHOT_DIR/$_name-$_run-before.png" 2>/dev/null || true
                _out=$("$K2S" --window "$_wid" --focus --presses "$PRESSES" --gap-ms "$GAP_MS" 2>&1 || true)
                [ -n "$SHOT_DIR" ] && screencapture -x "$SHOT_DIR/$_name-$_run-after.png" 2>/dev/null || true
                _m=$(printf '%s\n' "$_out" | sed -n 's/.* miss=\([0-9]*\).*/\1/p' | tail -1)
                [ -n "$_m" ] || _m="$PRESSES"
                _miss=$((_miss + _m))
                if [ "$_m" -gt $((PRESSES / 2)) ]; then
                    _mark='!'
                    _bad=$((_bad + 1))
                else
                    printf '%s\n' "$_out" | sed -n 's/^press *[0-9]* *\([0-9.]*\) ms$/\1/p' >> "$_samples"
                    _mark='.'
                fi
            fi
        fi
        printf '%s' "$_mark"
        kill "$_pid" 2>/dev/null || true
        # 거둬야 셸이 "Terminated: 15" 를 표 사이에 찍지 않는다.
        wait "$_pid" 2>/dev/null || true
        cleanup_terminals "$_name"
        sleep 1
        _run=$((_run + 1))
    done
    _n=$(wc -l < "$_samples" | tr -d ' ')
    printf '  %sx%s  표본 %s · miss %s\n' "$_cols" "$_rows" "$_n" "$_miss"
    printf '%s\t%s\t%s\t%s\t%s\n' "$_name" "$_cols" "$_rows" "$_miss" "$_bad" >> "$RESULTS"
}

echo "=== 터미널 키 → 화면 지연 비교 (#756) ==="
echo "키         a (keycode 0) · ${PRESSES} 번 × ${REPEAT} 회 · 간격 ${GAP_MS} ms"
echo "목표 그리드 ${COLS}x${ROWS} · scrollback ${SCROLLBACK}"
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

_ime_before=$("$MAC_INPUT" ime-get 2>/dev/null || echo "")
if "$MAC_INPUT" ime-ascii; then
    _ime_after=$("$MAC_INPUT" ime-get 2>/dev/null || echo "")
    if [ -n "$_ime_before" ] && [ "$_ime_before" != "$_ime_after" ]; then
        IME_RESTORE_ID="$_ime_before"
        echo "입력기를 영문으로 바꿨어요: $_ime_before → $_ime_after (끝나면 되돌려요)."
    fi
else
    echo "⚠ 영문 입력 소스로 못 바꿨어요 — 한글이면 재는 경로가 달라져요." >&2
fi
echo ""

terminals_launch_all

# --- 표 ---
#
# 회차의 표본을 모두 모아 낸다. 중앙값이 대표값이고, 평균 · p95 · min · max 를 함께 적는다 —
# 지연은 꼬리가 체감을 정해서 평균 하나로는 부족하다. p95 는 nearest-rank 다.
echo ""
printf '%-14s %8s %8s %8s %8s %8s %6s %10s  %s\n' terminal median mean p95 min max n grid 비고
printf '%s\n' "------------------------------------------------------------------------------------------"
while IFS="$(printf '\t')" read -r name cols rows miss bad; do
    _s="$WORK_DIR/$name.samples"
    _note=""
    [ "$bad" -gt 0 ] && _note="버린 회차 $bad (miss 가 절반 넘음)"
    [ "$cols" = "$COLS" ] && [ "$rows" = "$ROWS" ] || _note="$_note${_note:+ · }그리드 불일치"
    if [ ! -s "$_s" ]; then
        printf '%-14s %8s %8s %8s %8s %8s %6s %10s  %s\n' "$name" - - - - - 0 "${cols}x${rows}" "측정 실패${_note:+ · $_note}"
        continue
    fi
    sort -n "$_s" | awk -v name="$name" -v grid="${cols}x${rows}" -v note="$_note" '
        { v[NR] = $1; sum += $1 }
        END {
            n = NR
            med = (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
            r = int(0.95 * n); if (r < 0.95 * n) r++; if (r < 1) r = 1
            printf "%-14s %8.2f %8.2f %8.2f %8.2f %8.2f %6d %10s  %s\n", name, med, sum / n, v[r], v[1], v[n], n, grid, note
        }'
done < "$RESULTS"
echo ""
echo "단위 ms. 키를 보낸 순간 → 그 창의 그림이 처음 바뀐 프레임의 표시 시각 (ScreenCaptureKit)."
