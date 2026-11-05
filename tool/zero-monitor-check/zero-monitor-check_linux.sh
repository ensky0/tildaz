#!/usr/bin/env bash
# #859 — GNOME 확장이 모니터가 바뀔 때 TildaZ 창을 어디에 놓는지, 모니터가 0 개일 때 셸이 사는지 잰다.
# 사람 손 · 하드웨어 없이 nested `gnome-shell --headless` 에 가상 모니터 · 포인터 · 키를 넣는다.
#
#   tool/zero-monitor-check/zero-monitor-check_linux.sh                         # zig-out 의 dev 빌드
#   tool/zero-monitor-check/zero-monitor-check_linux.sh --bin /path/to/tildaz   # 다른 판 (고치기 전 판 대조)
#   … --keep                                                                    # 작업 폴더를 남긴다
#   … --close-first                                                             # A 다음 바로 E (고치기 전 판은 C 에서 죽어 E 에 못 닿는다)
#
# 회차 (판정은 셸 로그의 `[tildaz-dev] placed 9 on monitor N: x,y WxH` 와 셸 프로세스):
#   A  처음 뜰 때 마우스 모니터에 놓는다 (포인터를 주 모니터가 *아닌* 쪽에 둔다)
#   B  단축키로 숨기고 포인터를 다른 모니터로 옮겨 보이면 그 모니터로 온다
#   C  모니터를 모두 없애도 셸이 산다 (#856 — 고치기 전 판은 여기서 SIGSEGV)
#   D  크기가 다른 모니터로 돌아오면 그 모니터에 맞춰 다시 놓는다
#   E  TildaZ 를 닫은 뒤 모니터 구성이 바뀌어도 셸이 산다 (닫힌 창이 관리 목록에 남으면 확장이 그 창을
#      다시 배치한다 — Cinnamon 은 고치기 전 판이 여기서 muffin 단언으로 멈췄다)
#
# 격리: 셸 · 앱 모두 임시 `XDG_CONFIG_HOME` · `XDG_DATA_HOME` · `XDG_STATE_HOME` 와 자기 세션 버스
# (`dbus-run-session`) 를 쓴다. dconf 도 그 임시 폴더라 사용자 설정을 읽지도 쓰지도 않는다.
# `XDG_RUNTIME_DIR` 만 실제 것이다 — nested mutter 가 실제 pipewire 를 쓰고 (AGENTS.md: mutter devkit 은
# runtime dir 을 격리하면 죽는다), 확장과 앱이 `tildaz-dev/run/instance9.hotkey` 를 같은 곳에서 주고받는다.
# 그래서 dev instance 9 가 떠 있으면 시작하지 않고, 끝나면 `instance9.*` 를 지운다.
# 화면에는 아무것도 안 뜨지만 실기 측정이다 — 시작 전에 알린다 (AGENTS.md `# 실행 환경`).
#
# 필요한 것: gnome-shell (51 에서 확인) · gst-launch-1.0 + pipewiresrc · pw-link · python3 gi.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

if [ "${1:-}" = "--inner" ]; then
  # ── dbus-run-session 안 ────────────────────────────────────────────────────────────
  W=$2 BIN=$3 CLOSE_FIRST=$4
  SHELL_LOG=$W/shell.log
  F1=0xffbe                         # config_9 의 기본 hotkey (dev 판 index 9 = F1)
  vm() {                            # vm <명령…> → ack 의 결과
    # 번호는 호출마다 새로 만든다 — `$(vm …)` 는 하위 셸이라 카운터를 늘려도 남지 않아, 앞 명령의
    # 응답을 읽었다 (같은 회차에서 겪었다).
    local SEQ; SEQ=$(date +%s%N)
    echo "$SEQ $*" > "$W/ctl/cmd.tmp" && mv "$W/ctl/cmd.tmp" "$W/ctl/cmd"
    local i
    for i in $(seq 300); do
      if [ -f "$W/ctl/ack" ] && [ "$(cut -d' ' -f1 "$W/ctl/ack")" = "$SEQ" ]; then
        cut -d' ' -f2- "$W/ctl/ack"; return 0
      fi
      sleep 0.1
    done
    echo "vmon-timeout"
  }
  alive() { kill -0 "$SHELL_PID" 2>/dev/null; }
  placed_count() { grep -c "placed 9 on monitor" "$SHELL_LOG"; }
  wait_placed() {                   # wait_placed <이전 개수> → 새 placed 줄 (없으면 빈 줄)
    local i
    for i in $(seq 50); do
      [ "$(placed_count)" -gt "$1" ] && { grep "placed 9 on monitor" "$SHELL_LOG" | tail -1; return; }
      alive || return
      sleep 0.1
    done
  }
  # placed 줄의 x,y 가 그 모니터 (JSON 의 connector) 안인가
  inside() {                        # inside <placed 줄> <monitors JSON> <connector>
    python3 - "$1" "$2" "$3" <<'PY'
import json, re, sys
m = re.search(r"placed 9 on monitor (\d+): (-?\d+),(-?\d+) (\d+)x(\d+)", sys.argv[1])
mons = json.loads(sys.argv[2]); want = sys.argv[3]
if not m: print("no-placement"); sys.exit(1)
x, y = int(m[2]), int(m[3])
hit = [d["connector"] for d in mons if d["x"] <= x < d["x"] + d["w"] and d["y"] <= y < d["y"] + d["h"]]
print(f"at {x},{y} on {hit[0] if hit else '?'} (want {want})"); sys.exit(0 if hit == [want] else 1)
PY
  }
  conn_of() {                       # conn_of <monitors JSON> <w> <h> → 그 크기의 connector
    python3 -c 'import json,sys; print([d["connector"] for d in json.loads(sys.argv[1]) if (d["w"],d["h"])==(int(sys.argv[2]),int(sys.argv[3]))][0])' "$@"
  }
  primary_of() { python3 -c 'import json,sys; print([d["connector"] for d in json.loads(sys.argv[1]) if d["primary"]][0])' "$1"; }
  RESULT=0
  e_case() {
    kill -TERM "$APP" 2>/dev/null
    local i; for i in $(seq 50); do kill -0 "$APP" 2>/dev/null || break; sleep 0.1; done
    sleep 1
    echo "add: $(vm start 1024x768)"; sleep 2
    alive; verdict "E shell survives a monitor change after TildaZ closed" $?
  }
  finish() {
    vm quit >/dev/null
    kill -TERM "$APP" 2>/dev/null; sleep 1; kill -KILL "$APP" 2>/dev/null
    kill -TERM "$SHELL_PID" 2>/dev/null; sleep 2; kill -KILL "$SHELL_PID" 2>/dev/null
    kill "$VPID" 2>/dev/null
    wait 2>/dev/null
    echo "RESULT=$RESULT"
    exit $RESULT
  }
  verdict() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; RESULT=1; fi; }

  gsettings set org.gnome.shell enabled-extensions "['tildaz-dev@tildaz.dev']"
  gsettings set org.gnome.shell disable-user-extensions false
  gnome-shell --headless --wayland --no-x11 --wayland-display=wayland-zmon > "$SHELL_LOG" 2>&1 &
  SHELL_PID=$!
  for _ in $(seq 60); do [ -S "$XDG_RUNTIME_DIR/wayland-zmon" ] && break; sleep 0.25; done
  python3 "$HERE/vmon_linux.py" "$W/ctl" > "$W/vmon.log" 2>&1 &
  VPID=$!
  sleep 2

  # 1600x900 이 먼저 생기지만 주 모니터가 어느 쪽인지는 mutter 가 정한다 — 이름과 크기로 가른다.
  M=$(vm start 1600x900 1280x720); echo "monitors: $M"
  M=${M#ok }
  A_CONN=$(conn_of "$M" 1600 900) B_CONN=$(conn_of "$M" 1280 720) P_CONN=$(primary_of "$M")
  # 포인터를 주 모니터가 아닌 쪽에 둔다 — 그래야 "주 모니터에 놓는다" 와 "마우스 모니터" 가 갈린다.
  if [ "$P_CONN" = "$A_CONN" ]; then FAR=1 FAR_CONN=$B_CONN NEAR=0 NEAR_CONN=$A_CONN; else FAR=0 FAR_CONN=$A_CONN NEAR=1 NEAR_CONN=$B_CONN; fi
  vm pointer $FAR 100 100 >/dev/null

  # A — 처음 뜰 때
  n=$(placed_count)
  WAYLAND_DISPLAY=$XDG_RUNTIME_DIR/wayland-zmon TILDAZ_VERBOSE=1 "$BIN" --instance 9 > "$W/app.out" 2>&1 &
  APP=$!
  line=$(wait_placed "$n"); sleep 1
  r=$(inside "$line" "$M" "$FAR_CONN"); verdict "A first show on the pointer's monitor — $r" $?
  [ "$CLOSE_FIRST" = 1 ] && { e_case; finish; }

  # B — 숨기고 다른 모니터에서 보이기
  vm key $F1 >/dev/null; sleep 1
  vm pointer $NEAR 100 100 >/dev/null; sleep 0.3
  n=$(placed_count); vm key $F1 >/dev/null
  line=$(wait_placed "$n"); sleep 1
  r=$(inside "$line" "$M" "$NEAR_CONN"); verdict "B hotkey show follows the pointer — $r" $?

  # C — 모니터 0 개
  echo "stop: $(vm stop)"; sleep 2
  alive; verdict "C shell survives zero monitors" $?
  grep -q "no monitor — placement skipped" "$SHELL_LOG"; verdict "C extension skipped placement" $?

  # D — 크기가 다른 모니터로 돌아오기
  if alive; then
    n=$(placed_count)
    echo "start: $(vm start 1280x720)"
    line=$(wait_placed "$n"); sleep 1
    # 돌아온 직후에는 목록이 잠깐 비어 보인다 (같은 회차 실측) — 배치가 끝난 뒤 다시 묻는다.
    M=$(vm monitors); echo "monitors: $M"
    r=$(inside "$line" "$M" "$(conn_of "$M" 1280 720)"); verdict "D re-placed on the returning monitor — $r" $?
    alive; verdict "D shell still alive" $?
  else
    verdict "D skipped (shell is gone)" 1
  fi
  if alive; then e_case; else verdict "E skipped (shell is gone)" 1; fi
  finish
fi

# ── 바깥 — 준비 · 정리 ─────────────────────────────────────────────────────────────
BIN=$ROOT/zig-out/install-dev/bin/tildaz
[ -x "$BIN" ] || BIN=$ROOT/zig-out/bin/tildaz
KEEP=0 CLOSE_FIRST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bin) BIN=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --close-first) CLOSE_FIRST=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
die() { echo "$*" >&2; exit 1; }
[ -x "$BIN" ] || die "빌드가 없다: $BIN"
for t in gnome-shell gst-launch-1.0 pw-link gsettings dbus-run-session; do command -v $t >/dev/null || die "없다: $t"; done
gst-inspect-1.0 pipewiresrc >/dev/null 2>&1 || die "gst pipewiresrc 가 없다"
RUN=${XDG_RUNTIME_DIR:?}/tildaz-dev/run
[ -e "$RUN/instance9.lock" ] && die "dev instance 9 가 떠 있다 ($RUN/instance9.lock) — 내리고 다시"

W=$(mktemp -d "${TMPDIR:-/tmp}/tz-zmon.XXXXXX")
mkdir -p "$W/config" "$W/data/gnome-shell/extensions/tildaz-dev@tildaz.dev" "$W/state" "$W/ctl" "$W/home" "$W/run"
chmod 700 "$W/run"
cleanup() {
  rm -f "$RUN"/instance9.*
  # nested 셸이 실제 runtime 폴더에 만든 소켓. 셸은 이미 내렸지만, 듣는 프로세스가 있으면 남긴다.
  ss -xlp 2>/dev/null | grep -q "wayland-zmon " || rm -f "$XDG_RUNTIME_DIR/wayland-zmon" "$XDG_RUNTIME_DIR/wayland-zmon.lock"
  if [ $KEEP = 1 ]; then echo "작업 폴더: $W"; else rm -rf "$W"; fi
}
trap cleanup EXIT

# 앱을 화면 없이 한 번 띄워 그 판의 확장 파일 (+ 컴파일한 스키마) 과 완전한 config_9 를 만든다.
# 확장 폴더를 미리 만들어 두면 "처음 설치" 가 아니라서 활성 목록을 건드리지 않는다. 세션 버스가 없어
# dconf 에 쓸 수도 없다. 셸은 시작할 때만 확장을 읽으므로 셸보다 먼저 해야 한다.
env -i PATH="$PATH" HOME="$W/home" XDG_CONFIG_HOME="$W/config" XDG_DATA_HOME="$W/data" \
  XDG_STATE_HOME="$W/state" XDG_RUNTIME_DIR="$W/run" XDG_CURRENT_DESKTOP=GNOME \
  timeout 10 "$BIN" --instance 9 >/dev/null 2>&1
[ -s "$W/data/gnome-shell/extensions/tildaz-dev@tildaz.dev/extension.js" ] || die "확장 파일을 못 만들었다"
[ -s "$W/config/tildaz-dev/config_9.toml" ] || die "config_9.toml 을 못 만들었다"
rm -f "$W/state/tildaz-dev/tildaz_9.log"
echo "빌드: $BIN ($("$BIN" --version 2>/dev/null | head -1))"

env -u WAYLAND_DISPLAY -u DISPLAY -u SWAYSOCK -u HYPRLAND_INSTANCE_SIGNATURE -u DBUS_SESSION_BUS_ADDRESS \
  HOME="$W/home" XDG_CONFIG_HOME="$W/config" XDG_DATA_HOME="$W/data" XDG_STATE_HOME="$W/state" \
  XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_DESKTOP=gnome GSETTINGS_BACKEND=dconf \
  timeout 120 dbus-run-session -- bash "$0" --inner "$W" "$BIN" "$CLOSE_FIRST" 2> "$W/session.err"
rc=$?
grep -E "placed 9|no monitor|SIGSEGV|crashed|which_monitor" "$W/shell.log" | sed 's/^/  shell: /'
exit $rc
