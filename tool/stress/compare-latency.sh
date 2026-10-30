#!/bin/sh
# 여러 터미널의 **키 → 화면 지연**을 같은 잣대로 견준다 (#756).
#
# 대상마다 창을 띄우고, 합성 키 (`a`) 를 보낸 순간부터 그 창의 그림이 처음 바뀐 프레임까지를 **앱 밖에서**
# 잰다. 앱 내부 계측과 무관해서 어느 터미널이든 같은 잣대다. 관례로는 Typometer 와 같은 방식 (캡처로 화면
# 변화를 본다) 이다.
#
#   - macOS: 그 프레임이 화면에 **표시된** 시각 (`tool/key-to-screen_macos.m` · ScreenCaptureKit).
#   - Linux (KDE Plasma): 그 프레임이 측정기에 **도착한** 시각 (`tool/key-to-screen_linux.c` · portal
#     ScreenCast). KWin 의 스크린캐스트에는 표시 시각이 없다 — 그 파일 머리 주석. 그래서 **OS 사이에
#     절대값을 견주지 않는다** (2026-10-13 사용자 결정).
#   - Windows: 그 프레임의 `LastPresentTime` — DWM 이 바탕 화면 그림을 바꾼 시각 (`tool/key-to-screen_windows.c` ·
#     DXGI Desktop Duplication). 이것도 OS 사이에 절대값을 견주지 않는다.
#
#   tool/stress/compare-latency.sh --repeat 5 --presses 30
#
# - **유휴 지연**이다 — 키를 기다리는 터미널에 키 하나를 보낸다. 출력이 쏟아지는 동안의 지연은
#   재지 않는다.
# - 대상을 띄우고 닫는 코드는 처리량 비교와 같다 (`terminals.sh`). 격자 · scrollback 도 같다.
# - **macOS 와 Linux 의 KDE Plasma · GNOME** 에서 된다. KDE 는 창 위치를 KWin 에 묻고
#   (`tool/kwin-window_linux.py`), GNOME 은 창 위치를 안 알려 줘서 (`Introspect.GetWindows` 가 `AccessDenied`)
#   측정 프로그램이 처음에 칠한 마젠타를 측정기가 캡처에서 찾는다 (`key-to-screen_linux.c` 의 `--find-marker`).
#   Windows 는 Git Bash 에서 돌린다. 터미널 안 프로그램이 셸이 아니라 네이티브 프로그램이다 (`bench-child_windows.c`).
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
#     macOS 는 ABC 로 잠깐 바꾸고 끝나면 되돌린다 (`measure-input-latency.sh` 와 같은 처리). Linux 는 fcitx5 를
#     잠깐 내리고 끝나면 되살린다 — 영문 모드여도 text-input-v3 로 키를 가로채기 때문이다 (AGENTS.md 의 fcitx5
#     함정). 되살린 fcitx5 가 KDE 배열 목록을 자기 `Default Layout` 으로 덮어쓰므로 배열이 둘 이상이면 멈춘다.
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

IS_KDE=0
IS_GNOME=0
IS_COSMIC=0
case "${XDG_CURRENT_DESKTOP:-}" in *KDE*) IS_KDE=1 ;; *GNOME*) IS_GNOME=1 ;; *COSMIC*) IS_COSMIC=1 ;; esac
# GNOME · COSMIC 은 창 위치를 KWin 스크립트 같은 길로 알려 주지 않는다 — 터미널 안 프로그램이 칠한 마젠타
# 표식으로 창 영역을 캡처에서 찾는다 (`key-to-screen_linux.c` 의 `--find-marker`).
USE_MARKER=0
{ [ "$IS_GNOME" = 1 ] || [ "$IS_COSMIC" = 1 ]; } && USE_MARKER=1
if [ "$IS_MACOS" != 1 ] && [ "$IS_WINDOWS" != 1 ] && [ "$IS_KDE" != 1 ] && [ "$USE_MARKER" != 1 ]; then
    echo "지금은 macOS · Windows 와 Linux 의 KDE Plasma · GNOME · COSMIC 만 돼요 — 다른 데스크톱의 측정기는 아직 없어요 (#756)." >&2
    exit 2
fi
if [ "$IS_MACOS" = 1 ]; then
    command -v clang >/dev/null 2>&1 || { echo "clang 없음 — Xcode Command Line Tools 가 필요해요." >&2; exit 1; }
elif [ "$IS_WINDOWS" != 1 ]; then
    pkg-config --exists libpipewire-0.3 || { echo "libpipewire-0.3 개발 헤더가 없어요." >&2; exit 1; }
    python3 -c 'import dbus, gi' 2>/dev/null || { echo "python-dbus · python-gobject 가 필요해요." >&2; exit 1; }
fi

terminals_init
RESULTS="$WORK_DIR/results"
: > "$RESULTS"

# --- 도구 빌드 (저장소에 바이너리를 두지 않는다 — `color-capture_macos.m` 과 같은 방식) ---
K2S="$WORK_DIR/key-to-screen"
LISTER="$WORK_DIR/color-capture"
MAC_INPUT="$WORK_DIR/mac-input"
if [ "$IS_WINDOWS" = 1 ]; then
    win_bench_build latency || exit 1
    K2S="$WORK_DIR/key-to-screen.exe"
elif [ "$IS_MACOS" != 1 ]; then
    # shellcheck disable=SC2046 # pkg-config 출력은 낱말로 갈라야 한다
    cc -O2 -o "$K2S" "$REPO_ROOT/tool/key-to-screen_linux.c" $(pkg-config --cflags --libs libpipewire-0.3) ||
        { echo "key-to-screen 컴파일 실패." >&2; exit 1; }
else
clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework CoreMedia \
      -framework CoreVideo -o "$K2S" "$REPO_ROOT/tool/key-to-screen_macos.m" ||
    { echo "key-to-screen 컴파일 실패." >&2; exit 1; }
clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework ImageIO \
      -framework UniformTypeIdentifiers -o "$LISTER" "$REPO_ROOT/tool/color-capture_macos.m" ||
    { echo "color-capture 컴파일 실패." >&2; exit 1; }
clang -O2 -Wno-deprecated-declarations -framework ApplicationServices -framework Carbon \
      -o "$MAC_INPUT" "$REPO_ROOT/tool/input_macos.m" ||
    { echo "mac-input 컴파일 실패." >&2; exit 1; }
fi

IME_RESTORE_ID=""
FCITX_RESTORE=0
cleanup() {
    # Windows — 남은 측정 창을 트리째 끝낸다. 회차 정리 (`run_terminal`) 가 못 끝낸 것만 남는다.
    [ "$IS_WINDOWS" = 1 ] && { "$WORK_DIR/proc-usage.exe" kill latency-child.exe \
        "alacritty.exe;wezterm-gui.exe;WindowsTerminal.exe;conhost.exe;$(win_exe_of tildaz)" >/dev/null 2>&1 || true; }
    terminals_cleanup_all || true
    [ -n "$IME_RESTORE_ID" ] && "$MAC_INPUT" ime-set "$IME_RESTORE_ID" >/dev/null 2>&1 || true
    if [ "$FCITX_RESTORE" = 1 ] && ! pgrep -x fcitx5 >/dev/null 2>&1; then
        (setsid nohup fcitx5 -d >/dev/null 2>&1 &) || true
        echo "fcitx5 를 되살렸어요."
    fi
    hygiene_end || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# CGEvent 는 권한이 없어도 성공을 반환한다 — 키를 보내는 쪽에서 미리 본다 (`input_macos.m` 머리 주석).
if [ "$IS_MACOS" = 1 ]; then
    "$MAC_INPUT" check || exit 1
elif [ "$IS_WINDOWS" != 1 ]; then
    python3 -c "import os; os.close(os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK))" 2>/dev/null ||
        { echo "/dev/uinput 을 못 열어요 (권한 · 모듈)." >&2; exit 1; }
fi

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
# 표식 회차 (GNOME) — 창 영역을 측정기가 찾도록 화면을 마젠타로 칠해 둔다. BCE (배경색 지우기) 를 안 하는
# 터미널도 칠해지게 그 색의 공백 줄도 낸다 (`compare-startup.sh` 와 같은 표식).
if [ "${TILDAZ_BENCH_MARKER:-0}" = 1 ]; then
    printf '\033[48;5;201m\033[2J\033[H'
    _j=0
    while [ "$_j" -lt "${1:-40}" ]; do printf '%*s\n' "${2:-120}" ''; _j=$((_j + 1)); done
fi
# `pid` 는 Linux 가 창을 찾는 데 쓴다 — 창 주인은 이 셸의 조상 사슬에 있다 (`tool/kwin-window_linux.py`).
printf 'cols=%s\nrows=%s\npid=%s\n' "${2:-0}" "${1:-0}" "$$" > "$TILDAZ_STRESS_TIMING_FILE"
if [ "${TILDAZ_BENCH_MARKER:-0}" = 1 ]; then
    # 측정기가 영역을 찾으면 `.go` 를 만든다. 그때 표식을 지우고 키를 받는다.
    while [ ! -e "$TILDAZ_STRESS_TIMING_FILE.go" ]; do sleep 0.05; done
    printf '\033[0m\033[2J\033[H'
fi
while IFS= read -r _line; do :; done
EOF
chmod +x "$PRODUCER"
# Windows 는 같은 일을 하는 네이티브 프로그램이다 (`win_bench_build` 가 빌드했다).
[ "$IS_WINDOWS" = 1 ] && PRODUCER="$WORK_DIR/latency-child.exe"
PRODUCER_ENV=""
[ "$USE_MARKER" = 1 ] && PRODUCER_ENV="TILDAZ_BENCH_MARKER=1"
# 표식 회차가 쓰는 화면 크기 (물리 px — `tool/gnome-screen_linux.py` · `tool/cosmic-screen_linux.py`).
SCREEN_GEO=""
if [ "$IS_GNOME" = 1 ]; then
    SCREEN_GEO=$(python3 "$REPO_ROOT/tool/gnome-screen_linux.py") || { echo "화면 크기를 GNOME 에 못 물었어요." >&2; exit 1; }
elif [ "$IS_COSMIC" = 1 ]; then
    SCREEN_GEO=$(python3 "$REPO_ROOT/tool/cosmic-screen_linux.py") || { echo "화면 크기를 COSMIC 에 못 물었어요." >&2; exit 1; }
fi

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

# Linux 회차 하나 — 창 위치를 KWin 에 묻고, portal 스트림을 열어 측정기를 돌린다. 표시 하나 (`.` · `!` · `f` (포커스를 잃어 멈춤) ·
# `?`) 를 stdout 에 내고, 그 회차의 miss 수를 `round.miss` 에 둔다. 표본은 대상의 `.samples` 에 붙인다.
#
#   measure_round_linux <터미널 안 프로그램의 pid> <대상 이름> <회차>
measure_round_linux() {
    echo "$PRESSES" > "$WORK_DIR/round.miss"
    if [ "$USE_MARKER" = 1 ]; then
        _outp=$(printf '%s' "$SCREEN_GEO" | sed -n 's/.*output=\([^ ]*\).*/\1/p')
        _out=$(python3 "$REPO_ROOT/tool/screencast-portal_linux.py" -- "$K2S" --pw-fd '{fd}' --node '{node}' \
            --find-marker --go-file "$WORK_DIR/$2.timing.go" --output "$_outp" --dpr 1 --click \
            --presses "$PRESSES" --gap-ms "$GAP_MS" 2>"$WORK_DIR/round.err" || true)
        measure_round_linux_tally "$2"
        return 0
    fi
    # 창이 KWin 목록에 올라올 때까지 (최대 5 초). `--activate` 로 앞에 올린다 — 클릭이 그 창으로 가게.
    _geo=""
    _t=0
    while [ -z "$_geo" ] && [ "$_t" -lt 20 ]; do
        _geo=$(python3 "$REPO_ROOT/tool/kwin-window_linux.py" --child-pid "$1" --activate 2>/dev/null || true)
        [ -n "$_geo" ] || { sleep 0.25; _t=$((_t + 1)); }
    done
    [ "$VERBOSE" = 1 ] && echo "  [$2] 창: ${_geo:-(없음)}" >&2
    if [ -z "$_geo" ]; then printf '?'; return 0; fi
    _rect=$(printf '%s' "$_geo" | sed -n 's/.*rect=\([^ ]*\).*/\1/p')
    _outp=$(printf '%s' "$_geo" | sed -n 's/.*output=\([^ ]*\).*/\1/p')
    _dpr=$(printf '%s' "$_geo" | sed -n 's/.*dpr=\([^ ]*\).*/\1/p')
    # 셸이 뜬 직후의 첫 그림 (프롬프트 · 격자 조정) 이 가라앉을 때까지 (macOS 판과 같은 대기).
    # 키마다 KWin 의 활성 창이 이 창인지 먼저 본다 (#826 — 아니면 키가 사용자가 쓰던 창에 들어간다).
    sleep 1
    _out=$(python3 "$REPO_ROOT/tool/screencast-portal_linux.py" -- "$K2S" --pw-fd '{fd}' --node '{node}' \
        --rect "$_rect" --output "$_outp" --dpr "$_dpr" --click \
        --focus-check "python3 '$REPO_ROOT/tool/kwin-window_linux.py' --child-pid $1 --check-active >/dev/null" \
        --presses "$PRESSES" --gap-ms "$GAP_MS" 2>"$WORK_DIR/round.err" || true)
    measure_round_linux_tally "$2"
}

# Windows 회차 하나 — 측정기가 터미널 안 프로그램의 pid 에서 본체 · 창을 찾아 잰다. 표시 · miss · 표본은 Linux 판과
# 같은 자리에 둔다. 끝나면 그 터미널을 트리째 끝낸다 — Git Bash 에는 `pkill` 이 없고 `cleanup_terminals` 는 Windows 를
# 건너뛴다.
#
#   measure_round_windows <터미널 안 프로그램의 pid> <대상 이름>
measure_round_windows() {
    echo "$PRESSES" > "$WORK_DIR/round.miss"
    _wexe=$(win_exe_of "$2")
    # 셸이 뜬 직후의 첫 그림 (프롬프트 · 격자 조정) 이 가라앉을 때까지 (macOS · Linux 판과 같은 대기).
    sleep 1
    _vflag=""
    [ "$VERBOSE" = 1 ] && _vflag=--verbose
    _out=$("$K2S" --child-pid "$1" --main "$_wexe" --click --presses "$PRESSES" --gap-ms "$GAP_MS" $_vflag \
        2>"$WORK_DIR/round.err" || true)
    [ "$VERBOSE" = 1 ] && printf '%s\n' "$_out" | grep '^window' | sed "s/^/  [$2] /" >&2
    measure_round_linux_tally "$2"
    "$WORK_DIR/proc-usage.exe" kill latency-child.exe "$_wexe" >/dev/null 2>&1 || true
}

# 측정기 출력 (`$_out` · `round.err`) 을 회차 표시 · miss · 표본으로 옮긴다.
measure_round_linux_tally() {
    [ "$VERBOSE" = 1 ] && sed 's/^/    /' "$WORK_DIR/round.err" >&2
    _m=$(printf '%s\n' "$_out" | sed -n 's/.* miss=\([0-9]*\).*/\1/p' | tail -1)
    [ -n "$_m" ] || { sed 's/^/  ⚠ /' "$WORK_DIR/round.err" >&2; printf '!'; return 0; }
    # 포커스를 잃어 키를 멈춘 회차 — 표본을 버린다 (#826).
    if printf '%s\n' "$_out" | grep -q ' focus=no'; then
        sed 's/^/  ⚠ /' "$WORK_DIR/round.err" >&2
        echo "$_m" > "$WORK_DIR/round.miss"
        printf 'f'
        return 0
    fi
    echo "$_m" > "$WORK_DIR/round.miss"
    if [ "$_m" -gt $((PRESSES / 2)) ]; then printf '!'; return 0; fi
    printf '%s\n' "$_out" | sed -n 's/^press *[0-9]* *\([0-9.]*\) ms$/\1/p' >> "$WORK_DIR/$1.samples"
    printf '.'
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
        # `.go` 도 지운다 — 앞 회차의 것이 남으면 측정 프로그램이 표식을 칠하자마자 지워 측정기가 못 찾는다
        # (#756 · 2026-10-19 COSMIC 기록 회차에서 2 회차부터 전부 놓쳤다).
        rm -f "$_timing" "$_timing.go"
        [ "$IS_MACOS" = 1 ] && "$LISTER" --list 2>/dev/null | awk 'NR > 1 { print $1 }' > "$WORK_DIR/before"
        "$@" >/dev/null 2>&1 &
        _pid=$!
        _mark=x
        _ready=0
        wait_ready "$_timing" && _ready=1
        if [ "$_ready" = 1 ] && [ "$IS_MACOS" != 1 ]; then
            _cols=$(sed -n 's/^cols=//p' "$_timing")
            _rows=$(sed -n 's/^rows=//p' "$_timing")
            if [ "$IS_WINDOWS" = 1 ]; then
                _mark=$(measure_round_windows "$(sed -n 's/^pid=//p' "$_timing")" "$_name")
            else
                _mark=$(measure_round_linux "$(sed -n 's/^pid=//p' "$_timing")" "$_name" "$_run")
            fi
            case "$_mark" in
                .) ;;
                !|f) _bad=$((_bad + 1)) ;;
            esac
            _miss=$((_miss + $(cat "$WORK_DIR/round.miss" 2>/dev/null || echo "$PRESSES")))
        elif [ "$_ready" = 1 ]; then
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
[ "$IS_MACOS" = 1 ] && HYG_REFRESH=$("$MAC_INPUT" refresh 2>/dev/null || echo "?")
echo "위생   $(hygiene_status)"

if [ "$IS_MACOS" = 1 ]; then
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
elif pgrep -x fcitx5 >/dev/null 2>&1; then
    # 되살린 fcitx5 는 KDE 의 배열 목록을 자기 `Default Layout` 하나로 덮어쓴다 (AGENTS.md). 배열이
    # 하나면 잃을 것이 없고, 둘 이상이면 사용자가 다시 추가해야 하니 멈춘다. GNOME 입력 소스도 같은 일이
    # 나는지는 확인 안 했다 — 안전한 쪽으로 같이 막는다.
    if [ "$IS_KDE" = 1 ]; then
        _layouts=$(sed -n 's/^LayoutList=//p' "${XDG_CONFIG_HOME:-$HOME/.config}/kxkbrc" 2>/dev/null | tr ',' '\n' | grep -c .)
    elif [ "$IS_COSMIC" = 1 ]; then
        # `layout: "us,kr",` — cosmic-comp 의 `xkb_config` (AGENTS.md 의 COSMIC layout 절).
        _layouts=$(sed -n 's/^ *layout: *"\([^"]*\)".*/\1/p' "${XDG_CONFIG_HOME:-$HOME/.config}/cosmic/com.system76.CosmicComp/v1/xkb_config" 2>/dev/null |
            tr ',' '\n' | grep -c .)
    else
        # `[('xkb', 'us'), ('xkb', 'fr')]` — 항목마다 `('` 가 하나다.
        _layouts=$(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null | grep -o "('" | wc -l)
    fi
    if [ "${_layouts:-0}" -gt 1 ]; then
        echo "입력 배열이 둘 이상이에요 — fcitx5 를 되살리면 목록이 지워질 수 있어서 멈춰요. fcitx5 를 직접 끄고 다시 돌려요." >&2
        exit 1
    fi
    pkill -x fcitx5 || true
    FCITX_RESTORE=1
    echo "fcitx5 를 잠깐 내렸어요 (끝나면 되살려요)."
fi
echo ""

# wt 의 scrollback 은 측정용 fragment 프로필로 준다 (`terminals.sh` — 처리량과 같다). 다른 OS 에서는 할 일이 없다.
wt_fragment_apply

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
if [ "$IS_MACOS" = 1 ]; then
    echo "단위 ms. 키를 보낸 순간 → 그 창의 그림이 처음 바뀐 프레임의 표시 시각 (ScreenCaptureKit)."
elif [ "$IS_WINDOWS" = 1 ]; then
    echo "단위 ms. 키를 보낸 순간 → 그 창의 그림이 처음 바뀐 프레임의 LastPresentTime (DXGI Desktop Duplication)."
    echo "macOS · Linux 표와 절대값을 견주지 않아요."
else
    echo "단위 ms. 키를 보낸 순간 → 그 창의 그림이 처음 바뀐 프레임이 측정기에 도착한 시각 (portal ScreenCast)."
    echo "표시 시각이 아니라서 macOS 표와 절대값을 견주지 않아요."
fi
