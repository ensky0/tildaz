#!/bin/sh
# 유휴 깨우기의 절전 대가 — 패키지 전력 비교 ([#439](https://github.com/ensky0/tildaz/issues/439) ②).
#
# TildaZ **완전 유휴** 인스턴스 (`-e` 로 `sleep 3600` — 깨우기는 `frame_poll_ms` 16 ms
# 의 초당 62 회뿐) 가 떠 있을 때와 없을 때를 **ABAB 4 구간**으로 재서, `turbostat` 의
# 패키지 전력 (PkgWatt / SysWatt, RAPL) 과 패키지 C-state 잔류율을 비교한다.
#
#   sudo dist/stress/measure-idle-power.sh                  # 기본 — 구간 60 초 × 4
#   sudo dist/stress/measure-idle-power.sh --duration 120
#
# **sudo 가 필요하다** — RAPL 의 `energy_uj` 와 MSR 은 root 전용이다 (root 없이 돌리면
# turbostat 이 PkgWatt · Pkg%pc* 를 못 얹는다). 측정용 TildaZ 는 root 로 띄우면 사용자의
# Wayland 세션에 못 붙으므로 **`SUDO_USER` 계정으로** 띄운다.
#
# `measure-idle-cstates.sh` (root 불필요) 는 core-idle 잔류율만 본다 — i5-1240P 실측에서
# 62 회/s 깨우기가 core-idle 로는 잡음 아래였지만 이 스크립트로는 뚜렷했다 (시스템
# +0.19~0.24 W ≈ 유휴 소비의 +2 %, Pkg%pc8 잔류율 절반). **판정은 이쪽이다.**
# https://github.com/ensky0/tildaz/issues/439#issuecomment-5306404629
#
# ## 왜 `hygiene_begin` 을 안 쓰나 — 일부러다
#
# `hygiene_begin` 은 CPU 프로파일을 performance 로 강제하는데, 그건 **유휴 전력 자체를
# 바꾼다** — 재려는 대상이 *평소 구성*의 유휴 대가라서 프로파일을 바꾸면 측정 대상이
# 바뀐다. 그래서 worker 종료 (`hygiene_kill_worker`) 만 하고 프로파일 · 절전 설정은
# 그대로 둔다. 배경 조건의 요동은 A/B 를 교대(ABAB)로 재서 상쇄한다. 대신 **AC · 화면
# 상태를 결과에 함께 적는다** — 화면이 켜져 있으면 패키지가 pc8 위로 묶여 (Pk%pc10 ·
# S0ix 0) 화면 끈 대기 상태와는 절대값이 다르다.
#
# ⚠ 측정 중 키보드 · 마우스를 건드리면 오염된다 — 시작 전 15 초 가라앉힘이 있어서
#   실행 명령 입력 자체는 괜찮다.
set -u

DUR=60

usage() {
    cat <<'USAGE'
쓰는 법: sudo dist/stress/measure-idle-power.sh [옵션]

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

[ "$(uname -s)" = Linux ] || { echo "Linux 전용이에요 (turbostat). macOS 는 powermetrics, Windows 는 별도 도구로 잰다." >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "sudo 로 실행하세요 (RAPL·MSR 이 root 전용이에요)." >&2; exit 1; }
[ -n "${SUDO_USER:-}" ] || { echo "sudo 를 통해 사용자 세션에서 실행하세요 — 측정용 TildaZ 를 그 사용자의 Wayland 세션에 띄워야 해요." >&2; exit 1; }
command -v turbostat >/dev/null 2>&1 || { echo "turbostat 없음 — linux-tools 계열 패키지를 설치하세요." >&2; exit 1; }

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO_ROOT/dist/stress/hygiene.sh"

EXE="$REPO_ROOT/zig-out/bin/tildaz"
[ -x "$EXE" ] || { echo "tildaz 없음: $EXE  (먼저 zig build)" >&2; exit 1; }

RUNTIME=/run/user/$(id -u "$SUDO_USER")
WD=$(ls "$RUNTIME" 2>/dev/null | grep -m1 '^wayland-[0-9]*$' || echo wayland-0)

RUNNER=$(mktemp "${TMPDIR:-/tmp}/tildaz-idle-XXXXXX.sh")
printf '#!/bin/sh\nsleep 3600\n' > "$RUNNER"; chmod 755 "$RUNNER"
TPID=""
cleanup() { pkill -x tildaz 2>/dev/null; rm -f "$RUNNER"; }
trap cleanup EXIT INT TERM

# turbostat 한 구간. 원본 행을 그대로 남기고 (열이 기기마다 달라서 기록은 원본이 정본),
# 판정에 쓰는 열만 헤더 이름으로 뽑아 요약 한 줄을 붙인다.
ts() {
    _out=$(turbostat --quiet --Summary --interval "$DUR" --num_iterations 1 2>&1)
    echo "$_out"
    echo "$_out" | awk '
        /PkgWatt/ { for (i = 1; i <= NF; i++) h[$i] = i; next }
        NF && h["PkgWatt"] {
            printf "  → PkgWatt %s W", $(h["PkgWatt"])
            if (h["SysWatt"]) printf " · SysWatt %s W", $(h["SysWatt"])
            if (h["IRQ"])     printf " · IRQ %s", $(h["IRQ"])
            if (h["Pkg%pc8"]) printf " · Pkg%%pc8 %s%%", $(h["Pkg%pc8"])
            if (h["Busy%"])   printf " · Busy %s%%", $(h["Busy%"])
            printf "\n"; exit
        }'
}

app_start() {
    sudo -u "$SUDO_USER" env XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$WD" HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)" \
        "$EXE" --instance 1 -e "$RUNNER" -size 100x30 >/dev/null 2>&1 &
    sleep 8   # 창 생성 · 초기 렌더가 가라앉을 시간
    TPID=$(pgrep -x tildaz | head -1)
    [ -n "$TPID" ] || { echo "❌ tildaz 가 안 떴어요 (Wayland 연결 실패?)" >&2; exit 1; }
}
app_stop() { pkill -x tildaz 2>/dev/null; TPID=""; sleep 3; }
vctx() { awk '/^voluntary_ctxt_switches/ {print $2}' "/proc/$TPID/status" 2>/dev/null || echo 0; }

TOTAL=$(( 15 + DUR * 4 + 30 ))
cat <<EOF

========= 유휴 절전 대가 — 패키지 전력 (#439 ②) =========
 구간      : ${DUR} 초 × 4 (기준선 → TildaZ 유휴 → 기준선 → TildaZ 유휴)
 사용자    : $SUDO_USER · wayland=$WD
 예상 소요 : 약 ${TOTAL} 초
 ⚠ 측정 중 키보드 · 마우스 금지 — 배경 CPU 사용도 오염이에요
 ⚠ AC · 화면 상태를 결과에 함께 적어요 (화면 켬 = 패키지가 pc8 위로 묶임)
==========================================================

EOF

hygiene_kill_worker
sleep 15   # 직전 활동의 여진이 첫 기준선에 얹히지 않게 가라앉힌다

echo "== A1 기준선 (TildaZ 없음) =="; ts
app_start; V0=$(vctx); S0=$(date +%s)
echo "== B1 TildaZ 유휴 =="; ts
V1=$(vctx); S1=$(date +%s)
echo "  TildaZ voluntary_ctxt_switches: $V0 → $V1  (초당 $(( (V1 - V0) / (S1 - S0) )))"
app_stop
echo "== A2 기준선 (TildaZ 없음) =="; ts
app_start; V0=$(vctx); S0=$(date +%s)
echo "== B2 TildaZ 유휴 =="; ts
V1=$(vctx); S1=$(date +%s)
echo "  TildaZ voluntary_ctxt_switches: $V0 → $V1  (초당 $(( (V1 - V0) / (S1 - S0) )))"
app_stop

echo "##### 끝 #####"
