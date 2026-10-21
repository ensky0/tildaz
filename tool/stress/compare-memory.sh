#!/bin/sh
# 여러 터미널의 **메모리 · 유휴 CPU** 를 같은 잣대로 견준다 (#756).
#
#   tool/stress/compare-memory.sh --repeat 3 --idle-sec 30
#
# 회차 하나:
#   1. 대상 창을 띄우고 (깨운 Terminal.app · iTerm2 의 기본 창은 닫는다) **창을 한 번 눌러 포커스를
#      준다.** 포커스가 있는지에 따라 커서 깜빡임 같은 유휴 동작이 달라져서 모든 대상을 같게 둔다.
#   2. 3 초 뒤 **빈 화면 메모리**.
#   3. 터미널 안 프로그램이 100 자 줄을 `--fill-lines` 줄 (기본 40,000) 낸다. scrollback 상한
#      (32,767) 을 넘겨 모든 대상이 꽉 찬 상태가 된다. 3 초 뒤 **채운 뒤 메모리**.
#   4. 그 뒤 `--idle-sec` 초 동안 늘어난 CPU 시간 → **유휴 CPU %** (한 코어 = 100 %).
#
# - 메모리 · CPU 시간을 읽는 쪽과 "그 터미널의 프로세스" 의 정의는 `tool/proc-usage_macos.c` ·
#   `tool/proc-usage_linux.py` 머리 주석에 있다 — 본체 · 자손 (macOS 는 같은 앱 번들 안도), 셸 쪽은 뺀다.
# - 메모리는 macOS 가 `phys_footprint`, Linux 가 **PSS**, Windows 가 **Private Working Set** (작업 관리자의 "메모리"
#   열 — `tool/proc-usage_windows.c`) 다. 재는 것이 달라 OS 사이에 견주지 않는다.
# - **커서는 숨기지 않는다.** 각 터미널의 기본 동작 (깜빡임 등) 이 사용자가 보는 유휴 상태다.
# - **macOS · Windows 와 Linux 의 KDE Plasma** 에서 된다. Linux 는 본체 (창 주인) 와 포커스 클릭을 KWin 에 묻는다
#   (`tool/kwin-window_linux.py`). Windows 는 터미널 안 프로그램의 pid 에서 조상을 따라 본체를 찾는다
#   (`tool/proc-tree_windows.h`). 포커스 클릭은 `key-to-screen_windows.c --presses 0` 이다.
# - 대상을 띄우고 닫는 코드는 처리량 · 지연과 같다 (`terminals.sh`).

set -eu

REPEAT=3
IDLE_SEC=30
FILL_LINES=40000
COLS=120
ROWS=40
SCROLLBACK=32767
TIMEOUT=60
IGNORE_HYGIENE=0
ONLY=""
# `--verbose` — 고른 본체 pid 와 `proc-usage measure` 의 프로세스 목록을 찍는다 (진단용).
VERBOSE=0

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO_ROOT/tool/stress/hygiene.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        --repeat) REPEAT="$2"; shift 2 ;;
        --idle-sec) IDLE_SEC="$2"; shift 2 ;;
        --fill-lines) FILL_LINES="$2"; shift 2 ;;
        --cols) COLS="$2"; shift 2 ;;
        --rows) ROWS="$2"; shift 2 ;;
        --scrollback) SCROLLBACK="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --ignore-hygiene) IGNORE_HYGIENE=1; shift ;;
        # `--only kitty,terminal` — 일부 대상만 돈다 (진단용).
        --only) ONLY="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        --terminal-settings) TERMINAL_APP_SETTINGS="$2"; export TERMINAL_APP_SETTINGS; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

for _n in "$REPEAT" "$IDLE_SEC" "$FILL_LINES"; do
    case "$_n" in ''|*[!0-9]*|0) echo "--repeat · --idle-sec · --fill-lines 는 1 이상의 정수여야 해요: $_n" >&2; exit 2 ;; esac
done

. "$REPO_ROOT/tool/stress/terminals.sh"

IS_KDE=0
case "${XDG_CURRENT_DESKTOP:-}" in *KDE*) IS_KDE=1 ;; esac
if [ "$IS_MACOS" != 1 ] && [ "$IS_WINDOWS" != 1 ] && [ "$IS_KDE" != 1 ]; then
    echo "지금은 macOS · Windows 와 Linux 의 KDE Plasma 만 돼요 — 다른 데스크톱의 측정기는 아직 없어요 (#756)." >&2
    exit 2
fi
if [ "$IS_MACOS" = 1 ]; then
    command -v clang >/dev/null 2>&1 || { echo "clang 없음 — Xcode Command Line Tools 가 필요해요." >&2; exit 1; }
elif [ "$IS_WINDOWS" != 1 ]; then
    python3 -c 'import dbus, gi' 2>/dev/null || { echo "python-dbus · python-gobject 가 필요해요." >&2; exit 1; }
fi

terminals_init
RESULTS="$WORK_DIR/results"
: > "$RESULTS"

PROC_USAGE="$WORK_DIR/proc-usage"
MAC_INPUT="$WORK_DIR/mac-input"
if [ "$IS_WINDOWS" = 1 ]; then
    win_bench_build memory || exit 1
    PROC_USAGE="$WORK_DIR/proc-usage.exe"
elif [ "$IS_MACOS" = 1 ]; then
clang -O2 -o "$PROC_USAGE" "$REPO_ROOT/tool/proc-usage_macos.c" ||
    { echo "proc-usage 컴파일 실패." >&2; exit 1; }
clang -O2 -Wno-deprecated-declarations -framework ApplicationServices -framework Carbon \
      -o "$MAC_INPUT" "$REPO_ROOT/tool/input_macos.m" ||
    { echo "mac-input 컴파일 실패." >&2; exit 1; }
else
    # 출력 형식이 macOS 판과 같다 (`measure` 의 `total <개수> <byte> <ns>`). 아래 `measure_field` 가 그대로 쓴다.
    printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$REPO_ROOT/tool/proc-usage_linux.py" > "$PROC_USAGE"
    chmod +x "$PROC_USAGE"
fi

cleanup() {
    # Windows — 남은 측정 창을 트리째 끝낸다 (`compare-latency.sh` 의 같은 자리).
    [ "$IS_WINDOWS" = 1 ] && { "$PROC_USAGE" kill memory-child.exe \
        "alacritty.exe;wezterm-gui.exe;WindowsTerminal.exe;conhost.exe;$(win_exe_of tildaz)" >/dev/null 2>&1 || true; }
    terminals_cleanup_all || true
    hygiene_end || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# 포커스 클릭에 손쉬운 사용 권한이 필요하다 (`input_macos.m` 머리 주석). Linux 는 /dev/uinput 이다.
if [ "$IS_MACOS" = 1 ]; then
    "$MAC_INPUT" check || exit 1
elif [ "$IS_WINDOWS" != 1 ]; then
    python3 -c "import os; os.close(os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK))" 2>/dev/null ||
        { echo "/dev/uinput 을 못 열어요 (권한 · 모듈)." >&2; exit 1; }
fi

# --- 터미널 안에서 도는 프로그램 ---
#
# 준비를 알리고 → `<timing>.go` 가 생길 때까지 기다렸다가 → 줄을 내고 → `filled=1` 을 알리고 →
# 가만히 있는다. 줄 내기는 `awk` 다 (세 OS 에 다 있다). 100 자라 120 열에서 줄바꿈이 안 일어난다.
PRODUCER="$WORK_DIR/memory-child.sh"
cat > "$PRODUCER" << EOF
#!/bin/sh
# 목표 격자가 될 때까지 (최대 5 초) 기다린다 — Terminal.app 은 wrapper 의 escape sequence 로 창을
# 키우는데, 그것이 적용되기 전에 읽으면 120x30 을 본다 (2026-10-13 실측). producer 의 grid wait 와 같다.
_i=0
while [ "\$_i" -lt 50 ]; do
    set -- \$(stty size 2>/dev/null)
    [ "\${2:-0}x\${1:-0}" = "\$TILDAZ_STRESS_GRID" ] && break
    sleep 0.1; _i=\$((_i + 1))
done
# \`pid\` 는 Linux 가 창 주인을 찾는 데 쓴다 (\`tool/kwin-window_linux.py\`).
printf 'cols=%s\nrows=%s\npid=%s\n' "\${2:-0}" "\${1:-0}" "\$\$" > "\$TILDAZ_STRESS_TIMING_FILE"
while [ ! -e "\$TILDAZ_STRESS_TIMING_FILE.go" ]; do sleep 0.2; done
awk 'BEGIN { s = sprintf("%93s", ""); gsub(/ /, "x", s); for (i = 0; i < $FILL_LINES; i++) printf "%06d %s\n", i, s }'
echo filled=1 >> "\$TILDAZ_STRESS_TIMING_FILE"
while :; do sleep 60; done
EOF
chmod +x "$PRODUCER"
PRODUCER_ENV=""
# Windows 는 같은 일을 하는 네이티브 프로그램이다 (`win_bench_build`). 줄 수는 환경변수로 준다.
if [ "$IS_WINDOWS" = 1 ]; then
    PRODUCER="$WORK_DIR/memory-child.exe"
    PRODUCER_ENV="TILDAZ_BENCH_FILL_LINES=$FILL_LINES"
fi

terminal_skip() {
    [ -n "$ONLY" ] || return 1
    case ",$ONLY," in *",$1,"*) return 1 ;; esac
    return 0
}

wait_line() {   # $1 = 파일, $2 = 줄 앞부분
    _w=0
    while ! grep -q "^$2" "$1" 2>/dev/null; do
        sleep 1
        _w=$((_w + 1))
        [ "$_w" -ge "$TIMEOUT" ] && return 1
    done
    return 0
}

# `proc-usage measure` 의 마지막 줄 (`total <개수> <메모리 byte> <CPU ns>`) 에서 $2 번째 칸.
# `set --` 로 나누지 않는다 — `run_terminal` 의 `"$@"` (대상을 띄우는 명령) 을 덮어쓴다.
measure_field() { "$PROC_USAGE" measure "$1" 2>/dev/null | awk -v f="$2" '$1 == "total" { print $f }'; }

run_terminal() {
    _name="$1"
    shift
    _timing="$WORK_DIR/$_name.timing"
    printf '%-14s ' "$_name"
    _cols=0; _rows=0; _procs=0
    _run=1
    while [ "$_run" -le "$REPEAT" ]; do
        rm -f "$_timing" "$_timing.go"
        # Git Bash 의 `ps` 는 `-o` 를 모른다 (`terminals.sh` 의 `cleanup_terminals` 주석). Windows 는 이 목록을 안 쓴다.
        [ "$IS_WINDOWS" = 1 ] || ps -axo pid= > "$WORK_DIR/before"
        "$@" >/dev/null 2>&1 &
        _pid=$!
        _mark=x
        if wait_line "$_timing" rows=; then
            _cols=$(sed -n 's/^cols=//p' "$_timing")
            _rows=$(sed -n 's/^rows=//p' "$_timing")
            mac_close_woken_extras "$_name"
            if [ "$IS_MACOS" = 1 ]; then
                _main=$("$PROC_USAGE" find "$(mac_proc_path_of "$_name")" "$WORK_DIR/before" 2>/dev/null || true)
            elif [ "$IS_WINDOWS" = 1 ]; then
                # 터미널 안 프로그램에서 올라가 본체를 찾고, 그 창 가운데를 한 번 눌러 포커스를 준다.
                _cpid=$(sed -n 's/^pid=//p' "$_timing")
                _main=$("$PROC_USAGE" main "$_cpid" "$(win_exe_of "$_name")" 2>/dev/null || true)
                "$WORK_DIR/key-to-screen.exe" --child-pid "$_cpid" --main "$(win_exe_of "$_name")" --click --presses 0 \
                    >/dev/null 2>&1 || echo "  ⚠ [$_name] 포커스를 못 줬어요" >&2
                [ "$VERBOSE" = 1 ] && echo "  [$_name] 본체 pid: ${_main:-(없음)}" >&2
            else
                # 창 주인이 본체다 — 활성화하고 가운데를 한 번 누른다 (포커스는 아래 macOS 의 `focus` 와 같은 자리).
                _geo=""
                _t=0
                while [ -z "$_geo" ] && [ "$_t" -lt 20 ]; do
                    _geo=$(python3 "$REPO_ROOT/tool/kwin-window_linux.py" --child-pid "$(sed -n 's/^pid=//p' "$_timing")" \
                        --activate --click 2>/dev/null || true)
                    [ -n "$_geo" ] || { sleep 0.25; _t=$((_t + 1)); }
                done
                _main=$(printf '%s' "$_geo" | sed -n 's/.* pid=\([0-9]*\).*/\1/p')
                [ "$VERBOSE" = 1 ] && echo "  [$_name] 창: ${_geo:-(없음)}" >&2
            fi
            if [ "$VERBOSE" = 1 ] && [ "$IS_MACOS" = 1 ]; then
                echo "" >&2
                echo "  [$_name] 본체 pid: ${_main:-(없음)} · 같은 이름의 프로세스:" >&2
                ps -axo pid=,ppid=,lstart=,comm= | grep -F "$(mac_proc_path_of "$_name")" | grep -v grep | sed 's/^/    /' >&2 || true
                [ -n "$_main" ] && "$PROC_USAGE" measure "$_main" 2>&1 | sed 's/^/    measure: /' >&2
            fi
            if [ -z "$_main" ]; then
                _mark='?'
            else
                [ "$IS_MACOS" = 1 ] && { "$MAC_INPUT" focus "$_main" >/dev/null 2>&1 || true; }
                [ "$VERBOSE" = 1 ] && [ "$IS_MACOS" != 1 ] && "$PROC_USAGE" measure "$_main" 2>&1 | sed 's/^/    measure: /' >&2
                sleep 3
                _procs=$(measure_field "$_main" 2); _m1=$(measure_field "$_main" 3)
                touch "$_timing.go"
                if wait_line "$_timing" filled=; then
                    sleep 3
                    _m2=$(measure_field "$_main" 3); _c0=$(measure_field "$_main" 4)
                    sleep "$IDLE_SEC"
                    _c1=$(measure_field "$_main" 4)
                    printf '%s\t%s\t%s\t%s\t%s\t%sx%s\n' "$_m1" "$_m2" "$_c0" "$_c1" "$_procs" "$_cols" "$_rows" >> "$WORK_DIR/$_name.samples"
                    _mark='.'
                else
                    _mark='!'
                fi
            fi
        fi
        printf '%s' "$_mark"
        kill "$_pid" 2>/dev/null || true
        wait "$_pid" 2>/dev/null || true
        cleanup_terminals "$_name"
        [ "$IS_WINDOWS" = 1 ] && { "$PROC_USAGE" kill memory-child.exe "$(win_exe_of "$_name")" >/dev/null 2>&1 || true; }
        # 깨운 Terminal.app · iTerm2 는 **회차마다 종료한다.** 창만 닫으면 앱이 떠 있어서, 다음 회차는
        # 본체가 "측정 전부터 있던 프로세스" 로 걸러져 못 찾고 (2026-10-13 실측 — 2 · 3 회차 `?`),
        # 찾는다 해도 앞 회차의 흔적이 남은 앱을 잰다. 다른 대상은 회차마다 새 프로세스다.
        mac_app_quit_woken || true
        sleep 1
        _run=$((_run + 1))
    done
    printf '  %sx%s  프로세스 %s\n' "$_cols" "$_rows" "$_procs"
    printf '%s\t%s\t%s\n' "$_name" "$_cols" "$_rows" >> "$RESULTS"
}

echo "=== 터미널 메모리 · 유휴 CPU 비교 (#756) ==="
echo "회차       ${REPEAT} 회 · 채우는 줄 ${FILL_LINES} · 유휴 ${IDLE_SEC} 초"
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
echo ""

# wt 의 scrollback 은 측정용 fragment 프로필로 준다 (`terminals.sh` — 처리량과 같다). 다른 OS 에서는 할 일이 없다.
wt_fragment_apply

terminals_launch_all

# --- 표 --- 회차 값의 중앙값. MiB 는 1024², CPU % 는 한 코어 기준이다.
echo ""
printf '%-14s %12s %12s %10s %8s %10s  %s\n' terminal "빈 화면 MiB" "채운 뒤 MiB" "유휴 CPU%" 회차 grid 비고
printf '%s\n' "------------------------------------------------------------------------------------"
while IFS="$(printf '\t')" read -r name cols rows; do
    _s="$WORK_DIR/$name.samples"
    _note=""
    [ "$cols" = "$COLS" ] && [ "$rows" = "$ROWS" ] || _note="그리드 불일치"
    if [ ! -s "$_s" ]; then
        printf '%-14s %12s %12s %10s %8s %10s  %s\n' "$name" - - - 0 "${cols}x${rows}" "측정 실패${_note:+ · $_note}"
        continue
    fi
    # 회차 하나라도 격자가 어긋났으면 적는다 — 마지막 회차만 보면 중간 회차를 놓친다.
    _bad=$(awk -F '\t' -v g="${COLS}x${ROWS}" '$6 != g' "$_s" | wc -l | tr -d ' ')
    [ "$_bad" -gt 0 ] && _note="${_note:+$_note · }격자가 어긋난 회차 $_bad"
    awk -F '\t' -v name="$name" -v grid="${cols}x${rows}" -v note="$_note" -v idle="$IDLE_SEC" '
        function med(a, n,   i, j, t) {
            for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
            return (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
        }
        { n++; m1[n] = $1 / 1048576; m2[n] = $2 / 1048576; cpu[n] = ($4 - $3) / (idle * 1e9) * 100 }
        END { printf "%-14s %12.1f %12.1f %10.2f %8d %10s  %s\n", name, med(m1, n), med(m2, n), med(cpu, n), n, grid, note }
    ' "$_s"
done < "$RESULTS"
echo ""
if [ "$IS_MACOS" = 1 ]; then
    echo "메모리 = phys_footprint 합 (Activity Monitor 의 \"메모리\" 열과 같은 값). 셸 쪽 프로세스는 뺐다."
elif [ "$IS_WINDOWS" = 1 ]; then
    echo "메모리 = Private Working Set 합 (작업 관리자의 \"메모리\" 열과 같은 값). 셸 쪽 프로세스는 뺐다."
    echo "재는 것이 macOS · Linux 와 달라 OS 사이에 견주지 않아요."
else
    echo "메모리 = PSS 합 (/proc/<pid>/smaps_rollup — 공유 페이지를 나눠 센다). 셸 쪽 프로세스는 뺐다."
    echo "재는 것이 macOS 와 달라 OS 사이에 견주지 않아요."
fi
