#!/bin/bash
# 여러 tildaz 판을 **같은 화면**으로 띄워 KDE 에서 캡처하고 최종 그림을 픽셀 수로 견준다 (Linux · KDE Plasma).
# macOS 의 `dist/macos/render-ab-shot.sh` 에 대응한다 — #586 Linux atlas `grow` 실기에서 만들었다.
#
# ```sh
# dist/linux/render-ab-shot.sh <화면.sh> <격자> <대기초> <태그> <바이너리A> <바이너리B> [<바이너리C> …]
# dist/linux/render-ab-shot.sh /tmp/stack2.sh 150x40 8 stack2 /tmp/tildaz-4096 zig-out/bin/tildaz /tmp/tildaz-512
# ```
#
# - 판마다 `--instance 9 -e <화면> -size <격자>` 로 띄우고 `<대기초>` 뒤 `spectacle -b -n -f` 로 **전체 화면**을 찍는다
#   (KWin 은 wlr-screencopy 가 없어 `grim` 이 안 된다). 사용자의 다른 창이 함께 담기므로 **창 영역만** 견주고,
#   이슈에 올릴 때도 창 영역만 crop 한다 (`crop_1.png`). `-size` 창은 화면 **오른쪽 위**에 붙는다 (dock top · 오른쪽 정렬).
# - 창 영역은 **로그로 계산한다** — `TILDAZ_VERBOSE=1` 로 띄워 `layer-surface configure logical_w=… logical_h=… scale=N/120`
#   의 마지막 줄과 `screen=WxH` 를 읽어 `W = round(logical_w × N/120)` · `H = round(logical_h × N/120)` · `X = screen_w − W`.
#   (픽셀 스캔으로 검정 배경 경계를 찾는 방식은 글자 줄 · 스크롤바 트랙에 걸려 틀렸다.) 다르게 뜬 창은 `BOX=WxH+X+Y` 로 준다.
# - 픽셀 수는 `-compose difference` + `-threshold 0` 로 센다 (`compare -metric AE` 는 소수 · 지수 표기를 낸다).
#   ⚠️ **crop 은 이미지마다 괄호로 감싼다** — `A -crop G B -crop G` 는 두 번째 `-crop` 이 A 에도 다시 걸려 크기가 다른
#   두 이미지를 견주게 되고, 그러면 **모든 쌍이 정확히 같은 수로 다른** 가짜 차이가 난다 (2026-09-03 실기에서 걸렸다 —
#   같은 프로세스의 두 캡처까지 34 % 가 다르게 보였다). offset 이 crop 결과 밖이면 경고만 내고 무시돼 우연히 맞는다.
# - 로그는 `-e` 라 `$XDG_STATE_HOME/tildaz/tildaz_stress.log` 다. 판마다 지우고 새로 받아 `log_<i>.txt` 로 남긴다 —
#   픽셀 대조에는 `atlas grew` · `atlas full` 회수도 같이 본다.
# - 인스턴스 9 만 내린다 — `pkill -f` 는 자기 셸을 죽인다 (AGENTS.md). 그리고 **`pgrep -x tildaz` 도 안 된다** — 판 바이너리를
#   `tildaz-4096` 처럼 이름 붙이면 comm 이 달라 하나도 안 잡힌다 (2026-09-03 실기에서 창 17 개가 남았다). `/proc/<pid>/cmdline` 의
#   실행 파일 basename 이 `tildaz*` 이고 `--instance 9` 인 것을 고른다.
# - 실기라서 시작 전에 창이 몇 번 뜨는지 알리고, `systemd-inhibit --what=idle:sleep --mode=block` 으로 잠금을 막는다.
set -u
TARGET="${1:?화면.sh}"; SIZE="${2:?격자 (예 88x33)}"; WAIT="${3:?대기초}"; TAG="${4:?태그}"; shift 4
[ $# -ge 2 ] || { echo "바이너리를 둘 이상 주세요"; exit 1; }
OUT="${TMPDIR:-/tmp}/tildaz-ab-shot/$TAG"; mkdir -p "$OUT"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/tildaz/tildaz_stress.log"
kill_tz() {   # 실행 파일이 tildaz* 이고 --instance 9 인 것만 — 판 바이너리는 tildaz-4096 처럼 이름이 달라 `pgrep -x tildaz` 로는 못 잡는다
  for p in $(pgrep -u "$(id -u)"); do
    local cl; cl=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
    case "$(basename "${cl%% *}")" in tildaz*) ;; *) continue ;; esac
    case "$cl" in *"--instance 9"*) kill "$p" 2>/dev/null ;; esac
  done
}
winbox_from_log() {   # 마지막 layer-surface configure + screen → WxH+X+0
  python3 - "$1" <<'PY'
import re, sys
txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
cfg = re.findall(r"layer-surface configure .*?logical_w=(\d+) logical_h=(\d+) scale=(\d+)/(\d+)", txt)
scr = re.findall(r"screen=(\d+)x(\d+)", txt)
if not cfg or not scr:
    sys.exit("로그에 configure/screen 줄이 없다 — TILDAZ_VERBOSE=1 인지, BOX= 로 직접 주세요")
lw, lh, n, d = map(int, cfg[-1]); sw, sh = map(int, scr[-1])
W = round(lw * n / d); H = round(lh * n / d)
print(f"{W}x{H}+{sw - W}+0")
PY
}
pxdiff() {   # 괄호 crop — 위 주석의 함정
  local n tot
  n=$(magick \( "$1" -crop "$3" +repage \) \( "$2" -crop "$3" +repage \) -compose difference -composite -colorspace Gray -threshold 0 -format '%[fx:mean*w*h]' info:)
  tot=$(magick "$1" -crop "$3" +repage -format '%[fx:w*h]' info:)
  python3 -c "print(f'{int(round(float(\"$n\")))} / {int(float(\"$tot\"))} px')"
}
echo "md5:"; for b in "$@"; do printf '  %s  %s\n' "$(md5sum "$b" | cut -c1-32)" "$b"; done
i=0
for bin in "$@"; do
  i=$((i+1)); [ -x "$bin" ] || { echo "바이너리 없음: $bin"; exit 1; }
  kill_tz; sleep 0.5; rm -f "$LOG"
  TILDAZ_VERBOSE=1 "$bin" --instance 9 -e "$TARGET" -size "$SIZE" >"$OUT/stdout_$i.txt" 2>&1 &
  pid=$!; sleep "$WAIT"
  if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; echo "판 $i 가 먼저 끝남 exit=$? — stdout:"; cat "$OUT/stdout_$i.txt"; fi
  rm -f "$OUT/full_$i.png"; spectacle -b -n -f -o "$OUT/full_$i.png" >/dev/null 2>&1
  for _ in $(seq 1 30); do [ -s "$OUT/full_$i.png" ] && break; sleep 0.2; done
  sleep 0.5; cp "$LOG" "$OUT/log_$i.txt" 2>/dev/null || echo "(로그 없음)" > "$OUT/log_$i.txt"
  kill_tz; sleep 0.5
  echo "판 $i: $(basename "$bin") · grew=$(grep -c 'atlas grew' "$OUT/log_$i.txt") full=$(grep -c 'atlas full' "$OUT/log_$i.txt") · $(grep -o 'render_path=[a-z-]*' "$OUT/log_$i.txt" | head -1)"
done
BOX="${BOX:-$(winbox_from_log "$OUT/log_1.txt")}" || exit 1
echo "창 영역: $BOX  (다르게 떴으면 BOX=WxH+X+Y 로 다시)"
for ((j=2; j<=i; j++)); do echo "판 1 vs 판 $j [$BOX]: $(pxdiff "$OUT/full_1.png" "$OUT/full_$j.png" "$BOX")"; done
magick "$OUT/full_1.png" -crop "$BOX" +repage "$OUT/crop_1.png"
echo "캡처 · 로그: $OUT  (이슈에는 crop_1.png 처럼 창 영역만 올린다)"
