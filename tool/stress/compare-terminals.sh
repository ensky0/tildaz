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
#   tool/stress/compare-terminals.sh --mb 64 --workload plain --cols 120 --rows 40
#
# **기록으로 남길 수치는 `--repeat 5` 로 낸다** (#371 의 측정 프로토콜). 1 회 측정은 흔들림을
# 알 수 없다 — macOS 실측에서 같은 조건 3 회가 115.0 / 124.2 / 128.7 MiB/s 였다. 반복하면
# 대표값을 **min · max 를 뺀 나머지의 평균 (절사평균)** 으로 내고 `min~max` 를 함께 적는다.
#
#   tool/stress/compare-terminals.sh --mb 64 --workload plain --repeat 5
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
# **경로는 선택이다** — 안 주면 `tool/stress/shots` 에 남는다 (스크립트 바로 옆이라 찾기 쉽다).
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
. "$REPO_ROOT/tool/stress/hygiene.sh"
# 경로를 안 주면 여기에 남긴다 — **스크립트 바로 옆**이라 찾기 쉽다. platform 을 안 가린다.
# `.gitignore` 에 넣어 두어서 git 에는 안 잡힌다.
CAPTURE_DEFAULT_DIR="$REPO_ROOT/tool/stress/shots"

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
        # 경로는 선택이다. 안 주면 `tool/stress/shots`. 다음 인자가 `-` 로 시작하면 옵션이므로
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

# 대상 터미널을 띄우고 닫는 코드는 `terminals.sh` 에 있다 (#756). OS 판별 (`IS_WINDOWS` ·
# `IS_MACOS`) · `native_path` 도 거기서 온다.
. "$REPO_ROOT/tool/stress/terminals.sh"

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

terminals_init


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

# 처리량 지표가 producer 에게 주는 것 — 워크로드와 보낼 바이트 수. 나머지 (timing 경로 · 목표
# 격자) 는 `terminals.sh` 의 `producer_env_lines` 가 붙인다.
PRODUCER_ENV="TILDAZ_STRESS_WORKLOAD=$WORKLOAD
TILDAZ_STRESS_BYTES=$BYTES"

# 처리량에서 건너뛰는 대상. `terminals.sh` 의 훅이다.
#
# **Windows + ZWJ 계열은 alacritty 를 돌리지 않는다 — alacritty 가 멈춘다.** 실기에서 재현 조건을
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
terminal_skip() {
    if [ "$1" = alacritty ] && [ "$IS_WINDOWS" = 1 ] &&
       { [ "$WORKLOAD" = zwj ] || [ "$WORKLOAD" = zwj_varied ]; }
    then
        printf '%-14s %s\n' alacritty "건너뜀 (Windows + $WORKLOAD 은 alacritty 가 멈춰요)"
        printf '%s\tunsupported\t0\t0\t0\t0\n' alacritty >> "$RESULTS"
        return 0
    fi
    return 1
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
# 창의 내용이 나왔다). `tool/color-capture_macos.m` 을 그대로 쓴다 (#349 의 색 실측용 도구).
# clang 이 없거나 빌드가 안 되면 전체 화면으로 물러선다.
MAC_CAPTURE=""
if [ -n "$CAPTURE_DIR" ] && [ "$(uname -s)" = Darwin ] && command -v clang >/dev/null 2>&1 &&
   [ -f "$REPO_ROOT/tool/color-capture_macos.m" ]
then
    if clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit \
        -framework ImageIO -framework UniformTypeIdentifiers \
        -o "$WORK_DIR/color-capture" "$REPO_ROOT/tool/color-capture_macos.m" >/dev/null 2>&1
    then
        MAC_CAPTURE="$WORK_DIR/color-capture"
    fi
fi


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
        # `;` 로 이은 후보 목록이다 (tildaz 의 dev · 릴리즈 이름 — sh 쪽 `TILDAZ_CLASS` 주석). 같은 자리끼리 짝.
        $cls = $WindowClass.Split(';'); $tit = $WindowTitle.Split(';')
        for ($k = 0; $k -lt [Math]::Min($cls.Count, $tit.Count); $k++) {
            $c = [TzWin]::FindWindow($cls[$k], $tit[$k])
            if ($c -ne [IntPtr]::Zero) { return $c }
        }
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
# **세 platform 이 무엇을 찍었는지를 두 플래그로 알린다** (#448 에서 Linux 가 합류했다).
#   `CAPTURE_NOWIN`    대상 창을 못 찾음 — 전체 화면만 찍혔고 대상이 있다는 보장이 없다.
#   `CAPTURE_FELLBACK` 창은 찾았지만 창 단위 캡처가 안 돼서 전체 화면으로 물러섰다.
#
# 예전엔 Windows 만 이 구분을 했고 (macOS 는 #414 에서 합류) **Linux 는 둘 다 `0` 이라 `?` · `~` 가
# 구조적으로 안 나왔다.** 그래서 창이 이미 닫힌 회차도 `spectacle -a` 가 엉뚱한 활성 창을 찍어
# 2 KiB 를 넘기면 `@` 로 통과했고, **판정이 조용히 성립하는** 상태였다 (#448). 표시만의 문제가
# 아니었다 — #413 의 재시도 루프가 `~` · `?` · `_` 를 조건으로 도는데 Linux 에서 남는 것이 `_`
# 하나뿐이라 **hold 가 모자라 창이 먼저 닫힌 회차를 다시 찍지 않았다.**
CAPTURE_NOWIN=0
CAPTURE_FELLBACK=0

# 그 대상의 producer 가 **지금** 살아 있나 (Linux 판정용, #448).
#
# 왜 이걸로 판정이 되나: **hold 를 붙드는 주체가 producer** 다 (`stress.zig` 의 `env_hold_ms` —
# 환경변수가 없으면 `hold_ms = 0` 이라 timing 을 쓴 직후 끝난다). 캡처는 timing + `CAPTURE_DELAY`
# 에 찍으므로, 그 시점에 producer 가 살아 있다는 것이 곧 *찍을 창이 있었다*는 뜻이다.
#
# 패턴은 `cleanup_terminals` 가 *"우리가 띄운 것만"* 고를 때 쓰는 것과 같은 `WORK_DIR` 경로인데,
# **대상 이름까지 붙여 그 대상만** 본다.
#
# **명령줄만 보면 안 된다 — tildaz 를 놓친다.** 처음에 `ps -eo args` 로 짰다가 검증에서 걸렸다.
# 터미널 다섯은 `sh -c "env TILDAZ_STRESS_TIMING_FILE=… <producer>"` 를 인자로 받으니 명령줄에
# 남는데, tildaz 는 `env "TILDAZ_STRESS_TIMING_FILE=…" <tildaz> -e <producer>` 형태라 **`env` 가
# tildaz 를 exec 하면서 그 대입이 argv 에서 사라진다** (환경으로만 남는다). 그래서 명령줄 검사는
# tildaz 회차를 매번 `?` 로 만들었다.
#
# 그래서 `/proc` 의 **`cmdline` 과 `environ` 을 함께** 본다. 둘 중 어디서든 이 경로가 보이면 그
# 대상의 프로세스가 (터미널이든 producer 든) 아직 있다는 뜻이다. `environ` 쪽이 더 정확하다 —
# producer 는 이 변수를 상속받아 갖고 있고, hold 를 붙드는 주체가 그 producer 다.
#
# **`pgrep -f` 를 안 쓴다** — 패턴에 든 `/tmp/…` 경로를 정규식으로 해석하고 자기 자신을 세는
# 함정이 있다. `grep -aqF` 로 고정 문자열 비교를 한다 (`-a` 는 NUL 이 든 `cmdline` · `environ` 을
# 텍스트로 읽게 한다).
#
# `/proc` 이 없으면 **판정하지 않는다** (`?` 를 안 찍는다). 없는 근거로 실패를 단정하면 그게 곧
# 이 이슈가 고치려던 *조용한 오판*의 반대 방향 오판이다. Linux DE 에는 항상 있다.
capture_target_alive() {
    [ -r /proc/self/cmdline ] || return 0
    grep -aqF "$WORK_DIR/$1.timing" /proc/[0-9]*/cmdline /proc/[0-9]*/environ 2>/dev/null
}
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
                        '(b != "" && ($2 == b || $2 == b ".dev")) || index(tolower($3), t) == 1 { print $1 }' |
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
            # **찍기 전에 대상이 살아 있는지 본다** (#448). 어느 도구를 쓰든 같다 — 창이 이미
            # 닫혔으면 무엇을 찍어도 대상이 아니므로, 도구 선택보다 이 판정이 먼저다.
            capture_target_alive "$_ctarget" || CAPTURE_NOWIN=1
            if command -v grim >/dev/null 2>&1; then
                # wlroots 계열 (sway · Hyprland). **화면 단위**라 창 단위 성공이 애초에 없다 —
                # 그래서 정상 결과도 `~` 다 (#448). 전에는 `@` 로 찍혀서 Windows · macOS 의
                # `@` (창 단위로 찍었다) 와 **같은 표시가 다른 뜻**이었다.
                # 창 단위로 가려면 `grim -g` 에 geometry 를 줘야 하고 그건 compositor 질의
                # (`swaymsg -t get_tree` · `hyprctl clients`) 가 필요한데, 이 기기가 KDE 라
                # **검증할 수 없어서 넣지 않았다** — 별도 이슈 몫이다.
                grim "$_png" >/dev/null 2>&1 || true
                CAPTURE_FELLBACK=1
            elif command -v spectacle >/dev/null 2>&1; then
                # KDE Plasma. **`-a` (활성 창) 라 창 단위로 찍힌다** — grim (화면 단위) 과 다르다.
                # 방금 뜬 창이 포커스를 받으므로 대개 대상이 잡히고, 활성 창은 맨 앞이라 가려짐
                # 문제도 없다. 그래서 이 경로만 `@` 를 그대로 둔다.
                #
                # **남은 한계 — "대상은 살아 있는데 다른 창이 앞" 은 여전히 `@` 다.** 위 생존
                # 검사는 *창이 없어진 것*만 잡는다. 그걸 가르려면 대상을 먼저 활성화해야 하는데
                # (#381 이 보류한 KWin 경로), `spectacle` 에 창을 지목하는 옵션이 없어
                # (`--help` 실측: `-a` · `-u` 뿐) `WindowsRunner.Match` + `.Run` 으로 가야 하고,
                # 그 매칭 키가 resource class 라 대상마다 형식이 갈린다 (`foot` · `kitty` ·
                # `Alacritty` · `org.wezfurlong.wezterm` …). #414 가 macOS 에서 *"언어별 이름 표는
                # 두지 않는다"* 며 거부한 것과 같은 표가 필요해져서 **별개 결정으로 남겼다.**
                spectacle -b -n -a -o "$_png" >/dev/null 2>&1 || true
            elif command -v gnome-screenshot >/dev/null 2>&1; then
                # GNOME. grim 과 같이 **화면 단위**라 정상 결과도 `~` 다 (#448).
                gnome-screenshot -f "$_png" >/dev/null 2>&1 || true
                CAPTURE_FELLBACK=1
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
# `!` 인데 "2 회차가 안 찍혔어요" 로 나왔다 (#381 실기, 3d0c4d4 에서 표시를 넷으로 나눌 때부터
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

terminals_launch_all

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
    # **회차별 값을 실행 순서 그대로 적는다** (#449). `min~max` 만으로는 폭이 *어떤 모양*인지
    # 알 수 없다 — 무작위 산포인지, 두 무리로 갈리는지 (쌍안정, #435 가 Windows 에서 그랬다),
    # 회차가 갈수록 느려지는지 (열 · 전력 한계) 가 전부 같은 `min~max` 로 나온다. #449 의 진단이
    # 이것 때문에 **두 번 막혔다** — 표본이 `$WORK_DIR/results` 에만 있고 EXIT trap 이 그 디렉터리를
    # 지워서, 세 모양을 구분할 데이터가 아예 남지 않았다.
    #
    # **정렬하지 않는다.** 단조 감소를 보려면 실행 순서가 그대로여야 한다 (위 절사평균 계산은
    # 자기 사본을 정렬하므로 영향 없다).
    if [ "$REPEAT" -ge 2 ]; then
        printf '%14s   회차별: %s MiB/s\n' "" \
            "$(printf '%s\n' "$samples" | awk -v bytes="$BYTES" '{
                mib = bytes / 1048576
                for (i = 1; i <= NF; i++) printf "%s%.1f", (i > 1 ? "  " : ""), mib / ($i / 1000000000)
            }')"
    fi
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
    # `?` 의 **뜻과 처방이 platform 마다 다르다.** 한 문구로 적으면 반대로 안내한다 — Linux 가
    # 이 표시를 내게 된 뒤 (#448) 실제로 그랬다. Windows 문구는 *"hold 를 늘려도 안 고쳐진다"*
    # 인데 Linux 의 `?` 는 **창이 이미 닫힌 것**이라 hold 를 늘리는 게 바로 그 처방이다.
    if [ "$CAPTURE_NOWIN_TOTAL" -gt 0 ]; then
        echo "⚠ ${CAPTURE_NOWIN_TOTAL} 회차는 대상 창을 못 찾았어요 (?). PNG 에 대상이 있어도 우연이에요."
        if [ "$IS_WINDOWS" = 1 ]; then
            echo "  그 회차는 창을 앞으로 올리지도 (0,0) 으로 옮기지도 못했어요."
            echo "  이건 hold 를 늘려도 안 고쳐져요 — 오히려 앞 회차 창이 오래 남아 wt 처럼 기존"
            echo "  프로세스를 재사용하는 대상에서 더 자주 나요 (#413)."
        elif [ "$IS_MACOS" = 1 ]; then
            echo "  창 목록 (onScreen) 에서 대상을 못 찾아 전체 화면으로 물러섰어요. 배경 앱 숨김이"
            echo "  안 풀렸거나 bundle identifier 가 안 맞는 경우예요 (#414)."
        else
            echo "  캡처 직전에 그 대상의 프로세스가 이미 없었어요 (#448) — **hold 가 모자라 창이"
            echo "  먼저 닫힌 것**이 가장 흔한 원인이에요. 위 재시도가 hold 를 늘려 한 번 다시"
            echo "  찍었는데도 ? 면 --hold-ms 를 더 올려 주세요."
        fi
    fi
    if [ "$CAPTURE_FELLBACK_TOTAL" -gt 0 ]; then
        echo "⚠ ${CAPTURE_FELLBACK_TOTAL} 회차는 창 단위 캡처가 안 돼 전체 화면으로 물러섰어요 (~)."
        echo "  그 PNG 은 다른 창에 가리거나 최대화된 창 때문에 대상이 빠질 수 있으니 눈으로"
        echo "  확인해 주세요. 리눅스의 grim (sway · Hyprland) · gnome-screenshot 은 **원래 화면"
        echo "  단위**라 정상 결과도 여기 들어와요 — 그 환경에서는 회차 수가 곧 전체 회차예요 (#448)."
    fi
    echo "⚠ 전체 화면으로 찍힌 PNG (~ · ?) 은 대상이 다른 창 뒤에 있으면 안 보여요. PNG 을 눈으로"
    echo "  확인해 주세요."
    # KDE 는 창 단위로 찍히지만 **그 창이 대상이라는 보장까지는 없다** (#448 의 남은 한계).
    # 이 사실을 요약에 적어 두지 않으면 `@` 를 *"대상이 찍혔다"* 로 읽게 된다.
    if command -v spectacle >/dev/null 2>&1 && [ "$IS_WINDOWS" != 1 ] && [ "$IS_MACOS" != 1 ]; then
        echo "ℹ 리눅스 KDE 의 @ 는 '대상이 살아 있었고 활성 창을 창 단위로 찍었다' 는 뜻이에요."
        echo "  대상이 활성이 아니었으면 다른 창이 찍힐 수 있어요 (#448 — 대상 활성화는 미구현)."
    fi
    if [ "$CAPTURE_FAILED" -gt 0 ]; then
        echo "⚠ ${CAPTURE_FAILED} 회차가 안 찍혔어요. 권한 (macOS 화면 기록) · 캡처 도구 유무 (리눅스) ·"
        echo "  hold (${CAPTURE_HOLD_MS} ms) 안에 캡처가 못 끝났는지를 보세요."
    fi
fi
