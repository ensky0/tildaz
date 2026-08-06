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
# **기록으로 남길 수치는 `--repeat 5` 로 낸다** (#371 의 측정 프로토콜). 1 회 측정은 흔들림을
# 알 수 없다 — macOS 실측에서 같은 조건 3 회가 115.0 / 124.2 / 128.7 MiB/s 였다. 반복하면
# 대표값을 **min · max 를 뺀 나머지의 평균 (절사평균)** 으로 내고 `min~max` 를 함께 적는다.
#
#   dist/stress/compare-terminals.sh --mb 64 --workload plain --repeat 5
#
# TildaZ 도 자동이다 — 측정 내부용 `-e` · `-size` 옵션을 쓴다 (#382). 그 인스턴스는
# worker lock 을 잡지 않고 전역 핫키도 등록하지 않아서, 평소 쓰는 TildaZ 가 떠 있어도
# 충돌하지 않는다. 다만 **기록용 측정에서는 평소 쓰는 worker 를 종료한다** — 다른 터미널은
# 백그라운드 인스턴스가 없는데 TildaZ 만 worker 가 떠 있으면 CPU 를 나눠 쓴다.

set -eu

MB=64
WORKLOAD=plain
COLS=120
ROWS=40
TIMEOUT=180
REPEAT=1
# scrollback 을 **모든 대상에 같은 값으로** 준다 (#381). 기본값이 32767 인 이유는 그게
# **Windows Terminal 의 `historySize` 최대값**이라서다 — wt 는 그 이상을 가질 수 없고 CLI
# 로는 지정조차 안 되므로 (profile 설정), 맞출 수 있는 최댓값이 이 값이다. 우리 config
# 기본값 100,000 으로 재면 우리만 불리하다: 파서 층 실측으로 `plain` 이 100,000 → 9,000
# 에서 +45 % (294.6 → 427.8 MiB/s) 였다. 100,000 줄이면 작업 집합이 약 120 MB 다.
#
# **wt 는 이 값으로 맞출 수 없다** — `settings.json` 의 `profiles.defaults.historySize` 를
# 직접 고쳐야 한다. 스크립트는 그것을 대신 하지 않고 (사용자 설정 파일이다) 아래에서
# 안내만 한다. **conhost 는 아예 불가**다 (`mode con: lines` 가 창=버퍼).
SCROLLBACK=32767

# `--capture [디렉터리]` — **smoke 확인용**이다 (#381). 각 회차의 측정이 끝난 순간 화면을
# 찍어 `<디렉터리>/<이름>-<회차>.png` 로 남긴다. 창이 다른 창 뒤에 떠서 눈으로 확인할 수
# 없을 때 (Windows 에서 wezterm · wt 가 그랬다) 쓰라고 만든 것이다.
#
# **경로는 선택이다** — 안 주면 `dist/stress/shots` 에 남는다 (스크립트 바로 옆이라 찾기 쉽다).
# 모든 OS · 데스크톱 환경에서 같은 자리다.
#
# **이 옵션을 켜면 그 실행의 숫자는 기록용으로 쓰지 않는다.** 캡처 도구가 측정 직후에
# CPU 를 쓰고, producer 가 `HOLD_MS` 만큼 더 살아 있어서 다음 회차와 겹칠 수 있다.
# 기록용 측정 (`--repeat 5`) 은 이 옵션 없이 돈다.
CAPTURE_DIR=""
# 캡처가 끝날 때까지 producer 가 창을 붙들고 있는 시간. 고정값이고 **platform 을 안 가린다** —
# 값을 나누려면 각 platform 의 캡처 시간을 실측해야 하는데 그러지 않았다. 4 초는 아래 둘이다.
#   - 찍기 전 대기 `CAPTURE_DELAY` (2 초). timing 파일이 생긴 시점은 **측정이 끝난** 시점이지
#     창이 화면에 올라온 시점이 아니다 — wezterm 은 GUI 시작이 느려서 8 MiB 측정 (111 ms) 이
#     창보다 먼저 끝나는 회차가 있었고, 그 회차 캡처에 창이 아예 없었다 (macOS 실측).
#   - 캡처 자체에 2 초. macOS 는 0.3 초쯤이다 (실측). **Windows 는 안 재 봤다** — PowerShell
#     프로세스 시작과 `Add-Type` 의 C# 컴파일이 더 걸릴 수 있다. 모자라면 PNG 에 창이 안
#     찍히므로 바로 드러난다. 그때 실측값으로 올린다.
HOLD_MS=4000
# 측정이 끝나고 찍기까지 기다리는 시간 (초). 위 `HOLD_MS` 주석 참고.
CAPTURE_DELAY=2

# `--capture` 기본 위치를 정하는 데 필요해서 옵션 파싱보다 먼저 구한다.
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# 경로를 안 주면 여기에 남긴다 — **스크립트 바로 옆**이라 찾기 쉽다. platform 을 안 가린다.
# `.gitignore` 에 넣어 두어서 git 에는 안 잡힌다.
CAPTURE_DEFAULT_DIR="$REPO_ROOT/dist/stress/shots"

while [ $# -gt 0 ]; do
    case "$1" in
        --mb) MB="$2"; shift 2 ;;
        --workload) WORKLOAD="$2"; shift 2 ;;
        --cols) COLS="$2"; shift 2 ;;
        --rows) ROWS="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --repeat) REPEAT="$2"; shift 2 ;;
        --scrollback) SCROLLBACK="$2"; shift 2 ;;
        # 경로는 선택이다. 안 주면 `dist/stress/shots`. 다음 인자가 `-` 로 시작하면 옵션이므로
        # 경로로 보지 않는다.
        --capture)
            if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
                CAPTURE_DIR="$2"; shift 2
            else
                CAPTURE_DIR="$CAPTURE_DEFAULT_DIR"; shift 1
            fi
            ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$SCROLLBACK" in
    ''|*[!0-9]*) echo "--scrollback 은 0 이상의 정수여야 해요: $SCROLLBACK" >&2; exit 2 ;;
esac

case "$REPEAT" in
    ''|*[!0-9]*|0) echo "--repeat 은 1 이상의 정수여야 해요: $REPEAT" >&2; exit 2 ;;
esac

BYTES=$((MB * 1024 * 1024))

# --- platform ---
#
# Windows 는 **Git Bash** 에서 돌린다 (Git for Windows 에 항상 포함되므로 별도 설치가
# 필요 없다). 릴리즈 패키징이 Git Bash 를 요구하지 않는 것과는 다른 이야기다 — 이건 측정용
# 내부 도구다.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
    *) IS_WINDOWS=0 ;;
esac

# 캡처를 안 켜면 hold 는 0 이다 — producer 가 지금까지처럼 곧바로 끝난다.
if [ -z "$CAPTURE_DIR" ]; then
    HOLD_MS=0
else
    mkdir -p "$CAPTURE_DIR" || { echo "--capture 디렉터리를 만들 수 없어요: $CAPTURE_DIR" >&2; exit 2; }
fi

# 자식이 **Windows 실행파일**이면 경로를 Windows 형식으로 줘야 한다. MSYS 는 명령줄 인자를
# 자동 변환하지만 **환경변수 값은 변환하지 않는다** — producer 가 timing 파일을 열지 못하는
# 원인이 그것이다.
native_path() {
    if [ "$IS_WINDOWS" = 1 ]; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

PRODUCER="$REPO_ROOT/zig-out/bin/tildaz-stress"
[ "$IS_WINDOWS" = 1 ] && PRODUCER="$PRODUCER.exe"
WORK_DIR=$(mktemp -d)

# 우리가 띄운 터미널만 정리한다. **명령줄에 이 실행의 `WORK_DIR` 경로가 들어 있으므로**
# (timing 파일 · ghostty 임시 config) 그 패턴으로 우리 것만 골라 죽인다 — 사용자가 따로 열어
# 둔 kitty · ghostty 창은 건드리지 않는다. 스크립트 자신의 명령줄에는 이 경로가 없다.
#
# 왜 필요한가: 명령이 끝나도 **kitty 와 ghostty 는 창이 남는다** (macOS 실측, `--repeat 3` 에서
# 각 3 개씩 누적).
# - kitty 는 `--detach` 로 띄우므로 `kill $!` 이 잡는 것은 즉시 끝나는 부모다.
# - ghostty 는 `abnormal-command-exit-runtime` (기본 250 ms) 보다 빨리 끝난 명령을 실행 실패로
#   보고 "Press any key to close" 화면을 띄운다. 아래 임시 config 에서 이 값을 0 으로 끄지만,
#   그것과 무관하게 남는 경우까지 이 정리로 막는다.
# 남은 창은 다음 회차와 CPU 를 나눠 쓰므로 반복 측정을 오염시킨다.
# `pkill` 을 쓰지 않는다 — **Git Bash (Windows) 에는 없다** (별도로 MSYS2 의 `procps-ng` 를
# 설치해야 생긴다. 실기에서 확인했다). `ps` + `kill` 조합은 macOS · Linux 에서 확실하다.
#
# **Windows 는 당장 이 정리를 건너뛴다** — 필요한지, 어떻게 해야 하는지가 아직 확인되지 않았다.
# Git Bash 실기에서 본 것과 아직 모르는 것을 갈라 적는다 (#371).
#
# 확인된 것:
# - `ps -ef` 는 MSYS 프로세스만 보여준다 (`bash` · `mintty` · `ps` 자신). native Windows
#   프로세스는 `ps -W` 로 올라온다.
# - MSYS `ps` 는 `-o` 를 지원하지 않는다 (옵션이 `-a -e -f -h -l -p -s -u -v -W` 뿐이다).
#
# **확인 필요:** `ps -W` 의 COMMAND 에 **명령줄 인자가 나오는지.** 좁은 창에서는 exe 경로까지만
# 보였는데, `ps` 가 터미널 폭에서 잘라 출력하므로 그것이 "인자가 없다" 는 근거는 되지 못한다.
# 인자가 나온다면 아래 macOS · Linux 경로와 같은 방식 (`WORK_DIR` 패턴) 을 그대로 쓸 수 있고,
# 나오지 않는다면 PowerShell 의 `Get-CimInstance Win32_Process` 로 `CommandLine` 을 필터해야
# 한다. 이름 (`wt.exe`) 으로 죽이는 방법은 쓰지 않는다 — 사용자가 따로 열어 둔 창까지 죽는다.
# (`ps -W` 의 PID 가 부정확한 이슈도 있다 — msys2/MSYS2-packages#1724.)
#
# 그리고 **정리가 필요한지부터 확인해야 한다:**
# - 창이 남던 두 터미널 (kitty · ghostty) 은 Windows 판이 없어 이 문제의 대상이 아니다.
# - `wt` 는 프로필의 `closeOnExit` 가 기본값 `automatic` 이면 exit 0 인 명령 뒤에 스스로 닫는다.
#   사용자 프로필이 `never` 면 남을 수 있다.
# - alacritty · wezterm 은 macOS 실측에서 정상적으로 닫혔다 (같은 코드베이스).
# 남는다고 확인되면 그때 Windows 전용 정리를 붙인다 — 확인 전에 추측으로 코드를 넣지 않는다.
cleanup_terminals() {
    [ "$IS_WINDOWS" = 1 ] && return 0
    ps -eo pid,args 2>/dev/null | grep "$WORK_DIR" | grep -v grep | while read -r _p _rest; do
        kill "$_p" 2>/dev/null || true
    done
}
# --- wt 의 scrollback 을 맞추기 위한 설정 파일 교체 (#381, Windows 전용) ---------------
#
# **wt 는 `historySize` 를 CLI 로 못 받는다** — profile 설정이라 `settings.json` 뿐이다. 그래서
# 다른 대상과 scrollback 을 맞추려면 그 파일을 바꿔야 한다. 사용자 파일이므로 절차를 못 박는다.
#
#   1. 원본을 `<settings>.tildaz-compare-backup` 으로 **백업**
#   2. 측정 전용 **최소 설정**으로 교체 (`historySize` = `--scrollback`)
#   3. 끝나면 (`trap EXIT`) 백업에서 **복원**하고 백업 파일 삭제
#
# **crash 로 죽어도 복원된다** — 백업이 남아 있으면 다음 실행이 시작할 때 먼저 복원한다.
# 백업을 `WORK_DIR` 이 아니라 설정 파일 옆에 두는 이유가 그것이다 (`WORK_DIR` 은 trap 이 지운다).
#
# 최소 설정을 쓰는 이유는 두 가지다. 사용자 파일을 JSON 파싱하지 않아도 되고 (주석이 섞여 있을
# 수 있다), 폰트 · acrylic · 스킴 같은 사용자 커스터마이즈가 측정에 섞이지 않는다.
#
# ⚠ **wt 창이 열려 있으면 그 창의 설정도 잠시 바뀐다** (wt 가 파일 변경을 감시해 재적용한다).
# 측정이 끝나면 복원되지만 눈에 보이므로 실행 시 경고한다.
WT_SETTINGS=""
WT_BACKUP=""

wt_settings_find() {
    [ "$IS_WINDOWS" = 1 ] || return 1
    command -v wt >/dev/null 2>&1 || return 1
    [ -n "${LOCALAPPDATA:-}" ] || return 1
    _lad=$(cygpath -u "$LOCALAPPDATA" 2>/dev/null) || return 1
    for _p in \
        "$_lad/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json" \
        "$_lad/Packages/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json" \
        "$_lad/Microsoft/Windows Terminal/settings.json"
    do
        if [ -f "$_p" ]; then echo "$_p"; return 0; fi
    done
    return 1
}

wt_settings_apply() {
    WT_SETTINGS=$(wt_settings_find) || return 0
    WT_BACKUP="$WT_SETTINGS.tildaz-compare-backup"

    if [ -f "$WT_BACKUP" ]; then
        echo "⚠ 이전 실행이 남긴 wt 설정 백업이 있어요 (그 회차가 비정상 종료) — 먼저 복원해요"
        cp -f "$WT_BACKUP" "$WT_SETTINGS"
    fi
    cp -f "$WT_SETTINGS" "$WT_BACKUP" || { WT_BACKUP=""; return 0; }

    # guid 는 이 스크립트 전용 고정값이다 (사용자 프로필 guid 에 의존하지 않는다).
    cat > "$WT_SETTINGS" << EOF
{
    "\$schema": "https://aka.ms/terminal-profiles-schema",
    "defaultProfile": "{d0c1f3a2-0000-4000-8000-000000000381}",
    "actions": [],
    "schemes": [],
    "themes": [],
    "profiles":
    {
        "defaults":
        {
            "historySize": $SCROLLBACK
        },
        "list":
        [
            {
                "guid": "{d0c1f3a2-0000-4000-8000-000000000381}",
                "name": "tildaz-compare",
                "commandline": "cmd.exe",
                "hidden": false
            }
        ]
    }
}
EOF
    echo "wt 설정을 측정용으로 교체했어요 (historySize=$SCROLLBACK). 끝나면 복원해요."
    echo "  백업: $WT_BACKUP"
    # wt 는 파일 변경을 감시해 재적용한다. 쓰기 직후 곧바로 띄우면 옛 설정으로 뜰 수 있다.
    sleep 1
}

wt_settings_restore() {
    [ -n "$WT_BACKUP" ] || return 0
    [ -f "$WT_BACKUP" ] || return 0
    if cp -f "$WT_BACKUP" "$WT_SETTINGS"; then
        rm -f "$WT_BACKUP"
        echo "wt 설정을 원래대로 복원했어요."
    else
        echo "⚠ wt 설정 복원 실패 — 백업이 여기 있어요: $WT_BACKUP" >&2
    fi
}

trap 'cleanup_terminals; wt_settings_restore; rm -rf "$WORK_DIR"' EXIT

if [ ! -x "$PRODUCER" ]; then
    echo "producer 가 없어요: $PRODUCER" >&2
    echo "먼저 빌드해요: zig build stress -Doptimize=ReleaseFast -Dsimd=true -- throughput --mb 1" >&2
    exit 1
fi

echo "=== 터미널 처리량 비교 (#371 L4) ==="
echo "workload   $WORKLOAD"
echo "bytes      $BYTES ($MB MiB)"
echo "목표 그리드 ${COLS}x${ROWS}"
echo "scrollback ${SCROLLBACK} 줄 (모든 대상 동일 — 아래 예외 참고)"
echo "반복       ${REPEAT} 회"
echo "producer   $PRODUCER"
if [ -n "$CAPTURE_DIR" ]; then
    echo "캡처       $CAPTURE_DIR (회차마다 화면 PNG · hold ${HOLD_MS} ms)"
    echo ""
    echo "⚠ --capture 를 켠 실행의 숫자는 기록용으로 쓰지 마세요 — 캡처가 측정 직후에 CPU 를 쓰고"
    echo "  producer 가 창을 ${HOLD_MS} ms 더 붙들고 있어요. 기록용은 이 옵션 없이 --repeat 5 로 내요."
    case "$(uname -s)" in
        Darwin)
            echo "  macOS 는 **화면 기록 권한**이 필요해요. 잠금 화면이면 캡처가 실패해요."
            ;;
        MINGW*|MSYS*|CYGWIN*) ;;
        *)
            # 리눅스는 compositor 마다 통로가 달라서, 없으면 미리 알린다 — 다 돌고 나서
            # "한 장도 없다" 를 알게 되는 것보다 낫다.
            if command -v grim >/dev/null 2>&1; then
                echo "  캡처 도구: grim (wlroots 계열)"
            elif command -v spectacle >/dev/null 2>&1; then
                echo "  캡처 도구: spectacle (KDE Plasma)"
            elif command -v gnome-screenshot >/dev/null 2>&1; then
                echo "  캡처 도구: gnome-screenshot"
            else
                echo "  ⚠ 캡처 도구가 없어요 — grim (sway · Hyprland) 이나 spectacle (KDE) 을 설치해 주세요."
                echo "    Wayland 는 client 가 화면을 읽을 수 없어서 compositor 별 도구가 필요해요."
            fi
            ;;
    esac
fi
if [ "$IS_WINDOWS" = 1 ]; then
    # #381 — 맞출 수 없는 대상을 매 실행에서 알린다. 조용히 두면 표를 읽는 사람이 조건이
    # 같다고 오해한다 (그게 #381 에서 실제로 일어난 일이다).
    echo ""
    echo "⚠ conhost 는 scrollback 이 없어요 (mode con: lines 가 창=버퍼) — 이 대상만 조건이 달라요."
    if [ "$SCROLLBACK" -gt 32767 ]; then
        echo "⚠ --scrollback $SCROLLBACK 은 wt 의 최대값 32767 을 넘어요 — wt 는 32767 로 잘려요."
    fi
fi
echo ""
# wt 설정 교체는 측정 직전에 (헤더를 찍은 뒤) 한다 — 실패해도 헤더는 남는다.
wt_settings_apply
echo ""

# producer 를 셸 명령 한 줄로. 터미널마다 이 문자열을 자기 방식으로 실행한다.
# `exec` 로 셸을 대체해 셸이 남지 않게 한다.
producer_cmd() {
    printf 'env TILDAZ_STRESS_WORKLOAD=%s TILDAZ_STRESS_BYTES=%s TILDAZ_STRESS_TIMING_FILE=%s TILDAZ_STRESS_HOLD_MS=%s %s' \
        "$WORKLOAD" "$BYTES" "$(native_path "$1")" "$HOLD_MS" "$PRODUCER"
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

# --- 화면 캡처 (`--capture`) ---------------------------------------------------------
#
# **창 단위가 아니라 전체 화면**을 찍는다. 측정 중에는 대상 창이 하나만 떠 있어서 전체를
# 찍어도 그 창이 보이고, 창 하나를 특정하는 코드는 platform 마다 방식이 갈리는 데다 사용자가
# 따로 열어 둔 같은 앱 창과 구분하기가 어렵다. 아래 리눅스 도구들도 전체 화면이 기본이다.
#
# **Windows 만 찍기 직전에 대상 창을 앞으로 올린다** — 가려져 있으면 화면에 안 나오기 때문이다.
# `SWP_NOACTIVATE` 라 키보드 포커스는 뺏지 않는다. 별도 옵션으로 두지 않는다 — 캡처가 되게
# 하려는 수단이지 그 자체가 목적이 아니다.
#
# **리눅스는 하나로 다 되는 방법이 없다.** Wayland 는 client 가 화면을 읽을 수 없고 통로가
# compositor 마다 다르다. 되는 것을 순서대로 시도한다.
#   - `grim` — wlroots 계열 (sway · Hyprland). `zwlr_screencopy` 를 쓴다.
#   - `spectacle -a` — KDE Plasma. KWin 은 `zwlr_screencopy` 를 client 에게 노출하지 않아 grim 이
#     안 되고, `org.kde.KWin.ScreenShot2` 는 호출자를 검증해 직접 부를 수 없다. Spectacle 이
#     정상 통로다 (KDE 기본 설치). **`-a` 는 활성 창 하나만 찍어서 화면 단위인 grim 과 다르다.**
#   - `gnome-screenshot` — 있으면 쓴다 (GNOME 43 에서 빠졌다).
# 셋 다 없으면 찍지 않고 그 사실을 알린다. `xdg-desktop-portal` 은 표준이지만 권한 대화상자가
# 떠서 손 안 대고 도는 측정과 맞지 않는다.
CAPTURE_PS1="$WORK_DIR/capture.ps1"

# **macOS 는 창 단위로 찍는다.** 전체 화면을 찍으면 대상이 다른 창 뒤에 있을 때 안 보이는데,
# 그게 이 옵션을 만든 이유 자체다. ScreenCaptureKit 은 **완전히 가려진 창의 내용도** 준다
# (macOS 실측: 같은 자리에 창 둘을 겹쳐 놓고 아래 창을 찍어 확인했다 — 위 창이 아니라 아래
# 창의 내용이 나왔다). `dist/macos/color-capture.m` 을 그대로 쓴다 (#349 의 색 실측용 도구).
# clang 이 없거나 빌드가 안 되면 전체 화면으로 물러선다.
MAC_CAPTURE=""
if [ -n "$CAPTURE_DIR" ] && [ "$(uname -s)" = Darwin ] && command -v clang >/dev/null 2>&1 &&
   [ -f "$REPO_ROOT/dist/macos/color-capture.m" ]
then
    if clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit \
        -framework ImageIO -framework UniformTypeIdentifiers \
        -o "$WORK_DIR/color-capture" "$REPO_ROOT/dist/macos/color-capture.m" >/dev/null 2>&1
    then
        MAC_CAPTURE="$WORK_DIR/color-capture"
    fi
fi

# Windows 에서 그 대상의 창을 소유한 프로세스 이름. `wezterm` 은 실행 파일과 GUI 프로세스
# 이름이 다르다. 모르는 이름이면 빈 값 — 그때는 창을 올리지 않고 화면만 찍는다.
win_proc_name() {
    case "$1" in
        alacritty) printf 'alacritty' ;;
        wezterm) printf 'wezterm-gui' ;;
        tildaz) printf 'tildaz' ;;
        wt) printf 'WindowsTerminal' ;;
        conhost) printf 'conhost' ;;
        *) printf '' ;;
    esac
}

if [ -n "$CAPTURE_DIR" ] && [ "$IS_WINDOWS" = 1 ]; then
    # `Get-Process` 의 `StartTime` 으로 **이번 회차에 새로 뜬 창**만 고른다 — 사용자가 따로
    # 열어 둔 같은 앱 창을 건드리지 않기 위해서다. 못 찾으면 창을 올리지 않고 화면만 찍는다
    # (앞에 뜬 대상은 그래도 찍힌다).
    cat > "$CAPTURE_PS1" << 'EOF'
param([string]$Png, [string]$ProcName = "", [double]$SinceEpoch = 0)
$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class TzWin {
  [DllImport("user32.dll")]
  public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  public static readonly IntPtr TOPMOST = new IntPtr(-1);
  public static readonly IntPtr NOTOPMOST = new IntPtr(-2);
  // SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE — z-order 만 바꾸고 포커스는 안 건드린다.
  public const uint FLAGS = 0x0001 | 0x0002 | 0x0010;
}
"@
$h = [IntPtr]::Zero
if ($ProcName -ne "") {
    $since = [DateTimeOffset]::FromUnixTimeSeconds([long]$SinceEpoch).LocalDateTime
    $p = Get-Process -Name $ProcName |
         Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.StartTime -gt $since } |
         Sort-Object StartTime -Descending | Select-Object -First 1
    if ($p) {
        $h = $p.MainWindowHandle
        [void][TzWin]::SetWindowPos($h, [TzWin]::TOPMOST, 0, 0, 0, 0, [TzWin]::FLAGS)
        Start-Sleep -Milliseconds 200
    }
}
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$bmp.Save($Png, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()
if ($h -ne [IntPtr]::Zero) {
    [void][TzWin]::SetWindowPos($h, [TzWin]::NOTOPMOST, 0, 0, 0, 0, [TzWin]::FLAGS)
}
EOF
fi

# 한 회차의 화면을 찍는다. 실패해도 측정을 멈추지 않는다 — 찍힌 게 없다는 사실은
# 파일이 없는 것으로 알 수 있고, 표 옆에 표시도 남긴다.
capture_screen() {
    _png="$1"
    _ctarget="$2"
    _csince="$3"
    case "$(uname -s)" in
        Darwin)
            # 창 목록에서 그 앱의 **가장 큰 windowID** 를 고른다 — windowID 는 단조 증가하므로
            # 방금 뜬 창이다. 사용자가 따로 열어 둔 같은 앱의 창을 찍지 않기 위해서다.
            # 앱 이름은 대상 이름과 대소문자만 다르다 (`WezTerm` · `Ghostty` · `TildaZ`).
            _wid=""
            if [ -n "$MAC_CAPTURE" ]; then
                _wid=$("$MAC_CAPTURE" --list 2>/dev/null |
                    awk -v t="$_ctarget" 'index(tolower($2), t) == 1 { print $1 }' |
                    sort -n | tail -1)
            fi
            [ -n "$_wid" ] && { "$MAC_CAPTURE" --window "$_wid" "$_png" >/dev/null 2>&1 || true; }
            # 창을 못 찾았으면 전체 화면으로 물러선다 — 가려져 있으면 안 보이지만 없는 것보다 낫다.
            # `-x` 는 셔터음을 끈다. **화면 기록 권한**이 필요하고 잠금 화면이면 실패한다.
            [ -s "$_png" ] || screencapture -x "$_png" >/dev/null 2>&1 || true
            ;;
        MINGW*|MSYS*|CYGWIN*)
            powershell -NoProfile -ExecutionPolicy Bypass -File "$(native_path "$CAPTURE_PS1")" \
                -Png "$(native_path "$_png")" \
                -ProcName "$(win_proc_name "$_ctarget")" \
                -SinceEpoch "$_csince" >/dev/null 2>&1 || true
            ;;
        *)
            if command -v grim >/dev/null 2>&1; then
                grim "$_png" >/dev/null 2>&1 || true
            elif command -v spectacle >/dev/null 2>&1; then
                # KDE Plasma. **`-a` (활성 창) 라 창 단위로 찍힌다** — grim (화면 단위) 과 다르다.
                # 방금 뜬 창이 포커스를 받으므로 대개 대상이 잡히고, 활성 창은 맨 앞이라 가려짐
                # 문제도 없다. 대상이 활성이 아니면 엉뚱한 창이 찍히는데, 그건 PNG 을 보면 안다.
                # 확실히 하려면 KWin 스크립팅 (`org.kde.KWin.Scripting.loadScript` → `workspace
                # .activeWindow = w`) 으로 대상을 먼저 활성화해야 하는데, **정말 필요한지 확인
                # 되기 전에는 넣지 않는다** (#381).
                spectacle -b -n -a -o "$_png" >/dev/null 2>&1 || true
            elif command -v gnome-screenshot >/dev/null 2>&1; then
                gnome-screenshot -f "$_png" >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

# 캡처를 켰는데 PNG 이 안 만들어진 회차 수. 끝에서 한 번 안내한다.
CAPTURE_FAILED=0

RESULTS="$WORK_DIR/results"
: > "$RESULTS"

# 한 터미널을 `REPEAT` 회 돌리고, 회차별 경과 시간을 한 줄에 모아 적는다.
#
# 형식: 이름 <TAB> "ns ns ns …" <TAB> cols <TAB> rows <TAB> cols_start <TAB> rows_start
# 실패한 회차는 목록에서 빠진다 (한 회차도 못 얻으면 `skipped`).
run_terminal() {
    _name="$1"
    shift
    _timing="$WORK_DIR/$_name.timing"

    printf '%-14s ' "$_name"
    _samples=""
    _cols=0
    _rows=0
    _cols0=0
    _rows0=0
    _run=1
    while [ "$_run" -le "$REPEAT" ]; do
        # 회차마다 지운다 — 이전 회차 파일이 남아 있으면 `wait_for` 가 즉시 통과해 같은
        # 값을 다시 읽는다.
        rm -f "$_timing"
        # 캡처가 **이번 회차에 새로 뜬 창**만 고르도록 시작 시각을 남긴다 (Windows 에서만 쓴다).
        # 1 초 빼는 이유는 `date +%s` 가 초 단위라, 같은 초에 뜬 창이 비교에서 빠질 수 있어서다.
        _since=$(( $(date +%s) - 1 ))
        # 보통은 background 로 띄운다 — 창이 닫히기를 기다리면 멈추기 때문이다 (kitty 실측).
        # 단 conhost 는 foreground 로 띄운다. 아래 conhost 절의 wrapper `.cmd` 안 `start` 가 이미
        # 새 콘솔을 떼어 내므로 이 호출 자체는 곧바로 반환하고, background 로 둘 이유가 없다.
        # 죽일 pid 도 없다 — 창을 소유한 것은 `start` 가 띄운 conhost 이고 이 `cmd` 는 그것을
        # 띄우자마자 끝난다.
        #
        # (이전 주석은 원인을 `&` 로 적어 뒀는데 틀렸다 — `&` 가 아니라 **conhost 가 콘솔을
        # 상속받는 것**이 원인이었다. foreground 로 우연히 성공한 회차는 conhost 가 새 창을
        # 만든 것이 아니라 bash 콘솔 안에서 돈 것이라 conhost 창의 값도 아니었다. #382)
        if [ "$_name" = conhost ]; then
            "$@" >/dev/null 2>&1
            _pid=""
        else
            "$@" >/dev/null 2>&1 &
            _pid=$!
        fi
        if wait_for "$_timing"; then
            _samples="$_samples $(sed -n 's/^elapsed_ns=//p' "$_timing")"
            _cols=$(sed -n 's/^cols=//p' "$_timing")
            _rows=$(sed -n 's/^rows=//p' "$_timing")
            _cols0=$(sed -n 's/^cols_start=//p' "$_timing")
            _rows0=$(sed -n 's/^rows_start=//p' "$_timing")
            # producer 가 `HOLD_MS` 만큼 창을 붙들고 있는 동안 찍는다. 곧바로 찍지 않고
            # `CAPTURE_DELAY` 만큼 기다린다 — timing 이 생긴 시점은 측정이 끝난 시점이지 창이
            # 화면에 올라온 시점이 아니다 (위 `HOLD_MS` 주석).
            if [ -n "$CAPTURE_DIR" ]; then
                sleep "$CAPTURE_DELAY"
                _png="$CAPTURE_DIR/$_name-$_run.png"
                capture_screen "$_png" "$_name" "$_since"
                if [ -s "$_png" ]; then printf '@'; else CAPTURE_FAILED=$((CAPTURE_FAILED + 1)); printf '!'; fi
            else
                printf '.'
            fi
        else
            printf 'x'
        fi
        # 캡처를 켜면 producer 가 `HOLD_MS` 만큼 더 살아 있다. 그걸 중간에 죽이면 셸이
        # `Terminated: 15` 를 표 위에 찍어 결과를 읽기 어렵게 만든다 (macOS 실측). 스스로
        # 끝나기를 기다렸다가 정리한다 — 어차피 그때까지 창이 살아 있어야 캡처가 된다.
        if [ -n "$CAPTURE_DIR" ] && [ -n "$_pid" ]; then
            wait "$_pid" 2>/dev/null || true
        fi
        # 창이 남아 있으면 정리한다. `kill $_pid` 만으로는 부족하다 — kitty 는 `--detach` 라
        # 그 pid 가 즉시 끝나는 부모이고, ghostty 는 실행 실패 화면을 띄운 채 기다린다.
        # `cleanup_terminals` 가 이 실행의 `WORK_DIR` 패턴으로 실제 창을 정리한다.
        [ -n "$_pid" ] && kill "$_pid" 2>/dev/null || true
        cleanup_terminals
        _run=$((_run + 1))
    done

    if [ -z "$_samples" ]; then
        printf ' timeout / 실행 안 됨\n'
        printf '%s\tskipped\t0\t0\t0\t0\n' "$_name" >> "$RESULTS"
        return
    fi
    printf ' ok  %sx%s\n' "$_cols" "$_rows"
    # 앞의 공백을 없애 awk 가 필드를 세기 쉽게 한다.
    _samples=$(printf '%s' "$_samples" | sed 's/^ *//')
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_name" "$_samples" "$_cols" "$_rows" "$_cols0" "$_rows0" >> "$RESULTS"
}

# Windows 전용 — producer 를 sh 로 감싸지 않고 직접 실행한다. env 는 이 함수가 subshell 안에서
# export 해 자식(터미널 → producer)에게 상속시킨다. 두 가지를 함께 피하려는 것이다.
#   - alacritty · wezterm 은 MSYS sh 를 ConPTY 로 띄우지 못한다 — `-e sh` 는 sh 진입 자체가 안
#     되는데 (`-e ping` 은 정상) wt · conhost 는 sh 가 잘 돈다. 실기에서 확인했다.
#   - sh -c 에 넘기면 native_path (cygpath -w) 의 백슬래시 경로 (C:\Users\…) 가 sh 의 escape 로
#     뭉개져 (C:Users…) producer 가 timing 을 엉뚱한 상대경로에 쓴다.
# tildaz 가 쓰는 방식과 같다 — 터미널이 받는 command 는 native producer 경로 하나뿐이다.
# 회차마다 지우는 timing 경로는 run_terminal 이 `$_name` 으로 만드므로 여기 export 값과 같다.
run_terminal_win() {
    _wname="$1"
    shift
    (
        export TILDAZ_STRESS_WORKLOAD="$WORKLOAD"
        export TILDAZ_STRESS_BYTES="$BYTES"
        export TILDAZ_STRESS_TIMING_FILE="$(native_path "$WORK_DIR/$_wname.timing")"
        export TILDAZ_STRESS_HOLD_MS="$HOLD_MS"
        run_terminal "$_wname" "$@"
    )
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
        -o "scrollback_lines=$SCROLLBACK" \
        sh -c "$(producer_cmd "$T")"
fi

if command -v alacritty >/dev/null 2>&1; then
    T="$WORK_DIR/alacritty.timing"
    if [ "$IS_WINDOWS" = 1 ]; then
        run_terminal_win alacritty alacritty \
            -o "window.dimensions.columns=$COLS" \
            -o "window.dimensions.lines=$ROWS" \
            -o "scrolling.history=$SCROLLBACK" \
            -e "$(native_path "$PRODUCER")"
    else
        run_terminal alacritty alacritty \
            -o "window.dimensions.columns=$COLS" \
            -o "window.dimensions.lines=$ROWS" \
            -o "scrolling.history=$SCROLLBACK" \
            -e sh -c "$(producer_cmd "$T")"
    fi
fi

if command -v wezterm >/dev/null 2>&1; then
    T="$WORK_DIR/wezterm.timing"
    # `--config` 는 **전역 옵션**이라 `start` 앞에 와야 한다 (`wezterm --help`).
    # `start` 뒤에 두면 실행 자체가 안 된다.
    # `enable_tab_bar=false` — wezterm 은 탭바를 켜면 그 높이만큼 터미널 행이 줄어든다
    # (Windows 실기: `initial_rows=40` 이 120x38 로 떴다). 탭바를 끄면 요청 격자가 그대로 나와
    # 다른 터미널(탭바 없는 alacritty·wt)과 공정하게 비교된다. macOS 는 탭바를 네이티브 title
    # bar 에 그려 원래 행을 안 먹지만, 꺼도 결과는 같다.
    #
    # **`--always-new-process` 가 필수다.** `wezterm start` 는 기본이 *이미 떠 있는 wezterm GUI
    # 인스턴스에게 명령 실행을 요청* 하는 것이다 (`wezterm start --help`). 붙어 버리면 두 가지가
    # 깨진다.
    #   - 사용자가 열어 둔 창과 **같은 프로세스**를 쓰게 되어 CPU 를 나눠 쓴다. 반복 측정에서는
    #     회차 사이에 프로세스가 재사용돼 wezterm 만 **워밍업된 상태**로 재게 된다 — 다른 넷은
    #     매 회차 새 프로세스다.
    #   - 위의 `--config` 오버라이드가 기존 인스턴스에는 안 먹을 수 있다.
    # 이 플래그를 주면 이 호출이 producer 완료까지 블록되는데, `run_terminal` 이 background 로
    # 띄우고 timing 파일을 폴링하므로 상관없다. 오히려 `kill $_pid` 가 실제 GUI 를 잡게 된다.
    #
    # Windows 만 `wezterm-gui` 를 직접 부른다 — `wezterm.exe` 는 콘솔용 런처라 GUI 를 **손자
    # 프로세스**로 띄우는데, Win32 는 *foreground 프로세스가 직접 시작한 프로세스* 에만 창을 앞으로
    # 낼 권한을 준다 ([SetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow)).
    # 그래서 wezterm 창만 다른 창 뒤에 떠서 상태를 볼 수 없는 일이 생겼다 (#381 실기 관찰).
    # 인자 규격은 `wezterm` 과 같다 (`wezterm-gui --help` — `--config` 전역 옵션 + `start`).
    # 없는 환경이면 그대로 `wezterm` 을 쓴다.
    WEZTERM_BIN=wezterm
    if [ "$IS_WINDOWS" = 1 ] && command -v wezterm-gui >/dev/null 2>&1; then
        WEZTERM_BIN=wezterm-gui
    fi
    if [ "$IS_WINDOWS" = 1 ]; then
        run_terminal_win wezterm "$WEZTERM_BIN" \
            --config "initial_cols=$COLS" \
            --config "initial_rows=$ROWS" \
            --config "scrollback_lines=$SCROLLBACK" \
            --config "enable_tab_bar=false" \
            --config "window_padding={left=0,right=0,top=0,bottom=0}" \
            start --always-new-process -- "$(native_path "$PRODUCER")"
    else
        run_terminal wezterm "$WEZTERM_BIN" \
            --config "initial_cols=$COLS" \
            --config "initial_rows=$ROWS" \
            --config "scrollback_lines=$SCROLLBACK" \
            --config "enable_tab_bar=false" \
            --config "window_padding={left=0,right=0,top=0,bottom=0}" \
            start --always-new-process -- sh -c "$(producer_cmd "$T")"
    fi
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
    # `abnormal-command-exit-runtime = 0` — ghostty 는 이 값 (기본 250 ms) 보다 빨리 끝난 명령을
    # **실행 실패로 보고** "Ghostty failed to launch the requested command … Press any key to
    # close the window." 화면을 띄운 채 창을 유지한다. producer 는 정상 종료 (exit 0) 인데도
    # 짧은 측정에서는 그 조건에 걸려서, 반복 측정 때 창이 회차만큼 쌓인다 (macOS 실측: 8 MiB
    # 측정이 136 ms → `--repeat 3` 에서 창 3 개). 0 으로 두면 그 판정을 끈다.
    cat > "$GHOSTTY_CONF" << EOF
window-save-state = never
window-width = $COLS
window-height = $ROWS
scrollback-limit = $SCROLLBACK
abnormal-command-exit-runtime = 0
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
        "TILDAZ_STRESS_HOLD_MS=$HOLD_MS" \
        "$TILDAZ_BIN" -e "$(native_path "$PRODUCER")" -size "${COLS}x${ROWS}" \
        -scrollback "$SCROLLBACK"
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
    # 표 이름은 실행 파일명 `wt` 를 쓴다 — "windows-terminal" 은 표의 이름 칸 (14) 을 넘겨
    # 줄이 밀린다.
    run_terminal_win wt wt -w new --size "$COLS,$ROWS" \
        "$(native_path "$PRODUCER")"
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
# **`conhost.exe` 는 새 콘솔을 받아야 명령을 실행한다** (#382, Windows 실기). 호출한 프로세스의
# 콘솔을 상속받으면 명령을 돌리지 않고 조용히 exit 0 으로 끝난다 — Git Bash 에서 `conhost` 를
# 그냥 부르면 bash 의 콘솔을 물려받으므로 이 경로에 걸려서 timing 이 안 생기고, `wait_for` 가
# `TIMEOUT` × `--repeat` 만큼 (기본값이면 15 분) 멈춰 있었다. 그래서 아래 wrapper `.cmd` 의
# `start` 로 새 콘솔을 떼어 준다.
#
# **조건이 완전히 같지 않다는 점을 감안해서 읽어야 한다.** conhost 는 창 크기 옵션이 없어서
# `mode con` 으로 격자를 주는데, `lines=N` 이 창과 버퍼를 함께 N 으로 만들어 **스크롤백이
# 없다.** 다른 터미널에는 `--scrollback` 값을 주므로 conhost 값에는 스크롤백 관리 비용이 빠져 있다.
if [ "$IS_WINDOWS" = 1 ] && command -v conhost >/dev/null 2>&1; then
    T="$WORK_DIR/conhost.timing"
    # conhost 는 임시 `.cmd` 파일로 띄운다. 인라인 `cmd //c "… set \"VAR=값\" …"` 로 넘기면
    # `set` 의 큰따옴표가 바깥 따옴표와 중첩돼 명령이 깨져 producer 가 안 돈다 (Windows 실기:
    # timing 이 안 생겨 표에서 conhost 줄이 멈췄다). 파일이면 그 중첩이 없다. 두 가지가 더 있다.
    #   - `/c` 가 아니라 `//c` 다 — MSYS 가 인자 `/c` 를 Windows 경로 `C:\` 로 자동 변환하므로
    #     (tasklist `//v` 와 같은 회피).
    #   - `.cmd` 는 CRLF 로 쓴다 (cmd 관습). producer stdout 은 리다이렉트하지 않는다 — 콘솔이
    #     stdout 이라야 producer 가 `GetConsoleScreenBufferInfo` 로 격자를 읽는다. 리다이렉트하면
    #     그 호출이 실패해 timing 에 `cols=0 rows=0` 이 찍히고 격자 검증에서 버려진다.
    _conhost_cmd="$WORK_DIR/conhost.cmd"
    {
        printf 'mode con: cols=%s lines=%s\r\n' "$COLS" "$ROWS"
        printf 'set "TILDAZ_STRESS_WORKLOAD=%s"\r\n' "$WORKLOAD"
        printf 'set "TILDAZ_STRESS_BYTES=%s"\r\n' "$BYTES"
        printf 'set "TILDAZ_STRESS_TIMING_FILE=%s"\r\n' "$(native_path "$T")"
        printf 'set "TILDAZ_STRESS_HOLD_MS=%s"\r\n' "$HOLD_MS"
        printf '"%s"\r\n' "$(native_path "$PRODUCER")"
    } > "$_conhost_cmd"
    # wrapper 한 겹 — `start` 가 conhost 에 새 콘솔을 준다 (위 문단). `.cmd` 파일에 두는 이유는
    # 안쪽 `.cmd` 경로의 백슬래시와 따옴표가 bash → cmd 를 지나며 뭉개지지 않게 하려는 것으로,
    # `_conhost_cmd` 를 파일로 두는 것과 같은 이유다.
    #
    # **`/wait` 는 쓰지 않는다.** 동작은 하지만 호출이 producer 가 끝날 때까지 블록되어 producer
    # 가 멈추면 `wait_for` 의 타임아웃이 아예 작동하지 못한다 — 이 버그의 증상 (무한 대기) 을
    # 다시 만드는 형태다. `start` 만 쓰면 호출이 곧바로 반환하고 타임아웃 책임이 `wait_for` 에
    # 남아, 다른 네 터미널과 의미가 같아진다 (띄우고 timing 파일을 폴링).
    _conhost_launch="$WORK_DIR/conhost-launch.cmd"
    {
        printf '@echo off\r\n'
        printf 'start "" "%%windir%%\\system32\\conhost.exe" cmd /c "%s"\r\n' "$(native_path "$_conhost_cmd")"
    } > "$_conhost_launch"
    run_terminal conhost cmd //c "$(native_path "$_conhost_launch")"
fi

# foot 은 Wayland 전용이라 Linux 에서만 있다.
if command -v foot >/dev/null 2>&1; then
    T="$WORK_DIR/foot.timing"
    run_terminal foot foot --window-size-chars="${COLS}x${ROWS}" \
        sh -c "$(producer_cmd "$T")"
fi

# --- 표 ---

echo ""
# 대표값은 **min · max 를 뺀 나머지의 평균 (절사평균)** 이다 (#371 의 측정 프로토콜).
# 5 회에서 중간값은 사실상 1 개 샘플이라 그 값 자체가 흔들리고, 단순 평균은 이상치 하나에
# 끌려간다. `min~max` 를 함께 내는 것이 핵심이다 — 대표값만 보면 12 % 폭 안의 차이를 읽는
# 사람이 유의미하다고 오해한다 (macOS 실측에서 같은 조건 3 회가 115.0 / 124.2 / 128.7 MiB/s).
if [ "$REPEAT" -ge 3 ]; then
    STAT_LABEL="절사평균 (min·max 제외 $((REPEAT - 2)) 개)"
elif [ "$REPEAT" = 2 ]; then
    STAT_LABEL="단순 평균 (2 회 — 절사할 수 없어요)"
else
    STAT_LABEL="1 회 측정 (반복 없음 — 흔들림을 알 수 없어요)"
fi
echo "대표값: $STAT_LABEL"
printf '%-14s %12s %10s %17s %10s  %s\n' terminal ms MiB/s "min~max MiB/s" grid 비고
printf '%s\n' "--------------------------------------------------------------------------------------"
while IFS="$(printf '\t')" read -r name samples cols rows cols0 rows0; do
    if [ "$samples" = "skipped" ] || [ -z "$samples" ]; then
        printf '%-14s %12s %10s %17s %10s  %s\n' "$name" - - - - "측정 실패"
        continue
    fi
    # 절사평균 · min · max 를 한 번에 낸다. 표본이 3 개 미만이면 절사하지 않는다 —
    # **조용히 다른 통계로 바꾸지 않고** 위의 `STAT_LABEL` 이 그 사실을 적는다.
    stats=$(printf '%s\n' "$samples" | awk -v bytes="$BYTES" '{
        n = 0
        for (i = 1; i <= NF; i++) v[n++] = $i
        for (i = 0; i < n - 1; i++) for (j = 0; j < n - 1 - i; j++)
            if (v[j] > v[j+1]) { t = v[j]; v[j] = v[j+1]; v[j+1] = t }
        lo = 0; hi = n - 1
        if (n >= 3) { lo = 1; hi = n - 2 }
        sum = 0
        for (i = lo; i <= hi; i++) sum += v[i]
        mean_ns = sum / (hi - lo + 1)
        mib = bytes / 1048576
        # 시간이 길수록 MiB/s 는 작으므로 min / max 가 뒤집힌다.
        printf "%.1f %.1f %.1f %.1f %d", mean_ns/1000000, mib/(mean_ns/1000000000), \
            mib/(v[n-1]/1000000000), mib/(v[0]/1000000000), n
    }')
    ms=$(printf '%s' "$stats" | cut -d" " -f1)
    rate=$(printf '%s' "$stats" | cut -d" " -f2)
    rate_min=$(printf '%s' "$stats" | cut -d" " -f3)
    rate_max=$(printf '%s' "$stats" | cut -d" " -f4)
    got=$(printf '%s' "$stats" | cut -d" " -f5)
    note=""
    if [ "$cols" != "$COLS" ] || [ "$rows" != "$ROWS" ]; then
        note="그리드 불일치 — 비교 불가"
    elif [ "$cols0" != "$cols" ] || [ "$rows0" != "$rows" ]; then
        # 출력 도중에 창 크기가 바뀌었다는 뜻이다 (터미널이 셸 spawn 뒤 resize).
        note="측정 중 resize (${cols0}x${rows0} → ${cols}x${rows})"
    fi
    # 요청한 회차를 다 얻지 못했으면 그 사실을 적는다 (조용히 적은 표본으로 평균 내지 않는다).
    if [ "$got" != "$REPEAT" ]; then
        note="${note}${note:+ · }$got/$REPEAT 회만 성공"
    fi
    printf '%-14s %12s %10s %17s %10s  %s\n' \
        "$name" "$ms" "$rate" "$rate_min~$rate_max" "${cols}x${rows}" "$note"
done < "$RESULTS"

# --- 마무리 ---

echo ""
echo "timing 파일의 cols/rows 가 ${COLS}x${ROWS} 인지 표에서 확인해 주세요 — 다르면 그"
echo "숫자는 비교할 수 없어요. 탭이 2 개 이상이면 탭바 (28 pt) 가 들어가 rows 가 줄어요."

if [ -n "$CAPTURE_DIR" ]; then
    echo ""
    echo "캡처 (진행 표시의 @ = PNG 생성됨 · ! = 실패): $CAPTURE_DIR"
    echo "⚠ @ 는 **파일이 생겼다**는 뜻이지 창이 찍혔다는 보장이 아니에요 — 전체 화면으로 물러선"
    echo "  경우 (macOS 에서 창을 못 찾음 · 리눅스 전체) 대상이 다른 창 뒤에 있으면 안 보여요."
    echo "  PNG 을 눈으로 확인해 주세요."
    if [ "$CAPTURE_FAILED" -gt 0 ]; then
        echo "⚠ ${CAPTURE_FAILED} 회차가 안 찍혔어요. 권한 (macOS 화면 기록) · 캡처 도구 유무 (리눅스) ·"
        echo "  hold (${HOLD_MS} ms) 안에 캡처가 못 끝났는지를 보세요."
    fi
fi
