#!/bin/bash
# present-check_macos.sh — 여러 앱 판을 번갈아 띄워 **표시 경로**를 견주는 도구 (#766).
#
# 하위 명령은 셋이다. 셋 다 판을 `이름=경로[@환경변수=값...]` 으로 받는다. 경로는 `.app` 번들이나
# 그 안의 실행 파일이다. 환경변수는 대조 판 스위치 (`TILDAZ_TEMP476=nosync` 등) 를 넘길 때 쓴다.
#
#   tool/present-check_macos.sh latency [--flood] [--rounds 3] [--presses 30] 판...
#       키 → 화면 지연을 앱 밖에서 잰다 (`key-to-screen_macos.m`). 판을 번갈아 띄워 라운드마다 한 번씩.
#       회차마다 첫 키는 창이 막 뜬 직후라 빼고 요약한다.
#       --flood 면 창을 둘로 나눠 왼쪽 pane 은 출력을 쏟고, 오른쪽 pane 만 키를 받아 잰다.
#   tool/present-check_macos.sh mode [--toggles 2] 판...
#       Metal HUD (`MTL_HUD_ENABLED=1`) 로 창 모드 · 전체화면 (`⌘↵`) 의 표시 방식 (Direct / Composited) 을
#       찍고, 출력이 쏟아지는 동안 전체화면을 오가는 화면을 녹화해 전환 앞뒤 프레임을 한 장으로 붙인다.
#   tool/present-check_macos.sh tearing [--seconds 5] 판...
#       눈으로 보는 찢김 시험. 굵은 세로 막대가 화면을 가로로 지나가는 창을 판마다 차례로 띄운다.
#
#   예 (#766 ③ · ⑤):
#     tool/present-check_macos.sh latency main=zig-out/TildaZ-dev.app \
#         old=/tmp/wt-old/zig-out/TildaZ-dev.app old-nosync=/tmp/wt-old/zig-out/TildaZ-dev.app@TILDAZ_TEMP476=nosync
#
# 지키는 것 (AGENTS.md 의 `# macOS — 표시 대기열을 재는 법` 이 단일 출처다):
#   - **시작할 때 다른 TildaZ 가 떠 있으면 멈춘다** (`pgrep -x tildaz`). 다른 세션의 측정 창을 집어 합성 키를
#     보낸 일이 있다 (2026-10-15). `pgrep -f` 는 그 글자가 든 셸 명령까지 잡아서 쓰지 않는다.
#   - **이번에 띄운 창만 고른다.** 띄우기 전의 창 목록과 견줘 새로 생긴 창을 집는다.
#   - 판의 환경변수는 **그 판에만** 준다. 다른 판에 나온 변수는 지우고 띄운다.
#   - 입력기를 영문으로 바꿨다가 끝나면 되돌린다 (한글이면 `a` 가 IME 로 간다).
#   - 끝나면 시작할 때 맨 앞이던 앱 (보통 VS Code) 을 다시 올린다.
#   - 회차 로그에 TildaZ 시작이 둘 이상이면 그 회차를 **오염** 으로 표시한다.
#   - 화면 녹화 (`mode`) 와 ScreenCaptureKit (`latency`) 은 이 셸을 띄운 앱의 화면 기록 권한을 쓴다.
#     합성 입력은 손쉬운 사용 권한이다 (`input_macos.m check`).
#
# 실기라서 시작 전에 사용자 동의를 받고, 같은 기기의 다른 세션에 알린다 (AGENTS.md `# 워크플로우`).

set -u

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

[ $# -ge 1 ] || usage
CMD="$1"; shift

ROUNDS=3
PRESSES=30
GAP_MS=250
FLOOD=0
TOGGLES=2
SECONDS_EACH=5
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rounds) ROUNDS="$2"; shift 2 ;;
        --presses) PRESSES="$2"; shift 2 ;;
        --gap-ms) GAP_MS="$2"; shift 2 ;;
        --flood) FLOOD=1; shift ;;
        --toggles) TOGGLES="$2"; shift 2 ;;
        --seconds) SECONDS_EACH="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --help|-h) usage ;;
        --*) echo "모르는 옵션: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
[ $# -ge 1 ] || { echo "판이 없어요 — 이름=경로[@환경변수=값...]" >&2; exit 2; }

case "$CMD" in latency|mode|tearing) ;; *) usage ;; esac

REPO=$(cd "$(dirname "$0")/.." && pwd)
[ -n "$OUT" ] || OUT="${TMPDIR:-/tmp}/tildaz-present-check/$CMD-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
BIN="${TMPDIR:-/tmp}/tildaz-present-check/bin"
mkdir -p "$BIN"

# --- 도구 빌드 (소스가 더 새로우면 다시) ---
build_tool() { # 이름 소스 프레임워크...
    _name="$1"; _src="$2"; shift 2
    if [ ! -x "$BIN/$_name" ] || [ "$_src" -nt "$BIN/$_name" ]; then
        _fw=""
        for f in "$@"; do _fw="$_fw -framework $f"; done
        # shellcheck disable=SC2086
        clang -fobjc-arc $_fw -o "$BIN/$_name" "$_src" || { echo "$_name 빌드 실패" >&2; exit 1; }
    fi
}
build_tool mac-input "$REPO/tool/input_macos.m" Cocoa Carbon ApplicationServices
build_tool color-capture "$REPO/tool/color-capture_macos.m" Cocoa ScreenCaptureKit ImageIO UniformTypeIdentifiers
[ "$CMD" = latency ] && build_tool key-to-screen "$REPO/tool/key-to-screen_macos.m" Cocoa ScreenCaptureKit CoreMedia CoreVideo

# --- 판 해석 ---
NAMES=(); EXES=(); ENVS=()
ALL_KEYS=""
for spec in "$@"; do
    name="${spec%%=*}"; rest="${spec#*=}"
    path="${rest%%@*}"; envs=""
    [ "$rest" != "$path" ] && envs="${rest#*@}"
    case "$path" in *.app|*.app/) path="${path%/}/Contents/MacOS/tildaz" ;; esac
    [ -x "$path" ] || { echo "$name: 실행 파일이 없어요 — $path" >&2; exit 2; }
    NAMES+=("$name"); EXES+=("$path"); ENVS+=("${envs//@/ }")
    for kv in ${envs//@/ }; do ALL_KEYS="$ALL_KEYS ${kv%%=*}"; done
done

# --- 가드 ---
if pgrep -x tildaz >/dev/null; then
    echo "TildaZ 가 이미 떠 있어요 — 다른 세션의 측정일 수 있어요. 내리거나 그쪽에 물어본 뒤 다시 돌려요." >&2
    pgrep -lx tildaz >&2
    exit 1
fi
"$BIN/mac-input" check >/dev/null || { echo "손쉬운 사용 권한이 없어요 (합성 입력이 조용히 무시돼요)" >&2; exit 1; }
pmset -g batt | head -1 | grep -q "AC Power" || echo "⚠ AC 전원이 아니에요 — 배터리에서는 스로틀링이 걸려요" >&2

FRONT_APP=$(lsappinfo info -only bundlepath "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*bundle path="\(.*\)".*/\1/p')
IME0=$("$BIN/mac-input" ime-get 2>/dev/null)
APP=""
cleanup() {
    [ -n "$APP" ] && kill "$APP" 2>/dev/null
    [ -n "$IME0" ] && "$BIN/mac-input" ime-set "$IME0" >/dev/null 2>&1
    [ -n "$FRONT_APP" ] && open "$FRONT_APP" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM
[ "$CMD" = tearing ] || "$BIN/mac-input" ime-ascii >/dev/null || { echo "입력기를 영문으로 못 바꿨어요" >&2; exit 1; }

LOG_DEV="$HOME/Library/Logs/tildaz-dev/tildaz_stress.log"
LOG_REL="$HOME/Library/Logs/tildaz/tildaz_stress.log"
log_size() { [ -f "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }

# --- 화면 스크립트 (-e 는 인자를 못 받아서 파일로 둔다) ---
LOCK="$OUT/flood-lock"
cat > "$OUT/cat.sh" <<'EOF'
#!/bin/sh
exec cat
EOF
cat > "$OUT/flood.sh" <<'EOF'
#!/bin/sh
exec yes 'flood 0123456789'
EOF
# 첫 pane 은 쏟고 그 뒤 pane (분할로 다시 실행된 것) 은 키만 받는다.
cat > "$OUT/flood-or-cat.sh" <<EOF
#!/bin/sh
if mkdir "$LOCK" 2>/dev/null; then exec yes 'flood 0123456789'; fi
exec cat
EOF
cat > "$OUT/bar.py" <<'EOF'
# 굵은 세로 막대가 화면을 가로로 빠르게 지나간다. 찢기면 막대가 가로로 끊겨 옆으로 밀린 조각이 보인다.
import os, sys, time
cols, rows = os.get_terminal_size()
W = 4
sys.stdout.write("\x1b[?25l\x1b[2J")
x = 0
while True:
    row = " " * x + "\x1b[7m" + " " * W + "\x1b[0m" + " " * max(0, cols - x - W)
    sys.stdout.write("\x1b[H" + "\r\n".join(row for _ in range(rows - 1)))
    sys.stdout.flush()
    x = (x + 3) % (cols - W)
    time.sleep(1 / 240)
EOF
printf '#!/bin/sh\nexec /usr/bin/python3 "%s"\n' "$OUT/bar.py" > "$OUT/bar.sh"
chmod +x "$OUT"/*.sh

# --- 판 하나를 띄운다: launch 인덱스 화면스크립트 [추가 환경] ---
WID=""
launch() {
    _i="$1"; _screen="$2"; _extra="${3:-}"
    _unset=""
    for k in $ALL_KEYS; do _unset="$_unset -u $k"; done
    _before=" $("$BIN/color-capture" --list 2>/dev/null | awk '$2 ~ /tildaz/ {print $1}' | tr '\n' ' ')"
    # shellcheck disable=SC2086
    env $_unset ${ENVS[$_i]} $_extra "${EXES[$_i]}" -e "$_screen" -size 120x40 >/dev/null 2>&1 &
    APP=$!
    sleep 4
    kill -0 "$APP" 2>/dev/null || { echo "${NAMES[$_i]}: 앱이 바로 끝났어요" >&2; APP=""; return 1; }
    WID=$("$BIN/color-capture" --list 2>/dev/null | awk -v b="$_before " '$2 ~ /tildaz/ && index(b, " " $1 " ") == 0 {
        for (i = 3; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+$/) { split($i, a, "x"); if (a[1] * a[2] > m) { m = a[1] * a[2]; id = $1 }; break }
    } END { print id }')
    [ -n "$WID" ] || { echo "${NAMES[$_i]}: 새 창을 못 찾았어요" >&2; return 1; }
}
close_app() {
    [ -n "$APP" ] || return 0
    kill "$APP" 2>/dev/null; wait "$APP" 2>/dev/null; APP=""
    sleep 2
}
check_log() { # 회차 로그 파일 → 오염이면 표시
    _n=$(grep -c "initial tab created" "$1" 2>/dev/null)
    [ "${_n:-0}" -le 1 ] || echo "  ⚠ 이 회차에 TildaZ 시작이 $_n 번 — 다른 TildaZ 와 겹쳤어요 (오염)"
}
slice_logs() { # 시작크기dev 시작크기rel 출력
    { tail -c +$(( $1 + 1 )) "$LOG_DEV" 2>/dev/null; tail -c +$(( $2 + 1 )) "$LOG_REL" 2>/dev/null; } > "$3"
}

case "$CMD" in
latency)
    echo "=== 키 → 화면 지연 · $([ $FLOOD = 1 ] && echo 폭포 || echo 유휴) · ${#NAMES[@]} 판 × $ROUNDS 회 × 키 $PRESSES ==="
    echo "결과 폴더: $OUT"
    for r in $(seq 1 "$ROUNDS"); do
        for i in "${!NAMES[@]}"; do
            n="${NAMES[$i]}"; echo "##### $r · $n"
            pgrep -x tildaz >/dev/null && { echo "다른 TildaZ 가 떠 있어요 — 멈춰요" >&2; exit 1; }
            sd=$(log_size "$LOG_DEV"); sr=$(log_size "$LOG_REL")
            if [ $FLOOD = 1 ]; then rm -rf "$LOCK"; screen="$OUT/flood-or-cat.sh"; else screen="$OUT/cat.sh"; fi
            launch "$i" "$screen" || { close_app; continue; }
            "$BIN/mac-input" focus "$APP" >/dev/null || { echo "포커스 실패" >&2; close_app; continue; }
            xr=""
            if [ $FLOOD = 1 ]; then
                "$BIN/mac-input" send alt+cmd+right >/dev/null; sleep 2
                xr="--x0 0.55 --x1 1.0"
            fi
            # shellcheck disable=SC2086
            "$BIN/key-to-screen" --window "$WID" --presses "$PRESSES" --gap-ms "$GAP_MS" $xr > "$OUT/k2s-$r-$n.txt" 2>&1
            tail -1 "$OUT/k2s-$r-$n.txt"
            close_app
            slice_logs "$sd" "$sr" "$OUT/log-$r-$n.txt"
            check_log "$OUT/log-$r-$n.txt"
        done
    done
    /usr/bin/python3 - "$OUT" "$ROUNDS" "${NAMES[@]}" <<'EOF'
import os, re, sys, statistics as st
out, rounds, names = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
print("\n판            키   median    mean     min     p90     max   회차별 median")
for n in names:
    pool, per = [], []
    for r in range(1, rounds + 1):
        f = f"{out}/k2s-{r}-{n}.txt"
        if not os.path.exists(f):
            continue
        xs = [float(m[2]) for m in (re.match(r"press +(\d+) +([\d.]+) ms", l) for l in open(f)) if m and int(m[1]) > 1]
        if xs:
            pool += xs; per.append(st.median(xs))
    if not pool:
        print(f"{n:12s}  표본 없음"); continue
    s = sorted(pool)
    print(f"{n:12s} {len(s):4d} {st.median(s):8.2f} {st.mean(s):7.2f} {s[0]:7.2f} {s[int(len(s) * .9)]:7.2f} {s[-1]:7.2f}   "
          + " · ".join(f"{m:.2f}" for m in per))
print("\n단위 ms. 회차마다 첫 키는 뺐다. 절대값은 ScreenCaptureKit 지연이 섞이니 같은 실행의 판끼리 견준다.")
EOF
    ;;
mode)
    echo "=== 표시 방식 (Metal HUD) · 전체화면 전환 ${TOGGLES} 번 · ${#NAMES[@]} 판 ==="
    echo "결과 폴더: $OUT"
    command -v ffmpeg >/dev/null || echo "⚠ ffmpeg 이 없어요 — 영상은 남기지만 전환 프레임은 못 뽑아요" >&2
    for i in "${!NAMES[@]}"; do
        n="${NAMES[$i]}"; echo "##### $n"
        pgrep -x tildaz >/dev/null && { echo "다른 TildaZ 가 떠 있어요 — 멈춰요" >&2; exit 1; }
        sd=$(log_size "$LOG_DEV"); sr=$(log_size "$LOG_REL")
        launch "$i" "$OUT/flood.sh" MTL_HUD_ENABLED=1 || { close_app; continue; }
        "$BIN/mac-input" focus "$APP" >/dev/null || { echo "포커스 실패" >&2; close_app; continue; }
        "$BIN/color-capture" --window "$WID" "$OUT/$n-windowed.png" >/dev/null 2>&1
        rec_s=$(( TOGGLES * 3 + 3 ))
        screencapture -x -v -V "$rec_s" "$OUT/$n.mov" >/dev/null 2>&1 &
        REC=$!; sleep 1.5
        for k in $(seq 1 "$TOGGLES"); do
            "$BIN/mac-input" send cmd+return >/dev/null; sleep 1.5
            [ "$k" = 1 ] && "$BIN/color-capture" --window "$WID" "$OUT/$n-fullscreen.png" >/dev/null 2>&1
            "$BIN/mac-input" send cmd+return >/dev/null; sleep 1.5
        done
        wait "$REC"
        close_app
        slice_logs "$sd" "$sr" "$OUT/log-$n.txt"
        check_log "$OUT/log-$n.txt"
        # HUD 는 창 오른쪽 위에 그려진다.
        for m in windowed fullscreen; do
            [ -f "$OUT/$n-$m.png" ] && magick "$OUT/$n-$m.png" -gravity NorthEast -crop 720x340+0+0 +repage "$OUT/$n-$m-hud.png" 2>/dev/null
        done
        command -v ffmpeg >/dev/null || continue
        # 전환 찾기: 작은 회색 프레임끼리의 평균 차이가 튀는 곳. 쏟는 줄이 모두 같아서 스크롤만으로는 거의 안 바뀐다.
        ffmpeg -v error -i "$OUT/$n.mov" -fps_mode passthrough -vf scale=96:62,format=gray -f rawvideo - > "$OUT/$n.gray" 2>/dev/null
        trans=$(/usr/bin/python3 - "$OUT/$n.gray" <<'EOF'
import sys
d = open(sys.argv[1], "rb").read(); F = 96 * 62
fr = [d[i:i + F] for i in range(0, len(d) - F + 1, F)]
diff = [0] + [sum(abs(a - b) for a, b in zip(fr[i], fr[i - 1])) / F for i in range(1, len(fr))]
hits, last = [], -99
for i, v in enumerate(diff):
    if v > 8 and i - last > 10:
        hits.append(i); last = i
print(" ".join(map(str, hits)))
EOF
)
        rm -f "$OUT/$n.gray"
        echo "  전환 프레임: ${trans:-없음}"
        mkdir -p "$OUT/frames"
        ffmpeg -v error -i "$OUT/$n.mov" -fps_mode passthrough -vf scale=756:-1 "$OUT/frames/$n-%04d.png" 2>/dev/null
        rows=""
        for t in $trans; do
            files=""
            for d in -2 -1 0 1 2 3; do
                f=$(printf '%s/frames/%s-%04d.png' "$OUT" "$n" $(( t + d + 1 )))
                [ -f "$f" ] && files="$files $f"
            done
            [ -n "$files" ] || continue
            # shellcheck disable=SC2086
            magick $files +append "$OUT/frames/row-$n-$t.png" && rows="$rows $OUT/frames/row-$n-$t.png"
        done
        # shellcheck disable=SC2086
        [ -n "$rows" ] && magick $rows -append "$OUT/$n-transitions.png"
        rm -f "$OUT"/frames/"$n"-*.png
    done
    echo
    echo "HUD: <판>-windowed-hud.png · <판>-fullscreen-hud.png 의 둘째 줄 (Direct / Composited). IOSurface 판은 HUD 가 없다."
    echo "전환: <판>-transitions.png — 줄마다 전환 하나, 앞 2 · 뒤 3 프레임. 셋째 칸이 전환 프레임이다."
    ;;
tearing)
    echo "=== 찢김 눈 시험 · 판마다 ${SECONDS_EACH} 초 · 판 사이 2 초 ==="
    echo "굵은 세로 막대가 가로로 끊겨 옆으로 밀린 조각이 보이면 찢김이에요. 휴대폰 슬로 모션으로 찍으면 더 확실해요."
    for i in "${!NAMES[@]}"; do
        pgrep -x tildaz >/dev/null && { echo "다른 TildaZ 가 떠 있어요 — 멈춰요" >&2; exit 1; }
        echo "$(date +%T)  $(( i + 1 ))/${#NAMES[@]}  ${NAMES[$i]}"
        launch "$i" "$OUT/bar.sh" || { close_app; continue; }
        sleep "$SECONDS_EACH"   # launch 가 창이 뜰 때까지 4 초를 이미 기다렸다
        close_app
    done
    echo "$(date +%T)  끝"
    ;;
esac
