#!/bin/sh
# 여러 터미널의 **시작 시간** — 실행부터 그 안의 프로그램이 그린 표식이 화면에 처음 보일 때까지 (#756).
#
#   tool/stress/compare-startup.sh --repeat 5
#
# - 앱은 **사용자가 여는 길**로 띄운다 (`terminals.sh` 의 `terminals_open_all`). macOS 는 LaunchServices
#   (`open`, Dock · Spotlight 와 같은 길), Linux 는 앱의 `.desktop` 을 그 DE 의 런처로 (KDE `kioclient exec` ·
#   GNOME `gio launch`, 메뉴 · 런처와 같은 길 — 2026-10-13 사용자 결정). 각 앱의 기본 설정으로 연다.
# - 터미널 안 프로그램은 화면을 마젠타 (256 색 201 번) 로 칠한다. `tool/startup-to-screen_macos.m` 이 명령을
#   스스로 띄우고, 화면 전체 캡처에서 마젠타가 처음 보인 프레임까지를 잰다. 그 도구 머리 주석 참고.
# - **warm** 이다 — 회차마다 앱을 완전히 종료하고 다시 띄운다. 디스크 캐시는 데워진 상태다 (cold 는
#   `sudo purge` 가 필요하고 값이 크게 흔들려서 재지 않는다 — 2026-10-13 사용자 결정).
# - TildaZ 의 "단축키 → 창 표시" 는 이것과 별도다 (TildaZ 는 보통 떠 있다가 내려온다).
# - **macOS · Windows 와 Linux 의 KDE Plasma · GNOME** 에서 된다. Linux 는 화면 캡처가 portal ScreenCast 라 프레임의 **도착**
#   시각을 쓴다 (`tool/startup-to-screen_linux.c` 머리 주석) — OS 사이에 절대값을 견주지 않는다. Windows 는 `ShellExecuteEx`
#   (시작 메뉴 · 탐색기가 여는 길) 로 띄우고 프레임의 `LastPresentTime` 을 쓴다 (`tool/startup-to-screen_windows.c`).

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

IS_KDE=0
IS_GNOME=0
IS_COSMIC=0
case "${XDG_CURRENT_DESKTOP:-}" in *KDE*) IS_KDE=1 ;; *GNOME*) IS_GNOME=1 ;; *COSMIC*) IS_COSMIC=1 ;; esac
if [ "$IS_MACOS" != 1 ] && [ "$IS_WINDOWS" != 1 ] && [ "$IS_KDE" != 1 ] && [ "$IS_GNOME" != 1 ] && [ "$IS_COSMIC" != 1 ]; then
    echo "지금은 macOS · Windows 와 Linux 의 KDE Plasma · GNOME · COSMIC 만 돼요 — 다른 데스크톱의 측정기는 아직 없어요 (#756)." >&2
    exit 2
fi
# Windows 의 표식 판정 넓이는 물리 px 다 — macOS 의 10,000 point² 를 150 % 화면으로 옮긴 값 (= 22,500 px²) 이 기본이다.
[ "$IS_WINDOWS" = 1 ] && [ "$MIN_PIXELS" = 10000 ] && MIN_PIXELS=22500
if [ "$IS_MACOS" = 1 ]; then
    command -v clang >/dev/null 2>&1 || { echo "clang 없음 — Xcode Command Line Tools 가 필요해요." >&2; exit 1; }
elif [ "$IS_WINDOWS" != 1 ]; then
    pkg-config --exists libpipewire-0.3 || { echo "libpipewire-0.3 개발 헤더가 없어요." >&2; exit 1; }
    python3 -c 'import dbus, gi' 2>/dev/null || { echo "python-dbus · python-gobject 가 필요해요." >&2; exit 1; }
    if [ "$IS_KDE" = 1 ]; then
        command -v kioclient >/dev/null 2>&1 || { echo "kioclient 가 없어요 (KDE 런처)." >&2; exit 1; }
    else
        command -v gio >/dev/null 2>&1 || { echo "gio 가 없어요 (GLib 런처)." >&2; exit 1; }
    fi
fi

terminals_init
RESULTS="$WORK_DIR/results"
: > "$RESULTS"

S2S="$WORK_DIR/startup-to-screen"
PROC_USAGE="$WORK_DIR/proc-usage"
MAC_INPUT="$WORK_DIR/mac-input"
if [ "$IS_WINDOWS" = 1 ]; then
    win_bench_build startup || exit 1
    S2S="$WORK_DIR/startup-to-screen.exe"
    PROC_USAGE="$WORK_DIR/proc-usage.exe"
elif [ "$IS_MACOS" != 1 ]; then
    # shellcheck disable=SC2046 # pkg-config 출력은 낱말로 갈라야 한다
    cc -O2 -o "$S2S" "$REPO_ROOT/tool/startup-to-screen_linux.c" $(pkg-config --cflags --libs libpipewire-0.3) ||
        { echo "startup-to-screen 컴파일 실패." >&2; exit 1; }
    # 화면의 논리 크기 · 배율 — 측정기가 받은 스트림이 화면 전체인지 본다. 이 셸의 조상 창 (VS Code 등) 의 화면이다.
    if [ "$IS_KDE" = 1 ]; then
        _geo=$(python3 "$REPO_ROOT/tool/kwin-window_linux.py" --child-pid $$ 2>/dev/null || true)
    elif [ "$IS_COSMIC" = 1 ]; then
        _geo=$(python3 "$REPO_ROOT/tool/cosmic-screen_linux.py" 2>/dev/null || true)
    else
        _geo=$(python3 "$REPO_ROOT/tool/gnome-screen_linux.py" 2>/dev/null || true)
    fi
    SCREEN_OUT=$(printf '%s' "$_geo" | sed -n 's/.*output=\([^ ]*\).*/\1/p')
    SCREEN_DPR=$(printf '%s' "$_geo" | sed -n 's/.*dpr=\([^ ]*\).*/\1/p')
    [ -n "$SCREEN_OUT" ] && [ -n "$SCREEN_DPR" ] || { echo "화면 크기를 데스크톱에 못 물었어요 — 창 안의 셸에서 돌려 주세요." >&2; exit 1; }
else
clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
      -o "$S2S" "$REPO_ROOT/tool/startup-to-screen_macos.m" || { echo "startup-to-screen 컴파일 실패." >&2; exit 1; }
clang -O2 -o "$PROC_USAGE" "$REPO_ROOT/tool/proc-usage_macos.c" || { echo "proc-usage 컴파일 실패." >&2; exit 1; }
clang -O2 -Wno-deprecated-declarations -framework ApplicationServices -framework Carbon \
      -o "$MAC_INPUT" "$REPO_ROOT/tool/input_macos.m" || { echo "mac-input 컴파일 실패." >&2; exit 1; }
fi

# Konsole 은 사용자 기본 설정으로 띄우므로 (각 앱의 기본 설정 — 위 머리 주석) 끝날 때 사용자 상태 파일에
# 줄을 더한다 (2026-10-13 실측 — `RestorePositionForNextInstance=false`). 시작 전 내용으로 되돌린다. 처리량 ·
# 지연 · 메모리는 측정용 Konsole 에 빈 상태 폴더를 줘서 이 일이 없다 (`terminals.sh` 의 Konsole 절).
KONSOLE_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/konsolestaterc"
KONSOLE_STATE_BACKUP=""
if [ "$IS_MACOS" != 1 ] && [ "$IS_WINDOWS" != 1 ] && [ -f "$KONSOLE_STATE" ]; then
    KONSOLE_STATE_BACKUP="$WORK_DIR/konsolestaterc"
    cp "$KONSOLE_STATE" "$KONSOLE_STATE_BACKUP"
fi
cleanup() {
    [ "$IS_WINDOWS" = 1 ] && { "$PROC_USAGE" kill startup-child.exe \
        "alacritty.exe;wezterm-gui.exe;WindowsTerminal.exe;conhost.exe;$(basename "${TILDAZ_BIN:-tildaz.exe}")" >/dev/null 2>&1 || true; }
    terminals_cleanup_all || true
    if [ -n "$KONSOLE_STATE_BACKUP" ] && ! cmp -s "$KONSOLE_STATE_BACKUP" "$KONSOLE_STATE"; then
        cp "$KONSOLE_STATE_BACKUP" "$KONSOLE_STATE" && echo "Konsole 상태 파일을 시작 전 내용으로 되돌렸어요."
    fi
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
# Windows 는 같은 일을 하는 네이티브 프로그램이다 (`win_bench_build`).
[ "$IS_WINDOWS" = 1 ] && PRODUCER="$WORK_DIR/startup-child.exe"

terminal_skip() {
    [ -n "$ONLY" ] || return 1
    case ",$ONLY," in *",$1,"*) return 1 ;; esac
    return 0
}

# 회차가 끝나면 그 대상을 **완전히** 내린다 — 다음 회차가 새 프로세스로 뜨게.
stop_target() {
    _st_name="$1"
    cleanup_terminals "$_st_name"
    # Windows — 측정 프로그램을 품은 터미널을 트리째 끝낸다. 본체가 내려가야 다음 회차가 새 프로세스다 (warm).
    if [ "$IS_WINDOWS" = 1 ]; then
        "$PROC_USAGE" kill startup-child.exe "$(win_exe_of "$_st_name")" >/dev/null 2>&1 || true
        return 0
    fi
    case "$_st_name" in
        terminal|iterm2)
            mac_app_quit_woken || true
            ;;
        *)
            # Linux 는 위 `cleanup_terminals` 가 명령줄의 `WORK_DIR` 로 터미널과 측정 프로그램을 끝낸다
            # (런처용 `.desktop` 의 `Exec` 에 측정 프로그램 경로가 든다). 다 내려갈 때까지 기다린다 — warm 이다.
            if [ "$IS_MACOS" != 1 ]; then
                # GNOME Terminal 은 창이 닫혀도 `gnome-terminal-server` 가 남는다 — 다음 회차가 떠 있는 서버를
                # 쓰면 warm (앱 종료 후 다시) 이 아니다. 위생 검사가 시작 때 사용자 창이 없음을 보장한다.
                # `comm` 은 15 자로 잘린다 (`hygiene.sh` 의 같은 이름).
                [ "$_st_name" = gnome-terminal ] && { pkill -x gnome-terminal- || true; }
                _q=0
                while { ps -eo args= | grep -F "$WORK_DIR/startup-child.sh" | grep -v grep >/dev/null ||
                        { [ "$_st_name" = gnome-terminal ] && pgrep -x gnome-terminal- >/dev/null; }; } && [ "$_q" -lt 20 ]; do
                    sleep 0.25; _q=$((_q + 1))
                done
                return 0
            fi
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
        [ "$IS_WINDOWS" = 1 ] || ps -axo pid= > "$WORK_DIR/before"
        if [ "$IS_MACOS" = 1 ] || [ "$IS_WINDOWS" = 1 ]; then
            _out=$("$S2S" --timeout-ms "$TIMEOUT_MS" --min-pixels "$MIN_PIXELS" -- "$@" 2>&1 || true)
        else
            _out=$(python3 "$REPO_ROOT/tool/screencast-portal_linux.py" -- "$S2S" --pw-fd '{fd}' --node '{node}' \
                --output "$SCREEN_OUT" --dpr "$SCREEN_DPR" --timeout-ms "$TIMEOUT_MS" --min-pixels "$MIN_PIXELS" \
                -- "$@" 2>&1 || true)
        fi
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
if [ "$IS_MACOS" = 1 ]; then
    echo "회차       ${REPEAT} 회 (warm · 회차마다 앱 종료) · 실행 경로 LaunchServices (open)"
elif [ "$IS_WINDOWS" = 1 ]; then
    echo "회차       ${REPEAT} 회 (warm · 회차마다 앱 종료) · 실행 경로 ShellExecuteEx"
else
    if [ "$IS_KDE" = 1 ]; then
        echo "회차       ${REPEAT} 회 (warm · 회차마다 앱 종료) · 실행 경로 KDE 런처 (kioclient exec)"
    else
        echo "회차       ${REPEAT} 회 (warm · 회차마다 앱 종료) · 실행 경로 GLib 런처 (gio launch)"
    fi
fi
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
if [ "$IS_MACOS" = 1 ]; then
    echo "단위 ms. 실행 (open) → 터미널 안 프로그램이 칠한 마젠타가 화면에 처음 보인 프레임의 표시 시각."
elif [ "$IS_WINDOWS" = 1 ]; then
    echo "단위 ms. 실행 (ShellExecuteEx) → 터미널 안 프로그램이 칠한 마젠타가 보인 첫 프레임의 LastPresentTime."
    echo "macOS · Linux 표와 절대값을 견주지 않아요."
else
    echo "단위 ms. 실행 (런처) → 터미널 안 프로그램이 칠한 마젠타가 보인 첫 프레임이 측정기에 도착한 시각."
    echo "표시 시각이 아니라서 macOS 표와 절대값을 견주지 않아요."
fi
