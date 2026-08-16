#!/bin/sh
# 유휴 응답 지연 측정 ([#439](https://github.com/ensky0/tildaz/issues/439)).
#
# **입력 없이 PTY 출력만 도착하는 상황**에서, 그 출력이 화면에 닿기까지 얼마나 걸리는지 잰다.
# #439 가 *"유휴에서 첫 출력이 한 프레임 늦는다"* 고 가설로 적어 둔 것을 숫자로 만든다.
#
#   dist/stress/measure-idle-latency.sh                 # 기본 — 20 회 · 간격 2 초
#   dist/stress/measure-idle-latency.sh --samples 40 --gap 3
#
# ## `measure-input-latency.sh` 와 무엇이 다른가
#
# 그쪽은 **키** 에서 시작한다. 그런데 키가 오면 앱이 즉시 렌더를 요청하므로 **유휴 깨우기
# 경로를 아예 안 탄다** — #441 에서 유휴 평균이 0.67 ms 로 낮게 나온 이유다. 이 스크립트는
# 입력을 아예 보내지 않는다. 그래서 **합성 입력도 필요 없다** (ydotool · 포커스 · IME 무관).
#
# | | 시작 | 재는 것 |
# |---|---|---|
# | `measure-input-latency.sh` | 키 수신 | 사용자 입력의 왕복 |
# | **이 스크립트** | **PTY 도착** | **유휴 깨우기 지연** |
#
# ## 무엇이 갈림길인가
#
# 깨우기 주기 (Linux `frame_poll_ms` 16 ms · 60 Hz 16.7 ms · 120 Hz 8.3 ms) 에 흡수되면 가설대로다.
#
# 단 **상한은 깨우기 주기 그 자체가 아니라 `주기 + render + present`** 다 — `completeOutput()` 이
# present 가 끝난 자리이기 때문이다 (`perf.zig`). 실측 최악이 Linux 는 주기를 0.39 ms, Windows 는
# 1.70 ms 넘었고 둘 다 그 회차의 render + present 와 자릿수가 맞았다 (README 의 기록 수치).
# **그 여유보다 크게 넘으면** 깨우기 말고 다른 것이 끼어 있다는 뜻이라 원인을 다시 찾아야 한다.
set -u

SAMPLES=20
GAP=2
SCROLLBACK=32767
IGNORE_HYGIENE=0

usage() {
    cat <<'USAGE'
쓰는 법: dist/stress/measure-idle-latency.sh [옵션]

  --samples <N>   출력 횟수 (기본 20)
  --gap <초>      출력 사이 간격 (기본 2 — 앱이 확실히 유휴로 들어갈 만큼)
  --ignore-hygiene  위생 점검에 걸려도 강행 (동작 확인용 — 기록용 측정에는 쓰지 않는다)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --samples) SAMPLES="$2"; shift 2 ;;
        --gap) GAP="$2"; shift 2 ;;
        --ignore-hygiene) IGNORE_HYGIENE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "모르는 옵션: $1" >&2; usage >&2; exit 2 ;;
    esac
done

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO_ROOT/dist/stress/hygiene.sh"

# 자식이 Windows 실행파일이면 경로를 native 로 바꿔 넘긴다 (`measure-input-latency.sh` 와 같은
# 함수다). MSYS 는 명령줄 인자를 자동 변환하기도 하지만 기대지 않는다.
native_path() {
    if [ "$HYG_PLATFORM" = windows ]; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# **Windows 는 `.exe` 다.** 접미사가 없으면 `[ -x ]` 가 전부 실패해 `tildaz 없음` 으로 끝난다.
EXE_SUFFIX=""
[ "$HYG_PLATFORM" = windows ] && EXE_SUFFIX=".exe"
EXE=""
for _cand in \
    "$REPO_ROOT/zig-out/TildaZ.app/Contents/MacOS/tildaz" \
    "$REPO_ROOT/zig-out/bin/tildaz$EXE_SUFFIX"
do
    [ -x "$_cand" ] && EXE="$_cand" && break
done
[ -n "$EXE" ] || EXE="$REPO_ROOT/zig-out/bin/tildaz$EXE_SUFFIX"
[ -x "$EXE" ] || { echo "tildaz 없음: $EXE  (먼저 zig build)" >&2; exit 1; }

case "$HYG_PLATFORM" in
    linux) LOG="${XDG_STATE_HOME:-$HOME/.local/state}/tildaz/tildaz_stress.log" ;;
    macos) LOG="$HOME/Library/Logs/tildaz_stress.log" ;;
    windows) LOG="$(cygpath -u "$APPDATA")/tildaz/tildaz_stress.log" ;;
    *) echo "모르는 platform 이에요 ($(uname -s))." >&2; exit 2 ;;
esac

# `-e` 러너 — **입력을 읽지 않고 주기적으로 한 줄만 낸다.** 앱은 그 사이 완전히 유휴라
# 매 출력이 유휴 깨우기 경로를 그대로 탄다. 마지막에 `Ctrl+Shift+F12` 대신 스크립트가
# 스스로 끝나 앱이 정상 종료되게 둔다 — 종료 덤프(#396)가 값을 남긴다.
#
# `RUNNER` 는 지울 임시 파일, `RUN_CMD` 는 `-e` 에 넘길 값이다. **Windows 의 `-e` 는 인자를
# 받는다** — POSIX 는 PTY 자식의 argv 가 실행파일 하나로 고정이지만 (`run_options.zig`),
# Windows 는 `CreateProcessW` 의 `lpCommandLine` 이라 (`host/windows.zig` 의 `stress_shell_w`)
# `cmd.exe /c <배치>` 가 그대로 선다. POSIX `.sh` 를 그대로 넘기면 아예 안 뜬다.
if [ "$HYG_PLATFORM" = windows ]; then
    # Windows 의 TEMP 아래에 만든다 — Git Bash 의 `/tmp` 는 설치 경로 안이라
    # (`C:\Program Files\Git\tmp`) 공백이 섞이고, 그러면 `cmd /c "…"` 인용이 갈린다
    # (`measure-input-latency.sh` 와 같은 이유).
    RUNNER=$(TMPDIR="$(cygpath -u "$TEMP")" mktemp "$(cygpath -u "$TEMP")/tildaz-idle-XXXXXX.cmd")
    # 대기는 **`ping` 이지 `timeout` 이 아니다.** `timeout` 은 stdin 이 리다이렉트되면
    # `ERROR: Input redirection is not supported` 로 떨어진다. `ping -n K` 는 K-1 초를 쉰다.
    #
    # 배치는 **CRLF + `for /L` 한 줄**로 쓴다. 여러 줄 괄호 블록을 LF 만으로 쓰면 `cmd.exe`
    # 가 블록을 잘못 읽을 수 있다 (`compare-terminals.sh` 의 `conhost.cmd` 도 CRLF 로 쓴다).
    {
        printf '@echo off\r\n'
        printf 'for /L %%%%i in (1,1,%d) do (ping -n %d 127.0.0.1 >nul & echo idle-sample %%%%i)\r\n' \
            "$SAMPLES" "$((GAP + 1))"
        printf 'ping -n 2 127.0.0.1 >nul\r\n'
    } > "$RUNNER"
    RUN_CMD="cmd.exe /c \"$(native_path "$RUNNER")\""
else
    RUNNER=$(mktemp "${TMPDIR:-/tmp}/tildaz-idle-XXXXXX.sh")
    cat > "$RUNNER" <<EOF
#!/bin/sh
i=1
while [ "\$i" -le $SAMPLES ]; do
    sleep $GAP
    printf 'idle-sample %d\\n' "\$i"
    i=\$((i + 1))
done
sleep 1
EOF
    chmod +x "$RUNNER"
    RUN_CMD="$RUNNER"
fi

TOTAL_WAIT=$(( (SAMPLES * GAP) + 12 ))
cat <<EOF

============ 유휴 응답 지연 측정 (#439) ============
 표본      : ${SAMPLES} 회 · 간격 ${GAP} 초
 재는 구간 : PTY 도착 → 그 뒤 첫 present 완료
 예상 소요 : 약 ${TOTAL_WAIT} 초
====================================================

⚠ 이 측정은 **앱이 유휴여야** 성립해요. 창을 클릭하거나 키를 누르면 그 회차가 오염돼요
   (입력이 렌더를 유발해 깨우기 경로를 건너뜁니다). 시작하면 건드리지 마세요.

EOF

# **측정 위생을 지킨다.** `check-input-loss.sh` 는 판정이 "먹었나 / 안 먹었나" 라는 이산값이라
# 위생을 건너뛰지만, 이쪽은 **ms 단위 연속값**이라 얘기가 다르다.
#
# - **C-state** 가 유휴에서 깨어나는 시간에 직접 영향을 준다 — 이 측정이 재는 것이 바로 그
#   깨어남이다. 배터리에서는 더 깊은 절전으로 들어가 값이 달라진다.
# - **평소 쓰는 worker 를 안 내리면** 그 인스턴스가 CPU · 렌더를 나눠 써 값이 눌린다
#   (`hygiene_begin` ⓪).
#
# ⚠ 그래서 이 스크립트는 **평소 쓰던 TildaZ 를 종료시킨다.** 그 안에서 무언가 돌고 있으면
#    (예: 이 스크립트를 그 창에서 실행하면) 함께 끊긴다 — 다른 터미널에서 돌린다.
hygiene_check || {
    [ "$IGNORE_HYGIENE" = 1 ] || {
        echo "측정 위생 점검에 걸렸어요. 고치거나 --ignore-hygiene 로 강행해요." >&2
        exit 1
    }
}
# 복원은 어떤 경로로 끝나든 돌아야 한다 (Ctrl+C 포함).
trap hygiene_end EXIT INT TERM
hygiene_begin

START_LEN=0
[ -f "$LOG" ] && START_LEN=$(wc -c < "$LOG" | tr -d ' ')

"$EXE" -e "$RUN_CMD" -size 100x30 -scrollback "$SCROLLBACK" >/dev/null 2>&1 &
APP=$!

waited=0
while [ "$waited" -lt "$TOTAL_WAIT" ]; do
    kill -0 "$APP" 2>/dev/null || break
    sleep 1
    waited=$((waited + 1))
done
kill "$APP" 2>/dev/null
sleep 1
rm -f "$RUNNER"

RAW=$(mktemp "${TMPDIR:-/tmp}/tildaz-idle-log-XXXXXX")
if [ "$START_LEN" -gt 0 ]; then
    tail -c "+$((START_LEN + 1))" "$LOG" > "$RAW"
else
    cp "$LOG" "$RAW" 2>/dev/null || : > "$RAW"
fi

# `output   samples=N ms=X max_ms=Y` — perf.zig 의 dumpAndReset 형식.
awk -v want="$SAMPLES" '
/^output / {
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^samples=/)     { split($i, a, "="); s += a[2] }
        else if ($i ~ /^ms=/)     { split($i, a, "="); t += a[2] }
        else if ($i ~ /^max_ms=/) { split($i, a, "="); if (a[2] + 0 > m) m = a[2] + 0 }
    }
}
# 입력이 섞였는지 확인 — 유휴 측정에서는 0 이어야 한다.
/^input / { for (i = 1; i <= NF; i++) if ($i ~ /^samples=/) { split($i, a, "="); inp += a[2] } }
END {
    printf "\n==================== 결과 ====================\n"
    if (s + 0 == 0) {
        printf " ❌ 표본 없음 — 출력이 화면에 닿지 않았거나 덤프가 안 남았어요\n"
    } else {
        printf " 표본 %d / %d   평균 %6.2f ms   최악 %6.2f ms\n", s, want, t / s, m
    }
    if (inp + 0 > 0) printf " ⚠ 입력 표본이 %d 개 섞였어요 — 측정 중 조작이 있었어요 (회차 폐기)\n", inp
    printf "==============================================\n\n"
}' "$RAW"

rm -f "$RAW"
