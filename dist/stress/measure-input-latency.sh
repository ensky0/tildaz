#!/bin/sh
# 응답 **시간** 측정 (#441 축 ②).
#
# `check-input-loss.sh` 가 *"먹었나"* 를 본다면 이쪽은 **"얼마나 늦게 반영되나"** 를 잰다.
# 예산 4 ms (SPEC §13.3) 가 최악 지연 상한이라는 주장은 지금까지 한 번도 숫자로 확인된 적이
# 없다. 그리고 [#439](https://github.com/ensky0/tildaz/issues/439) 의 *"유휴에서 첫 출력이 한
# 프레임 늦는다"* 도 가설로만 있다 — 이 도구가 그 둘을 숫자로 만든다.
#
#   dist/stress/measure-input-latency.sh                 # idle · flood 둘 다
#   dist/stress/measure-input-latency.sh --mode idle --presses 50
#
# ## 무엇이 재지는가
#
# 앱이 `perf.markInput()` (키 수신) 부터 `perf.completeInput()` (그 뒤 첫 present 완료) 까지를
# 잰다. 그래서 이 값은 **키 → PTY write → 셸 에코 → PTY read → parse → render → present** 를
# 전부 포함한다. 셸 왕복이 섞이지만 **그게 사용자가 실제로 기다리는 시간**이다.
#
# 못 재는 것: `present → 실제 화면 발광` (외부 장비가 필요하다) 과 `키 눌림 → 앱 수신`
# (compositor / OS 몫이 섞인다).
#
# ## 왜 문자 키를 보내는가
#
# `Ctrl+Shift+F12` 같은 앱 단축키로는 못 잰다 — **화면을 안 바꾸므로 present 가 일어나지
# 않는다.** 그러면 `completeInput` 이 불리지 않아 표본이 0 이다. 그래서 `a` 를 보내 에코가
# 화면에 닿기까지를 재고, 끝에 Ctrl+C 로 입력 줄을 비운다.
#
# ## 어디서 도는가 — **Linux · Windows**
#
# 합성 입력이 platform 마다 다르다. Linux 는 `ydotool` (uinput), Windows 는 `SendInput`
# ([`send-keys.ps1`](send-keys.ps1)) 이다. **macOS 는 아직 없다** — `CGEvent` 로 #387 이 이미
# 쓴 경로를 옮겨오면 되지만 하지 않았다. 계측 자체 (`perf.input_latency`) 는 세 platform 에
# 다 있다.
#
# **Windows 는 Git Bash 에서 돌린다** (`compare-terminals.sh` · `measure-repeat.sh` 와 같은
# 제약이다). PowerShell 판을 따로 두지 않는 이유는 `measure-repeat.sh` 헤더에 있다 — #381 에서
# 두 벌이 실제로 갈렸다.
set -u

PRESSES=30
MODE=both
MB=2048
GAP=0.2
SCROLLBACK=32767
# 창을 클릭해 포커스를 줄 시간. **기본은 0 (사람 개입 없음)** 이다 — 새 창은 포커스를
# 자동으로 받는 것이 실측으로 확인됐다 (클릭한 회차와 안 한 회차의 값이 idle 최악
# 12.30 / 12.33 ms 로 사실상 같았다). 표본이 부족하게 나오는 환경에서만 쓴다.
FOCUS_WAIT=0
# 표본 부족(포커스 실패)으로 폐기된 회차를 몇 번까지 다시 돌릴지.
RETRIES=3
IGNORE_HYGIENE=0

usage() {
    cat <<'USAGE'
쓰는 법: dist/stress/measure-input-latency.sh [옵션]

  --presses <N>   보낼 키 횟수 (기본 30)
  --mode <이름>   idle · flood · both (기본 both)
  --mb <N>        flood 모드의 폭포 분량 MiB (기본 2048)
  --gap <초>      키 사이 간격 (기본 0.2 — 각 키가 독립적으로 처리되도록)
  --focus-wait <초>  창을 클릭할 시간을 준다 (기본 0 = 개입 없음).
                     표본이 부족하게 나오는 환경에서만 쓴다
  --retries <N>   폐기된 회차를 다시 돌릴 횟수 (기본 3)
  --ignore-hygiene  위생 점검에 걸려도 강행 (동작 확인용 — 기록용 측정에는 쓰지 않는다)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --presses) PRESSES="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --mb) MB="$2"; shift 2 ;;
        --gap) GAP="$2"; shift 2 ;;
        --focus-wait) FOCUS_WAIT="$2"; shift 2 ;;
        --retries) RETRIES="$2"; shift 2 ;;
        --ignore-hygiene) IGNORE_HYGIENE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "모르는 옵션: $1" >&2; usage >&2; exit 2 ;;
    esac
done

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO_ROOT/dist/stress/hygiene.sh"

case "$HYG_PLATFORM" in
    linux|windows) ;;
    *) echo "이 스크립트는 Linux · Windows 전용이에요 ($(uname -s)) — macOS 는 합성 입력(CGEvent)이 아직 없어요." >&2
       exit 2 ;;
esac

# 자식이 Windows 실행파일이면 경로를 native 로 바꿔 넘긴다 (`measure-repeat.sh` 와 같은
# 함수다). MSYS 는 명령줄 인자를 자동 변환하기도 하지만 기대지 않는다.
native_path() {
    if [ "$HYG_PLATFORM" = windows ]; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

EXE_SUFFIX=""
[ "$HYG_PLATFORM" = windows ] && EXE_SUFFIX=".exe"
EXE="$REPO_ROOT/zig-out/bin/tildaz$EXE_SUFFIX"
STRESS="$REPO_ROOT/zig-out/bin/tildaz-stress$EXE_SUFFIX"
SENDKEYS="$REPO_ROOT/dist/stress/send-keys.ps1"

# `paths.zig` 의 `logDir` 와 같은 규칙이다 (`measure-repeat.sh` 와 같은 표).
case "$HYG_PLATFORM" in
    linux)   LOG="${XDG_STATE_HOME:-$HOME/.local/state}/tildaz/tildaz_stress.log" ;;
    windows) LOG="$(cygpath -u "$APPDATA")/tildaz/tildaz_stress.log" ;;
esac

[ -x "$EXE" ] || { echo "tildaz 없음: $EXE  (먼저 zig build)" >&2; exit 1; }
[ -x "$STRESS" ] || { echo "tildaz-stress 없음: $STRESS  (먼저 zig build stress)" >&2; exit 1; }

YDOTOOLD_PID=""
IME_RESTORE=""

if [ "$HYG_PLATFORM" = linux ]; then
    command -v ydotool >/dev/null 2>&1 || { echo "ydotool 없음 — 합성 입력에 필요해요." >&2; exit 1; }

    # `wtype` 은 KWin 이 `zwp_virtual_keyboard_v1` 을 지원하지 않아 쓸 수 없다 (#441 실측).
    # `ydotool` 은 uinput 경로라 compositor 를 안 가린다. 대신 데몬과 `/dev/uinput` 접근이 필요하다.
    SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.ydotool_socket"
    # **소켓 파일의 존재로 데몬을 판정하면 안 된다.** 데몬이 죽어도 소켓 파일은 남고, 그러면
    # "이미 떠 있다" 로 잘못 보고 데몬을 안 띄운다 → 모든 `ydotool` 호출이 조용히 실패해서
    # **키가 하나도 안 나간 채 회차가 끝난다** (실측으로 겪었다). 프로세스로 판정한다.
    if ! pgrep -x ydotoold >/dev/null 2>&1; then
        command -v ydotoold >/dev/null 2>&1 || { echo "ydotoold 없음 — ydotool 데몬이 필요해요." >&2; exit 1; }
        [ -w /dev/uinput ] || {
            echo "/dev/uinput 에 쓸 수 없어요. ACL (setfacl -m u:$USER:rw /dev/uinput) 이나" >&2
            echo "input 그룹 가입이 필요해요." >&2
            exit 1
        }
        rm -f "$SOCK"          # stale 소켓 정리 — 남아 있으면 데몬이 바인딩에 실패한다
        ydotoold >/dev/null 2>&1 &
        YDOTOOLD_PID=$!
        sleep 2
        [ -S "$SOCK" ] || { echo "ydotoold 소켓이 안 생겼어요: $SOCK" >&2; exit 1; }
    fi

    # **입력기가 한글이면 측정이 성립하지 않는다.** 우리가 보내는 것은 문자 키 `a` 인데,
    # 한글 모드에서는 IME 가 그것을 조합용으로 가져가 (`ㅁ` 이 찍힌다) 앱의 키 핸들러를
    # 타지 않는다 → `markInput()` 이 안 불려 표본이 잡히지 않는다. 실측에서 폐기된 회차가
    # 전부 이것이었다 (포커스 문제로 오해했다).
    #
    # **단축키는 다르다** — `Ctrl+Shift+F12` 는 한글 모드에서도 앱에 도달한다 (#465).
    # 그래서 "IME 는 단축키에 영향이 없다" 는 사실과 여기 제약은 서로 모순이 아니다.
    #
    # Windows 는 이 자리가 없다 — 한/영이 keyboard layout 이 아니라 **창별 IME conversion
    # mode** 라서, 측정 창이 뜬 뒤에 `send-keys.ps1` 이 그 창을 상대로 처리한다.
    if command -v fcitx5-remote >/dev/null 2>&1; then
        if [ "$(fcitx5-remote 2>/dev/null)" = "2" ]; then
            fcitx5-remote -c >/dev/null 2>&1      # deactivate = 영문
            IME_RESTORE=1
            echo "  입력기가 한글이라 영문으로 바꿨어요 (측정이 끝나면 되돌립니다)."
        fi
    else
        echo "  ⚠ fcitx5-remote 가 없어요 — 입력기가 한글이면 표본이 안 잡혀요. 영문인지 확인하세요." >&2
    fi
else
    command -v powershell >/dev/null 2>&1 || { echo "powershell 없음 — SendInput 합성 입력에 필요해요." >&2; exit 1; }
    [ -f "$SENDKEYS" ] || { echo "send-keys.ps1 없음: $SENDKEYS" >&2; exit 1; }
fi

APP=""
cleanup() {
    [ -n "$APP" ] && kill "$APP" 2>/dev/null
    [ -n "$YDOTOOLD_PID" ] && kill "$YDOTOOLD_PID" 2>/dev/null
    [ -n "$IME_RESTORE" ] && fcitx5-remote -o >/dev/null 2>&1   # 원래대로 한글
    hygiene_end
}
trap cleanup EXIT INT TERM

# --- 측정 위생 --------------------------------------------------------------
#
# `measure-repeat.sh` 와 같은 로직이다 — worker · AC · 주사율 · CPU 프로파일을 보고,
# 절전 차단 · 성능 프로파일 · 배경 앱 최소화를 걸고 끝나면 되돌린다. **배경 앱이 그리고
# 있으면 우리 수치만 눌리고** (README "배경 앱" 절), Windows 는 DRR 이 켜져 있으면 회차가
# 두 무리로 갈린다 — 응답 시간도 같은 오염을 받는다.
hygiene_check || {
    [ "$IGNORE_HYGIENE" = 1 ] || {
        echo "측정 위생 점검에 걸렸어요. 고치거나 --ignore-hygiene 로 강행해요." >&2
        exit 1
    }
}
hygiene_begin

# **키가 실제로 나가는지 먼저 확인한다.** 안 나가면 회차를 도는 의미가 없다.
# 화면을 바꾸지 않는 modifier 한 번으로 왕복만 본다.
#
# Windows 에는 이 사전 확인이 없다 — `send-keys.ps1` 은 **측정 창을 찾고 그 창이 활성일
# 때만** 키를 보내므로 (사용자 창으로 새는 것을 막는 가드), 창이 뜨기 전에는 부를 대상이
# 없다. 대신 그 스크립트가 창 없음 / 포커스 없음 / 전송 중단을 각각 다른 종료 코드로
# 알려서 회차가 조용히 비는 일이 없다.
if [ "$HYG_PLATFORM" = linux ]; then
    if ! ydotool key 42:1 42:0 >/dev/null 2>&1; then
        echo "ydotool 이 키를 보내지 못했어요 — 데몬 · /dev/uinput 권한을 확인하세요." >&2
        exit 1
    fi
fi

# evdev 키코드 — `a`=30 · LEFTCTRL=29 · LEFTSHIFT=42 · c=46 · w=17 · F12=88.
send_keys() {
    if [ "$HYG_PLATFORM" = windows ]; then
        # 한 회차의 키 순서를 **한 번의 호출로** 보낸다. 키마다 powershell 을 띄우면 그
        # 기동 시간이 `--gap` 을 지배한다. 실패 (창 없음 · 포커스 상실) 는 종료 코드로 온다.
        powershell -NoProfile -ExecutionPolicy Bypass -File "$(native_path "$SENDKEYS")" \
            -Presses "$PRESSES" -GapSec "$GAP" || {
            echo "⚠ 합성 입력이 실패했어요 — 회차를 중단해요." >&2
            return 1
        }
        return 0
    fi

    i=1
    while [ "$i" -le "$PRESSES" ]; do
        # 첫 키는 실패를 삼키지 않는다 — 조용히 실패하면 표본 0 인 회차가 그대로 끝난다.
        if [ "$i" -eq 1 ]; then
            ydotool key 30:1 30:0 || { echo "⚠ ydotool 전송 실패 — 회차를 중단해요." >&2; return 1; }
        else
            ydotool key 30:1 30:0 >/dev/null 2>&1
        fi
        sleep "$GAP"
        i=$((i + 1))
    done
    ydotool key 29:1 46:1 46:0 29:0 >/dev/null 2>&1   # Ctrl+C — 입력 줄 비우기
    sleep 0.3
    # **덤프를 여기서 직접 남긴다.** 종료 시 자동 덤프 (#396) 에만 기대면, 앱이 제때
    # 안 닫혀 정리 대상이 됐을 때 값이 통째로 사라진다 — 실측에서 `Alt+F4` 가 도달해
    # `pending_quit_request` 까지 갔는데도 종료가 안 끝나 `kill -9` 했고, 그 회차는
    # `input` 줄 자체가 없어 "표본 없음" 으로 보였다.
    ydotool key 29:1 42:1 88:1 88:0 42:0 29:0 >/dev/null 2>&1   # Ctrl+Shift+F12 — perf 덤프
    sleep 0.5
    # **`Alt+F4` 가 아니라 `Ctrl+Shift+W` 다.** `Alt+F4` 는 종료 확인 다이얼로그를 띄우고
    # 기다려서 앱이 안 닫힌다 (그 다이얼로그가 포커스까지 가져간다). 탭이 하나면
    # `Ctrl+Shift+W` (탭 닫기) 가 곧 앱 종료다.
    ydotool key 29:1 42:1 17:1 17:0 42:0 29:0 >/dev/null 2>&1   # Ctrl+Shift+W
}

# 종료 키가 안 먹으면 `wait` 가 영원히 매달린다 (실측으로 겪었다). 유예를 두고 그래도
# 살아 있으면 정리한다. 값은 위에서 `Ctrl+Shift+F12` 로 이미 남겼으므로 여기서 정리해도
# 회차가 통째로 날아가지는 않는다.
wait_app() {
    waited=0
    while [ "$waited" -lt 15 ]; do
        kill -0 "$APP" 2>/dev/null || return 0
        sleep 1
        waited=$((waited + 1))
    done
    echo "⚠ 앱이 안 닫혀서 정리해요 (종료 키가 안 먹었을 수 있어요 — 값은 이미 덤프됐어요)." >&2
    kill "$APP" 2>/dev/null
    sleep 1
    kill -9 "$APP" 2>/dev/null
    return 1
}

# `-e` 로 띄워야 stress role 이 되고, 그래야 종료 시 자동 덤프가 남는다 (#396 `dumpOnExit`).
# idle 모드도 러너를 쓰는 이유가 이것이다 — producer 없이 셸만 올린다.
#
# `RUNNER` 는 지울 임시 파일 (없으면 빈 문자열), `RUN_CMD` 는 `-e` 에 넘길 값이다.
# **Windows 의 `-e` 는 인자를 받는다** — POSIX 는 PTY 자식의 argv 가 고정이라 실행파일
# 하나뿐이지만 (`run_options.zig`), Windows 는 `CreateProcessW` 의 `lpCommandLine` 이라
# `cmd.exe /c <배치>` 가 그대로 선다.
make_runner() {
    if [ "$HYG_PLATFORM" = windows ]; then
        if [ "$1" = flood ]; then
            # Windows 의 TEMP 아래에 만든다 — Git Bash 의 `/tmp` 는 설치 경로 안이라
            # (`C:\Program Files\Git\tmp`) 공백이 섞이고, 그러면 `cmd /c "…"` 인용이 갈린다.
            RUNNER=$(TMPDIR="$(cygpath -u "$TEMP")" mktemp "$(cygpath -u "$TEMP")/tildaz-latency-XXXXXX.cmd")
            # producer 를 배경으로 돌리고 같은 ConPTY 에 셸을 올린다 (Linux 러너와 같은 배치).
            # `start /b` 라 새 콘솔 창이 생기지 않고 출력이 이 PTY 로 온다.
            cat > "$RUNNER" <<EOF
@echo off
start "" /b "$(native_path "$STRESS")"
"%COMSPEC%"
EOF
            RUN_CMD="cmd.exe /c \"$(native_path "$RUNNER")\""
        else
            RUNNER=""
            RUN_CMD="cmd.exe"
        fi
        return 0
    fi

    RUNNER=$(mktemp "${TMPDIR:-/tmp}/tildaz-latency-XXXXXX.sh")
    if [ "$1" = flood ]; then
        cat > "$RUNNER" <<EOF
#!/bin/sh
TILDAZ_STRESS_WORKLOAD=plain
TILDAZ_STRESS_BYTES=$((MB * 1024 * 1024))
export TILDAZ_STRESS_WORKLOAD TILDAZ_STRESS_BYTES
"$STRESS" &
exec "${SHELL:-/bin/bash}"
EOF
    else
        cat > "$RUNNER" <<EOF
#!/bin/sh
exec "${SHELL:-/bin/bash}"
EOF
    fi
    chmod +x "$RUNNER"
    RUN_CMD="$RUNNER"
}

run_one() {
    MODE_NAME="$1"
    make_runner "$MODE_NAME"

    # producer 파라미터는 환경변수로 간다 (`stress.zig`). Linux 는 러너 안에서 export
    # 하지만 Windows 배치에서 같은 일을 하면 인용이 한 겹 더 붙으므로, **앱 프로세스의
    # 환경**에 실어 자식까지 물려준다. 두 platform 다 producer 가 같은 값을 받는다.
    if [ "$MODE_NAME" = flood ] && [ "$HYG_PLATFORM" = windows ]; then
        TILDAZ_STRESS_WORKLOAD=plain
        TILDAZ_STRESS_BYTES=$((MB * 1024 * 1024))
        export TILDAZ_STRESS_WORKLOAD TILDAZ_STRESS_BYTES
    else
        unset TILDAZ_STRESS_WORKLOAD TILDAZ_STRESS_BYTES 2>/dev/null || true
    fi

    START_LEN=0
    [ -f "$LOG" ] && START_LEN=$(wc -c < "$LOG" | tr -d ' ')

    "$EXE" -e "$RUN_CMD" -size 120x40 -scrollback "$SCROLLBACK" >/dev/null 2>&1 &
    APP=$!
    sleep 4                     # 창 map + 폰트 init + (flood 면) 폭포 시작

    # 합성 입력은 **포커스된 창** 으로만 간다. 다만 `-e` 로 띄운 새 창은 포커스를 자동으로
    # 받는다 — 클릭한 회차와 클릭하지 않은 회차의 값이 idle 최악 12.30 / 12.33 ms 로 사실상
    # 같았다 (실측). 그래서 **사람 개입 없이 돈다.**
    #
    # 한때 표본이 2~4 개로 나와 "포커스를 못 받는다" 고 봤지만, 그 회차들은 다른 원인이었다
    # (ydotool 데몬 미기동 · 측정 중 조작 · 덤프 회수 실패). 포커스가 진짜 문제인 환경이라면
    # 표본 부족 경고가 뜨므로, 그때 `--focus-wait` 로 클릭할 시간을 주면 된다.
    # **Enter 로 신호를 받으면 안 된다.** Enter 를 치려면 이 터미널로 돌아와야 하고,
    # 그 순간 포커스가 여기로 옮겨와 방금 준 포커스가 사라진다. 그래서 고정 대기를 두고
    # 그 사이에 **클릭만** 하게 한다 — 클릭 후 손을 떼면 포커스가 그대로 남는다.
    if [ "$FOCUS_WAIT" -gt 0 ]; then
        printf '\n  ▶ 새 창이 활성이 아니면 %d 초 안에 한 번 클릭하세요 (활성이면 그대로).\n' "$FOCUS_WAIT"
        i="$FOCUS_WAIT"
        while [ "$i" -gt 0 ]; do
            printf '\r     %2d 초...' "$i"
            sleep 1
            i=$((i - 1))
        done
        printf '\r     키 전송 시작.     \n'
    fi

    send_keys || { kill "$APP" 2>/dev/null; [ -n "$RUNNER" ] && rm -f "$RUNNER"; return 1; }
    wait_app
    APP=""
    [ -n "$RUNNER" ] && rm -f "$RUNNER"

    RAW=$(mktemp "${TMPDIR:-/tmp}/tildaz-latency-log-XXXXXX")
    if [ "$START_LEN" -gt 0 ]; then
        tail -c "+$((START_LEN + 1))" "$LOG" > "$RAW"
    else
        cp "$LOG" "$RAW" 2>/dev/null || : > "$RAW"
    fi

    # `input    samples=N ms=X max_ms=Y` — perf.zig 의 dumpAndReset 형식.
    # **표본 수를 기대치와 대조한다.** 합성 입력은 *포커스된 창* 으로 가므로, 측정 중에
    # 창을 바꾸거나 마우스를 움직이면 키가 다른 앱으로 새고 표본만 적게 남는다. 그때도
    # 평균은 그럴듯한 값이 나와서 **모르고 결론을 내기 쉽다** (실측으로 겪었다).
    VERDICT=$(awk -v mode="$MODE_NAME" -v want="$PRESSES" '
    /^input / {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^samples=/)  { split($i, a, "="); s += a[2] }
            else if ($i ~ /^ms=/)  { split($i, a, "="); t += a[2] }
            else if ($i ~ /^max_ms=/) { split($i, a, "="); if (a[2] + 0 > m) m = a[2] + 0 }
        }
    }
    END {
        if (s + 0 == 0) { printf "  %-6s  ❌ 표본 없음 — 키가 앱에 안 갔거나 화면이 안 바뀌었어요\n", mode; exit }
        printf "  %-6s  표본 %3d / %d   평균 %6.2f ms   최악 %6.2f ms", mode, s, want, t / s, m
        # 8 할 미만이면 회차를 믿지 않는다 — 남은 표본으로 낸 평균은 그럴듯해 보이지만
        # 어떤 키가 빠졌는지 모르므로 대표성이 없다.
        if (s < want * 0.8) printf "   ⚠ 표본 부족 — 입력기가 한글이거나 측정 중 조작이 있었어요 (회차 폐기)"
        printf "\n"
    }' "$RAW")
    rm -f "$RAW"
    printf '%s\n' "$VERDICT"
    # 폐기 회차는 호출부가 다시 돌릴 수 있게 실패로 돌려준다.
    case "$VERDICT" in *"회차 폐기"*|*"표본 없음"*) return 1 ;; esac
    return 0
}

# 회차가 폐기되면 여기서 되풀이한다. 알려진 원인은 **입력기가 한글인 것** (위에서 미리
# 막는다) 과 측정 중 조작이다. 값 자체는 회차마다 매우 안정적이라 (idle 최악 12.30 /
# 12.33 / 12.38 ms) 유효 회차만 모으면 대표값이 성립한다.
run_with_retry() {
    attempt=1
    while [ "$attempt" -le "$RETRIES" ]; do
        if run_one "$1"; then return 0; fi
        [ "$attempt" -lt "$RETRIES" ] && echo "     ↻ 다시 시도해요 ($attempt/$RETRIES)" >&2
        attempt=$((attempt + 1))
        sleep 3
    done
    return 1
}

cat <<EOF

============ 응답 시간 측정 (#441 축 ②) ============
 키        : 'a' × ${PRESSES} (간격 ${GAP}s) → Ctrl+C → Ctrl+Shift+F12 → Ctrl+Shift+W
 모드      : $MODE
 재는 구간 : 키 수신 → 그 뒤 첫 present 완료
             (PTY write · 셸 에코 · parse · render 포함)
 환경      : $(hygiene_status)
====================================================

⚠ 합성 입력은 **포커스된 창**으로 갑니다. 회차마다 새 창이 뜨면 포커스만 확인하고,
   키가 나가기 시작하면 키보드 · 마우스를 건드리지 마세요 (건드리면 그 회차는 폐기됩니다).

EOF

case "$MODE" in
    idle)  run_with_retry idle ;;
    flood) run_with_retry flood ;;
    both)  run_with_retry idle; sleep 2; run_with_retry flood ;;
    *) echo "모르는 모드: $MODE (idle · flood · both)" >&2; exit 2 ;;
esac

echo
