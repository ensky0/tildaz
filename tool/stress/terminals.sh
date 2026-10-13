#!/bin/sh
# 비교 대상 터미널을 띄우고 닫는 코드 — 지표 도구들이 함께 쓴다 (#756).
#
# 대상마다 "격자 · scrollback 을 맞춰 띄우고, 그 안에서 producer 를 돌리고, 닫는" 방법이 다르고
# 함정도 대상마다 쌓여 있다 (wt 프로필 · iTerm2 Dynamic Profile · Terminal.app 확인 시트 · Ghostty
# config 파일). 처리량 (`compare-terminals.sh`) 말고 다른 지표도 똑같이 띄우고 닫아야 하므로,
# 그 코드를 복사하지 않고 여기 한 벌만 둔다. 원래 `compare-terminals.sh` 안에 있던 것을 그대로
# 옮겼다 — 주석의 실측 기록도 함께 왔다.
#
# **source 해서 쓴다.** 부르는 쪽이 정해 둘 것:
#   - `REPO_ROOT` · `COLS` · `ROWS` · `SCROLLBACK` — source 전에
#   - `PRODUCER_ENV` — producer 에게 줄 지표 몫 환경변수 (`KEY=VALUE` 한 줄에 하나)
#   - `run_terminal <이름> <명령…>` — 대상 하나를 띄우고 재는 함수. 지표마다 다르다
#   - `terminal_skip <이름>` — (선택) 0 을 돌려주면 그 대상을 건너뛴다. 안내 출력도 그쪽 몫이다
#
# 순서: source → `terminals_init` (producer 경로 · `WORK_DIR`) → `terminals_launch_all`.
# 끝날 때 `terminals_cleanup_all` 을 부른다 (EXIT trap).

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

# 자식이 **Windows 실행파일**이면 경로를 Windows 형식으로 줘야 한다. MSYS 는 명령줄 인자를
# 자동 변환하지만 **환경변수 값은 변환하지 않는다** — producer 가 timing 파일을 열지 못하는
# 원인이 그것이다.
native_path() {
    if [ "$IS_WINDOWS" = 1 ]; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# producer 경로와 이 실행의 작업 디렉터리. `WORK_DIR` 은 대상을 고르는 표식이기도 하다 —
# 아래 `cleanup_terminals` 가 그 경로가 명령줄에 든 프로세스만 정리한다.
#
# `WORK_DIR` 을 마지막에 둔다 — 함수의 마지막 명령이 `[ … ] && …` 이면 거짓일 때 함수가 1 을
# 돌려줘 `set -e` 가 부르는 쪽을 끝낸다.
terminals_init() {
    PRODUCER="$REPO_ROOT/zig-out/bin/tildaz-stress"
    [ "$IS_WINDOWS" = 1 ] && PRODUCER="$PRODUCER.exe"
    WORK_DIR=$(mktemp -d)
}

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
# Terminal.app 측정 탭에 줄 프로필 (settings set) 이름. **비우면 사용자 기본 프로필**이다 (지금까지와
# 같다). 프로필은 색 · 투명도까지 담아서, 기본 프로필이 반투명이면 이 대상만 합성 비용이 다른 조건이
# 된다 (2026-10-13 · 이 기기의 기본은 `Clear Dark`). 대조할 때 `Basic` (불투명) 을 준다 (#756).
TERMINAL_APP_SETTINGS="${TERMINAL_APP_SETTINGS:-}"

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
# 우리 창은 **세션의 프로필 이름**으로 고른다 (`iterm2_windows`). #414 때는 창 이름이 곧 프로파일
# 이름이라 이름으로 골랐는데 (`[tildaz-stress]` 와 `[-bash]` 가 갈렸다), iTerm2 3.7.4 에서는 창 이름이
# 실행 중인 명령이라 그 방식이 창을 하나도 못 닫았다 (#756, 2026-10-13 실측).
#
# **AppleScript 의 `windows` 목록에는 닫은 뒤에도 항목이 남을 수 있다.** 실제로 닫혔는지는
# ScreenCaptureKit 의 창 목록으로 확인했다 (화면에서 사라진다). Terminal.app 도 같다.
ITERM_WINDOW_OPENED=0
# 측정용 프로파일 이름. wt 의 `WT_PROFILE_NAME` 과 같은 자리이고, 아래 프로파일 JSON · 창 생성 ·
# 창 정리가 모두 이 값을 쓴다.
ITERM_PROFILE_NAME="tildaz-stress"
iterm2_window_close() {
    [ "$ITERM_WINDOW_OPENED" = 1 ] || return 0
    iterm2_windows close-ours >/dev/null || true
}

# iTerm2 의 창을 **세션의 프로필 이름**으로 가른다 (#756).
#
#   iterm2_windows ids            우리 창 (프로필이 `ITERM_PROFILE_NAME`) 의 id — 한 줄에 하나
#   iterm2_windows close-ours     우리 창과, 세션이 끝나 탭이 없는 빈 창을 닫는다
#   iterm2_windows close-others   우리 창도 빈 창도 아닌 창을 닫는다 (`mac_close_woken_extras`)
#
# **창 이름으로는 못 가른다.** #414 때는 창 이름이 프로필 이름이었는데, iTerm2 3.7.4 에서는 실행 중인
# 명령이다 (측정 창 `sh` · 기본 창 `-bash` — 2026-10-13 실측). 그래서 이름으로 고르던 예전 정리는 창을
# 하나도 못 닫았다. AppleScript 의 창 `id` 는 화면 창 id (`CGWindowID`) 와 같다 (같은 날 실측 —
# `create window` 가 돌려준 id 와 `color-capture --list` 의 id 가 같았다).
#
# 빈 창 — `Close Sessions On End` 는 세션만 닫아서 탭이 없는 창이 남는다 (#414). 깨운 앱에는 사용자
# 창이 없고, 사용자 창은 늘 세션이 있으니 빈 창은 우리 것으로 본다.
#
# 앱이 안 떠 있을 때 부르면 AppleScript 가 앱을 **띄운다** — 부르는 쪽이 조건을 본다.
iterm2_windows() {
    osascript - "$1" "$ITERM_PROFILE_NAME" 2>/dev/null << 'APPLESCRIPT'
on run argv
    set mode to item 1 of argv
    set prof to item 2 of argv
    set out to ""
    tell application "iTerm"
        repeat with w in (get every window)
            set mine to false
            set empty to false
            try
                if (count of tabs of w) is 0 then set empty to true
            end try
            try
                if (profile name of current session of w) is prof then set mine to true
            end try
            if mode is "ids" then
                if mine then set out to out & (id of w) & linefeed
            else if mode is "close-ours" then
                if mine or empty then close w
            else if mode is "close-others" then
                if not mine and not empty then close w
            end if
        end repeat
    end tell
    return out
end run
APPLESCRIPT
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

# 측정이 **깨운** 앱은 끝날 때 종료한다 (#756). macOS 전용이다.
#
# Terminal.app · iTerm2 는 이미 떠 있는 프로세스에 창을 붙이는 방식이라, 꺼져 있던 앱은 측정이
# 깨운다. 그때 앱이 **스스로 기본 창 (로그인 셸) 을 하나 연다** — 우리가 단 태그가 없어서
# `terminal_app_close` · `iterm2_window_close` 가 닫지 않는다. 앱이 그 창과 함께 남으면 **다음
# 실행의 위생 검사가 "대상 터미널이 떠 있다" 로 멈춘다** (`hygiene.sh`). 워크로드를 이어서 재면
# 두 번째에서 멈추던 원인이다 (2026-10-13 macOS 실기 — 두 앱에 `-bash` 창이 하나씩 남았다).
#
# **띄우기 직전에 떠 있지 않았던 앱만** 종료한다 (`*_APP_WOKE`). 위생 검사가 시작 때 두 앱이
# 꺼져 있음을 보장하지만, `--ignore-hygiene` 실행에서는 사용자가 쓰던 앱일 수 있다.
#
# **iTerm2 는 기본 설정이면 `quit` 에 "Quit iTerm2?" 확인 창을 띄워 멈춘다.** 측정 기기에서는
# Settings → General → Closing 의 *Confirm "Quit iTerm2" Command* 를 꺼 둔다 (`README.md` 의
# iTerm2 절). Terminal.app 은 로그인 셸만 있는 창이면 묻지 않는다 (실측).
#
# 종료가 끝날 때까지 기다린다 — 바로 이어지는 실행의 위생 검사가 아직 지워지는 중인 프로세스를
# 볼 수 있다.
TERMINAL_APP_WOKE=0
ITERM_APP_WOKE=0
mac_app_quit() {
    # $1 = AppleScript 의 앱 이름, $2 = 프로세스 이름 (iTerm2 는 둘이 다르다)
    osascript -e "tell application \"$1\" to quit" >/dev/null 2>&1 || true
    _q=0
    while pgrep -x "$2" >/dev/null 2>&1 && [ "$_q" -lt 20 ]; do
        sleep 0.25
        _q=$((_q + 1))
    done
    if pgrep -x "$2" >/dev/null 2>&1; then
        echo "⚠ 측정이 깨운 $1 이 5 초 안에 안 끝났어요 — 확인 창이 떠 있는지 봐요 (README 의 iTerm2 절)." >&2
    fi
}
# 측정이 깨운 앱이 **스스로 연 기본 창을 닫는다** (#756). 측정 창이 뜬 뒤에 부른다.
#
# 기본 창이 측정 창 위에 겹치면, 측정 창을 누르려던 클릭이 기본 창으로 가서 키가 측정 창에 안
# 닿는다 (2026-10-13 macOS 실측 — Terminal.app 의 측정 창 가운데가 기본 창 안에 있어 키 10 개 중 9 개를
# 놓쳤다). 깨운 앱만이라 사용자 창은 없고, 기본 창은 빈 로그인 셸이라 확인 없이 닫힌다 (실측).
#
# Terminal.app 은 AppleScript 의 창 이름에 든 태그로, iTerm2 는 세션의 프로필 이름으로 가른다
# (`iterm2_windows`). 처음에 iTerm2 도 창 이름으로 갈랐다가 측정 창까지 닫았다 — 3.7.4 의 창 이름은
# 실행 중인 명령 (`sh`) 이라 프로필 이름이 없다 (2026-10-13 실측).
mac_close_woken_extras() {
    case "$1" in
        terminal)
            [ "$TERMINAL_APP_WOKE" = 1 ] || return 0
            osascript -e "tell application \"Terminal\" to close (every window whose name does not contain \"$TERMINAL_APP_TAG\")" \
                >/dev/null 2>&1 || true
            ;;
        iterm2)
            [ "$ITERM_APP_WOKE" = 1 ] || return 0
            iterm2_windows close-others >/dev/null || true
            ;;
    esac
    return 0
}

mac_app_quit_woken() {
    [ "$TERMINAL_APP_WOKE" = 1 ] && mac_app_quit Terminal Terminal
    [ "$ITERM_APP_WOKE" = 1 ] && mac_app_quit iTerm iTerm2
    return 0
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

# 이 파일이 띄운 것을 모두 되돌린다. EXIT trap 에서 부른다.
#
# ⚠️ 각 단계를 `|| true` 로 끊는다 — 이유는 `compare-terminals.sh` 의 trap 주석에 있다.
terminals_cleanup_all() {
    cleanup_terminals || true
    # 창을 닫은 **뒤에** 앱을 끝낸다 — 측정 창이 남아 있으면 그 셸 때문에 종료를 물을 수 있다.
    mac_app_quit_woken || true
    wt_fragment_remove || true
    wt_stub_remove || true
    iterm2_profile_remove || true
}

# producer 에게 줄 환경변수. **여기 한 곳에서만 만든다** (#756) — 예전에는 `producer_cmd` ·
# `run_terminal_win` · TildaZ 절 · conhost 절이 같은 목록을 따로 적었다. 지표를 하나 더하려면
# 네 곳을 다 고쳐야 했고, 하나만 빠져도 그 대상만 다른 조건으로 돈다.
#
# 지표 몫 (`PRODUCER_ENV`) 이 먼저, 대상마다 다른 timing 경로와 목표 격자가 뒤에 온다. 값에 공백을
# 넣지 않는다 — 아래 셸 명령 한 줄과 `env` 인자로 그대로 들어간다.
#
# **`TILDAZ_STRESS_HOLD_MS` 는 여기서 안 준다** — `run_terminal` 이 시도마다 export 한다 (#413 의
# 재시도). 이 목록은 대상마다 **한 번** 만들어지므로 여기에 값을 박으면 재시도가 늘린 hold 가
# 반영되지 않는다. 자식은 환경에서 상속받는다.
PRODUCER_ENV=""
producer_env_lines() {
    [ -z "$PRODUCER_ENV" ] || printf '%s\n' "$PRODUCER_ENV"
    printf 'TILDAZ_STRESS_TIMING_FILE=%s\n' "$(native_path "$1")"
    printf 'TILDAZ_STRESS_GRID=%s\n' "${COLS}x${ROWS}"
}

# producer 를 셸 명령 한 줄로. 터미널마다 이 문자열을 자기 방식으로 실행한다.
producer_cmd() {
    printf 'env %s %s' "$(producer_env_lines "$1" | tr '\n' ' ' | sed 's/ $//')" "$PRODUCER"
}

# conhost 창을 찾을 제목. `mode con:` 과 함께 `conhost.cmd` 안에서 `title` 로 박는다.
CONHOST_TITLE="TildaZ-stress-conhost"
# TildaZ 측정 창의 클래스와 제목. **소스의 단일 원본은 `src/instances.zig`** 다
# (`window_class_name` · `stress_window_title`). worker 는 `TildaZ-<번호>` 라서 제목이 겹치지
# 않는다 — 그 계약을 `instances.zig` 의 테스트가 지킨다.
#
# **판마다 이름이 다르다** (#654) — dev 빌드 (기본) `TildaZ-devWindow` · `TildaZ-dev-stress`, 릴리즈
# (`-Drelease=true`) `TildaZWindow` · `TildaZ-stress`. 예전에는 릴리즈 이름만 있어서 기본 빌드의 창을
# 못 찾았다 (2026-10-10 #692 Windows 회차에서 발견). 그래서 `;` 로 이은 **후보 목록**이고, 같은 자리끼리
# 짝이다 — 아래 PowerShell 의 `Find-Target` 이 차례로 찾는다.
TILDAZ_CLASS="TildaZ-devWindow;TildaZWindow"
TILDAZ_TITLE="TildaZ-dev-stress;TildaZ-stress"

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
# [`dist/macos/Info.plist.in`](../../dist/macos/Info.plist.in) 이 원본이다.
mac_bundle_id() {
    case "$1" in
        terminal) printf 'com.apple.Terminal' ;;
        iterm2) printf 'com.googlecode.iterm2' ;;
        kitty) printf 'net.kovidgoyal.kitty' ;;
        alacritty) printf 'org.alacritty' ;;
        wezterm) printf 'com.github.wez.wezterm' ;;
        ghostty) printf 'com.mitchellh.ghostty' ;;
        # dev 빌드 (기본) 는 `me.ensky0.tildaz.dev` 다 (#654) — 창을 고르는 awk 가 `.dev` 도 받는다.
        tildaz) printf 'me.ensky0.tildaz' ;;
        *) printf '' ;;
    esac
}

# macOS 에서 대상의 창 id 를 찾는다 (#756 에서 `compare-terminals.sh` 의 캡처에서 옮겼다).
#
#   mac_window_of <대상 이름> <color-capture 경로> [측정 전 창 id 목록 파일] [태그로 좁힘 (1)]
#
# bundle id 가 같거나 (dev 빌드는 `.dev` 가 붙는다), **앱 이름이 대상 이름으로 시작하는** 창이다.
# 앱 이름을 함께 보는 이유는 CLI 로 띄운 alacritty 가 LaunchServices 를 안 거쳐 bundle id 가 비어서다
# (`color-capture_macos.m` 의 `--list` 주석). 여러 개면 id 가 가장 큰 것 (가장 새 창).
#
# - 셋째 인자를 주면 **그 파일에 적힌 창은 뺀다** — 측정 전부터 있던 같은 앱의 창을 고르지 않게.
# - 넷째 인자가 1 이면 **우리 창만** 고른다. 꺼져 있던 앱을 깨우면 앱이 스스로 기본 창을 하나 더
#   열기 때문이다 (`mac_app_quit_woken` 주석). Terminal.app 은 제목에 든 태그로, iTerm2 는 세션의 프로필
#   이름으로 가른다 (`iterm2_windows` — 3.7.4 에서는 제목에 프로필 이름이 안 든다).
mac_window_of() {
    _mw_tag=""
    if [ "${4:-0}" = 1 ]; then
        case "$1" in
            terminal) _mw_tag="$TERMINAL_APP_TAG" ;;
            iterm2)
                iterm2_windows ids | awk 'NF' | sort -n | tail -1
                return 0
                ;;
        esac
    fi
    "$2" --list 2>/dev/null |
        awk -v b="$(mac_bundle_id "$1")" -v t="$1" -v tag="$_mw_tag" -v ex="${3:-}" '
            BEGIN { if (ex != "") while ((getline l < ex) > 0) skip[l] = 1 }
            NR == 1 || ($1 in skip) { next }
            (b != "" && ($2 == b || $2 == b ".dev")) || index(tolower($3), t) == 1 {
                if (tag == "" || index($0, tag) > 0) print $1
            }' |
        sort -n | tail -1
}

# macOS 에서 그 대상의 **본체 프로세스** 실행 파일 경로에 든 문자열 (`tool/proc-usage_macos.c` 의 `find`).
# 경로는 `proc_pidpath` 가 주는 실제 경로다 — Homebrew 의 `alacritty` · `wezterm-gui` 는 앱 번들 안으로
# 가는 링크라 번들 경로로 찾는다 (확인 필요 — 못 찾으면 `compare-memory.sh` 가 그 회차를 `?` 로 남긴다).
mac_proc_path_of() {
    case "$1" in
        kitty) printf '/kitty.app/Contents/MacOS/kitty' ;;
        alacritty) printf '/Contents/MacOS/alacritty' ;;
        wezterm) printf '/wezterm-gui' ;;
        ghostty) printf '/Ghostty.app/Contents/MacOS/ghostty' ;;
        iterm2) printf '/iTerm.app/Contents/MacOS/iTerm2' ;;
        terminal) printf '/Terminal.app/Contents/MacOS/Terminal' ;;
        tildaz) printf '%s' "$TILDAZ_BIN" ;;
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

# 저장소 빌드본을 찾아 `TILDAZ_BIN` 에 둔다 — 설치본은 버전이 다를 수 있다. `terminals_launch_all` ·
# `terminals_open_all` 이 같이 쓴다.
terminals_find_tildaz() {
    TILDAZ_BIN=""
    for candidate in \
        "$REPO_ROOT/zig-out/TildaZ-dev.app/Contents/MacOS/tildaz" \
        "$REPO_ROOT/zig-out/bin/tildaz" \
        "$REPO_ROOT/zig-out/bin/tildaz.exe"
    do
        if [ -x "$candidate" ]; then TILDAZ_BIN="$candidate"; break; fi
    done
    return 0
}

# macOS 대상을 **LaunchServices (`open`)** 로 띄운다 — 시작 시간 (`compare-startup.sh`, #756).
#
# 사용자가 Dock · Spotlight 로 앱을 여는 길과 같다 (2026-10-13 사용자 결정). `terminals_launch_all` 은 대상마다
# CLI · `open` · AppleScript 가 섞여 있어서, 띄운 **뒤**를 재는 처리량 · 지연에는 상관없지만 시작 시간에는
# AppleScript 대상 (Terminal.app · iTerm2) 에만 `osascript` 비용이 섞인다.
#
# - 실행할 것은 `$PRODUCER` (실행 권한이 있는 스크립트) 하나다. `open` 은 환경변수를 넘기지 않으니
#   (`--env` 는 있지만 대상마다 앱 안에서 다시 넘어가는지 갈린다) 스크립트가 스스로 다 알아야 한다.
# - **격자 · scrollback 은 맞추지 않는다.** 각 앱의 기본 설정으로 연다 — 사용자가 여는 그대로다.
# - Terminal.app · iTerm2 는 인자로 명령을 못 받아서 **스크립트 파일을 연다** (`open -a <앱> <파일>`).
#   iTerm2 는 기본 설정이면 *"OK to run …?"* 경고로 멈춘다 — 측정 기기에서 한 번 끈다 (README).
# - `-n` 은 새 인스턴스다. 한 프로세스에 창을 붙이는 Terminal.app · iTerm2 에는 쓰지 않는다 — 회차마다
#   앱을 종료하므로 어차피 새로 뜬다.
# Linux 대상을 **데스크톱 런처**로 띄운다 — 시작 시간 (`compare-startup.sh`, #756).
#
# 사용자가 메뉴 · 런처로 여는 길이다 (2026-10-13 사용자 결정 — macOS 의 `open` 과 같은 자리). 앱의 설치된
# `.desktop` 을 복사해 **`Exec` 에만** 측정 프로그램을 더하고, 그 파일을 그 DE 의 런처로 연다. 나머지 키
# (`StartupNotify` · `StartupWMClass` 등) 는 그대로라 런처가 하는 일이 같다.
#
#   linux_desktop_launch <대상 이름> <설치된 .desktop> <새 Exec>
#
# - KDE Plasma 는 `kioclient exec <파일>` 이다 (`kioclient --commands` 의 `emacs.desktop` 예). 실행 권한을
#   준다 — 표준 위치 밖의 실행 권한 없는 `.desktop` 은 KIO 가 신뢰하지 않는다.
# - GNOME 은 `gio launch <파일>` 이다 (GLib 의 `GDesktopAppInfo` — 셸의 앱 실행과 같은 라이브러리).
# - `[Desktop Entry]` 절만 남긴다. 뒤의 `[Desktop Action …]` 절에도 `Exec` 가 있어서 함께 바꾸면 안 된다.
linux_desktop_launch() {
    _ld_name="$1"; _ld_src="$2"; _ld_exec="$3"
    _ld_file="$WORK_DIR/$_ld_name.desktop"
    awk -v ex="$_ld_exec" '
        /^\[/ { main = ($0 == "[Desktop Entry]") }
        !main { next }
        /^Exec=/ { print "Exec=" ex; next }
        /^TryExec=/ || /^Actions=/ { next }
        { print }' "$_ld_src" > "$_ld_file"
    chmod +x "$_ld_file"
    case "${XDG_CURRENT_DESKTOP:-}" in
        *GNOME*) run_terminal "$_ld_name" gio launch "$_ld_file" ;;
        *) run_terminal "$_ld_name" kioclient exec "file:$_ld_file" ;;
    esac
}

terminals_open_all() {
    if [ "$IS_MACOS" != 1 ] && [ "$IS_WINDOWS" != 1 ]; then
        # DE 마다 표의 대상 셋이다 (#756 — 그 DE 의 터미널 · TildaZ · Alacritty).
        if [ -f /usr/share/applications/Alacritty.desktop ] && ! terminal_skip alacritty; then
            linux_desktop_launch alacritty /usr/share/applications/Alacritty.desktop "alacritty -e $PRODUCER"
        fi
        case "${XDG_CURRENT_DESKTOP:-}" in
            *GNOME*)
                # `org.gnome.Terminal.desktop` 은 D-Bus 활성화가 아니라 `Exec=gnome-terminal` 이다 (3.60.0) — 그래서
                # 다른 대상처럼 `Exec` 만 바꾸면 런처가 같은 일을 한다.
                if [ -f /usr/share/applications/org.gnome.Terminal.desktop ] && ! terminal_skip gnome-terminal; then
                    linux_desktop_launch gnome-terminal /usr/share/applications/org.gnome.Terminal.desktop \
                        "gnome-terminal -- $PRODUCER"
                fi
                ;;
            *)
                if [ -f /usr/share/applications/org.kde.konsole.desktop ] && ! terminal_skip konsole; then
                    linux_desktop_launch konsole /usr/share/applications/org.kde.konsole.desktop "konsole -e $PRODUCER"
                fi
                ;;
        esac
        terminals_find_tildaz
        _ld_tz="${XDG_DATA_HOME:-$HOME/.local/share}/applications/tildaz-dev.desktop"
        if [ -z "$TILDAZ_BIN" ]; then
            echo "tildaz         빌드본이 없어요 — zig build 로 먼저 빌드해 주세요"
        elif [ ! -f "$_ld_tz" ]; then
            echo "tildaz         $_ld_tz 가 없어요 — dist/linux/install.sh 로 dev 판을 한 번 설치해 주세요"
        elif ! terminal_skip tildaz; then
            # 설치본 대신 저장소 빌드본을 띄운다 (`terminals_find_tildaz` 주석과 같은 이유).
            linux_desktop_launch tildaz "$_ld_tz" "$TILDAZ_BIN -e $PRODUCER"
        fi
        return 0
    fi
    [ "$IS_MACOS" = 1 ] || return 0
    if [ -d /Applications/kitty.app ] && ! terminal_skip kitty; then
        run_terminal kitty open -na /Applications/kitty.app --args "$PRODUCER"
    fi
    if [ -d /Applications/Alacritty.app ] && ! terminal_skip alacritty; then
        run_terminal alacritty open -na /Applications/Alacritty.app --args -e "$PRODUCER"
    fi
    if [ -d /Applications/WezTerm.app ] && ! terminal_skip wezterm; then
        run_terminal wezterm open -na /Applications/WezTerm.app --args start --always-new-process -- "$PRODUCER"
    fi
    if [ -d /Applications/Ghostty.app ] && ! terminal_skip ghostty; then
        run_terminal ghostty open -na /Applications/Ghostty.app --args -e "$PRODUCER"
    fi
    if [ -d /Applications/iTerm.app ] && ! terminal_skip iterm2; then
        pgrep -x iTerm2 >/dev/null 2>&1 || ITERM_APP_WOKE=1
        run_terminal iterm2 open -a /Applications/iTerm.app "$PRODUCER"
    fi
    if ! terminal_skip terminal; then
        pgrep -x Terminal >/dev/null 2>&1 || TERMINAL_APP_WOKE=1
        run_terminal terminal open -a Terminal "$PRODUCER"
    fi
    terminals_find_tildaz
    if [ -z "$TILDAZ_BIN" ]; then
        echo "tildaz         빌드본이 없어요 — zig build 로 먼저 빌드해 주세요"
    elif ! terminal_skip tildaz; then
        run_terminal tildaz open -na "${TILDAZ_BIN%%.app/*}.app" --args -e "$PRODUCER"
    fi
    return 0
}

# 건너뛸 대상이 없으면 모두 띄운다. 부르는 쪽이 다시 정의한다 (위 머리 주석).
terminal_skip() { return 1; }

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
        # 목록은 `producer_env_lines` 하나에서 온다. `TILDAZ_STRESS_HOLD_MS` 는 `run_terminal` 이
        # 시도마다 export 한다 (#413 재시도).
        while IFS= read -r _kv; do export "$_kv"; done << EOF
$(producer_env_lines "$WORK_DIR/$_wname.timing")
EOF
        run_terminal "$_wname" "$@"
    )
}

# 대상 전부를 차례로 띄운다. 대상마다 `run_terminal <이름> <명령…>` 을 부른다.
#
# **본문을 들여쓰지 않는다** — 대상 블록 안의 heredoc (Ghostty config · iTerm2 프로필 ·
# Terminal.app wrapper) 은 종료 표시가 줄 맨 앞에 있어야 한다.
terminals_launch_all() {
# --- 터미널별 실행 방법 ---
#
# 실행 방법과 그리드 지정 옵션이 터미널마다 다르다. 그리드가 맞는지는 producer 가 남긴
# 값으로 확인한다 — 표의 grid 열이 목표와 다르면 그 줄은 비교에 쓰지 않는다.

if command -v kitty >/dev/null 2>&1 && ! terminal_skip kitty; then
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

if command -v alacritty >/dev/null 2>&1 && ! terminal_skip alacritty; then
    T="$WORK_DIR/alacritty.timing"
    # Windows + ZWJ 계열은 처리량에서 건너뛴다 — 이유는 `compare-terminals.sh` 의 `terminal_skip`.
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

if command -v wezterm >/dev/null 2>&1 && ! terminal_skip wezterm; then
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
if { [ -d /Applications/Ghostty.app ] || command -v ghostty >/dev/null 2>&1; } && ! terminal_skip ghostty; then
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
if [ "$IS_MACOS" = 1 ] && [ -d /Applications/iTerm.app ] && ! terminal_skip iterm2; then
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
    # 꺼져 있던 앱을 깨우는지 적어 둔다 — 끝날 때 종료한다 (`mac_app_quit_woken`).
    pgrep -x iTerm2 >/dev/null 2>&1 || ITERM_APP_WOKE=1
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
if [ "$IS_MACOS" = 1 ] && ! terminal_skip terminal; then
    T="$WORK_DIR/terminal.timing"
    # 태그에 pid 를 넣어 **이 실행이 만든 창만** 고른다. 앞선 실행이 남긴 창이 있어도 안 건드린다.
    TERMINAL_APP_TAG="TildaZ-stress-$$"
    # 꺼져 있던 앱을 깨우는지 적어 둔다 — 끝날 때 종료한다 (`mac_app_quit_woken`).
    pgrep -x Terminal >/dev/null 2>&1 || TERMINAL_APP_WOKE=1
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
    if [ -z "$TERMINAL_APP_SETTINGS" ]; then
        run_terminal terminal osascript \
            -e 'tell application "Terminal"' \
            -e "set t to do script \"exec sh '$TERMINAL_WRAPPER'\"" \
            -e "set custom title of t to \"$TERMINAL_APP_TAG\"" \
            -e 'end tell' \
            -e 'tell application "System Events" to set visible of process "Terminal" to true'
    else
        # 프로필을 줄 때는 **빈 탭 → 프로필 → wrapper** 순서다. 프로필 (settings set) 이 창 크기도
        # 담을 수 있어서, wrapper 가 격자를 맞춘 뒤에 바꾸면 되돌아갈 수 있다 (확인 필요). 빈 탭의
        # 로그인 셸은 `exec` 로 wrapper 에 대체되니 남지 않는다.
        run_terminal terminal osascript \
            -e 'tell application "Terminal"' \
            -e 'set t to do script ""' \
            -e "set current settings of t to settings set \"$TERMINAL_APP_SETTINGS\"" \
            -e "set custom title of t to \"$TERMINAL_APP_TAG\"" \
            -e "do script \"exec sh '$TERMINAL_WRAPPER'\" in t" \
            -e 'end tell' \
            -e 'tell application "System Events" to set visible of process "Terminal" to true'
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
terminals_find_tildaz

if [ -z "$TILDAZ_BIN" ]; then
    echo "tildaz         빌드본이 없어요 — zig build 로 먼저 빌드해 주세요"
elif ! terminal_skip tildaz; then
    T="$WORK_DIR/tildaz.timing"
    # producer 파라미터는 TildaZ 프로세스의 환경변수로 준다 — 자식(producer)이 상속한다.
    # `-e` 는 실행파일 경로만 받는다 (POSIX 는 PTY 자식의 argv 가 고정이다).
    # `env` 인자로 펼치려고 위치 인자를 빌려 쓴다 (값에 공백이 없다 — `producer_env_lines`).
    set --
    while IFS= read -r _kv; do set -- "$@" "$_kv"; done << EOF
$(producer_env_lines "$T")
EOF
    # GNOME 에서는 `-size` 를 주지 않는다 — layer-shell 이 없어 창 크기를 compositor 가 정하고, 앱이 그 옵션을
    # 받으면 시작을 거부한다 (AGENTS.md 의 `-size` 절 · #506). 격자는 표의 grid 열에 그대로 드러난다 (#756 본문의
    # "GNOME 에서는 TildaZ `-size` 를 못 쓴다").
    case "${XDG_CURRENT_DESKTOP:-}" in
        *GNOME*) set -- "$@" "$TILDAZ_BIN" -e "$(native_path "$PRODUCER")" -scrollback "$SCROLLBACK" ;;
        *) set -- "$@" "$TILDAZ_BIN" -e "$(native_path "$PRODUCER")" -size "${COLS}x${ROWS}" -scrollback "$SCROLLBACK" ;;
    esac
    run_terminal tildaz env "$@"
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
if [ "$IS_WINDOWS" = 1 ] && command -v wt >/dev/null 2>&1 && ! terminal_skip wt; then
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
if [ "$IS_WINDOWS" = 1 ] && command -v conhost >/dev/null 2>&1 && ! terminal_skip conhost; then
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
        # 목록은 `producer_env_lines` 하나에서 온다. `TILDAZ_STRESS_HOLD_MS` 는 안 박는다 —
        # `run_terminal` 이 시도마다 export 한 값을 이 `.cmd` 가 상속받는다 (#413 재시도). 여기
        # 박으면 파일이 한 번만 쓰이므로 늘린 hold 가 반영되지 않는다.
        producer_env_lines "$T" | while IFS= read -r _kv; do printf 'set "%s"\r\n' "$_kv"; done
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
if command -v foot >/dev/null 2>&1 && ! terminal_skip foot; then
    T="$WORK_DIR/foot.timing"
    # `scrollback.lines` 를 꼭 준다 — 기본값이 1,000 이라 빠뜨리면 foot 만 scrollback 이 작은 조건으로
    # 돈다 (#756 에서 발견 — 그 전의 Linux 측정은 그 조건이었다). foot 은 이 값에 보이는 줄 수를 더해
    # 2 의 거듭제곱으로 올려 잡는다 (`foot.ini(5)` 의 `scrollback.lines`).
    run_terminal foot foot --window-size-chars="${COLS}x${ROWS}" \
        -o "scrollback.lines=$SCROLLBACK" \
        sh -c "$(producer_cmd "$T")"
fi

# --- Linux 데스크톱 기본 터미널 셋 (#756) ---
#
# KDE Plasma · GNOME · COSMIC 사용자가 실제로 쓰는 터미널이다. macOS 의 Terminal.app · iTerm2,
# Windows 의 wt · conhost 와 같은 자리다.

if command -v konsole >/dev/null 2>&1 && ! terminal_skip konsole; then
    T="$WORK_DIR/konsole.timing"
    # `--separate` (= `--nofork`) 가 필수다 — 없으면 이미 떠 있는 Konsole 에 창을 붙여 사용자 창과 같은
    # 프로세스에서 그린다 (wezterm 의 `--always-new-process` 와 같은 함정). `-p` 는 이 세션의 프로필 값만
    # 바꾸고 저장하지 않는다. `HistoryMode=1` 은 고정 크기 (`Enumeration.h` 의 `FixedSizeHistory`, 26.08.2).
    #
    # **`XDG_STATE_HOME` 을 빈 폴더로 준다.** "창 크기 기억" (`RememberWindowSize`, 기본 켜짐) 이 켜져 있고
    # `konsolestaterc` 에 저장된 크기가 있으면 Konsole 은 프로필의 격자를 무시한다 (`MainWindow::showEvent`
    # 의 `wasWindowGeometrySaved`). 이 기기에서 `110x28` 로 떴다 (2026-10-13). 빈 폴더면 저장된 크기가 없어
    # 프로필 격자로 뜨고, 끝날 때 측정 창 크기가 사용자 상태 파일에 저장되지도 않는다.
    mkdir -p "$WORK_DIR/konsole-state"
    run_terminal konsole env XDG_STATE_HOME="$WORK_DIR/konsole-state" konsole --separate \
        -p "TerminalColumns=$COLS" -p "TerminalRows=$ROWS" \
        -p HistoryMode=1 -p "HistorySize=$SCROLLBACK" \
        -e sh -c "$(producer_cmd "$T")"
fi

if command -v gnome-terminal >/dev/null 2>&1 && ! terminal_skip gnome-terminal; then
    T="$WORK_DIR/gnome-terminal.timing"
    # 창은 D-Bus 로 뜨는 `gnome-terminal-server` 가 그린다 — 띄운 프로세스의 자손이 아니다.
    # `--wait` 는 명령이 끝날 때까지 이 클라이언트를 붙잡아 두는 것뿐이다. 정리는 서버의 자식인
    # producer 셸 (명령줄에 `WORK_DIR` 이 든다) 을 `cleanup_terminals` 가 끝내서 된다.
    # **scrollback 은 못 맞춘다** — 프로필 (dconf) 설정이라 CLI 로 줄 수 없다. 사용자 프로필 값이
    # 쓰인다 (Terminal.app · conhost 와 같은 "조건이 다른 대상").
    run_terminal gnome-terminal gnome-terminal --wait --geometry="${COLS}x${ROWS}" \
        -- sh -c "$(producer_cmd "$T")"
fi

if command -v cosmic-term >/dev/null 2>&1 && ! terminal_skip cosmic-term; then
    T="$WORK_DIR/cosmic-term.timing"
    # `--no-daemon` 이 없으면 스스로 fork 해 부모가 바로 끝난다 (`main.rs` 의 `fork::daemon`).
    # **격자도 scrollback 도 못 맞춘다** (cosmic-term 1.9.0 `main.rs`) — 창 크기 옵션이 없고,
    # scrollback 은 `scrolling_history: 100_000` 으로 고정이다. 격자는 표의 grid 열에 그대로 드러난다.
    run_terminal cosmic-term cosmic-term --no-daemon \
        -e sh -c "$(producer_cmd "$T")"
fi
}
