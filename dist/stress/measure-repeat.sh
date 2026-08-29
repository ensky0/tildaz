#!/bin/sh
# perf 스냅숏 반복 측정 (Linux · macOS · Windows) — 배분을 5 회 규칙대로 뜬다.
#
# `compare-terminals.sh` 와는 역할이 다르다 — 저쪽은 **여러 터미널을 나란히 놓고 처리량**을
# 재고, 이쪽은 **우리 앱 하나**를 반복해 띄워 종료 시 자동 덤프 (#396) 로 남는
# `parse` · `render` · `shape` 배분을 모은다.
#
#   zig build -Doptimize=ReleaseFast -Dsimd=true
#   zig build stress -Doptimize=ReleaseFast -Dsimd=true -- throughput --layer parser --mb 1
#   dist/stress/measure-repeat.sh --phase before
#   dist/stress/measure-repeat.sh --phase after --workloads zwj,plain
#
# 결과는 `--out` (기본 `dist/stress/shots/`) 에 `<phase>-raw.txt` (로그 원문) 와
# `<phase>.csv` (회차별 값) 로 남고, 표는 화면에 찍는다.
#
# **왜 만들었나** — README 는 *"Linux · macOS 는 같은 일을 `systemd-inhibit` / `caffeinate` 를
# 붙인 짧은 셸 루프로 해요"* 라고 적어 두고 실물이 없었다. 그런데 위생 검사를 사람 기억에
# 맡기면 회차를 통째로 버린다 — Windows 에서 AC · DRR 을 안 보고 40 회차를 날렸다 (#394).
# #397 의 Linux 실기 검증 (2 커밋 x 2 워크로드 x 5 회 = 20 회차) 이 계기다.
#
# **Windows 도 이 파일로 돈다 — `measure-repeat.ps1` 은 없어졌다** (#381). 처음엔 PowerShell
# 판을 따로 뒀지만 (Git Bash 를 요구하지 않으려고) **두 벌이 실제로 갈렸다**: `parse 비중`
# 계산식이 표마다 달랐고 (#395, [7d3ab4e](https://github.com/ensky0/tildaz/commit/7d3ab4e))
# 워크로드 목록 · 로그 파싱 정규식이 양쪽에 중복이었다. `compare-terminals.sh` 가 이미 Git
# Bash 를 요구하고 그건 Git for Windows 에 항상 들어 있어서, 한 벌로 합치는 값이 더 크다.
#
# **Windows 는 Git Bash 에서 돌린다** (`compare-terminals.sh` 와 같은 제약이다).
#
# ⚠️ **macOS 경로는 아직 실기 검증하지 않았다** (2026-08-07 현재). Linux (KDE Plasma Wayland ·
# Intel i5-1240P) 와 Windows (같은 기기) 에서만 돌려 봤다. macOS 에서 처음 쓸 때는
# `caffeinate` 가 실제로 붙었는지와 로그 경로 (`~/Library/Logs/tildaz_stress.log`) 를 먼저 확인해요.

set -eu

PHASE=run
MB=64
WORKLOADS="plain,cjk,emoji_vs16,zwj"
REPEAT=5
# 앱에 넘길 scrollback 줄 수. 기본 32,767 은 `compare-terminals.sh` 와 같은 값이라
# 두 도구의 회차를 나란히 둘 수 있다 (다른 터미널의 상한에 맞춘 값이다). 처리량이
# 이 값에 어떻게 반응하는지 보려면 바꾼다 (#425).
SCROLLBACK=32767
# #397 의 드레인 고침 이후 HOLD 는 필요 없다. 주면 출력이 끝난 뒤 idle 프레임이 섞여
# `render` 가 낮게 나오고, 무엇보다 **#397 이 잡은 결함 자체를 가린다** — 유휴 시간이
# 드레인할 기회를 줘서 고치기 전 커밋도 손실이 16 byte 로 보인다 (Windows 실측).
HOLD_MS=0
# 배경 앱이 그리고 있으면 우리 수치만 눌린다 (README "배경 앱" 절, cluster 워크로드에서
# +64 %). 창을 내릴 시간을 주고 가라앉히는 대기다.
LEAD_IN=8
OUT=""
IGNORE_HYGIENE=0

usage() {
    cat <<'USAGE'
쓰는 법: dist/stress/measure-repeat.sh [옵션]

  --phase <이름>       결과 파일 이름과 표 제목 (기본 run). before / after 를 나눠 부를 때 쓴다
  --mb <N>             회차당 쏟아부을 MiB (기본 64 — 기록용은 반드시 64, README 참고)
  --workloads <a,b>    쉼표로 구분 (기본 plain,cjk,emoji_vs16,zwj)
  --repeat <N>         반복 횟수 (기본 5 — 절사평균이 성립하는 최소값)
  --scrollback <N>     앱에 넘길 scrollback 줄 수 (기본 32767 — compare-terminals.sh 와 같은 값)
  --hold-ms <N>        TILDAZ_STRESS_HOLD_MS (기본 0 — 위 주석 참고)
  --lead-in <초>       측정 시작 전 가라앉히는 시간 (기본 8)
  --out <디렉터리>     결과 위치 (기본 dist/stress/shots)
  --ignore-hygiene     위생 점검에 걸려도 강행 (동작 확인용 — 기록용 측정에는 쓰지 않는다)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --phase) PHASE="$2"; shift 2 ;;
        --mb) MB="$2"; shift 2 ;;
        --workloads) WORKLOADS="$2"; shift 2 ;;
        --repeat) REPEAT="$2"; shift 2 ;;
        --scrollback) SCROLLBACK="$2"; shift 2 ;;
        --hold-ms) HOLD_MS="$2"; shift 2 ;;
        --lead-in) LEAD_IN="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --ignore-hygiene) IGNORE_HYGIENE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "모르는 옵션: $1" >&2; usage >&2; exit 2 ;;
    esac
done

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "$OUT" ] || OUT="$REPO_ROOT/dist/stress/shots"

# 측정 위생은 `compare-terminals.sh` 와 **같은 로직**을 쓴다.
. "$REPO_ROOT/dist/stress/hygiene.sh"

# 자식이 Windows 실행파일이면 경로를 native 로 바꿔 넘긴다 (`compare-terminals.sh` 와 같은
# 함수다). MSYS 는 명령줄 인자를 자동 변환하기도 하지만 기대지 않는다.
native_path() {
    if [ "$HYG_PLATFORM" = windows ]; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

EXE_SUFFIX=""
[ "$HYG_PLATFORM" = windows ] && EXE_SUFFIX=".exe"
# **macOS 는 `.app` 번들 안에 있다** — `zig build` 산출물이 platform 마다 자리가 다르다.
# `compare-terminals.sh` 와 같은 후보 순회를 쓴다. 이게 없으면 macOS 에서 `tildaz 없음` 으로
# 즉시 죽는다 (#399 배칭 before/after 를 재려다 실측으로 드러났다 — 이 파일은 Linux · Windows
# 에서만 검증됐었다).
EXE=""
for _cand in \
    "$REPO_ROOT/zig-out/TildaZ.app/Contents/MacOS/tildaz" \
    "$REPO_ROOT/zig-out/bin/tildaz$EXE_SUFFIX"
do
    [ -x "$_cand" ] && EXE="$_cand" && break
done
[ -n "$EXE" ] || EXE="$REPO_ROOT/zig-out/bin/tildaz$EXE_SUFFIX"   # 없으면 아래에서 안내가 나온다
STRESS="$REPO_ROOT/zig-out/bin/tildaz-stress$EXE_SUFFIX"

case "$HYG_PLATFORM" in
    # paths.zig 의 `logDir` 와 같은 규칙이다. 여기서 어긋나면 회차는 도는데 표가 비어서
    # 원인을 찾기 어려우니, 그 파일이 단일 출처라는 것을 기억해요.
    linux) LOG="${XDG_STATE_HOME:-$HOME/.local/state}/tildaz/tildaz_stress.log" ;;
    macos) LOG="$HOME/Library/Logs/tildaz_stress.log" ;;
    # `$APPDATA` 는 `C:\Users\…\AppData\Roaming` 형태로 오므로 POSIX 경로로 바꿔서 쓴다 —
    # 아래에서 `wc -c` · `tail -c` 로 직접 읽는 대상이기 때문이다.
    windows) LOG="$(cygpath -u "$APPDATA")/tildaz/tildaz_stress.log" ;;
    *) echo "모르는 platform 이에요 ($(uname -s)) — Linux · macOS · Windows(Git Bash) 만 돌아요." >&2; exit 2 ;;
esac

[ -x "$EXE" ] || { echo "tildaz 없음: $EXE  (먼저 zig build)" >&2; exit 1; }
[ -x "$STRESS" ] || { echo "tildaz-stress 없음: $STRESS  (먼저 zig build stress)" >&2; exit 1; }

# 이름을 미리 검증한다. 오타 하나로 회차 전부가 날아가지 않게 — 모르는 이름은
# `stress.zig` 의 `Kind.parse` 가 탈락시켜 **producer 모드로 진입하지 않고**, 창은 뜨는데
# 폭포가 없는 껍데기 회차가 된다 (`.ps1` 에서 실측으로 10 회를 날렸다).
# 목록은 `src/stress/workload.zig` 의 `Kind` 와 같아야 한다.
KNOWN="plain ansi cjk hangul emoji_vs16 skintone zwj hangul_varied emoji_vs16_varied skintone_varied zwj_varied"
WORKLOAD_LIST=$(echo "$WORKLOADS" | tr ',' ' ')
for w in $WORKLOAD_LIST; do
    found=0
    for k in $KNOWN; do [ "$w" = "$k" ] && found=1 && break; done
    [ "$found" = 1 ] || { echo "모르는 워크로드 '$w' — 가능: $KNOWN" >&2; exit 2; }
done

# --- 측정 위생 --------------------------------------------------------------
#
# 검사도 준비도 `hygiene.sh` 가 한다. worker · AC · 주사율 · CPU 프로파일을 보고,
# 절전 차단 · 성능 프로파일 · 배경 앱 최소화까지 걸고 끝나면 되돌린다.
hygiene_check || {
    [ "$IGNORE_HYGIENE" = 1 ] || {
        echo "측정 위생 점검에 걸렸어요. 고치거나 --ignore-hygiene 로 강행해요." >&2
        exit 1
    }
}

# 복원은 어떤 경로로 끝나든 돌아야 한다 (Ctrl+C 포함) — 안 그러면 CPU 가 performance 인
# 채로, 창이 내려간 채로 남는다.
trap hygiene_end EXIT INT TERM
hygiene_begin

mkdir -p "$OUT"

START_LEN=0
[ -f "$LOG" ] && START_LEN=$(wc -c < "$LOG" | tr -d ' ')

HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
DIRTY=$([ -n "$(git -C "$REPO_ROOT" status --porcelain)" ] && echo yes || echo no)
TOTAL=0
for w in $WORKLOAD_LIST; do TOTAL=$((TOTAL + REPEAT)); done

echo "phase=$PHASE  mb=$MB  repeat=$REPEAT  hold_ms=$HOLD_MS  workloads=$WORKLOADS"
echo "commit=$HEAD_SHA  dirty=$DIRTY  $(hygiene_status)"
echo "log=$LOG  start_offset=$START_LEN"
echo "회차 $TOTAL 개를 시작해요. 끝날 때까지 기기를 건드리지 마세요."

sleep "$LEAD_IN"

TILDAZ_STRESS_BYTES=$((MB * 1048576))
export TILDAZ_STRESS_BYTES
TILDAZ_STRESS_HOLD_MS="$HOLD_MS"
export TILDAZ_STRESS_HOLD_MS

# 회차가 안 끝나고 매달리면 전체가 멈춘다. 있으면 상한을 건다 — 정상 회차는 64 MiB
# 에서도 한참 아래다. macOS 는 `timeout` 이 기본 설치가 아니라 (`gtimeout`) 없으면 생략한다.
if command -v timeout >/dev/null 2>&1; then RUN_TIMEOUT="timeout 300"
elif command -v gtimeout >/dev/null 2>&1; then RUN_TIMEOUT="gtimeout 300"
else RUN_TIMEOUT=""; fi

# **라운드로빈** — 워크로드를 안쪽에 두고 $REPEAT 바퀴를 돈다. 한 워크로드를 몰아서
# 돌리면 열 드리프트가 그 워크로드에만 쌓인다 (#389 의 Linux · macOS 세션과 같은 순서).
i=1
while [ "$i" -le "$REPEAT" ]; do
    for w in $WORKLOAD_LIST; do
        TILDAZ_STRESS_WORKLOAD="$w"
        export TILDAZ_STRESS_WORKLOAD
        # 실패해도 남은 회차는 계속 돈다 — 한 회차가 죽었다고 나머지를 버리지 않는다.
        # 그 회차는 로그에 스냅숏을 안 남기므로 표의 회차 수로 드러난다.
        $RUN_TIMEOUT "$EXE" -e "$(native_path "$STRESS")" -size 120x40 -scrollback "$SCROLLBACK" \
            >/dev/null 2>&1 || echo "⚠ 회차 실패: $w ($i/$REPEAT)" >&2
        sleep 1.5
    done
    i=$((i + 1))
done

# 이번 phase 에 추가된 로그만 잘라 낸다.
RAW="$OUT/$PHASE-raw.txt"
if [ "$START_LEN" -gt 0 ]; then
    tail -c "+$((START_LEN + 1))" "$LOG" > "$RAW"
else
    cp "$LOG" "$RAW"
fi

CSV="$OUT/$PHASE.csv"

# 파싱 · 통계는 POSIX awk 한 벌로 한다 (gawk 의 `asort` 를 쓰지 않는 이유 — macOS 의
# awk 에는 없다). `.ps1` 의 정규식과 같은 줄을 잡는다: perf.zig 의 `dumpAndReset` 이
# 찍는 형식은 세 platform 공통이다.
awk -v out_csv="$CSV" -v raw="$RAW" -v phase="$PHASE" -v order="$WORKLOAD_LIST" -v repeat="$REPEAT" '
BEGIN {
    print "workload,rl_calls,rl_bytes,readloop_ms,yields,drain_bytes,lost_bytes,drain_ms,parse_ms,render_calls,render_ms,shape_calls,shape_ms,miss,present_calls,present_ms,onrender_calls,onrender_ms,skip" > out_csv
    nw = split(order, wl, " ")
}
function trimmed(arr, n,   i, j, t, s, lo, hi, sum, cnt) {
    for (i = 1; i <= n; i++) s[i] = arr[i]
    for (i = 1; i < n; i++)
        for (j = 1; j <= n - i; j++)
            if (s[j] > s[j+1]) { t = s[j]; s[j] = s[j+1]; s[j+1] = t }
    # 표본이 3 개 미만이면 절사하지 않고 단순 평균으로 떨어진다 (README 의 대표값 규칙).
    if (n >= 3) { lo = 2; hi = n - 1 } else { lo = 1; hi = n }
    sum = 0; cnt = 0
    for (i = lo; i <= hi; i++) { sum += s[i]; cnt++ }
    return cnt > 0 ? sum / cnt : 0
}
function vmin(arr, n,   i, m) { m = arr[1]; for (i = 2; i <= n; i++) if (arr[i] < m) m = arr[i]; return m }
function vmax(arr, n,   i, m) { m = arr[1]; for (i = 2; i <= n; i++) if (arr[i] > m) m = arr[i]; return m }
function row(label, w, key, fmt,   i, a, n) {
    n = cnt[w]
    for (i = 1; i <= n; i++) a[i] = v[w, key, i]
    printf(fmt, label, trimmed(a, n), vmin(a, n), vmax(a, n))
}
function uniq(w, key,   i, seen, s) {
    s = ""
    for (i = 1; i <= cnt[w]; i++) {
        if (!((w, key, v[w, key, i]) in seen)) {
            seen[w, key, v[w, key, i]] = 1
            s = (s == "" ? "" : s ",") sprintf("%d", v[w, key, i])
        }
    }
    return s
}
/^=== .* @ ts=[0-9]+ms ===$/ { cur = $2; next }
cur != "" {
    if ($1 == "readloop") { split($2, a, "="); rl_calls = a[2]; split($3, a, "="); rl_bytes = a[2]; split($4, a, "="); readloop = a[2] }
    else if ($1 == "push") { split($4, a, "="); yields = a[2] }
    else if ($1 == "drain") { split($3, a, "="); drain_bytes = a[2]; split($4, a, "="); drain = a[2] }
    else if ($1 == "parse") { split($3, a, "="); parse = a[2] }
    else if ($1 == "render") { split($2, a, "="); render_calls = a[2]; split($3, a, "="); render = a[2] }
    else if ($1 == "shape") { split($2, a, "="); shape_calls = a[2]; split($3, a, "="); shape = a[2]; split($4, a, "="); miss = a[2] }
    else if ($1 == "present") { split($2, a, "="); present_calls = a[2]; split($3, a, "="); present = a[2] }
    else if ($1 == "onrender") {
        split($2, a, "="); onrender_calls = a[2]; split($3, a, "="); onrender = a[2]; split($4, a, "="); skip = a[2]
        w = cur; n = ++cnt[w]
        v[w, "readloop", n] = readloop; v[w, "drain", n] = drain; v[w, "parse", n] = parse
        v[w, "render", n] = render; v[w, "shape", n] = shape; v[w, "present", n] = present
        v[w, "rl_bytes", n] = rl_bytes; v[w, "drain_bytes", n] = drain_bytes
        # #397 의 핵심 지표. `readloop bytes >= 요청` 은 PTY 에서 읽은 양이라 부분 파싱을
        # 못 잡는다 — 소화한 양과의 차이를 봐야 한다.
        v[w, "lost", n] = rl_bytes - drain_bytes
        v[w, "render_calls", n] = render_calls; v[w, "shape_calls", n] = shape_calls
        v[w, "miss", n] = miss; v[w, "present_calls", n] = present_calls
        v[w, "onrender_calls", n] = onrender_calls; v[w, "skip", n] = skip; v[w, "yields", n] = yields
        v[w, "shape_ratio", n] = render > 0 ? 100.0 * shape / render : 0
        # `parse 비중` 은 표마다 계산식이 달랐다 (#389 의 Linux 표는 present 를 빼고 macOS
        # 표는 넣었다). 어느 쪽과 견주든 되게 둘 다 찍는다.
        v[w, "parse_share", n] = 100.0 * parse / (parse + render)
        v[w, "parse_share_p", n] = 100.0 * parse / (parse + render + present)
        v[w, "per_frame", n] = render_calls > 0 ? render / render_calls : 0
        v[w, "per_shape", n] = shape_calls > 0 ? 1000.0 * shape / shape_calls : 0
        printf("%s,%d,%d,%.3f,%d,%d,%d,%.3f,%.3f,%d,%.3f,%d,%.3f,%d,%d,%.3f,%d,%.3f,%d\n",
            w, rl_calls, rl_bytes, readloop, yields, drain_bytes, rl_bytes - drain_bytes, drain,
            parse, render_calls, render, shape_calls, shape, miss,
            present_calls, present, onrender_calls, onrender, skip) > out_csv
        cur = ""
    }
}
END {
    total = 0
    for (i = 1; i <= nw; i++) total += cnt[wl[i]]
    printf("\n##### %s — %d 회차 #####\n", phase, total)
    if (repeat < 3) print "⚠ 표본이 3 개 미만이라 절사하지 않고 단순 평균이에요."
    for (i = 1; i <= nw; i++) {
        w = wl[i]
        if (cnt[w] == 0) { printf("%s : 회차 없음 (⚠ 실패)\n", w); continue }
        printf("\n--- %s (%d 회차) ---\n", w, cnt[w])
        row("readloop", w, "readloop", "%-16s %10.3f   min~max %.3f ~ %.3f\n")
        row("drain",    w, "drain",    "%-16s %10.3f   min~max %.3f ~ %.3f\n")
        row("parse",    w, "parse",    "%-16s %10.3f   min~max %.3f ~ %.3f\n")
        row("render",   w, "render",   "%-16s %10.3f   min~max %.3f ~ %.3f\n")
        row("shape",    w, "shape",    "%-16s %10.3f   min~max %.3f ~ %.3f\n")
        row("present",  w, "present",  "%-16s %10.3f   min~max %.3f ~ %.3f\n")
        row("shape/render%",    w, "shape_ratio",   "%-16s %10.1f   min~max %.1f ~ %.1f\n")
        row("parse비중% (P+R)", w, "parse_share",   "%-16s %10.1f   min~max %.1f ~ %.1f\n")
        row("parse비중% (+pr)", w, "parse_share_p", "%-16s %10.1f   min~max %.1f ~ %.1f\n")
        row("프레임당render ms", w, "per_frame",    "%-16s %10.2f   min~max %.2f ~ %.2f\n")
        row("호출당shape us",   w, "per_shape",     "%-16s %10.2f   min~max %.2f ~ %.2f\n")
        printf("shape calls %s · miss %s\n", uniq(w, "shape_calls"), uniq(w, "miss"))
        printf("그린 프레임 %s · skip %s / onrender %s · yields %s\n",
            uniq(w, "render_calls"), uniq(w, "skip"), uniq(w, "onrender_calls"), uniq(w, "yields"))
        printf("읽은 바이트 %s · 소화 %s · 손실 %s\n",
            uniq(w, "rl_bytes"), uniq(w, "drain_bytes"), uniq(w, "lost"))
    }
    printf("\nraw=%s\ncsv=%s\n##### 끝 #####\n", raw, out_csv)
}
' "$RAW"
