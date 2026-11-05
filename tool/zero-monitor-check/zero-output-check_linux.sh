#!/usr/bin/env bash
# #859 — **실제 세션**에서 모니터가 모두 사라졌다 돌아올 때 TildaZ 와 셸이 사는지 잰다.
# nested 로 못 만드는 경우 (KDE · COSMIC · Hyprland · sway 의 layer-shell 경로, 실제 GNOME · Cinnamon) 용이다.
# nested GNOME 은 `zero-monitor-check_linux.sh` 가 사람 손 없이 잰다.
#
#   tool/zero-monitor-check/zero-output-check_linux.sh --manual 90
#       90 초 안에 사람이 모니터 케이블을 뽑았다가 다시 꽂는다 (KVM 전환과 같은 일)
#   tool/zero-monitor-check/zero-output-check_linux.sh --off-cmd '<모든 출력 끄기>' --on-cmd '<다시 켜기>' [--off-seconds 8]
#       데스크톱 명령으로 끈다. 끄는 동안 화면이 안 보인다 — 도구가 죽어도 `--guard` 초 (기본 40) 뒤에
#       on-cmd 를 다시 부르는 안전장치가 따로 돈다
#   … --bin <tildaz>      판 (기본: zig-out 의 dev 빌드)
#
# 띄우는 창:
#   - KDE · COSMIC · Hyprland · sway: `-e` 측정 창 (instance 9). config 를 만들지 않고 전역 hotkey 도 등록하지 않는다.
#     layer-surface 가 닫힐 때의 처리 (`zwlr_layer_surface_v1.closed`) 는 평소 창과 같은 코드다.
#   - GNOME · Cinnamon: 확장이 잡는 평소 worker 여야 해서 `--instance 9` worker 를 띄운다. 실제 dev config 폴더에
#     `config_9.toml` (hotkey `shift+f11` · auto_start 꺼짐) 을 잠깐 두고 끝나면 지운다. 확장은 **이 브랜치의 dev
#     확장**이어야 한다 — `bash dist/linux/install.sh` 뒤 다시 로그인해야 셸이 새 확장을 읽는다.
#
# 판정 (앱 로그 `tildaz_stress.log` / `tildaz_9.log` 와 프로세스):
#   - 출력이 사라졌다 (`bound wl_output removed`) 돌아왔다 (`wl_output bound after hotplug`) — 회차가 성립했는가
#   - 앱이 살아 있다 · 종료 확인 경로 (`drainQuitRequest`) 를 밟지 않았다 (출력이 없어 닫힌 표면을
#     "사용자가 닫았다" 로 읽지 않았다). `pending_quit_request` set 줄은 closed 마다 *항상* 찍히고
#     batch 끝 검사가 topology 변화와 겹치면 recreate 로 바꿔요 — 그 문자열은 표식이 못 된다
#     (2026-11-05 KDE 실기에서 정상 recreate 가 FAIL 로 나온 것을 고침)
#   - GNOME · Cinnamon: 셸 PID 가 그대로다 (셸이 죽으면 세션이 내려가 로그아웃된다 — 고치기 전 판의 #856)
# 실기 측정이다 — 시작 전에 알리고 동의를 받는다 (AGENTS.md `# 실행 환경`).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BIN=$ROOT/zig-out/install-dev/bin/tildaz
[ -x "$BIN" ] || BIN=$ROOT/zig-out/bin/tildaz
MODE= MANUAL_SECONDS=90 OFF_CMD= ON_CMD= OFF_SECONDS=8 GUARD=40
while [ $# -gt 0 ]; do
  case "$1" in
    --manual) MODE=manual; [ "${2:-}" -eq "${2:-}" ] 2>/dev/null && { MANUAL_SECONDS=$2; shift; }; shift ;;
    --off-cmd) MODE=cmd; OFF_CMD=$2; shift 2 ;;
    --on-cmd) ON_CMD=$2; shift 2 ;;
    --off-seconds) OFF_SECONDS=$2; shift 2 ;;
    --guard) GUARD=$2; shift 2 ;;
    --bin) BIN=$2; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
die() { echo "$*" >&2; exit 1; }
[ -n "$MODE" ] || die "--manual 또는 --off-cmd/--on-cmd 를 준다"
[ "$MODE" = cmd ] && [ -z "$ON_CMD" ] && die "--off-cmd 에는 --on-cmd 가 필요하다"
[ -x "$BIN" ] || die "빌드가 없다: $BIN"
DE=${XDG_CURRENT_DESKTOP:?데스크톱 세션의 터미널에서 돌린다}
APP=tildaz-dev
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/$APP
CONF=${XDG_CONFIG_HOME:-$HOME/.config}/$APP
W=$(mktemp -d "${TMPDIR:-/tmp}/tz-zout.XXXXXX")
case "$DE" in
  *GNOME*) KIND=worker SHELL_NAME=gnome-shell ;;
  *Cinnamon*) KIND=worker SHELL_NAME=cinnamon ;;
  *) KIND=stress SHELL_NAME= ;;
esac
echo "데스크톱: $DE · 창: $KIND · 빌드: $BIN ($("$BIN" --version 2>/dev/null | head -1))"

APP_PID= GUARD_PID=
cleanup() {
  [ -n "$GUARD_PID" ] && kill "$GUARD_PID" 2>/dev/null
  [ -n "$APP_PID" ] && { kill -TERM "$APP_PID" 2>/dev/null; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; }
  if [ "$KIND" = worker ]; then rm -f "$CONF/config_9.toml" "$STATE/tildaz_9.log"; fi
  rm -rf "$W"
}
trap cleanup EXIT

if [ "$KIND" = worker ]; then
  [ -e "$CONF/config_9.toml" ] && die "이미 있다: $CONF/config_9.toml — 다른 회차가 남긴 것인지 보고 지운다"
  [ -e "${XDG_RUNTIME_DIR:?}/$APP/run/instance9.lock" ] && die "dev instance 9 가 떠 있다"
  SHELL_PID=$(pgrep -xo "$SHELL_NAME") || die "$SHELL_NAME 이 안 보인다"
  # 이 판의 완전한 config 를 만든다 (키가 빠지면 시작 안내 다이얼로그가 뜬다). Wayland 없이 띄우면 config 만 만들고 끝난다.
  mkdir -p "$W/c" "$W/s" "$W/r" "$W/h"; chmod 700 "$W/r"
  env -i PATH="$PATH" HOME="$W/h" XDG_CONFIG_HOME="$W/c" XDG_STATE_HOME="$W/s" XDG_RUNTIME_DIR="$W/r" \
    timeout 10 "$BIN" --instance 9 >/dev/null 2>&1
  [ -s "$W/c/$APP/config_9.toml" ] || die "config 템플릿을 못 만들었다"
  mkdir -p "$CONF"
  sed -e 's|^hotkey  *= .*|hotkey           = "shift+f11"|' -e 's|^auto_start  *= .*|auto_start       = false|' \
      -e 's|^hidden_start  *= .*|hidden_start     = false|' "$W/c/$APP/config_9.toml" > "$CONF/config_9.toml"
  LOG=$STATE/tildaz_9.log; rm -f "$LOG"
  TILDAZ_VERBOSE=1 setsid "$BIN" --instance 9 > "$W/app.out" 2>&1 < /dev/null &
else
  LOG=$STATE/tildaz_stress.log; rm -f "$LOG"
  printf '#!/bin/sh\necho "TildaZ zero-output check — do not close"\nwhile :; do sleep 1; done\n' > "$W/hold.sh"; chmod +x "$W/hold.sh"
  TILDAZ_VERBOSE=1 setsid "$BIN" --instance 9 -e "$W/hold.sh" > "$W/app.out" 2>&1 < /dev/null &
fi
APP_PID=$!
for _ in $(seq 60); do grep -q "configure" "$LOG" 2>/dev/null && break; sleep 0.25; done
sleep 2
kill -0 "$APP_PID" 2>/dev/null || { tail -5 "$LOG" 2>/dev/null; die "앱이 뜨지 않았다"; }
echo "앱이 떴다 (pid $APP_PID). 출력: $(grep -c 'bound wl_output\|wl_output bound' "$LOG") 개 묶음 기록"

removed() { grep -c "bound wl_output removed" "$LOG"; }
returned() { grep -c "wl_output bound after hotplug" "$LOG"; }
R0=$(removed) B0=$(returned)
if [ "$MODE" = manual ]; then
  echo ">>> 지금 모니터 케이블을 뽑고, 5~10 초 뒤 다시 꽂아 주세요. (${MANUAL_SECONDS} 초 기다려요)"
  end=$((SECONDS + MANUAL_SECONDS))
  while [ $SECONDS -lt $end ]; do
    [ "$(removed)" -gt "$R0" ] && [ "$(returned)" -gt "$B0" ] && break
    sleep 0.5
  done
  sleep 5
else
  # 도구가 죽어도 화면이 돌아오게 — 따로 도는 안전장치
  setsid sh -c "sleep $GUARD; $ON_CMD" > /dev/null 2>&1 < /dev/null &
  GUARD_PID=$!
  echo ">>> 출력을 끈다 (${OFF_SECONDS} 초 — 그동안 화면이 꺼져요)"
  sh -c "$OFF_CMD" > "$W/off.out" 2>&1; echo "    off rc=$? $(head -c 300 "$W/off.out")"
  sleep "$OFF_SECONDS"
  sh -c "$ON_CMD" > "$W/on.out" 2>&1; echo "    on rc=$? $(head -c 300 "$W/on.out")"
  kill "$GUARD_PID" 2>/dev/null; GUARD_PID=
  sleep 6
fi

RESULT=0
verdict() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; RESULT=1; fi; }
[ "$(removed)" -gt "$R0" ]; verdict "the outputs went away (bound wl_output removed)" $?
[ "$(returned)" -gt "$B0" ]; verdict "the outputs came back (wl_output bound after hotplug)" $?
kill -0 "$APP_PID" 2>/dev/null; verdict "TildaZ is still running" $?
! grep -q "drainQuitRequest" "$LOG"; verdict "TildaZ did not reach the quit-confirm path" $?
if [ -n "$SHELL_NAME" ]; then
  [ "$(pgrep -xo "$SHELL_NAME")" = "$SHELL_PID" ]; verdict "$SHELL_NAME kept its pid $SHELL_PID" $?
fi
echo "--- 앱 로그 (출력 · 표면 · 종료 관련)"
grep -E "wl_output|layer-surface closed|recreate|quit|\[exit\]|\[fatal\]" "$LOG" | tail -20
echo "RESULT=$RESULT"
exit $RESULT
