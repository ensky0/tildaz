#!/bin/sh
# 응답성 — **입력 손실** 검사 (#441 축 ①).
#
# 폭포가 흐르는 동안 입력이 먹히는지 본다. 처리량 하네스 (`measure-repeat.sh`) 가
# *얼마나 빨리 소화하나* 를 재는 것과 달리, 이쪽은 *그 동안 사용자를 잃지 않나* 를 본다.
# 드레인 구조를 건드리는 변경은 전부 처리량과 응답성의 거래라서 (#387 · #435 · #436 ·
# #439) 두 축이 함께 있어야 판정이 성립한다.
#
#   dist/stress/check-input-loss.sh                 # 기본 — 10 회 · plain · 2 GiB
#   dist/stress/check-input-loss.sh --presses 20
#
# **두 경로를 따로 본다.** 하나로 뭉치면 판정이 안 된다 (#436 실측).
#
#   ① 앱 단축키 — 앱이 소비하는 키. 처리되면 로그에 `=== snapshot` 블록이 정확히 하나 남는다.
#      **PTY write 경로를 지나지 않는다** (Ctrl+Shift 분기에서 앱이 먹는다).
#   ② PTY 전달 — 타이핑한 명령이 폭포 후 실행되는지. ①이 못 보는 write 경로를 본다.
#      producer 가 foreground 라 **Ctrl+C 검사도 함께 성립**한다.
#
# 사람이 하는 것은 *키를 누르고 타이핑하는 것* 뿐이고 판정은 이 스크립트가 한다.
# 합성 입력을 갖추지 않은 이유는 Linux Wayland 가 걸리기 때문이다 (#441 본문) —
# 응답 **시간** 측정 (축 ②) 과 함께 남겨 둔 몫이다.
#
# **Linux · macOS 전용이다.** Windows 는 `-e` 에 러너 스크립트를 넘길 수 없어
# (CreateProcess 가 `.cmd` 를 직접 실행하지 않는다) 절차를 README 에 글로 적어 두었다.
set -u

PRESSES=10
WORKLOAD=plain
# **처리량 측정의 64 MiB 를 그대로 쓰면 안 된다.** Linux 에서 plain 은 200 MB/s 급이라
# 64 MiB 는 0.3 초에 끝나고, 그러면 누를 시간이 없어 부하 없는 상태에서 누른 것이 된다
# (#441 첫 회차에서 실제로 그렇게 나왔다 — 스냅숏마다 `drain bytes=0`). 10 회를 여유 있게
# 누르려면 몇 초는 흘러야 해서 기본을 2 GiB 로 둔다. 느린 머신에서는 더 오래 흐를 뿐이라 안전하다.
MB=2048
SCROLLBACK=32767
KEEP_RUNNER=0

usage() {
    cat <<'USAGE'
쓰는 법: dist/stress/check-input-loss.sh [옵션]

  --presses <N>      폭포 중 누를 단축키 횟수 (기본 10 — SPEC 13.2 의 "입력 10 회")
  --workload <이름>  폭포 워크로드 (기본 plain)
  --mb <N>           쏟아부을 MiB (기본 2048 — 64 MiB 는 0.3 초에 끝나 누를 시간이 없다)
  --scrollback <N>   앱에 넘길 scrollback 줄 수 (기본 32767)
  --keep-runner      임시 러너 스크립트를 지우지 않는다 (진단용)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --presses) PRESSES="$2"; shift 2 ;;
        --workload) WORKLOAD="$2"; shift 2 ;;
        --mb) MB="$2"; shift 2 ;;
        --scrollback) SCROLLBACK="$2"; shift 2 ;;
        --keep-runner) KEEP_RUNNER=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "모르는 옵션: $1" >&2; usage >&2; exit 2 ;;
    esac
done

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# platform 판정만 빌려 쓴다 (`HYG_PLATFORM`). 처리량 측정과 달리 위생 (AC · 주사율 ·
# 배경 앱) 이 판정을 바꾸지 않아서 `hygiene_check` 는 부르지 않는다 — 여기 판정은
# "먹었나 / 안 먹었나" 라는 이산값이고, 위생이 나쁘면 폭포가 느려질 뿐이다.
. "$REPO_ROOT/dist/stress/hygiene.sh"

EXE=""
for _cand in \
    "$REPO_ROOT/zig-out/TildaZ.app/Contents/MacOS/tildaz" \
    "$REPO_ROOT/zig-out/bin/tildaz"
do
    [ -x "$_cand" ] && EXE="$_cand" && break
done
[ -n "$EXE" ] || EXE="$REPO_ROOT/zig-out/bin/tildaz"
STRESS="$REPO_ROOT/zig-out/bin/tildaz-stress"

case "$HYG_PLATFORM" in
    # `paths.zig` 의 `logDir` 와 같은 규칙이다. `-e` 로 띄운 회차는 **`tildaz_stress.log`**
    # 로 간다 (`instance_context.isStress`) — 평소의 `tildaz_N.log` 가 아니다.
    linux) LOG="${XDG_STATE_HOME:-$HOME/.local/state}/tildaz/tildaz_stress.log" ;;
    macos) LOG="$HOME/Library/Logs/tildaz_stress.log" ;;
    *)
        echo "이 스크립트는 Linux · macOS 전용이에요 ($(uname -s))." >&2
        echo "Windows 는 dist/stress/README.md 의 '입력 손실' 절에 수동 절차가 있어요." >&2
        exit 2
        ;;
esac

[ -x "$EXE" ] || { echo "tildaz 없음: $EXE  (먼저 zig build)" >&2; exit 1; }
[ -x "$STRESS" ] || { echo "tildaz-stress 없음: $STRESS  (먼저 zig build stress)" >&2; exit 1; }

# platform 별 단축키 — `dump_perf` 를 부르는 키다 (`wayland_minimal.zig` · `macos.zig`).
case "$HYG_PLATFORM" in
    macos) KEY="Shift+Cmd+F12" ;;
    *) KEY="Ctrl+Shift+F12" ;;
esac

MARKER=/tmp/tz-ok
rm -f "$MARKER"

# `-e` 는 인자를 못 넘긴다 (`run_options.zig` — POSIX PTY 의 argv 가 `{shell}` 로 고정).
# 그래서 러너 스크립트를 만들어 넘긴다.
#
# **`exec <셸>` 이 이 검사의 핵심이다.** producer 를 그냥 `-e` 로 띄우면 폭포가 끝날 때
# 앱이 함께 종료돼, 버퍼에 쌓인 입력을 실행할 셸이 없다. producer 가 stdin 을 읽지 않으므로
# 폭포 중 타이핑은 termios 버퍼에 남고, `exec` 로 올라온 셸이 같은 PTY slave 를 물려받아
# 그것을 읽는다.
# **producer 모드는 환경변수 두 개로만 켜진다** (`stress.zig` 의 `producerRequest` —
# `TILDAZ_STRESS_WORKLOAD` + `TILDAZ_STRESS_BYTES` 가 둘 다 유효해야 하고, 하나라도
# 빠지면 조용히 일반 모드로 둔다). 인자를 주면 그건 *독립 측정* 모드라 자기 안에서
# 재고 끝나 **앱 PTY 로는 폭포가 흐르지 않는다** — #441 첫 회차가 이 실수였다.
RUNNER=$(mktemp "${TMPDIR:-/tmp}/tildaz-input-check-XXXXXX.sh")
SHELL_PATH="${SHELL:-/bin/bash}"
BYTES=$((MB * 1024 * 1024))
cat > "$RUNNER" <<EOF
#!/bin/sh
TILDAZ_STRESS_WORKLOAD=$WORKLOAD
TILDAZ_STRESS_BYTES=$BYTES
export TILDAZ_STRESS_WORKLOAD TILDAZ_STRESS_BYTES
"$STRESS"
exec "$SHELL_PATH"
EOF
chmod +x "$RUNNER"

cat <<EOF

================ 입력 손실 검사 (#441 축 ①) ================
 폭포      : $WORKLOAD · ${MB} MiB
 단축키    : $KEY 를 ${PRESSES} 회
 marker    : $MARKER
 로그      : $LOG
============================================================

⚠ **입력기(IME)를 영문 모드로 두세요.** 한글 모드면 둘 다 판정이 안 나와요 —
   타이핑이 한글로 조합돼 명령이 되지 않고, 키 이벤트도 IME 를 먼저 지나가서
   단축키가 앱까지 오지 않아요 (#441 실측: fcitx5 · KDE 에서 0/10).

창이 뜨면 **폭포가 흐르는 동안** 아래 둘을 하세요.

  ① $KEY 를 ${PRESSES} 회 누른다   (앱이 소비 — 로그에 흔적이 남는다)
  ② touch $MARKER  를 타이핑한다    (PTY 전달 — 폭포가 끝나면 셸이 실행한다)

  ②는 폭포 중에 화면에 안 보이는 것이 정상이에요. 초당 수만 줄이 지나가서
  에코가 나타난 순간 이미 스크롤 위로 밀려요 — 그래서 눈으로 판정하지 않아요.

폭포가 끝나면 셸 프롬프트가 돌아와요. 확인 후 창을 닫으면 (Alt+F4 · Cmd+Q)
판정이 나옵니다.

EOF
printf '준비되면 Enter — '
read -r _

# 이번 회차에 추가된 로그만 잘라 내려고 현재 크기를 기록한다 (`measure-repeat.sh` 와 같은 패턴).
START_LEN=0
[ -f "$LOG" ] && START_LEN=$(wc -c < "$LOG" | tr -d ' ')

"$EXE" -e "$RUNNER" -size 120x40 -scrollback "$SCROLLBACK"

RAW=$(mktemp "${TMPDIR:-/tmp}/tildaz-input-check-log-XXXXXX")
if [ "$START_LEN" -gt 0 ]; then
    tail -c "+$((START_LEN + 1))" "$LOG" > "$RAW"
elif [ -f "$LOG" ]; then
    cp "$LOG" "$RAW"
else
    : > "$RAW"
fi

# 단축키 덤프는 라벨이 `snapshot` 이고, 종료 시 자동 덤프 (#396) 는 워크로드 이름이다
# (`perf.zig` 의 `dumpAndReset` / `dumpOnExit`). 그래서 그 패턴만 세면 자동 덤프가 안 섞인다.
#
# **개수만 세면 안 된다.** 폭포가 없는 상태에서 누른 것도 10/10 이 나오는데, 그건 이 검사가
# 보려던 것이 아니다 (#441 첫 회차가 그랬다). 그래서 각 스냅숏의 `drain bytes` 로 **그 시점에
# 폭포가 흐르고 있었는지** 를 함께 본다 — `dumpAndReset` 은 읽으면서 리셋하므로 한 스냅숏의
# bytes 는 *직전 스냅숏 이후* 의 몫이고, 0 이면 그 사이에 아무것도 안 흘렀다는 뜻이다.
eval "$(awk '
/^=== snapshot @/ { snap = 1; next }
/^=== /           { snap = 0 }
/^readloop / {
    for (i = 1; i <= NF; i++) if ($i ~ /^bytes=/) { split($i, a, "="); total += a[2] }
}
/^drain / {
    if (snap) {
        snaps++
        for (i = 1; i <= NF; i++) if ($i ~ /^bytes=/) { split($i, a, "="); if (a[2] + 0 > 0) busy++ }
        snap = 0
    }
}
END { printf "SNAPS=%d BUSY=%d TOTAL_BYTES=%d\n", snaps + 0, busy + 0, total + 0 }
' "$RAW")"

# 폭포가 실제로 흘렀나. 기대 분량의 절반이면 충분하다 — 사용자가 폭포 도중에 창을 닫을 수도 있고,
# 여기서 보려는 것은 "producer 가 돌았나" 이지 정확한 처리량이 아니다.
FLOW_OK=0
[ "$TOTAL_BYTES" -ge "$((BYTES / 2))" ] && FLOW_OK=1
FLOW_MIB=$((TOTAL_BYTES / 1024 / 1024))

if [ -f "$MARKER" ]; then PTY_VERDICT="✅ 성공 (파일 생성됨)"; PTY_OK=1
else PTY_VERDICT="❌ 실패 (파일 없음)"; PTY_OK=0; fi

# 통과 조건은 "눌린 횟수" 가 아니라 **"폭포 중에 눌린 횟수"** 다.
if [ "$BUSY" -eq "$PRESSES" ]; then KEY_VERDICT="✅ $BUSY / $PRESSES"; KEY_OK=1
else KEY_VERDICT="❌ $BUSY / $PRESSES"; KEY_OK=0; fi

if [ "$FLOW_OK" -eq 1 ]; then FLOW_VERDICT="✅ ${FLOW_MIB} MiB 흘렀어요"
else FLOW_VERDICT="❌ ${TOTAL_BYTES} byte 뿐 — producer 가 안 돌았어요"; fi

cat <<EOF

==================== 결과 ====================
 폭포                      $FLOW_VERDICT
 ① 앱 단축키 · 앱이 소비   $KEY_VERDICT   (전체 눌림 $SNAPS)
 ② PTY 전달 · 타이핑       $PTY_VERDICT
==============================================

EOF

if [ "$FLOW_OK" -eq 0 ]; then
    cat >&2 <<'HINT'
⚠ 폭포가 흐르지 않았어요 — 이 회차는 판정이 성립하지 않아요.
  부하 없이 누르면 ①은 당연히 다 먹고 ②도 버퍼에 쌓일 이유가 없어요.
  producer 모드는 TILDAZ_STRESS_WORKLOAD + TILDAZ_STRESS_BYTES 가 둘 다 유효할 때만 켜져요
  (stress.zig 의 producerRequest). --keep-runner 로 러너를 남겨 확인해 보세요.
HINT
elif [ "$SNAPS" -eq 0 ] && [ "$PTY_OK" -eq 0 ]; then
    cat >&2 <<'HINT'
⚠ 폭포는 흘렀는데 ①②가 둘 다 0 이면 **입력기(IME)가 한글 모드였을 가능성이 큽니다.**
  타이핑은 한글로 조합돼 명령이 되지 않고, 키 이벤트도 IME 를 먼저 지나가 단축키가
  앱까지 오지 않아요. 영문 모드로 바꾸고 다시 돌려 보세요 (#441 실측: fcitx5 · KDE).
HINT
elif [ "$SNAPS" -gt "$BUSY" ]; then
    echo "⚠ $((SNAPS - BUSY)) 회는 폭포가 끝난 뒤에 눌렸어요 — 그건 이 검사의 대상이 아니에요." >&2
    echo "  --mb 를 늘려 폭포를 길게 하거나, 더 일찍 누르세요." >&2
fi
if [ "$SNAPS" -gt "$PRESSES" ]; then
    echo "⚠ 센 횟수가 기대보다 많아요 — 더 눌렀거나 이전 회차 로그가 섞였을 수 있어요." >&2
fi
if [ "$KEY_OK" -eq 0 ] || [ "$PTY_OK" -eq 0 ] || [ "$FLOW_OK" -eq 0 ]; then
    echo "로그 원문: $RAW" >&2
fi

[ "$KEEP_RUNNER" -eq 1 ] || rm -f "$RUNNER"
rm -f "$MARKER"

[ "$KEY_OK" -eq 1 ] && [ "$PTY_OK" -eq 1 ] && [ "$FLOW_OK" -eq 1 ]
