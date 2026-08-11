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
# **wt 도 이 값으로 맞춘다** — `historySize` 가 profile 설정이라 CLI 로는 못 주지만, JSON
# fragment 로 측정용 프로필을 더해 거기에 담는다 (아래 `wt_fragment_apply`). 사용자
# `settings.json` 은 건드리지 않는다. **conhost 는 아예 불가**다 (`mode con: lines` 가 창=버퍼).
SCROLLBACK=32767

# `--capture [디렉터리]` — **smoke 확인용**이다 (#381). 각 회차의 측정이 끝난 순간 화면을
# 찍어 `<디렉터리>/<워크로드>-<이름>-<회차>.png` 로 남긴다. 창이 다른 창 뒤에 떠서 눈으로
# 확인할 수 없을 때 (Windows 에서 wezterm · wt 가 그랬다) 쓰라고 만든 것이다.
#
# **파일명이 워크로드로 시작하는 이유** — 워크로드를 바꿔 가며 같은 디렉터리에 여러 번 찍는 게
# 정상 사용법인데 (`zwj` 로 한 번, `cjk` 로 한 번), 이름에 워크로드가 없으면 뒤 실행이 앞
# 실행을 덮어써서 비교할 수가 없다. 이름순 정렬도 워크로드끼리 묶여서 보기 좋다.
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
#   - 캡처 자체에 2 초. **macOS 0.3 초 · Windows 0.73 초**다 (둘 다 실측 — Windows 값은
#     PowerShell 프로세스 시작과 `Add-Type` 의 C# 컴파일을 포함한다).
#
# **이 값이 모자라면 PNG 에 창이 없다** — 찍을 때 producer 가 이미 창을 놓은 것이다. 화면이 크면
# 캡처 비용이 그만큼 커져서 [#413](https://github.com/ensky0/tildaz/issues/413) 에서 실제로 걸렸다
# (2880x1800 · 200 % 에서 tildaz 가 `~`. 이 값만 늘리자 `@` 가 됐다). 그래서 두 가지를 뒀다 —
# `--hold-ms` 로 바꿀 수 있고, 실패하면 `CAPTURE_RETRY_HOLD_MS` 로 그 회차를 한 번 다시 찍는다.
HOLD_MS=4000
# 측정이 끝나고 찍기까지 기다리는 시간 (초). 위 `HOLD_MS` 주석 참고.
CAPTURE_DELAY=2
# 캡처가 `~` (전체 화면으로 물러섬) · `_` (빈 이미지) 로 끝난 회차를 다시 찍을 때 쓸 hold.
#
# **`?` (창을 못 찾음) 는 재시도하지 않는다.** 그건 타이밍이 아니라 **창을 못 고른** 것이라
# hold 를 늘리면 오히려 나빠진다 — wt 는 `wt -w new` 가 기존 프로세스에 창을 요청하고 곧바로
# 반환해서, 앞 회차 창이 오래 남아 있으면 새 프로세스가 안 뜨고 `StartTime` 필터에 걸린다
# (#413 실측: hold 15 초에서 wt 3 회차 중 2 회차가 `?` 였다. 기본 4 초에서는 안 났다).
CAPTURE_RETRY_HOLD_MS=15000

# 위생 점검에 걸려도 강행할지 (`--ignore-hygiene`).
IGNORE_HYGIENE=0

# `--capture` 기본 위치를 정하는 데 필요해서 옵션 파싱보다 먼저 구한다.
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# 측정 위생은 `measure-repeat.sh` 와 **같은 로직**을 쓴다.
. "$REPO_ROOT/dist/stress/hygiene.sh"
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
        # 표기는 `measure-repeat.sh` 와 맞춘다 (그쪽에 이미 `--hold-ms` 가 있다).
        --hold-ms) HOLD_MS="$2"; shift 2 ;;
        # 경로는 선택이다. 안 주면 `dist/stress/shots`. 다음 인자가 `-` 로 시작하면 옵션이므로
        # 경로로 보지 않는다.
        --capture)
            if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
                CAPTURE_DIR="$2"; shift 2
            else
                CAPTURE_DIR="$CAPTURE_DEFAULT_DIR"; shift 1
            fi
            ;;
        # 위생 점검 (worker · AC · 주사율 · 배경 앱) 에 걸려도 강행한다. 동작 확인용이고
        # 기록용 측정에는 쓰지 않는다.
        --ignore-hygiene) IGNORE_HYGIENE=1; shift ;;
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
# macOS 전용 대상 (iTerm2) 을 고르는 데 쓴다. Windows 의 `wt` · Linux 의 `foot` 과 같은
# 자리다 — 그 platform 사람들이 실제로 쓰는 터미널이라 빠지면 비교가 개발자 취향 쪽으로만 쏠린다.
case "$(uname -s)" in
    Darwin) IS_MACOS=1 ;;
    *) IS_MACOS=0 ;;
esac

# 캡처를 안 켜면 hold 는 0 이다 — producer 가 지금까지처럼 곧바로 끝난다.
if [ -z "$CAPTURE_DIR" ]; then
    HOLD_MS=0
else
    mkdir -p "$CAPTURE_DIR" || { echo "--capture 디렉터리를 만들 수 없어요: $CAPTURE_DIR" >&2; exit 2; }
    # hold 가 `CAPTURE_DELAY` 이하면 **찍으러 갈 때 창이 이미 없다** — 구조적으로 한 회차도
    # 창 단위로 못 찍는다. 재시도가 있어도 첫 시도를 통째로 버리는 셈이라 미리 막는다.
    # (실기에서 `--hold-ms 1500` 을 주고 다섯 대상이 전부 `?` 로 떨어지는 것을 봤다.)
    if [ "$HOLD_MS" -le $(( CAPTURE_DELAY * 1000 )) ]; then
        echo "--hold-ms 는 $(( CAPTURE_DELAY * 1000 + 1 )) 이상이어야 해요 (찍기 전 ${CAPTURE_DELAY} 초를 기다려요)." >&2
        echo "  준 값: ${HOLD_MS} ms" >&2
        exit 2
    fi
fi

# 자식이 **Windows 실행파일**이면 경로를 Windows 형식으로 줘야 한다. MSYS 는 명령줄 인자를
# 자동 변환하지만 **환경변수 값은 변환하지 않는다** — producer 가 timing 파일을 열지 못하는
# 원인이 그것이다.
native_path() {
    if [ "$IS_WINDOWS" = 1 ]; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# **Windows 창 단위 캡처는 `PrintWindow` 하나다.**
#
# 예전에는 ffmpeg 의 `ddagrab` (Desktop Duplication API) 으로 창 rect 만 잘라 찍는 2 차 경로가
# 있었다. `PrintWindow` 가 환경에 따라 깨진다고 봤기 때문인데, 그 전제가
# [#413](https://github.com/ensky0/tildaz/issues/413) 에서 **반증됐다** — 깨진 것이 아니라
# **캡처가 `HOLD_MS` 를 넘겨 창이 이미 닫힌 뒤에 찍고 있었다.**
#
# 근거 (AMD Ryzen AI 7 350 · 2880x1800 · 200 %, #413 코멘트 ②③):
#
# | hold | 표본 (대상 x 회차) | `PrintWindow` 실패 |
# |---|---|---|
# | 넉넉 (15 초) | 18 | **0 건** |
# | 기본 (4 초) | 5 | 1 건 |
#
# 넉넉한 hold 에서는 다섯 대상이 전부 `PrintWindow` 로 찍힌다. 그래서 2 차 경로를 지웠다. 지우면
# **캡처가 빨라져 타임아웃 자체가 줄고** (그 경로가 1.18 초를 먹었다), ffmpeg 의존 · 창을 맨 앞으로
# 올리기 · 주 모니터 원점 가드 · 다중 모니터 미검증 · HDR 미검증이 함께 없어진다. 대신 hold 를
# `--hold-ms` 로 조절하고, 실패한 회차는 `CAPTURE_RETRY_HOLD_MS` 로 한 번 다시 찍는다.

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
# Terminal.app 측정 창에 붙이는 태그 (#414). 값은 아래 Terminal.app 절에서 채운다.
# **비어 있으면 이 실행에서 Terminal.app 을 안 띄웠다는 뜻**이라 창을 닫으러 가지 않는다 —
# 떠 있지도 않은 Terminal.app 을 osascript 가 깨우면 측정 도중에 앱 하나가 새로 뜬다.
TERMINAL_APP_TAG=""

# 우리가 태그를 붙인 Terminal.app 창만 닫는다.
#
# **닫기 전에 그 창의 프로세스가 죽어 있어야 한다.** 실행 중인 셸이 있는 창을 닫으려 하면
# Terminal.app 이 확인 시트 (`취소` / `종료`) 를 띄우는데, 시트가 응답을 기다리는 동안 창은
# 안 닫히고 **뒤따르는 close 가 전부 무시된다** (macOS 실측, #414 — 네 번을 반복해도 창이
# 그대로였고 `System Events` 로 보고서야 시트가 원인인 것을 알았다). 시트를 승인하려면
# Accessibility 권한이 필요하고 버튼 이름이 로케일 의존이라 자동화로 쓸 수 없다.
#
# 그래서 호출부인 `cleanup_terminals` 는 `ps` 로 프로세스를 먼저 죽인 **뒤에** 이걸 부른다.
# 측정 창 자체도 `exec` 로 로그인 셸을 대체해 (아래 Terminal.app 절) producer 가 끝나면
# 남는 프로세스가 없다.
#
# 태그로만 찾으므로 **사용자가 따로 열어 둔 창은 후보에 들어가지 않는다.**
terminal_app_close() {
    [ -n "$TERMINAL_APP_TAG" ] || return 0
    osascript -e "tell application \"Terminal\" to close (every window whose custom title is \"$TERMINAL_APP_TAG\")" \
        >/dev/null 2>&1 || true
}

# iTerm2 측정 창도 우리가 닫는다 (#414).
#
# 프로파일의 `Close Sessions On End` 는 **세션만** 닫아서 **빈 창이 남는다.** 회차마다 쌓이고,
# 다음 실행의 위생 검사 (`hygiene_running_terminals`) 에도 계속 걸린다.
#
# 창 이름이 곧 프로파일 이름이라 그것으로 우리 창만 고른다 — 사용자가 열어 둔 창은 이름이
# 달라서 후보에 안 들어간다 (실측: `[tildaz-stress]` 와 `[-bash]` 가 이름으로 갈렸다).
#
# **AppleScript 의 `windows` 목록에는 닫은 뒤에도 항목이 남을 수 있다.** 실제로 닫혔는지는
# ScreenCaptureKit 의 창 목록으로 확인했다 (화면에서 사라진다). Terminal.app 도 같다.
ITERM_WINDOW_OPENED=0
# 프로파일 이름이자 **창 이름**이다 (iTerm2 가 프로파일 이름을 창 제목으로 쓴다). wt 의
# `WT_PROFILE_NAME` 과 같은 자리이고, 아래 프로파일 JSON · 창 생성 · 창 정리가 모두 이 값을 쓴다.
ITERM_PROFILE_NAME="tildaz-stress"
iterm2_window_close() {
    [ "$ITERM_WINDOW_OPENED" = 1 ] || return 0
    osascript -e "tell application \"iTerm\" to close (every window whose name is \"$ITERM_PROFILE_NAME\")" \
        >/dev/null 2>&1 || true
}

# 측정 창을 만든 **뒤** 그 앱의 hide 를 푼다 (#414). macOS 전용이다.
#
# 위생 절차가 배경 앱을 hide 하는데 (`hygiene.sh` 의 `hygiene_minimize_macos`), **이미 떠
# 있던 앱에 창을 붙이는 두 대상 (Terminal.app · iTerm2) 은 그 hide 를 그대로 물려받는다.**
# hide 된 앱의 창은 화면에 올라오지 않아서 두 가지가 깨진다.
#
#   - **캡처** — `--list` 는 `onScreen` 인 창만 낸다. 목록에 없으니 전체 화면으로 물러선다.
#   - **측정 자체** — 그리지 않는 창은 렌더 부하가 빠진다. 새 프로세스로 떠서 화면에 올라오는
#     다른 대상들과 조건이 달라지므로, 이 대상만 유리해진다.
#
# `set visible to true` 는 **hide 만 풀고 앞으로 가져오지는 않는다** — 포커스를 뺏지 않는다
# (실측으로 확인). 가려져 있어도 ScreenCaptureKit 은 창 내용을 준다.
#
# Automation 권한이 없으면 조용히 실패하고 지금까지와 똑같이 동작한다.
mac_app_unhide() {
    osascript -e "tell application \"System Events\" to set visible of process \"$1\" to true" \
        >/dev/null 2>&1 || true
}

cleanup_terminals() {
    # 회차 정리는 그 대상 이름을 준다. EXIT trap 은 안 준다 (아래 참고).
    _ct_name="${1:-}"
    [ "$IS_WINDOWS" = 1 ] && return 0
    ps -eo pid,args 2>/dev/null | grep "$WORK_DIR" | grep -v grep | while read -r _p _rest; do
        kill "$_p" 2>/dev/null || true
    done
    # 이름이 없으면 (EXIT trap) 항상 시도한다 — 중단된 실행이 창을 남기지 않게 하는 안전망이다.
    # 이름이 있으면 그 대상의 회차 정리이므로 Terminal.app 회차에서만 닫는다. 다른 대상의
    # 회차마다 osascript 를 부르면 측정 사이에 쓸데없는 프로세스가 돈다.
    if [ -z "$_ct_name" ] || [ "$_ct_name" = terminal ]; then
        terminal_app_close
    fi
    if [ -z "$_ct_name" ] || [ "$_ct_name" = iterm2 ]; then
        iterm2_window_close
    fi
}
# --- wt 의 scrollback 을 맞추기 위한 fragment 프로필 (#381, Windows 전용) ---------------
#
# **wt 는 `historySize` 를 CLI 로 못 받는다** — profile 설정이다. 그래서 다른 대상과 scrollback
# 을 맞추려면 프로필을 하나 만들어야 하는데, **사용자 `settings.json` 을 건드리지 않고** 할 수
# 있다: [JSON fragment extension](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions)
# 이다. iTerm2 의 Dynamic Profiles 와 같은 자리이고, 아래 `iterm2_profile_*` 와 대칭이다.
#
#   `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\{앱}\{파일}.json`
#
# 그 디렉터리의 `.json` 을 wt 가 전부 읽어 프로필로 더한다. 우리는 **우리가 만든 디렉터리
# 하나만 지우면 끝**이다.
#
# **`hidden: true` 가 핵심이다** (실측, #381):
#
#   | `hidden` | `-p` 로 띄우기 | 사용자 `settings.json` |
#   |---|---|---|
#   | `false`  | 된다 | ❌ 참조 **스텁이 기록된다** (1,986 → 2,197 byte) |
#   | `true`   | 된다 | ✅ **한 바이트도 안 바뀐다** (해시 동일) |
#
# wt 는 fragment 프로필을 발견하면 보통 사용자 파일에 `{guid, name, source}` 스텁을 남기는데
# (WSL · Azure 프로필이 목록에 있는 것과 같은 방식), **`hidden: true` 면 그것조차 없다.** 그러면서
# `-p` 로는 정상적으로 띄워진다.
#
# **예전에는 `settings.json` 을 통째로 갈아끼우고 `trap` 으로 복원했다.** 그 구조에서는 crash 로
# 죽으면 사용자 설정이 임시본인 채로 남아서, 백업을 설정 파일 옆에 두고 다음 실행이 복원하는
# 안전장치가 필요했다. 덮어쓰지 않으면 지킬 것이 없으므로 그 세 겹이 통째로 없어졌다.
WT_FRAGMENT_DIR=""
WT_PROFILE_NAME="tildaz-compare"

wt_fragment_apply() {
    [ "$IS_WINDOWS" = 1 ] || return 0
    command -v wt >/dev/null 2>&1 || return 0
    [ -n "${LOCALAPPDATA:-}" ] || return 0
    _lad=$(cygpath -u "$LOCALAPPDATA" 2>/dev/null) || return 0

    WT_FRAGMENT_DIR="$_lad/Microsoft/Windows Terminal/Fragments/tildaz-compare"
    mkdir -p "$WT_FRAGMENT_DIR" || { WT_FRAGMENT_DIR=""; return 0; }

    # ⚠ 파일은 **UTF-8** 이어야 한다 (공식 문서 경고 — PowerShell 로 만들면 기본이 UTF-16LE 라
    # wt 가 못 읽는다). heredoc 은 셸이 그대로 쓰므로 문제없다.
    #
    # `commandline` 은 자리를 채우는 값이고 **실제 명령은 CLI 인자로 덮어쓴다** — producer 경로와
    # 환경변수는 다른 대상과 같은 방식으로 넘어간다.
    cat > "$WT_FRAGMENT_DIR/measure.json" << EOF
{
    "profiles":
    [
        {
            "name": "$WT_PROFILE_NAME",
            "commandline": "cmd.exe",
            "historySize": $SCROLLBACK,
            "hidden": true
        }
    ]
}
EOF
    echo "wt 측정용 프로필을 fragment 로 추가했어요 (historySize=$SCROLLBACK · hidden)."
    echo "  사용자 settings.json 은 건드리지 않아요. 끝나면 이 디렉터리만 지워요: $WT_FRAGMENT_DIR"
    # wt 는 시작할 때 fragment 를 읽는다. 쓰기 직후 곧바로 띄우면 아직 못 본 채로 뜰 수 있다.
    sleep 1
}

wt_fragment_remove() {
    [ -n "$WT_FRAGMENT_DIR" ] || return 0
    [ -d "$WT_FRAGMENT_DIR" ] || return 0
    rm -rf "$WT_FRAGMENT_DIR"
}

# fragment 를 지워도 **사용자 `settings.json` 에는 참조 스텁이 남는다.**
#
#   { "guid": "...", "hidden": true, "name": "tildaz-compare", "source": "tildaz-compare" }
#
# wt 는 fragment · dynamic 프로필을 발견하면 이 스텁을 자기 파일에 적는다 (WSL · Azure 프로필이
# 목록에 있는 것과 같은 방식이고, **종료할 때** 쓴다). fragment 를 지운 뒤 wt 를 다시 띄워도
# **자동으로 정리되지 않는다** (실측, #381). `hidden: true` 라 사용자 눈에는 안 보이지만, 우리가
# 만든 것이므로 우리가 지운다.
#
# **JSON 파싱을 하지 않는다.** wt 설정은 주석을 허용하는 JSONC 라 파서 왕복이 사용자 주석을
# 날린다 — 사용자 파일을 통째로 갈아끼우지 않으려고 이 방식으로 온 마당에 그건 앞뒤가 안 맞는다.
# 우리가 넣은 `source` 값으로 블록을 찾아 **그 범위만** 들어낸다.
wt_stub_remove() {
    [ "$IS_WINDOWS" = 1 ] || return 0
    [ -n "${LOCALAPPDATA:-}" ] || return 0
    _lad=$(cygpath -u "$LOCALAPPDATA" 2>/dev/null) || return 0
    for _s in \
        "$_lad/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json" \
        "$_lad/Packages/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json" \
        "$_lad/Microsoft/Windows Terminal/settings.json"
    do
        [ -f "$_s" ] || continue
        grep -q "\"source\"[[:space:]]*:[[:space:]]*\"$WT_PROFILE_NAME\"" "$_s" || continue
        _tmp="$_s.tildaz-clean"
        # 우리 블록의 시작 (`{` 만 있는 줄) 과 끝 (`}` · `},`) 을 찾아 그 구간을 버린다.
        # 우리 항목이 **목록의 마지막**이면 닫는 줄에 콤마가 없으므로, 바로 앞 블록의 `},` 에서
        # 콤마를 떼어야 JSON 이 유효하다.
        awk -v marker="$WT_PROFILE_NAME" '
            { line[NR] = $0 }
            END {
                t = 0
                for (i = 1; i <= NR; i++)
                    if (line[i] ~ ("\"source\"[ \t]*:[ \t]*\"" marker "\"")) { t = i; break }
                if (t == 0) { for (i = 1; i <= NR; i++) print line[i]; exit }
                s = t; while (s > 1 && line[s] !~ /^[ \t]*\{[ \t]*$/) s--
                e = t; while (e < NR && line[e] !~ /^[ \t]*\}[ \t]*,?[ \t]*$/) e++
                if (line[e] !~ /,[ \t]*$/) {
                    p = s - 1
                    while (p > 1 && line[p] !~ /^[ \t]*\}[ \t]*,[ \t]*$/) p--
                    if (p > 1) sub(/,[ \t]*$/, "", line[p])
                }
                for (i = 1; i <= NR; i++) { if (i >= s && i <= e) continue; print line[i] }
            }
        ' "$_s" > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; continue; }
        # wt 가 쓴 파일은 **끝 개행이 없다.** awk 는 마지막 줄에 개행을 붙이므로 그대로 두면
        # 내용이 같아도 1 byte 가 커진다. 원본이 개행으로 끝나지 않았으면 맞춰 준다 —
        # `$(cat …)` 이 trailing newline 을 떼므로 `printf '%s'` 로 다시 쓴다.
        if [ -n "$(tail -c 1 "$_s")" ]; then
            printf '%s' "$(cat "$_tmp")" > "$_tmp.n" && mv -f "$_tmp.n" "$_tmp"
        fi
        # 결과가 비었거나 마커가 그대로면 손대지 않는다 — 어설프게 쓰느니 스텁을 남긴다.
        if [ -s "$_tmp" ] && ! grep -q "\"source\"[[:space:]]*:[[:space:]]*\"$WT_PROFILE_NAME\"" "$_tmp"; then
            cp -f "$_tmp" "$_s" && echo "wt 설정에서 측정용 프로필 스텁을 지웠어요."
        else
            echo "⚠ wt 설정의 스텁을 못 지웠어요 — 직접 지워요 (\"name\": \"$WT_PROFILE_NAME\"): $_s" >&2
        fi
        rm -f "$_tmp"
    done
}

# iTerm2 는 **Dynamic Profiles** 로 준다 — 격자 · scrollback · 실행 명령을 JSON 하나에 담고
# 사용자 설정 파일은 전혀 건드리지 않는다. `wt` 가 `settings.json` 을 통째로 갈아끼우고
# 복원해야 하는 것과 대비되는 자리라, 여기서는 **우리가 만든 파일 하나만 지우면 끝**이다.
ITERM_PROFILE_DIR="$HOME/Library/Application Support/iTerm2/DynamicProfiles"
ITERM_PROFILE_FILE="$ITERM_PROFILE_DIR/$ITERM_PROFILE_NAME.json"
iterm2_profile_remove() {
    [ -f "$ITERM_PROFILE_FILE" ] || return 0
    rm -f "$ITERM_PROFILE_FILE"
}

# ⚠️ 각 단계를 `|| true` 로 끊어 준다. `set -e` 아래에서는 앞 단계가 non-zero 를 돌려주면
# **거기서 trap 이 끊겨** 뒤가 통째로 안 돈다 — 실제로 `hygiene_end` 가 실행되지 않아 창이
# 내려간 채로 남았다 (실측). 복원은 하나라도 빠지면 사용자 환경이 바뀐 채 끝난다.
trap 'cleanup_terminals || true; wt_fragment_remove || true; wt_stub_remove || true; iterm2_profile_remove || true; hygiene_end || true; rm -rf "$WORK_DIR"' EXIT

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
        MINGW*|MSYS*|CYGWIN*)
            # 실패하면 hold 를 늘려 그 회차를 다시 찍는다 (#413). 얼마로 늘리는지 미리 알린다.
            echo "  캡처 도구: PrintWindow (실패한 회차는 hold ${CAPTURE_RETRY_HOLD_MS} ms 로 1 회 재시도)"
            ;;
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
if [ "$IS_MACOS" = 1 ]; then
    # #414 — conhost 와 같은 이유로 매 실행에서 알린다. 다만 **성격이 다르다**: conhost 는
    # "스크롤백 없음" 으로 고정이라 적어도 재현은 되는데, Terminal.app 은 사용자 프로파일
    # 값이라 머신마다 다르다. 조건이 다를 뿐 아니라 재현성도 떨어진다는 뜻이다.
    echo ""
    echo "⚠ terminal (Terminal.app) 은 scrollback 을 못 맞춰요 — 사용자 프로파일 값이 쓰여요."
    echo "  AppleScript 에 크기 속성이 없어서 통로가 없어요 (격자는 escape sequence 로 줘요)."
fi
echo ""
# #381 — **배경에서 그리는 앱이 우리 수치만 누른다.** 같은 조건에서 VS Code · Edge 를 최소화하는
# 것만으로 tildaz 가 17.1 → 28.1 MiB/s (+64 %) 였고, 다른 넷은 +0.7~9 % 였다 (`emoji_vs16` ·
# 8 MiB · `--repeat 5` · Intel i5-1240P). 우리 렌더 경로가 자원 경쟁에 약한 탓이라 **정리하지
# 않으면 비교가 우리에게 불리해진다.**
#
# 닫지는 않는다 — worker 와 달리 **사용자의 작업 창**이라 없애면 안 된다. 대신 **KDE 에서는
# Show Desktop 으로 내렸다가 끝나면 되돌린다** (토글이라 복원이 실제로 된다). 그 밖의 환경은
# 경고만 한다 — 규칙으로만 적어 뒀더니 실제로 잊고 30 회차를 돌렸다 (#381).
hygiene_check || {
    [ "$IGNORE_HYGIENE" = 1 ] || {
        echo "측정 위생 점검에 걸렸어요. 고치거나 --ignore-hygiene 로 강행해요." >&2
        exit 1
    }
}
hygiene_begin
echo "위생   $(hygiene_status)"
echo ""
# #381 — **작은 페이로드는 표를 통째로 뒤집는다.** 이 표의 시간은 producer 가 *쓰기를 끝낸*
# 시점 기준인데, 터미널은 그 뒤로도 소화한다. 잔여는 대상의 읽기 버퍼 크기라 거의 고정이므로,
# 페이로드가 작을수록 상대 오차가 커진다. 우리 실측 (Intel i5-1240P):
#
#   | 워크로드 | 8 MiB 에서 우리/wt | 64 MiB 에서 우리/wt |
#   |---|---|---|
#   | `ansi` | 110 % | 92 % |
#   | `cjk` | 114 % | 56 % |
#   | `emoji_vs16` | 25 % | **10 %** |
#
# 8 MiB 에서는 우리가 앞선 것처럼 보이는 워크로드가 64 MiB 에서 뒤집힌다. 앱 카운터로 확인한
# 잔여는 우리 쪽 약 3 MB 였다 (`emoji_vs16` 에서 producer 282 ms 대 앱 549 ms).
if [ "$REPEAT" -ge 5 ] && [ "$MB" -lt 64 ]; then
    echo "⚠ --mb $MB 는 기록용으로 쓰지 마세요 — 페이로드가 작으면 표가 뒤집혀요."
    echo "  producer 가 쓰기를 끝낸 시점 기준이라, 아직 소화 못 한 잔여 (대상마다 다름) 가"
    echo "  상대적으로 커져요. 실측으로 cjk 가 8 MiB 에서 114 %, 64 MiB 에서 56 % 였어요."
    echo "  기록용은 --mb 64 (기본값) 로 내세요."
    echo ""
fi
# 평소 쓰는 TildaZ worker 는 `hygiene_begin` 이 내린다 (`hygiene.sh` 의 ⓪).
#
# **예전엔 여기에 `kill_worker` 가 있었는데 도달하지 못했다** — `hygiene_check` 가 worker 를
# 발견하면 *"먼저 내려요"* 로 `exit 1` 시키는 자리가 이 코드보다 **위**여서, README 의
# *"이제 스크립트가 자동으로 해요"* 가 실제로는 한 번도 실행되지 않았다 (#381 Windows 실기).
# 종료를 `hygiene.sh` 로 옮겨 세 도구 (`compare-terminals.sh` · `measure-repeat.sh` · `.ps1`)
# 가 같은 동작을 하게 했고, 그래서 그 순서 함정이 구조적으로 없어졌다.

# wt 설정 교체는 측정 직전에 (헤더를 찍은 뒤) 한다 — 실패해도 헤더는 남는다.
wt_fragment_apply
echo ""

# producer 를 셸 명령 한 줄로. 터미널마다 이 문자열을 자기 방식으로 실행한다.
# `exec` 로 셸을 대체해 셸이 남지 않게 한다.
#
# **`TILDAZ_STRESS_HOLD_MS` 는 여기서 안 준다** — `run_terminal` 이 시도마다 export 한다 (#413 의
# 재시도). 이 문자열은 호출부에서 **한 번** 만들어지므로 여기에 값을 박으면 재시도가 늘린 hold 가
# 반영되지 않는다. 자식은 환경에서 상속받는다.
producer_cmd() {
    printf 'env TILDAZ_STRESS_WORKLOAD=%s TILDAZ_STRESS_BYTES=%s TILDAZ_STRESS_TIMING_FILE=%s TILDAZ_STRESS_GRID=%s %s' \
        "$WORKLOAD" "$BYTES" "$(native_path "$1")" "${COLS}x${ROWS}" "$PRODUCER"
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
# **Windows 만 찍기 직전에 대상 창을 앞으로 올리고 (0,0) 으로 옮긴다** — 가려져 있으면 화면에
# 안 나오고, 창이 화면 아래로 삐져나가면 그만큼 잘리기 때문이다. `SWP_NOACTIVATE` 라 키보드
# 포커스는 뺏지 않는다. 별도 옵션으로 두지 않는다 — 캡처가 되게 하려는 수단이지 그 자체가
# 목적이 아니다.
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

# conhost 창을 찾을 제목. `mode con:` 과 함께 `conhost.cmd` 안에서 `title` 로 박는다.
CONHOST_TITLE="TildaZ-stress-conhost"
# TildaZ 측정 창의 클래스와 제목. **소스의 단일 원본은 `src/instances.zig`** 다
# (`window_class_name` = `TildaZWindow`, `stress_window_title` = `TildaZ-stress`). worker 는
# `TildaZ-<번호>` 라서 제목이 겹치지 않는다 — 그 계약을 `instances.zig` 의 테스트가 지킨다.
TILDAZ_CLASS="TildaZWindow"
TILDAZ_TITLE="TildaZ-stress"

# Windows 에서 그 대상의 창을 소유한 프로세스 이름. `wezterm` 은 실행 파일과 GUI 프로세스
# 이름이 다르다. 모르는 이름이면 빈 값 — 그때는 창을 올리지 않고 화면만 찍는다.
#
# **우리가 정체를 아는 둘 (conhost · tildaz) 은 빈 값이다** — 아래 클래스 + 제목으로 찾는다.
# 프로세스로 찾는 방법은 둘 다 실패한다.
#
# - **conhost**: 고전 콘솔 창의 주인은 `conhost.exe` 가 아니라 **클라이언트인 `cmd.exe`** 다.
#   Windows 실기로 확인했다 (#381): `EnumWindows` 로 보면 `ConsoleWindowClass` 창의
#   `GetWindowThreadProcessId` 가 cmd 의 pid 를 주고, `Get-Process -Name conhost` 는 **11 개
#   전부 `MainWindowHandle = 0`** 이었다. `cmd` 로 바꾸는 것도 안 된다 — 이 스크립트 자신의
#   wrapper `cmd` 가 같은 순간에 뜬다.
# - **tildaz**: `Get-Process -Name tildaz` 의 `MainWindowHandle` 이 **간헐적으로 0** 이다
#   (#381 실기: 같은 조건에서 어떤 회차는 잡히고 어떤 회차는 못 잡았다). drop-down 이라
#   숨은 상태의 worker 는 원래 0 인데, 측정 인스턴스도 0 으로 나오는 순간이 있었다.
#
# 클래스 + 제목은 그런 흔들림이 없다. **`FindWindowW` 는 창을 직접 물으므로 프로세스 스냅숏의
# 타이밍에 좌우되지 않는다.**
win_proc_name() {
    case "$1" in
        alacritty) printf 'alacritty' ;;
        wezterm) printf 'wezterm-gui' ;;
        wt) printf 'WindowsTerminal' ;;
        *) printf '' ;;
    esac
}

# macOS 에서 그 대상의 창을 찾을 **bundle identifier**. 위 `win_proc_name` 과 같은 자리다.
#
# **로케일과 무관한 유일한 식별자라서 쓴다** (#414). 앱 이름 (`applicationName`) 은 시스템
# 언어로 번역돼서 (`Terminal` → `터미널`) 찾는 기준이 될 수 없다. 언어별 이름 표를 두는
# 방법은 쓰지 않는다 — 언어가 늘 때마다 표를 늘려야 하고, 같은 언어에서도 OS 판이 바뀌면
# 표기가 달라져 조용히 빗나간다.
#
# 값은 각 앱의 `Info.plist` 에서 직접 읽었다 (macOS, 2026-08-10). tildaz 는
# [`dist/macos/Info.plist.in`](../macos/Info.plist.in) 이 원본이다.
mac_bundle_id() {
    case "$1" in
        terminal) printf 'com.apple.Terminal' ;;
        iterm2) printf 'com.googlecode.iterm2' ;;
        kitty) printf 'net.kovidgoyal.kitty' ;;
        alacritty) printf 'org.alacritty' ;;
        wezterm) printf 'com.github.wez.wezterm' ;;
        ghostty) printf 'com.mitchellh.ghostty' ;;
        tildaz) printf 'me.ensky0.tildaz' ;;
        *) printf '' ;;
    esac
}

# `FindWindowW(<클래스>, <제목>)` 로 찾을 대상의 창 클래스 / 제목. 둘 다 있어야 쓴다.
win_window_class() {
    case "$1" in
        conhost) printf 'ConsoleWindowClass' ;;
        tildaz) printf '%s' "$TILDAZ_CLASS" ;;
        *) printf '' ;;
    esac
}

win_window_title() {
    case "$1" in
        conhost) printf '%s' "$CONHOST_TITLE" ;;
        tildaz) printf '%s' "$TILDAZ_TITLE" ;;
        *) printf '' ;;
    esac
}

if [ -n "$CAPTURE_DIR" ] && [ "$IS_WINDOWS" = 1 ]; then
    # `Get-Process` 의 `StartTime` 으로 **이번 회차에 새로 뜬 창**만 고른다 — 사용자가 따로
    # 열어 둔 같은 앱 창을 건드리지 않기 위해서다. 못 찾으면 창을 올리지 않고 화면만 찍는다
    # (앞에 뜬 대상은 그래도 찍힌다).
    # **UTF-8 BOM 을 먼저 쓴다.** Windows PowerShell 5.1 은 BOM 이 없는 `.ps1` 을 **ANSI
    # 코드페이지** (한국어 Windows 는 CP949) 로 읽는다. 이 스크립트는 UTF-8 이라 한글 주석의
    # 바이트가 CP949 로 잘못 해독되고, 어떤 조합은 **토큰까지 깨뜨려 파싱이 통째로 실패**한다.
    # 실제로 주석에 `①` 을 넣자 "예기치 않은 '}' 토큰" 으로 캡처가 다섯 대상 전부 `!` 가 됐다
    # (#381 실기). BOM 이 있으면 UTF-8 로 읽으므로 그 계열의 사고가 아예 안 난다.
    printf '\357\273\277' > "$CAPTURE_PS1"
    cat >> "$CAPTURE_PS1" << 'EOF'
param(
    [string]$Png = "",
    [string]$ProcName = "",
    [string]$WindowClass = "",
    [string]$WindowTitle = "",
    [double]$SinceEpoch = 0,
    # 창을 찾아 배치만 하고 끝낸다 (찍지 않는다). 대상을 띄운 직후에 부른다.
    [switch]$PlaceOnly,
    # 창이 뜰 때까지 기다릴 시간. 0 이면 한 번만 찾아본다.
    [int]$WaitMs = 0
)
$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class TzWin {
  [DllImport("user32.dll")]
  public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")]
  public static extern int GetSystemMetrics(int index);
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr h, out RECT r);
  // 창 하나를 그 창의 DC 에 직접 그리게 한다. `PW_RENDERFULLCONTENT` (0x2, Windows 8.1+) 라야
  // DWM 이 합성하는 최신 내용을 준다.
  [DllImport("user32.dll")]
  public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  public const uint PW_RENDERFULLCONTENT = 0x00000002;
  [DllImport("user32.dll")]
  public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")]
  public static extern bool SetProcessDPIAware();
  public static readonly IntPtr TOPMOST = new IntPtr(-1);
  public static readonly IntPtr NOTOPMOST = new IntPtr(-2);
  // HWND_TOP — topmost 밴드에 넣지 않고 보통 창들 중 맨 앞으로만 올린다. 배치 단계에서
  // 쓴다. 측정이 도는 내내 topmost 로 박아 두면 사용자의 다른 창을 계속 덮는다.
  public static readonly IntPtr TOP = IntPtr.Zero;
  // 올리면서 (0,0) 으로 옮길 때. SWP_NOSIZE | SWP_NOACTIVATE — 크기와 포커스는 안 건드리고
  // **위치는 건드린다** (`SWP_NOMOVE` 를 뺐다).
  public const uint RAISE = 0x0001 | 0x0010;
  // 되돌릴 때. SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE — z-order 만 바꾼다.
  public const uint RESTORE = 0x0001 | 0x0002 | 0x0010;
  // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2. 모니터마다 배율이 다를 수 있어서
  // system-aware (한 배율로 고정) 가 아니라 per-monitor 를 쓴다.
  public static readonly IntPtr PER_MONITOR_V2 = new IntPtr(-4);
  public const int SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77;
  public const int SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;
  // `SetProcessDpiAwarenessContext` 는 Windows 10 1703+ 다. 그 전 버전에서는 export 가
  // 없어 EntryPointNotFoundException 이 나므로 구형 API 로 물러선다.
  public static void MakeDpiAware() {
    try { if (SetProcessDpiAwarenessContext(PER_MONITOR_V2)) { return; } } catch {}
    try { SetProcessDPIAware(); } catch {}
  }
}
"@
# **화면 크기를 읽기 전에 제일 먼저 부른다.** Windows PowerShell 5.1 은 DPI-unaware 라
# 그냥 두면 화면 metric 이 *논리* 크기로 나오는데 (200 % 배율의 2880x1800 화면에서 1440x900),
# `CopyFromScreen` 은 **물리 픽셀을 1:1 로** 복사한다. 그래서 좌상단 1/4 만 찍혔다 (#381 실측:
# 다섯 장 전부 1440x900 이고 작업 표시줄이 없고 창이 오른쪽에서 잘렸다). aware 로 만들면
# metric 도 물리 픽셀이 되어 둘이 맞는다.
[TzWin]::MakeDpiAware()

# 대상 창 하나를 찾는다. 못 찾으면 `IntPtr::Zero`.
#   - **클래스 + 제목을 아는 대상 (conhost · tildaz) 은 그것으로** 찾는다. 창을 직접 묻는
#     방식이라 프로세스 스냅숏의 타이밍에 좌우되지 않는다 (sh 쪽 `win_proc_name` 주석에
#     둘이 왜 프로세스로는 안 잡히는지 적어 뒀다).
#   - 그 밖에는 프로세스로 찾되 **이번 회차에 새로 뜬 창**만 고른다 (`StartTime`) — 사용자가
#     따로 열어 둔 같은 앱 창을 건드리지 않기 위해서다.
function Find-Target {
    if ($WindowTitle -ne "" -and $WindowClass -ne "") {
        $c = [TzWin]::FindWindow($WindowClass, $WindowTitle)
        if ($c -ne [IntPtr]::Zero) { return $c }
    }
    if ($ProcName -ne "") {
        $since = [DateTimeOffset]::FromUnixTimeSeconds([long]$SinceEpoch).LocalDateTime
        $p = Get-Process -Name $ProcName |
             Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.StartTime -gt $since } |
             Sort-Object StartTime -Descending | Select-Object -First 1
        if ($p) { return $p.MainWindowHandle }
    }
    return [IntPtr]::Zero
}

# 창이 뜨기를 기다린다. 배치 단계에서는 대상을 막 띄운 참이라 아직 창이 없다.
$h = [IntPtr]::Zero
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($true) {
    $h = Find-Target
    if ($h -ne [IntPtr]::Zero -or $sw.ElapsedMilliseconds -ge $WaitMs) { break }
    Start-Sleep -Milliseconds 100
}
if ($h -ne [IntPtr]::Zero) {
    # **맨 앞으로 올리면서 (0,0) 으로 옮긴다.** 올리기만 하면 창이 화면 아래로 삐져나간 만큼
    # 잘린다 — Windows 가 창을 cascade 로 놓아서 y 가 0 이 아니고, 40 행짜리 창은 그 offset
    # 만큼 아래가 작업 표시줄 밖으로 나간다 (#381 실기: alacritty 는 작업 표시줄에 가렸고
    # wezterm 은 아래 20 px 이 잘렸다). (0,0) 은 주 모니터의 좌상단이라 항상 보이는 자리다.
    #
    # z-order 는 단계마다 다르다. **배치 단계는 `HWND_TOP`** — 측정이 도는 내내 topmost 로
    # 박아 두면 사용자의 다른 창을 계속 덮는다. **찍기 직전에만 `HWND_TOPMOST`** 로 올려서
    # 그 순간 확실히 보이게 한다.
    #
    # **창이 화면보다 크면 그래도 잘린다** — 그때는 `--rows` 를 줄여서 찍는다.
    #
    # **TildaZ 는 이 옮기기가 안 먹는다 — 의도된 것이다.** `src/window.zig` 의
    # `WM_WINDOWPOSCHANGING` 핸들러가 `SWP_NOMOVE` 가 없는 외부 요청의 x/y 를
    # `expected_x`/`expected_y` 로 되돌린다 (Display Fusion · FancyZones 류가 drop-down rect 를
    # 건드리는 것을 막으려고 넣은 방어다). z-order 는 그대로 올라가고 위치만 무시된다.
    # TildaZ 는 drop-down 이라 원래 y=0 에 붙어 있어서 잘릴 일이 없으니 문제가 아니다 —
    # 여기서 예외 처리를 하지 않는 이유다.
    [void][TzWin]::SetWindowPos($h, [TzWin]::TOP, 0, 0, 0, 0, [TzWin]::RAISE)
    Start-Sleep -Milliseconds 200
}

# 배치만 하는 호출은 여기서 끝난다.
if ($PlaceOnly) { exit 0 }

# 성긴 격자로 훑어 **전부 같은 색**이면 true. `PrintWindow` 가 실패했는지 판정하는 데 쓴다.
function Test-Uniform($b) {
    $first = $b.GetPixel(0, 0)
    $sx = [Math]::Max(1, [int]($b.Width / 16))
    $sy = [Math]::Max(1, [int]($b.Height / 16))
    for ($y = 0; $y -lt $b.Height; $y += $sy) {
        for ($x = 0; $x -lt $b.Width; $x += $sx) {
            if (-not $b.GetPixel($x, $y).Equals($first)) { return $false }
        }
    }
    return $true
}


# --- 찍기 --------------------------------------------------------------------
#
# **창 단위로 먼저 시도한다.** 가려짐 · 화면 밖으로 삐져나감 · 작업 표시줄 겹침을 한 번에
# 없애 준다 (macOS 가 ScreenCaptureKit 으로 창 단위를 찍는 것과 같은 방향).
#
# 순서는 둘이다. 앞이 안 되면 다음으로 간다.
#   ① `PrintWindow(PW_RENDERFULLCONTENT)` — 창에게 자기 DC 에 그리라고 시킨다. **가려져
#      있어도** 되고 창 프레임 밖 그림자가 안 들어가서 제일 깨끗하다.
#   ② 전체 화면 `CopyFromScreen`. 대상이 다른 창에 가리면 안 보이므로 마지막이다.
#
# **① 이 실패하는 흔한 원인은 창이 이미 닫힌 것**이다 (#413). 그때는 여기서 할 수 있는 게 없고,
# sh 쪽이 hold 를 늘려 그 회차를 다시 찍는다. `ddagrab` 2 차 경로는 그 오진 위에 있던 것이라
# 지웠다 — sh 쪽 주석의 실측 표 참고.
$captured = $false
$r = New-Object TzWin+RECT
$ww = 0
$wh = 0
if ($h -ne [IntPtr]::Zero -and [TzWin]::GetWindowRect($h, [ref]$r)) {
    $ww = $r.R - $r.L
    $wh = $r.B - $r.T
}

# ① 창 단위 — PrintWindow
if ($ww -gt 0 -and $wh -gt 0) {
    $wb = New-Object System.Drawing.Bitmap $ww, $wh
    $wg = [System.Drawing.Graphics]::FromImage($wb)
    $hdc = $wg.GetHdc()
    $ok = [TzWin]::PrintWindow($h, $hdc, [TzWin]::PW_RENDERFULLCONTENT)
    $wg.ReleaseHdc($hdc)
    $wg.Dispose()
    # GPU 로 그리는 창은 `PrintWindow` 에 **단색**을 주기도 한다. 그때는 다음 경로로 가야
    # 하므로 단색이면 실패로 본다.
    if ($ok -and -not (Test-Uniform $wb)) {
        $wb.Save($Png, [System.Drawing.Imaging.ImageFormat]::Png)
        $captured = $true
    }
    $wb.Dispose()
}

# ② 는 **화면에 보이는 것**을 읽으므로 대상을 맨 앞으로 올린 뒤에 한다.
$raised = $false
if (-not $captured -and $h -ne [IntPtr]::Zero) {
    [void][TzWin]::SetWindowPos($h, [TzWin]::TOPMOST, 0, 0, 0, 0, [TzWin]::RAISE)
    Start-Sleep -Milliseconds 200
    $raised = $true
}

if (-not $captured) {
    # ③ 물러서기 — 전체 화면.
    # 가상 화면 = 모니터 전부를 감싸는 사각형. 주 모니터 왼쪽 / 위에 다른 모니터가 있으면
    # 원점이 음수라 X · Y 도 함께 읽는다.
    $vx = [TzWin]::GetSystemMetrics([TzWin]::SM_XVIRTUALSCREEN)
    $vy = [TzWin]::GetSystemMetrics([TzWin]::SM_YVIRTUALSCREEN)
    $vw = [TzWin]::GetSystemMetrics([TzWin]::SM_CXVIRTUALSCREEN)
    $vh = [TzWin]::GetSystemMetrics([TzWin]::SM_CYVIRTUALSCREEN)
    $bmp = New-Object System.Drawing.Bitmap $vw, $vh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vx, $vy, 0, 0, $bmp.Size)
    $bmp.Save($Png, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
}

# 올렸으면 되돌린다 — ② 로 찍었어도 topmost 로 둔 채 나가지 않는다.
# z-order 만 되돌린다. 위치는 (0,0) 에 둔 채로 놔둔다 — producer 가 곧 끝나면서 창이 닫히므로
# 원래 자리로 되돌릴 이유가 없고, 되돌리려면 옮기기 전 rect 가 필요하다.
if ($raised) {
    [void][TzWin]::SetWindowPos($h, [TzWin]::NOTOPMOST, 0, 0, 0, 0, [TzWin]::RESTORE)
}

# PNG 은 어느 경로로든 만들되 **무엇을 찍었는지**를 종료 코드로 알린다. 이 구분이 없어서
# 창을 한 번도 못 잡고 있던 conhost 가 계속 성공처럼 보였다 (#381).
#   3 = 대상 창을 못 찾음 (전체 화면만 찍힘 — 대상이 있다는 보장 없음)
#   4 = 창은 찾았지만 창 단위 캡처 실패 → 전체 화면으로 물러섬
if ($h -eq [IntPtr]::Zero) { exit 3 }
if (-not $captured)        { exit 4 }
exit 0
EOF
fi

# 한 회차의 화면을 찍는다. 실패해도 측정을 멈추지 않는다 — 찍힌 게 없다는 사실은
# 파일이 없는 것으로 알 수 있고, 표 옆에 표시도 남긴다.
#
# Windows 는 무엇을 찍었는지를 두 플래그로 알린다. 다른 platform 은 이 구분이 없다 (`0`).
#   `CAPTURE_NOWIN`    대상 창을 못 찾음 — 전체 화면만 찍혔고 대상이 있다는 보장이 없다.
#   `CAPTURE_FELLBACK` 창은 찾았지만 창 단위 캡처가 안 돼서 전체 화면으로 물러섰다.
CAPTURE_NOWIN=0
CAPTURE_FELLBACK=0
capture_screen() {
    _png="$1"
    _ctarget="$2"
    _csince="$3"
    CAPTURE_NOWIN=0
    CAPTURE_FELLBACK=0
    case "$(uname -s)" in
        Darwin)
            # 창 목록에서 그 앱의 **가장 큰 windowID** 를 고른다 — windowID 는 단조 증가하므로
            # 방금 뜬 창이다. 사용자가 따로 열어 둔 같은 앱의 창을 찍지 않기 위해서다.
            #
            # **찾는 기준은 bundle identifier 다** (#414). 예전에는 앱 이름으로 찾았는데,
            # `applicationName` 이 **시스템 로케일로 번역된 이름**이라 한국어 macOS 에서
            # Terminal.app 이 `터미널` 로 나와 매칭이 통째로 빗나갔다 (실측 — 그 회차가 조용히
            # 전체 화면으로 찍혔다). 현지화되지 않는 대상들 (kitty · alacritty · wezterm ·
            # ghostty) 만 우연히 멀쩡했던 것이라, OS 기본 앱을 넣자마자 드러났다.
            #
            # **이름 매칭도 남겨 둔다.** bundle identifier 가 없는 창이 있고 (`-` 로 나온다),
            # 번들 안 바이너리를 직접 띄우는 tildaz 가 그럴 수 있다. 둘 중 하나만 맞아도 고른다.
            _wid=""
            if [ -n "$MAC_CAPTURE" ]; then
                _wid=$("$MAC_CAPTURE" --list 2>/dev/null |
                    awk -v b="$(mac_bundle_id "$_ctarget")" -v t="$_ctarget" \
                        '(b != "" && $2 == b) || index(tolower($3), t) == 1 { print $1 }' |
                    sort -n | tail -1)
            fi
            # 창을 못 찾았거나 창 단위 캡처가 실패하면 전체 화면으로 물러선다 — 가려져 있으면
            # 안 보이지만 없는 것보다 낫다. **어느 쪽이었는지 표시를 남긴다** — 예전에는 macOS 가
            # 이 구분 없이 전부 `@` 로 찍혀서, 전체 화면으로 물러선 회차를 **사람이 PNG 을 열어
            # 봐야만** 알 수 있었다 (#414 에서 실제로 그렇게 발견됐다).
            if [ -z "$_wid" ]; then
                CAPTURE_NOWIN=1
            else
                "$MAC_CAPTURE" --window "$_wid" "$_png" >/dev/null 2>&1 || true
                [ -s "$_png" ] || CAPTURE_FELLBACK=1
            fi
            # `-x` 는 셔터음을 끈다. **화면 기록 권한**이 필요하고 잠금 화면이면 실패한다.
            [ -s "$_png" ] || screencapture -x "$_png" >/dev/null 2>&1 || true
            ;;
        MINGW*|MSYS*|CYGWIN*)
            # `|| true` 를 쓰지 않는다 — 종료 코드 3 · 4 를 읽어야 하기 때문이다.
            # `set -e` 아래서는 `if` 문맥이라 0 이 아니어도 스크립트가 죽지 않는다.
            if powershell -NoProfile -ExecutionPolicy Bypass -File "$(native_path "$CAPTURE_PS1")" \
                -Png "$(native_path "$_png")" \
                -ProcName "$(win_proc_name "$_ctarget")" \
                -WindowClass "$(win_window_class "$_ctarget")" \
                -WindowTitle "$(win_window_title "$_ctarget")" \
                -SinceEpoch "$_csince" >/dev/null 2>&1
            then :; else
                # `&&` 연쇄로 쓰면 마지막 검사가 거짓일 때 함수가 0 이 아닌 값을 돌려주고,
                # `set -e` 아래서 호출부가 그걸 실패로 본다. `if` 로 쓴다.
                _rc=$?
                if   [ "$_rc" -eq 3 ]; then CAPTURE_NOWIN=1
                elif [ "$_rc" -eq 4 ]; then CAPTURE_FELLBACK=1
                fi
            fi
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

# 대상을 **띄우자마자** 창을 찾아 (0,0) 으로 옮기고 맨 앞으로 올린다 (Windows · 캡처 켤 때만).
#
# 찍기 직전에만 옮기면 **도는 동안 내내** 창이 가려 있거나 화면 밖으로 나가 있어서 눈으로
# 볼 수가 없다 — 눈으로 보는 게 `--capture` 를 만든 이유다 (#381 사용자 지적). 그래서 배치를
# 앞으로 당기고, 찍기 직전의 올리기는 그대로 둔다 (그사이 다른 창이 앞에 올 수 있다).
#
# **background 로 던진다.** 창이 뜰 때까지 최대 `PLACE_WAIT_MS` 를 폴링하므로 여기서 기다리면
# timing 파일 폴링이 그만큼 늦어진다. 실패해도 측정을 막지 않는다.
#
# 터미널이 주는 위치 옵션 (`wezterm --position` 등) 을 쓰지 않는 이유는 **문법이 대상마다 다르고
# conhost 는 옵션 자체가 없어서**다. 창을 찾아 옮기는 방법 하나면 다섯 대상이 같은 코드로 처리된다.
PLACE_WAIT_MS=5000

place_window() {
    powershell -NoProfile -ExecutionPolicy Bypass -File "$(native_path "$CAPTURE_PS1")" \
        -PlaceOnly \
        -WaitMs "$PLACE_WAIT_MS" \
        -ProcName "$(win_proc_name "$1")" \
        -WindowClass "$(win_window_class "$1")" \
        -WindowTitle "$(win_window_title "$1")" \
        -SinceEpoch "$2" >/dev/null 2>&1 || true
}

# 회차별 캡처 결과를 **파일에** 한 줄씩 적는다 (`failed` · `nowin` · `fellback` · `dda` · `ok`).
#
# **셸 변수로 세면 안 된다** — `run_terminal_win` 이 `run_terminal` 을 서브셸 `( … )` 안에서
# 부르므로 (환경변수를 이 실행에만 걸기 위해서다) 그 안에서 올린 변수는 밖에 안 남는다.
# 그래서 alacritty · wezterm · wt 의 회차가 요약에서 통째로 빠져 있었다 — 다섯 대상이 전부
# `!` 인데 "2 회차가 안 찍혔어요" 로 나왔다 (#381 실기, 212ec07 에서 표시를 넷으로 나눌 때부터
# 있던 버그다). 파일은 서브셸에서 append 해도 남는다.
CAPTURE_LOG="$WORK_DIR/capture-outcomes"
: > "$CAPTURE_LOG"

# #413 — hold 를 늘려 다시 찍은 회차 수. `CAPTURE_LOG` 와 같은 이유로 파일에 쌓는다
# (`run_terminal_win` 이 서브셸 안에서 `run_terminal` 을 부르므로 변수는 안 남는다).
CAPTURE_RETRY_LOG="$WORK_DIR/capture-retries"
: > "$CAPTURE_RETRY_LOG"
# 옵션으로 정해진 hold. `run_terminal` 이 재시도 때 잠깐 올렸다가 이 값으로 되돌린다.
CAPTURE_HOLD_MS="$HOLD_MS"

# 이보다 작은 PNG 은 **사실상 빈 이미지**로 본다 (위 `_` 표시 주석). 실측 근거는 alacritty 의
# 550 byte 단색 캡처이고, 같은 실행의 정상 캡처는 65~134 KB 였다 (#381).
CAPTURE_MIN_BYTES=2048

# 그 파일에서 한 종류의 회차 수를 센다. `grep -c` 는 0 건일 때 종료 코드가 1 이라 `set -e`
# 아래서 다루기 번거로워 awk 를 쓴다.
capture_count() {
    awk -v k="$1" '$0 == k { n++ } END { print n + 0 }' "$CAPTURE_LOG"
}

RESULTS="$WORK_DIR/results"
: > "$RESULTS"

# producer 가 끝난 뒤에도 안 닫혀 상한에 걸린 회차를 적는다 (#414). **없으면 아무것도 안 찍는다** —
# 정상 실행의 표를 어지럽히지 않으려는 것이다.
#
# ⚠️ 진행 줄 (`printf '%-14s '` 로 시작해 `@` · `~` 를 이어 찍는 그 줄) 이 **개행으로 끝난 뒤에**
# 불러야 한다. 중간에 부르면 표가 깨진다. 들여쓰기는 그 줄의 이름 칸 (14 자 + 공백) 에 맞춘 것이다.
stuck_note() {
    [ "$_stuck" -gt 0 ] || return 0
    echo "               ⚠ $_name — producer 가 끝난 뒤에도 안 닫혀서 ${_stuck} 회차를 강제로 정리했어요 (측정값은 유효해요)."
}

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
    # 목표 그리드를 기다린 시간 중 **최댓값**. 한 회차라도 오래 걸렸으면 그 대상은 늦게
    # resize 한다는 뜻이라, 평균으로 뭉개지 않는다.
    _wait_max=0
    # 이 대상에서 hold 를 늘려 다시 찍은 회차 수. 표 아래 요약에 적는다.
    _retried=0
    # producer 가 끝난 뒤에도 터미널이 안 닫혀 상한에 걸린 회차 수 (#414). `stuck_note` 참고.
    _stuck=0
    _run=1
    while [ "$_run" -le "$REPEAT" ]; do
        # #413 — 한 회차를 최대 두 번 시도한다. **창 단위로 못 찍었으면** (`~` · `_` · `?`)
        # 창이 이미 닫힌 뒤에 찍었을 가능성이 크므로, hold 를 늘려 그 회차를 통째로 다시
        # 돌린다. 어느 표시가 대상인지는 아래 재시도 판정에 적어 뒀다.
        #
        # **PNG 만 다시 찍을 수는 없다** — hold 는 producer 안에 있고 그 시점엔 창이 없다.
        # 그래서 회차를 다시 돌리고, timing 과 PNG 을 같은 시도의 것으로 함께 바꾼다.
        _attempt=1
        _hold_this="$HOLD_MS"
        while :; do
        # 회차마다 지운다 — 이전 회차 파일이 남아 있으면 `wait_for` 가 즉시 통과해 같은
        # 값을 다시 읽는다.
        rm -f "$_timing"
        # 이 시도에 쓸 hold. **launcher 들은 이 값을 명령 문자열에 박지 않고 환경에서
        # 상속받는다** — 명령 문자열은 회차마다 다시 만들어지지 않기 때문이다 (#413).
        HOLD_MS="$_hold_this"
        export TILDAZ_STRESS_HOLD_MS="$_hold_this"
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
        # 창이 뜨는 대로 (0,0) 에 놓는다 (위 `place_window` 주석). background 다.
        if [ -n "$CAPTURE_DIR" ] && [ "$IS_WINDOWS" = 1 ]; then
            place_window "$_name" "$_since" &
        fi
        _mark=""
        _word=""
        _sample=""
        if wait_for "$_timing"; then
            _sample=$(sed -n 's/^elapsed_ns=//p' "$_timing")
            _cols=$(sed -n 's/^cols=//p' "$_timing")
            _rows=$(sed -n 's/^rows=//p' "$_timing")
            _cols0=$(sed -n 's/^cols_start=//p' "$_timing")
            _rows0=$(sed -n 's/^rows_start=//p' "$_timing")
            # 예전 producer 는 이 줄을 안 쓴다 — 없으면 0 으로 둔다.
            _wait=$(sed -n 's/^grid_wait_ms=//p' "$_timing")
            [ -n "$_wait" ] || _wait=0
            [ "$_wait" -gt "$_wait_max" ] && _wait_max=$_wait
            # producer 가 `HOLD_MS` 만큼 창을 붙들고 있는 동안 찍는다. 곧바로 찍지 않고
            # `CAPTURE_DELAY` 만큼 기다린다 — timing 이 생긴 시점은 측정이 끝난 시점이지 창이
            # 화면에 올라온 시점이 아니다 (위 `HOLD_MS` 주석).
            if [ -n "$CAPTURE_DIR" ]; then
                sleep "$CAPTURE_DELAY"
                _png="$CAPTURE_DIR/$WORKLOAD-$_name-$_run.png"
                capture_screen "$_png" "$_name" "$_since"
                # `@` 대상 창을 창 단위로 찍었고 **내용이 있다** (가장 좋은 결과)
                # `_` PNG 은 생겼는데 **사실상 비어 있다** (단색) — 아래 참고
                # `~` 창은 찾았지만 창 단위가 안 돼서 전체 화면으로 물러섰다
                # `?` 창을 아예 못 찾았다 — 화면에 대상이 있다는 보장이 없다
                # `!` PNG 자체가 안 생겼다
                #
                # **표시는 이 시도의 결과이지 회차의 결과가 아니다.** `~` · `_` 이면 아래에서
                # hold 를 늘려 회차를 다시 돌리므로, 최종 표시는 마지막 시도의 것이다.
                #
                # **빈 PNG 을 먼저 거른다.** `@` 는 지금까지 *"캡처 API 가 성공을 돌려줬다"* 는
                # 뜻이었을 뿐이라, 창 단위로 찍었는데 **단색 이미지**가 나와도 성공으로 보였다
                # (실측: alacritty 가 550 byte — 정상은 65~134 KB, #381). README 의 *"`@` 는 파일이
                # 생겼다는 뜻이지 창이 찍혔다는 보장이 아니다"* 라는 경고가 바로 이것이고, 그
                # 판정을 사람 눈이 아니라 스크립트가 한다.
                #
                # 판정은 **파일 크기**다. 단색 PNG 은 압축이 극단적으로 잘 돼 수백 byte 로 떨어지고
                # 텍스트가 찬 터미널 화면은 그럴 수 없다. 이미지 라이브러리에 기대지 않아 세
                # platform 이 같은 코드로 판정한다. 창을 아주 작게 (`--rows` 를 줄여) 찍으면 오탐이
                # 날 수 있으므로 임계는 실측 (550 byte) 보다 넉넉히 잡되 정상값 (65 KB) 보다 훨씬
                # 아래인 2 KiB 로 둔다.
                if [ ! -s "$_png" ]; then
                    _word=failed; _mark='!'
                elif [ "$(wc -c < "$_png" | tr -d ' ')" -lt "$CAPTURE_MIN_BYTES" ]; then
                    _word=blank; _mark='_'
                elif [ "$CAPTURE_NOWIN" = 1 ]; then
                    _word=nowin; _mark='?'
                elif [ "$CAPTURE_FELLBACK" = 1 ]; then
                    _word=fellback; _mark='~'
                else
                    _word=ok; _mark='@'
                fi
            else
                _mark='.'
            fi
        else
            _mark='x'
        fi
        # 캡처를 켜면 producer 가 `HOLD_MS` 만큼 더 살아 있다. 그걸 중간에 죽이면 셸이
        # `Terminated: 15` 를 표 위에 찍어 결과를 읽기 어렵게 만든다 (macOS 실측). 스스로
        # 끝나기를 기다렸다가 정리한다 — 어차피 그때까지 창이 살아 있어야 캡처가 된다.
        #
        # **기다림에는 상한이 있다** (#414 Windows 실기). 기다리는 목적이 *producer 의 hold 가
        # 끝나는 것* 하나뿐이라 상한도 **그 시도의 hold** (`_hold_this`) 다 — 그보다 오래
        # 기다려서 얻는 것이 없다. 재시도 회차는 hold 가 `CAPTURE_RETRY_HOLD_MS` 로 늘어나므로
        # (#413) 상한도 같이 늘어난다. 아래 settle 이 쓰는 값과 같은 변수를 쓴다.
        # 상한이 없던 동안 alacritty 회차가 **영영 끝나지 않았다.** producer 는 정상 종료했는데
        # (프로세스가 남지 않고 timing 도 완전하다) `alacritty.exe` 만 남았다. 우리 스크립트
        # 없이 `alacritty -e <producer>` 만으로도 나고, 180 초를 기다려도 안 닫히며 그동안
        # **CPU 시간이 늘지 않는다** — 오래 걸리는 일을 하는 중이 아니라 멈춘 것이다. 출력량
        # 의존이라 8 MiB 이하는 멀쩡하다 (README 의 Windows 절에 실측 표가 있다).
        #
        # 상한이 지나면 **아래 `kill` 이 정리한다** (멈춘 alacritty 가 그 `kill` 하나로 창까지
        # 사라지는 것을 실측했다). **그 회차의 값은 버리지 않는다** — 멈춤은 측정과 캡처가 모두
        # 끝난 뒤에 일어나고, 값은 producer 가 쓴 timing 파일에서 나오기 때문이다.
        if [ -n "$CAPTURE_DIR" ] && [ -n "$_pid" ]; then
            # 0.2 초씩 센다 — 매 바퀴 `date` 를 부르지 않으려는 것이다. 그래서 이 값은 **하한**
            # 이다: 한 바퀴가 `sleep` 이 자는 시간보다 길 수 있어서 (Git Bash 실측 316 ms — MSYS
            # 는 프로세스 생성이 비싸다) 실제로는 조금 더 기다린다. 우리에게 필요한 보장이
            # *"producer 의 hold 가 끝날 때까지는 기다린다"* 라 넉넉한 쪽이 안전하다.
            _left=$(( ((_hold_this + 999) / 1000 + 3) * 5 ))
            while [ "$_left" -gt 0 ] && kill -0 "$_pid" 2>/dev/null; do
                sleep 0.2
                _left=$((_left - 1))
            done
            # 상한에 걸렸으면 **조용히 넘기지 않는다** — 대상 줄 아래에 회차 수를 적는다.
            if kill -0 "$_pid" 2>/dev/null; then
                _stuck=$((_stuck + 1))
            fi
        fi
        # 창이 남아 있으면 정리한다. `kill $_pid` 만으로는 부족하다 — kitty 는 `--detach` 라
        # 그 pid 가 즉시 끝나는 부모이고, ghostty 는 실행 실패 화면을 띄운 채 기다린다.
        # `cleanup_terminals` 가 이 실행의 `WORK_DIR` 패턴으로 실제 창을 정리한다.
        [ -n "$_pid" ] && kill "$_pid" 2>/dev/null || true
        cleanup_terminals "$_name"

        # #413 — **hold 가 끝날 때까지 기다린 뒤에 다음으로 넘어간다.**
        #
        # `wait "$_pid"` 로는 부족하다. wt 는 `wt -w new` 가 기존 WindowsTerminal 프로세스에
        # 창을 요청하고 **곧바로 반환**하고 (conhost 도 `start` 로 떼어 내 `_pid` 가 없다),
        # 그러면 앞 창이 살아 있는 채로 다음 회차가 시작된다. 그 상태에서 `wt -w new` 를 또
        # 부르면 새 프로세스가 안 뜨고 *"이번 회차에 새로 뜬 창만 고른다"* 는 `StartTime`
        # 필터에 걸려 `?` 가 된다 (hold 15 초에서 wt 3 회차 중 2 회차가 그랬다).
        #
        # 캡처는 timing + `CAPTURE_DELAY` 에 했으므로 남은 시간은 그만큼 뺀 값이다.
        if [ -n "$CAPTURE_DIR" ]; then
            _settle=$(( _hold_this / 1000 - CAPTURE_DELAY ))
            [ "$_settle" -gt 0 ] && sleep "$_settle"
        fi

        # 다시 찍을 값어치가 있나. **창 단위로 못 찍은 것은 전부 대상이다** (`~` · `_` · `?`).
        #
        # `?` 도 넣는 이유 — 원인이 둘인데 둘 다 재시도가 맞다. **창이 이미 닫혀서** 못 찾은
        # 경우는 hold 를 늘리면 고쳐지고, **앞 창이 남아 프로세스가 재사용된** 경우는 바로 위
        # settle 이 그 창을 없앤 뒤라 다시 뜬다. 처음엔 `?` 를 뺐다가, hold 를 `CAPTURE_DELAY`
        # 보다 짧게 준 실기에서 다섯 대상이 전부 `?` 로 떨어지는데 재시도가 한 번도 안 걸려서
        # 고쳤다.
        if [ "$_attempt" = 1 ] && [ "$_mark" != '@' ] && [ "$_mark" != 'x' ] && [ "$_mark" != '.' ]; then
            _attempt=2
            _hold_this="$CAPTURE_RETRY_HOLD_MS"
            _retried=$((_retried + 1))
            continue
        fi
        break
        done
        # 이 회차의 최종 결과를 남긴다. 재시도했으면 마지막 시도의 것이다 — timing 과 PNG 이
        # 같은 시도에서 나와야 짝이 맞는다.
        [ -n "$_sample" ] && _samples="$_samples $_sample"
        [ -n "$_word" ] && echo "$_word" >> "$CAPTURE_LOG"
        printf '%s' "$_mark"
        _run=$((_run + 1))
    done
    # 다음 대상이 기본값으로 시작하도록 되돌린다.
    HOLD_MS="$CAPTURE_HOLD_MS"
    [ "$_retried" -gt 0 ] && echo "$_retried" >> "$CAPTURE_RETRY_LOG"

    if [ -z "$_samples" ]; then
        printf ' timeout / 실행 안 됨\n'
        stuck_note
        printf '%s\tskipped\t0\t0\t0\t0\n' "$_name" >> "$RESULTS"
        return
    fi
    printf ' ok  %sx%s\n' "$_cols" "$_rows"
    stuck_note
    # 앞의 공백을 없애 awk 가 필드를 세기 쉽게 한다.
    _samples=$(printf '%s' "$_samples" | sed 's/^ *//')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_name" "$_samples" "$_cols" "$_rows" "$_cols0" "$_rows0" "$_wait_max" >> "$RESULTS"
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
        # `TILDAZ_STRESS_HOLD_MS` 는 `run_terminal` 이 시도마다 export 한다 (#413 재시도).
        export TILDAZ_STRESS_GRID="${COLS}x${ROWS}"
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
    # **Windows + ZWJ 계열은 돌리지 않는다 — alacritty 가 멈춘다.** 실기에서 재현 조건을
    # 좁혔다 ([#381](https://github.com/ensky0/tildaz/issues/381), Ryzen AI 7 350 · Windows 11):
    #
    #   - 워크로드 11 종 × 8 MiB 를 한 번씩 돌려 **`zwj` 와 `zwj_varied` 둘만** 멈췄다
    #     (나머지 9 종은 978~1,746 ms 로 완주). `cjk` 도 ZWJ 를 담지만 줄에 몇 개뿐이라
    #     멀쩡하다 — **ZWJ 밀도**가 임계를 넘을 때만 난다.
    #   - `zwj` 는 1 MiB 는 완주하고 **2 MiB 부터 멈춘다** (8 MiB 2/2 멈춤).
    #   - 멈춘 회차의 producer 는 **CPU 시간이 0 이 아니다** (0.016~0.047 s) — 출력을 하다가
    #     write 에서 막힌 것이다. 창에 입력 이벤트를 주면 조금 진행하고 다시 막힌다.
    #     alacritty 가 back-pressure 상황에서 ConPTY 출력을 그만 소비하는 것으로 보인다.
    #
    # 예전 주석의 "`main` 진입 전에 멈춘다 · CPU 시간 0" 은 **틀렸다** (위 실측으로 반증).
    #
    # 30 초씩 기다렸다 버리느니 아예 빼고 그 사실을 표에 적는다. 다른 platform 은 영향 없다.
    if [ "$IS_WINDOWS" = 1 ] && { [ "$WORKLOAD" = zwj ] || [ "$WORKLOAD" = zwj_varied ]; }; then
        printf '%-14s %s\n' alacritty "건너뜀 (Windows + $WORKLOAD 은 alacritty 가 멈춰요)"
        printf '%s\tunsupported\t0\t0\t0\t0\n' alacritty >> "$RESULTS"
    elif [ "$IS_WINDOWS" = 1 ]; then
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

# iTerm2 — macOS 전용. 다른 대상 (alacritty · kitty · wezterm · ghostty) 이 전부 개발자
# 취향의 선택지라 **일반 macOS 사용자가 실제로 쓰는 터미널**이 비교에 없었다. Windows 의
# `wt` · Linux 의 `foot` 과 같은 자리다 ([#381](https://github.com/ensky0/tildaz/issues/381)).
#
# **Dynamic Profiles 로 준다** — `~/Library/Application Support/iTerm2/DynamicProfiles/` 에
# JSON 을 놓으면 iTerm2 가 파일 감시로 읽어 프로파일이 생긴다. 격자 · scrollback · 실행
# 명령을 한 파일에 담을 수 있고 **사용자 설정을 건드리지 않는다.**
#
# 다른 길은 전부 막혔다 (macOS 실측, #381):
#   - CLI (`open -na iTerm.app --args`) 에 격자 옵션이 없다.
#   - AppleScript 로 창을 만든 뒤 크기를 바꾸면 **명령이 먼저 시작돼** 그 시점 격자로
#     출력한다 — Terminal.app 에서 이 순서 문제를 실측했다 (AppleScript 는 120x40 이라
#     보고하는데 shell 은 30x120 을 봤다). 프로파일이라야 처음부터 맞는다.
#
# `Close Sessions On End` 로 명령이 끝나면 세션이 닫힌다 — 회차마다 창이 쌓이지 않는다
# (ghostty 의 `abnormal-command-exit-runtime = 0` 과 같은 목적).
if [ "$IS_MACOS" = 1 ] && [ -d /Applications/iTerm.app ]; then
    T="$WORK_DIR/iterm2.timing"
    mkdir -p "$ITERM_PROFILE_DIR"
    cat > "$ITERM_PROFILE_FILE" << EOF
{
  "Profiles": [{
    "Name": "$ITERM_PROFILE_NAME",
    "Guid": "$ITERM_PROFILE_NAME",
    "Columns": $COLS,
    "Rows": $ROWS,
    "Scrollback Lines": $SCROLLBACK,
    "Unlimited Scrollback": false,
    "Custom Command": "Yes",
    "Command": "$(producer_cmd "$T")",
    "Close Sessions On End": true
  }]
}
EOF
    # 파일 감시로 읽으므로 반영을 기다린다. 바로 창을 만들면 프로파일이 없어서 실패한다.
    sleep 2
    # 회차 정리가 이 실행의 창을 닫도록 표시한다 (`iterm2_window_close`).
    ITERM_WINDOW_OPENED=1
    # 창을 만든 **뒤** hide 를 푼다 — 이유는 `mac_app_unhide` 주석에 있다. 순서가 중요하다:
    # 창이 생기기 전에 풀면 그 뒤에 만들어진 창이 다시 안 보이는 상태로 남을 수 있다.
    run_terminal iterm2 osascript \
        -e "tell application \"iTerm\" to create window with profile \"$ITERM_PROFILE_NAME\"" \
        -e 'tell application "System Events" to set visible of process "iTerm2" to true'
fi

# Terminal.app — macOS 의 OS 기본 터미널이라 **Windows 의 conhost 와 같은 자리**다 (#414).
# 하한 기준선이자, 시스템 기본 터미널이 어느 정도인지 보여 주는 대조군이다.
#
# **격자는 escape sequence 로 준다** — `CSI 8 ; rows ; cols t` 로 **셸이 자기 손으로 창을
# 리사이즈**한다. 프로파일이 필요 없고 사용자 설정에 흔적이 안 남는다.
#
# [#381](https://github.com/ensky0/tildaz/issues/381#issuecomment-5220061290) 에서 막혔던 세
# 방법 (AppleScript 로 창을 만든 뒤 격자 변경 · `defaults` 임시 프로파일 · `.terminal` 파일)
# 은 셋 다 *Terminal.app 에게 격자를 알려 주는* 통로를 찾고 있었다. 이건 방향이 반대라 그
# 구조에 아예 걸리지 않는다 — macOS 실측 3/3 에서 `stty size` 가 목표 격자와 일치했다.
#
# **`exec` 가 중요하다.** 로그인 셸을 wrapper 로 대체하므로 producer 가 끝나는 순간 그 창에
# 실행 중인 프로세스가 없다. 그래야 회차 정리가 확인 시트 없이 창을 닫는다
# (`terminal_app_close` 주석). `exec` 없이 닫으려다 시트에 막히는 것을 실측했다.
#
# **scrollback 은 못 맞춘다** — AppleScript 사전에 크기 속성이 아예 없다 (있는 `history` 는
# 내용 읽기 전용이다). 사용자 프로파일 값이 그대로 쓰이므로 **이 대상만 조건이 다르고**,
# 위의 scrollback 경고가 매 실행에서 그 사실을 알린다.
#
# 앱은 `/System/Applications/Utilities/Terminal.app` 에 항상 있어서 존재 검사를 두지 않는다
# (iTerm2 · ghostty 처럼 설치 여부가 갈리는 대상과 다르다).
if [ "$IS_MACOS" = 1 ]; then
    T="$WORK_DIR/terminal.timing"
    # 태그에 pid 를 넣어 **이 실행이 만든 창만** 고른다. 앞선 실행이 남긴 창이 있어도 안 건드린다.
    TERMINAL_APP_TAG="TildaZ-stress-$$"
    TERMINAL_WRAPPER="$WORK_DIR/terminal-app.sh"
    # heredoc 이 `\033` 은 리터럴로 두고 `${ROWS}` 만 확장한다 (unquoted heredoc 의 백슬래시는
    # `$` · 백틱 · `\` · 개행 앞에서만 특수하다).
    cat > "$TERMINAL_WRAPPER" << EOF
#!/bin/sh
printf '\033[8;${ROWS};${COLS}t'
$(producer_cmd "$T")
EOF
    chmod +x "$TERMINAL_WRAPPER"
    # `do script` 가 돌려주는 **tab** 에 태그를 단다. `front window` 로 잡으면 그 찰나에
    # 사용자가 다른 창을 앞으로 가져왔을 때 **사용자 창에 태그가 붙어 나중에 닫히므로**
    # 그렇게 하지 않는다.
    run_terminal terminal osascript \
        -e 'tell application "Terminal"' \
        -e "set t to do script \"exec sh '$TERMINAL_WRAPPER'\"" \
        -e "set custom title of t to \"$TERMINAL_APP_TAG\"" \
        -e 'end tell' \
        -e 'tell application "System Events" to set visible of process "Terminal" to true'
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
        "TILDAZ_STRESS_GRID=${COLS}x${ROWS}" \
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
# - `-p` 로 위 `wt_fragment_apply` 가 만든 측정용 프로필을 고른다. scrollback 이 거기서 온다.
#
# ⚠ **`--size` 는 `-p` 보다 앞에 와야 한다.** `-p` 를 주면 파서가 서브커맨드 모드로 들어가서
#   뒤따르는 `--size` 를 못 받고 `The following argument was not expected: --size` 로 죽는다
#   (실측, #381). wezterm 의 `--config` 가 `start` 앞에 와야 하는 것과 같은 종류다.
if [ "$IS_WINDOWS" = 1 ] && command -v wt >/dev/null 2>&1; then
    # 표 이름은 실행 파일명 `wt` 를 쓴다 — "windows-terminal" 은 표의 이름 칸 (14) 을 넘겨
    # 줄이 밀린다.
    if [ -n "$WT_FRAGMENT_DIR" ]; then
        run_terminal_win wt wt -w new --size "$COLS,$ROWS" -p "$WT_PROFILE_NAME" \
            "$(native_path "$PRODUCER")"
    else
        # fragment 를 못 만든 경우 (LOCALAPPDATA 없음 등) — 기본 프로필로 돈다. 그때는
        # scrollback 이 사용자 설정값이라 다른 대상과 조건이 다르다.
        echo "⚠ wt 측정용 프로필을 못 만들었어요 — 기본 프로필로 돌아요 (scrollback 이 안 맞아요)"
        run_terminal_win wt wt -w new --size "$COLS,$ROWS" \
            "$(native_path "$PRODUCER")"
    fi
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
        # 캡처가 창을 찾을 수 있게 제목을 박는다 — 프로세스로는 못 찾기 때문이다
        # (`win_proc_name` 의 conhost 주석). 제일 앞에 두어 창이 뜨자마자 식별되게 한다.
        printf 'title %s\r\n' "$CONHOST_TITLE"
        printf 'mode con: cols=%s lines=%s\r\n' "$COLS" "$ROWS"
        printf 'set "TILDAZ_STRESS_WORKLOAD=%s"\r\n' "$WORKLOAD"
        printf 'set "TILDAZ_STRESS_BYTES=%s"\r\n' "$BYTES"
        printf 'set "TILDAZ_STRESS_TIMING_FILE=%s"\r\n' "$(native_path "$T")"
        # `TILDAZ_STRESS_HOLD_MS` 는 안 박는다 — `run_terminal` 이 시도마다 export 한 값을
        # 이 `.cmd` 가 상속받는다 (#413 재시도). 여기 박으면 파일이 한 번만 쓰이므로 늘린
        # hold 가 반영되지 않는다.
        printf 'set "TILDAZ_STRESS_GRID=%s"\r\n' "${COLS}x${ROWS}"
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
while IFS="$(printf '\t')" read -r name samples cols rows cols0 rows0 wait_max; do
    if [ "$samples" = "unsupported" ]; then
        printf '%-14s %12s %10s %17s %10s  %s\n' "$name" - - - - "측정 불가 — 위 안내 참고"
        continue
    fi
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
        # 출력 도중에 창 크기가 바뀌었다는 뜻이다 (터미널이 셸 spawn 뒤 resize). producer 가
        # 목표 그리드를 기다리게 된 뒤로는 (`TILDAZ_STRESS_GRID`) 여기 걸리는 것이 곧
        # **상한까지 기다려도 목표에 도달하지 못했다**는 뜻이다.
        note="측정 중 resize (${cols0}x${rows0} → ${cols}x${rows})"
    fi
    # 목표 그리드를 기다린 시간. 오염은 아니지만 (기다린 만큼 출력은 온전하다) 그 대상이
    # 얼마나 늦게 resize 하는지가 여기 드러난다.
    if [ -n "${wait_max:-}" ] && [ "${wait_max:-0}" -gt 0 ]; then
        note="${note}${note:+ · }그리드 대기 ${wait_max} ms"
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
    # 서브셸에서도 남는 파일에서 센다 (위 `CAPTURE_LOG` 주석).
    CAPTURE_FAILED=$(capture_count failed)
    CAPTURE_NOWIN_TOTAL=$(capture_count nowin)
    CAPTURE_FELLBACK_TOTAL=$(capture_count fellback)
    CAPTURE_BLANK_TOTAL=$(capture_count blank)
    # 대상별로 한 줄씩 쌓인 재시도 횟수를 합친다.
    CAPTURE_RETRY_TOTAL=$(awk '{ n += $1 } END { print n + 0 }' "$CAPTURE_RETRY_LOG")
    echo ""
    echo "캡처: $CAPTURE_DIR"
    echo "  @ = 창 단위로 찍었고 내용 있음 · _ = 찍혔지만 사실상 빈 이미지 · ~ = 창 단위 실패로"
    echo "  전체 화면 · ? = 창을 못 찾음 · ! = 실패"
    if [ "$CAPTURE_RETRY_TOTAL" -gt 0 ]; then
        echo "ℹ ${CAPTURE_RETRY_TOTAL} 회차는 첫 시도가 실패해 hold 를 ${CAPTURE_RETRY_HOLD_MS} ms 로 늘려 다시 찍었어요."
        echo "  표시는 마지막 시도의 결과예요. 자주 뜨면 --hold-ms 를 올려 두는 게 나아요 (#413)."
    fi
    if [ "$CAPTURE_BLANK_TOTAL" -gt 0 ]; then
        echo "⚠ ${CAPTURE_BLANK_TOTAL} 회차는 PNG 이 ${CAPTURE_MIN_BYTES} byte 미만이라 **사실상 비어 있어요** (_)."
        echo "  hold 를 늘려 다시 찍고도 그랬다면, 그 대상은 이 경로로 못 찍는 거예요."
    fi
    if [ "$CAPTURE_NOWIN_TOTAL" -gt 0 ]; then
        echo "⚠ ${CAPTURE_NOWIN_TOTAL} 회차는 대상 창을 못 찾았어요 (?). 그 회차는 창을 앞으로 올리지도"
        echo "  (0,0) 으로 옮기지도 못했으니, PNG 에 대상이 있어도 우연이에요."
        echo "  이건 hold 를 늘려도 안 고쳐져요 — 오히려 앞 회차 창이 오래 남아 wt 처럼 기존"
        echo "  프로세스를 재사용하는 대상에서 더 자주 나요 (#413)."
    fi
    if [ "$CAPTURE_FELLBACK_TOTAL" -gt 0 ]; then
        echo "⚠ ${CAPTURE_FELLBACK_TOTAL} 회차는 창 단위 캡처가 안 돼 전체 화면으로 물러섰어요 (~)."
        echo "  hold 를 늘려 다시 찍고도 그랬다는 뜻이에요. 그 PNG 은 다른 창에 가리거나 최대화된"
        echo "  창 때문에 대상이 빠질 수 있으니 눈으로 확인해 주세요."
    fi
    echo "⚠ 전체 화면으로 찍힌 PNG (~ · ? · macOS 에서 창 못 찾음 · 리눅스 전체) 은 대상이 다른 창"
    echo "  뒤에 있으면 안 보여요. PNG 을 눈으로 확인해 주세요."
    if [ "$CAPTURE_FAILED" -gt 0 ]; then
        echo "⚠ ${CAPTURE_FAILED} 회차가 안 찍혔어요. 권한 (macOS 화면 기록) · 캡처 도구 유무 (리눅스) ·"
        echo "  hold (${CAPTURE_HOLD_MS} ms) 안에 캡처가 못 끝났는지를 보세요."
    fi
fi
