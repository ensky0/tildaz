#!/bin/sh
# 유휴 깨우기의 절전 대가 — core-idle 잔류율 비교 ([#439](https://github.com/ensky0/tildaz/issues/439) ②).
#
# TildaZ **완전 유휴** 인스턴스 (`-e` 로 `sleep 3600` — 출력도 입력도 없어 `frame_poll_ms`
# 16 ms 깨우기만 남는다, 초당 62 회) 가 떠 있을 때와 없을 때를 **ABAB 4 구간**으로 재서
# CPU core 의 idle state 잔류율과 유휴 진입 횟수를 비교한다. root 가 필요 없다
# (`/sys/devices/system/cpu/cpu*/cpuidle` 은 누구나 읽는다).
#
#   dist/stress/measure-idle-cstates.sh                  # 기본 — 구간 60 초 × 4
#   dist/stress/measure-idle-cstates.sh --duration 120
#
# ⚠ **core-idle 지표는 패키지 전력이 아니다.** i5-1240P 실측에서 62 회/s 깨우기가 이
#   지표로는 잡음 아래였지만 (시스템 전체 유휴 진입 ~700-830 회/s 의 요동이 더 크다),
#   패키지 수준 (RAPL) 에서는 시스템 +0.2 W 로 뚜렷했다 — 판정은 `measure-idle-power.sh`
#   (sudo 필요) 로 한다. 이 스크립트는 root 없이 경향을 볼 때만 쓴다.
#   https://github.com/ensky0/tildaz/issues/439#issuecomment-5305627637
#
# ## 왜 `hygiene_begin` 을 안 쓰나 — 일부러다
#
# `hygiene_begin` 은 CPU 프로파일을 performance 로 강제하는데, 그건 **유휴 전력 자체를
# 바꾼다** — 재려는 대상이 *평소 구성*의 유휴 대가라서 프로파일을 바꾸면 측정 대상이
# 바뀐다. 그래서 worker 종료 (`hygiene_kill_worker`) 만 하고 프로파일 · 절전 설정은
# 그대로 둔다. 배경 조건의 요동은 A/B 를 교대(ABAB)로 재서 상쇄한다.
#
# ⚠ 측정 중 키보드 · 마우스를 건드리면 오염된다 — 입력 처리뿐 아니라 배경 앱의 CPU
#   사용도 A/B 어느 한쪽에만 얹히면 비교가 깨진다. 시작 전 15 초 가라앉힘이 있어서
#   실행 명령 입력 자체는 괜찮다.
set -u

DUR=60

usage() {
    cat <<'USAGE'
쓰는 법: dist/stress/measure-idle-cstates.sh [옵션]

  --duration <초>   구간 길이 (기본 60 — A·B 각 2 회, 총 4 구간)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --duration) DUR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "모르는 옵션: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ "$(uname -s)" = Linux ] || { echo "Linux 전용이에요 (cpuidle sysfs). Windows·macOS 는 그 platform 도구로 잰다." >&2; exit 2; }

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO_ROOT/dist/stress/hygiene.sh"

EXE="$REPO_ROOT/zig-out/bin/tildaz"
[ -x "$EXE" ] || { echo "tildaz 없음: $EXE  (먼저 zig build)" >&2; exit 1; }

RUNNER=$(mktemp "${TMPDIR:-/tmp}/tildaz-idle-XXXXXX.sh")
printf '#!/bin/sh\nsleep 3600\n' > "$RUNNER"; chmod +x "$RUNNER"
SNAP0=$(mktemp "${TMPDIR:-/tmp}/tildaz-cstate-XXXXXX")
SNAP1=$(mktemp "${TMPDIR:-/tmp}/tildaz-cstate-XXXXXX")
APP=""
cleanup() { [ -n "$APP" ] && kill "$APP" 2>/dev/null; rm -f "$RUNNER" "$SNAP0" "$SNAP1"; }
trap cleanup EXIT INT TERM

snap() {
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu=${c##*/cpu}
        for s in "$c"/cpuidle/state*; do
            printf '%s %s %s %s\n' "$cpu" "$(cat "$s/name")" "$(cat "$s/time")" "$(cat "$s/usage")"
        done
    done
}

phase() { # $1 = 라벨
    t0=$(date +%s%N); snap > "$SNAP0"
    sleep "$DUR"
    t1=$(date +%s%N); snap > "$SNAP1"
    awk -v t0="$t0" -v t1="$t1" -v label="$1" '
        NR==FNR { time0[$1" "$2]=$3; usage0[$1" "$2]=$4; next }
        { dt[$2]+=$3-time0[$1" "$2]; du[$2]+=$4-usage0[$1" "$2]; cpus[$1]=1 }
        END {
            wall=(t1-t0)/1e9; n=0; for (c in cpus) n++
            total_us=wall*1e6*n; wk=0; idle=0
            printf "== %s  (wall %.1f s · cpu %d) ==\n", label, wall, n
            for (s in dt) { printf "  %-6s 잔류 %7.3f %%   진입 %7d 회 (%7.1f /s)\n", s, 100*dt[s]/total_us, du[s], du[s]/wall
                wk+=du[s]; idle+=dt[s] }
            printf "  C0(비유휴) %.3f %%   유휴 진입 합계 %.1f /s (전체 CPU)\n", 100*(1-idle/total_us), wk/wall
        }' "$SNAP0" "$SNAP1"
}

app_start() {
    "$EXE" --instance 1 -e "$RUNNER" -size 100x30 >/dev/null 2>&1 &
    APP=$!
    sleep 8   # 창 생성 · 초기 렌더가 가라앉을 시간
    kill -0 "$APP" 2>/dev/null || { echo "❌ tildaz 가 안 떴어요" >&2; exit 1; }
}
app_stop() { kill "$APP" 2>/dev/null; APP=""; sleep 3; }
vctx() { awk '/^voluntary_ctxt_switches/ {print $2}' "/proc/$APP/status" 2>/dev/null || echo 0; }

TOTAL=$(( 15 + DUR * 4 + 30 ))
cat <<EOF

========= 유휴 절전 대가 — core-idle (#439 ②) =========
 구간      : ${DUR} 초 × 4 (기준선 → TildaZ 유휴 → 기준선 → TildaZ 유휴)
 예상 소요 : 약 ${TOTAL} 초
 ⚠ 측정 중 키보드 · 마우스 금지 — 배경 CPU 사용도 오염이에요
========================================================

EOF

hygiene_kill_worker
sleep 15   # 직전 활동 (셸 · 에디터) 의 여진이 첫 기준선에 얹히지 않게 가라앉힌다

phase "A1 기준선 (TildaZ 없음)"
app_start; V0=$(vctx); S0=$(date +%s)
phase "B1 TildaZ 유휴"
V1=$(vctx); S1=$(date +%s)
echo "  TildaZ voluntary_ctxt_switches: $V0 → $V1  (초당 $(( (V1 - V0) / (S1 - S0) )))"
app_stop
phase "A2 기준선 (TildaZ 없음)"
app_start; V0=$(vctx); S0=$(date +%s)
phase "B2 TildaZ 유휴"
V1=$(vctx); S1=$(date +%s)
echo "  TildaZ voluntary_ctxt_switches: $V0 → $V1  (초당 $(( (V1 - V0) / (S1 - S0) )))"
app_stop

echo "##### 끝 #####"
