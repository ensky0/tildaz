#!/bin/sh
# 여러 터미널이 같은 워크로드를 소화하는 속도를 비교한다 (#371 L4).
#
# 각 터미널을 띄우고 그 안에서 `tildaz-stress` 를 producer 모드로 돌린다. producer 는
# 출력을 끝낸 뒤 경과 시간과 **자기 그리드 크기**를 timing 파일에 적는다. 이 스크립트는
# 그 파일을 모아 표로 낸다.
#
# 그리드를 함께 남기는 게 핵심이다 — 터미널마다 폰트 크기 해석이 달라 같은 창 크기를
# 줘도 셀 수가 갈리고, 열 수가 다르면 줄바꿈 횟수가 달라져 파서 부하가 달라진다.
# #362 에서 그리드가 31 배 어긋난 채로 비교하려던 적이 있다.
#
#   dist/stress/compare-terminals.sh --mb 64 --workload plain --cols 120 --rows 40
#
# TildaZ 도 자동이다 — 측정 내부용 `-e` · `-size` 옵션을 쓴다 (#382). 그 인스턴스는
# worker lock 을 잡지 않고 전역 핫키도 등록하지 않아서, 평소 쓰는 TildaZ 가 떠 있어도
# 충돌하지 않는다.

set -eu

MB=64
WORKLOAD=plain
COLS=120
ROWS=40
TIMEOUT=180

while [ $# -gt 0 ]; do
    case "$1" in
        --mb) MB="$2"; shift 2 ;;
        --workload) WORKLOAD="$2"; shift 2 ;;
        --cols) COLS="$2"; shift 2 ;;
        --rows) ROWS="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

BYTES=$((MB * 1024 * 1024))
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# --- platform ---
#
# Windows 는 **Git Bash** 에서 돌린다 (Git for Windows 에 항상 포함되므로 별도 설치가
# 필요 없다). 릴리즈 패키징이 Git Bash 를 요구하지 않는 것과는 다른 이야기다 — 이건 측정용
# 내부 도구다.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
    *) IS_WINDOWS=0 ;;
esac

# 자식이 **Windows 실행파일**이면 경로를 Windows 형식으로 줘야 한다. MSYS 는 명령줄 인자를
# 자동 변환하지만 **환경변수 값은 변환하지 않는다** — producer 가 timing 파일을 열지 못하는
# 원인이 그것이다.
native_path() {
    if [ "$IS_WINDOWS" = 1 ]; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

PRODUCER="$REPO_ROOT/zig-out/bin/tildaz-stress"
[ "$IS_WINDOWS" = 1 ] && PRODUCER="$PRODUCER.exe"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

if [ ! -x "$PRODUCER" ]; then
    echo "producer 가 없어요: $PRODUCER" >&2
    echo "먼저 빌드해요: zig build stress -Doptimize=ReleaseFast -Dsimd=true -- throughput --mb 1" >&2
    exit 1
fi

echo "=== 터미널 처리량 비교 (#371 L4) ==="
echo "workload   $WORKLOAD"
echo "bytes      $BYTES ($MB MiB)"
echo "목표 그리드 ${COLS}x${ROWS}"
echo "producer   $PRODUCER"
echo ""

# producer 를 셸 명령 한 줄로. 터미널마다 이 문자열을 자기 방식으로 실행한다.
# `exec` 로 셸을 대체해 셸이 남지 않게 한다.
producer_cmd() {
    printf 'env TILDAZ_STRESS_WORKLOAD=%s TILDAZ_STRESS_BYTES=%s TILDAZ_STRESS_TIMING_FILE=%s %s' \
        "$WORKLOAD" "$BYTES" "$(native_path "$1")" "$PRODUCER"
}

# 같은 것을 **cmd 문법**으로. conhost 는 `sh` 대신 `cmd` 로 띄우기 때문이다 — `env` 는 Git
# Bash 의 실행파일이라 cmd 가 보는 PATH 에 없을 수 있다. `set "VAR=값"` 형태여야 값 끝에
# 공백이 붙지 않는다 (`set VAR=값 && …` 는 "값 " 이 된다).
producer_cmd_cmdexe() {
    printf 'set "TILDAZ_STRESS_WORKLOAD=%s" && set "TILDAZ_STRESS_BYTES=%s" && set "TILDAZ_STRESS_TIMING_FILE=%s" && "%s"' \
        "$WORKLOAD" "$BYTES" "$(native_path "$1")" "$(native_path "$PRODUCER")"
}

# timing 파일이 생길 때까지 기다린다. 터미널을 background 로 띄우기 때문에 (그러지 않으면
# 창이 닫히기를 기다리며 멈춘다) 완료 신호는 이 파일뿐이다.
wait_for() {
    _file="$1"
    _waited=0
    while [ ! -s "$_file" ]; do
        sleep 1
        _waited=$((_waited + 1))
        if [ "$_waited" -ge "$TIMEOUT" ]; then
            return 1
        fi
    done
    # 파일이 부분만 쓰인 순간에 읽지 않도록 마지막 줄까지 왔는지 확인한다.
    _settle=0
    while ! grep -q '^rows=' "$_file"; do
        sleep 1
        _settle=$((_settle + 1))
        [ "$_settle" -ge 5 ] && return 1
    done
    return 0
}

RESULTS="$WORK_DIR/results"
: > "$RESULTS"

record() {
    _name="$1"
    _file="$2"
    if [ ! -s "$_file" ]; then
        printf '%s\tskipped\t0\t0\t0\n' "$_name" >> "$RESULTS"
        return
    fi
    _ns=$(sed -n 's/^elapsed_ns=//p' "$_file")
    _cols=$(sed -n 's/^cols=//p' "$_file")
    _rows=$(sed -n 's/^rows=//p' "$_file")
    _cols0=$(sed -n 's/^cols_start=//p' "$_file")
    _rows0=$(sed -n 's/^rows_start=//p' "$_file")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_name" "$_ns" "$_cols" "$_rows" "$_cols0" "$_rows0" >> "$RESULTS"
}

run_terminal() {
    _name="$1"
    shift
    _timing="$WORK_DIR/$_name.timing"

    printf '%-14s ' "$_name"
    # background 로 띄운다 — 창이 닫히기를 기다리면 멈춘다 (kitty 실측).
    "$@" >/dev/null 2>&1 &
    _pid=$!

    if wait_for "$_timing"; then
        _ns=$(sed -n 's/^elapsed_ns=//p' "$_timing")
        _cols=$(sed -n 's/^cols=//p' "$_timing")
        _rows=$(sed -n 's/^rows=//p' "$_timing")
        printf 'ok  %sx%s\n' "$_cols" "$_rows"
    else
        printf 'timeout / 실행 안 됨\n'
    fi
    # 창이 남아 있으면 정리한다.
    kill "$_pid" 2>/dev/null || true
    record "$_name" "$_timing"
}

# --- 터미널별 실행 방법 ---
#
# 실행 방법과 그리드 지정 옵션이 터미널마다 다르다. 그리드가 맞는지는 producer 가 남긴
# 값으로 확인한다 — 표의 grid 열이 목표와 다르면 그 줄은 비교에 쓰지 않는다.

if command -v kitty >/dev/null 2>&1; then
    T="$WORK_DIR/kitty.timing"
    # `remember_window_size=no` 가 없으면 이전 세션 크기를 복원해서 아래 두 옵션을
    # 무시한다 (실측: 100x30 을 줬는데 91x29 로 떴다).
    run_terminal kitty kitty --detach \
        -o remember_window_size=no \
        -o "initial_window_width=${COLS}c" \
        -o "initial_window_height=${ROWS}c" \
        -o scrollback_lines=100000 \
        sh -c "$(producer_cmd "$T")"
fi

if command -v alacritty >/dev/null 2>&1; then
    T="$WORK_DIR/alacritty.timing"
    run_terminal alacritty alacritty \
        -o "window.dimensions.columns=$COLS" \
        -o "window.dimensions.lines=$ROWS" \
        -o "scrolling.history=100000" \
        -e sh -c "$(producer_cmd "$T")"
fi

if command -v wezterm >/dev/null 2>&1; then
    T="$WORK_DIR/wezterm.timing"
    # `--config` 는 **전역 옵션**이라 `start` 앞에 와야 한다 (`wezterm --help`).
    # `start` 뒤에 두면 실행 자체가 안 된다.
    run_terminal wezterm wezterm \
        --config "initial_cols=$COLS" \
        --config "initial_rows=$ROWS" \
        --config "scrollback_lines=100000" \
        start -- sh -c "$(producer_cmd "$T")"
fi

# ghostty 는 창 크기를 **config 파일로** 준다. CLI 로 config key 옵션을 여러 개 주면
# macOS 의 `open -na … --args` 경로에서 한 값으로 합쳐져 실패한다 (실측:
# `window-width: invalid value "200 --window-height=60"`). `--config-file` 하나만 넘기면
# 정상이라, 임시 config 를 만들어 쓰면 **사용자 설정을 건드리지 않는다.**
#
# `window-save-state = never` 가 필수다 — 없으면 이전 창 크기를 복원해서 아래 두 줄을
# 무시한다 (kitty 의 `remember_window_size` 와 같은 성질). 값은 `false` 가 아니라
# `default | never | always` 중 하나다.
if [ -d /Applications/Ghostty.app ] || command -v ghostty >/dev/null 2>&1; then
    GHOSTTY_CONF="$WORK_DIR/ghostty.conf"
    cat > "$GHOSTTY_CONF" << EOF
window-save-state = never
window-width = $COLS
window-height = $ROWS
scrollback-limit = 100000
EOF
    T="$WORK_DIR/ghostty.timing"
    if [ -d /Applications/Ghostty.app ]; then
        # macOS 는 CLI 로 터미널을 띄울 수 없어서 (`ghostty --help`) LaunchServices 를 거친다.
        run_terminal ghostty open -na /Applications/Ghostty.app --args \
            "--config-file=$GHOSTTY_CONF" -e sh -c "$(producer_cmd "$T")"
    else
        run_terminal ghostty ghostty \
            "--config-file=$GHOSTTY_CONF" -e sh -c "$(producer_cmd "$T")"
    fi
fi

# TildaZ — `-e` · `-size` 로 자동 측정한다 (#382). 그 두 옵션은 **측정 내부용**이라
# 문서화하지 않는다 (`src/run_options.zig`).
#
# 측정용 인스턴스는 평소 쓰는 TildaZ 를 건드리지 않는다 — worker lock 을 잡지 않고, 전역
# 핫키를 등록하지 않고, instance 요청 endpoint 상태를 기록하지 않고, Windows 에서는 창
# 타이틀도 worker 와 다른 이름을 쓴다 (worker 창을 타이틀로 찾는 경로가 있다). 뒤의 둘은
# Windows 실기 검증에서 빠진 것이 드러나 #382 에서 추가했다. 명령이 끝나면 스스로 종료한다.
#
# 저장소 빌드본을 쓴다 — 설치본은 버전이 다를 수 있다.
TILDAZ_BIN=""
for candidate in \
    "$REPO_ROOT/zig-out/TildaZ.app/Contents/MacOS/tildaz" \
    "$REPO_ROOT/zig-out/bin/tildaz" \
    "$REPO_ROOT/zig-out/bin/tildaz.exe"
do
    [ -x "$candidate" ] && TILDAZ_BIN="$candidate" && break
done

if [ -n "$TILDAZ_BIN" ]; then
    T="$WORK_DIR/tildaz.timing"
    # producer 파라미터는 TildaZ 프로세스의 환경변수로 준다 — 자식(producer)이 상속한다.
    # `-e` 는 실행파일 경로만 받는다 (POSIX 는 PTY 자식의 argv 가 고정이다).
    run_terminal tildaz env \
        "TILDAZ_STRESS_WORKLOAD=$WORKLOAD" \
        "TILDAZ_STRESS_BYTES=$BYTES" \
        "TILDAZ_STRESS_TIMING_FILE=$(native_path "$T")" \
        "$TILDAZ_BIN" -e "$(native_path "$PRODUCER")" -size "${COLS}x${ROWS}"
else
    echo "tildaz         빌드본이 없어요 — zig build 로 먼저 빌드해 주세요"
fi

# Windows Terminal 은 Windows 전용이다.
#
# - `--size <cols>,<rows>` 로 격자를 준다. **사용자의 `launchMode` 가 `maximized` ·
#   `fullscreen` · `focus` 계열이면 이 옵션이 무시된다** (Microsoft Learn 의 command-line
#   arguments 문서). 그때는 표의 grid 열이 목표와 달라지므로 그 줄을 비교에 쓰지 않는다 —
#   kitty 의 `remember_window_size` 와 같은 성질이고, 스크립트는 producer 가 남긴 격자로
#   그것을 걸러낸다.
# - `-w new` 가 필수다. 사용자의 `windowingBehavior` 가 `useAnyExisting` 이면 `wt` 가 **기존
#   창에 탭으로** 붙어서 창 크기 옵션이 의미를 잃는다. `new` 는 항상 새 창이다.
if [ "$IS_WINDOWS" = 1 ] && command -v wt >/dev/null 2>&1; then
    T="$WORK_DIR/wt.timing"
    # 표 이름은 실행 파일명 `wt` 를 쓴다 — "windows-terminal" 은 표의 이름 칸 (14) 을 넘겨
    # 줄이 밀린다.
    run_terminal wt wt -w new --size "$COLS,$ROWS" \
        sh -c "$(producer_cmd "$T")"
fi

# conhost — Windows 의 전통 콘솔 호스트 (`%windir%\System32\conhost.exe`). `cmd.exe` 는 UI 가
# 없고 이 프로세스가 창 · 렌더링 · 입력을 담당한다.
#
# 두 가지 이유로 함께 잰다.
# 1. **하한 기준선**이다 — legacy GDI 렌더러라 현대 터미널보다 크게 느리다.
# 2. **ConPTY 오버헤드를 가늠할 단서**다. Windows Terminal · alacritty · TildaZ 처럼 ConPTY 를
#    쓰는 터미널은 내부적으로 headless conhost 를 거치므로, 같은 producer 를 conhost 에 직접
#    돌린 값과 비교하면 그 몫이 보인다 ([#371](https://github.com/ensky0/tildaz/issues/371) 의
#    `cjk` 초과분 +25.6 % 가 그 후보다).
#
# `conhost.exe <명령>` 으로 그 명령을 legacy 콘솔 창에서 띄운다. 널리 쓰이는 방법이지만
# **Microsoft 공식 문서에 인자 규격이 정리돼 있지 않다** (확인 필요).
#
# **조건이 완전히 같지 않다는 점을 감안해서 읽어야 한다.** conhost 는 창 크기 옵션이 없어서
# `mode con` 으로 격자를 주는데, `lines=N` 이 창과 버퍼를 함께 N 으로 만들어 **스크롤백이
# 없다.** 다른 터미널에는 100000 줄을 주므로 conhost 값에는 스크롤백 관리 비용이 빠져 있다.
if [ "$IS_WINDOWS" = 1 ] && command -v conhost >/dev/null 2>&1; then
    T="$WORK_DIR/conhost.timing"
    run_terminal conhost conhost cmd /c \
        "mode con: cols=$COLS lines=$ROWS && $(producer_cmd_cmdexe "$T")"
fi

# foot 은 Wayland 전용이라 Linux 에서만 있다.
if command -v foot >/dev/null 2>&1; then
    T="$WORK_DIR/foot.timing"
    run_terminal foot foot --window-size-chars="${COLS}x${ROWS}" \
        sh -c "$(producer_cmd "$T")"
fi

# --- 표 ---

echo ""
printf '%-14s %12s %10s %10s  %s\n' terminal ms MiB/s grid 비고
printf '%s\n' "------------------------------------------------------------------"
while IFS="$(printf '\t')" read -r name ns cols rows cols0 rows0; do
    if [ "$ns" = "skipped" ] || [ "$ns" = "0" ] || [ -z "$ns" ]; then
        printf '%-14s %12s %10s %10s  %s\n' "$name" - - - "측정 실패"
        continue
    fi
    ms=$(awk "BEGIN{printf \"%.1f\", $ns/1000000}")
    rate=$(awk "BEGIN{printf \"%.1f\", ($BYTES/1048576)/($ns/1000000000)}")
    note=""
    if [ "$cols" != "$COLS" ] || [ "$rows" != "$ROWS" ]; then
        note="그리드 불일치 — 비교 불가"
    elif [ "$cols0" != "$cols" ] || [ "$rows0" != "$rows" ]; then
        # 출력 도중에 창 크기가 바뀌었다는 뜻이다 (터미널이 셸 spawn 뒤 resize).
        note="측정 중 resize (${cols0}x${rows0} → ${cols}x${rows})"
    fi
    printf '%-14s %12s %10s %10s  %s\n' "$name" "$ms" "$rate" "${cols}x${rows}" "$note"
done < "$RESULTS"

# --- 마무리 ---

echo ""
echo "timing 파일의 cols/rows 가 ${COLS}x${ROWS} 인지 표에서 확인해 주세요 — 다르면 그"
echo "숫자는 비교할 수 없어요. 탭이 2 개 이상이면 탭바 (28 pt) 가 들어가 rows 가 줄어요."
