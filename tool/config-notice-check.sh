#!/bin/bash
# #655 — config 가 망가져도 **뜨는지**, 그리고 무엇을 고쳤다고 알리는지를 자동 검증한다.
# Linux · macOS 공통 (Windows 는 `tool/config-notice-check_windows.ps1`).
#
#   tool/config-notice-check.sh              # 전체
#   tool/config-notice-check.sh order clamp  # 고른 회차만
#   tool/config-notice-check.sh list         # 회차 목록
#
# 환경변수: TILDAZ (기본 zig-out 의 바이너리) · TZCN_WORK (작업 디렉터리).
# 판정 줄은 `RESULT <회차>: PASS|FAIL …` 로 시작한다. 하나라도 FAIL 이면 exit 1.
#
# **사용자 파일을 건드리지 않는다.** `XDG_CONFIG_HOME` · `XDG_STATE_HOME` · `HOME` 을
# 작업 디렉터리로 돌려서 config 와 로그가 모두 그 안에만 생긴다. instance 9 를 쓰는 것도
# 같은 이유다 — 격리가 어디선가 새더라도 평소 쓰는 0 번과 겹치지 않는다. **Linux 에서는
# 그것만으로 부족해서** 데스크톱 연동 변수도 함께 뺀다 — 아래 `SESSION_GUARD` 주석.
#
# **기본 config 를 스크립트가 적지 않는다.** 빈 디렉터리에서 앱을 한 번 돌려 *앱이*
# 만들게 하고 (`mkbase`) 그것을 망가뜨린다. 손으로 적으면 스키마가 넓어진 날 (이 이슈가
# 다루는 바로 그 일이다) 검증이 조용히 헛돈다.
#
# 회차는 앱을 **평소처럼 띄웠다 내린다.** `-e` 로 대신할 수 없다 — 측정 인스턴스는 config
# 파일을 만들지 않고 (`instances.createDefaultConfig` 를 거치지 않는다) 로그도
# `tildaz_stress.log` 로 간다. 안내 다이얼로그가 뜨지만 곧 죽이므로 막히지 않는다.
# 예외는 `quiet` 회차 하나로, `-e` 가 **다이얼로그를 띄우지 않는다**는 것 자체를 잰다.
#
# 다이얼로그의 *생김새* (여백 · 스크롤 · 버튼 동작) 는 로그로 못 재니 아래 "눈으로 볼 것"
# 을 따로 둔다 — `tool/config-notice-check.sh list`.
set -u
set +m   # `kill` 이 남기는 "Terminated" 잡음을 죽인다

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TZCN_WORK:-${TMPDIR:-/tmp}/tildaz-config-notice}"
IDX=9

case "$(uname -s)" in
  Darwin) DEFAULT_BIN="$ROOT/zig-out/TildaZ.app/Contents/MacOS/tildaz" ;;
  *)      DEFAULT_BIN="$ROOT/zig-out/bin/tildaz" ;;
esac
BIN="${TILDAZ:-$DEFAULT_BIN}"

fail_count=0
result() { # <회차> <PASS|FAIL> <설명>
  printf 'RESULT %s: %s %s\n' "$1" "$2" "$3"
  [ "$2" = FAIL ] && fail_count=$((fail_count + 1))
  return 0
}

# 회차 하나가 쓸 격리된 환경. 매번 지우고 새로 만든다 — 앞 회차의 로그가 남으면
# `grep` 이 남의 줄을 읽는다.
env_reset() {
  rm -rf "$WORK/run"
  mkdir -p "$WORK/run/config" "$WORK/run/state" "$WORK/run/home"
}

CFG() { echo "$WORK/run/config/tildaz/config_$1.toml"; }

# `-e` 로 돌린 회차는 로그 이름이 다르다 — 측정 인스턴스는 index 대신 `stress` 를 쓴다.
LOG() { # <index|stress>
  case "$(uname -s)" in
    Darwin) echo "$WORK/run/home/Library/Logs/tildaz_$1.log" ;;
    *)      echo "$WORK/run/state/tildaz/tildaz_$1.log" ;;
  esac
}

ENVV() {
  echo XDG_CONFIG_HOME="$WORK/run/config" XDG_STATE_HOME="$WORK/run/state" HOME="$WORK/run/home"
}

# ⚠️ **`XDG_*` 를 돌리는 것만으로는 사용자 세션이 안 막힌다** (2026-09-17 #655 Linux 회차 실측).
# 앱이 `XDG_CURRENT_DESKTOP` 과 `DBUS_SESSION_BUS_ADDRESS` 를 그대로 물려받으면 **사용자의
# 세션 버스에 붙어 전역 단축키를 등록한다.** KDE 세션에서 그냥 돌렸더니
# `~/.config/kglobalshortcutsrc` 에 `[tildaz.instance9] toggle-9=F10` 이 생겼고 앱을 내려도
# 남아서, D-Bus `org.kde.KGlobalAccel.unregister` 로 지워야 했다. GNOME 도 같은 부류다
# (gsettings · Shell extension 경로). AGENTS.md 의 *"파일 경로만 바꾸는 격리는 다른 프로세스를
# 거치는 상태를 못 막는다"* 와 같은 자리다.
#
# 이 회차들이 재는 것은 **config 로드 동작**이지 데스크톱 연동이 아니므로, 그 두 변수를 빼서
# 등록 경로를 아예 안 타게 한다 (`de=(unset)` 이면 앱이 hotkey 등록을 건너뛴다). `hotkey`
# 회차가 보는 것은 OS 등록이 아니라 **config 단계의 중복 판정**이라 그대로 성립한다.
case "$(uname -s)" in
  Linux) SESSION_GUARD="-u XDG_CURRENT_DESKTOP -u DBUS_SESSION_BUS_ADDRESS" ;;
  *)     SESSION_GUARD="" ;;
esac

# 평소처럼 띄웠다가 내린다. **`-e` 로는 대신할 수 없다** — 측정 인스턴스는 config 파일을
# 만들지 않고 (`instances.createDefaultConfig` 를 거치지 않는다) 로그도 `tildaz_stress.log`
# 로 간다. 안내 다이얼로그가 뜨지만 곧 죽이므로 스크립트를 막지 않는다.
run_app() { # <index> [설 시간]
  local idx="$1" wait_s="${2:-6}"
  env $SESSION_GUARD $(ENVV) "$BIN" --instance "$idx" >/dev/null 2>&1 &
  local pid=$!
  local i=0
  while [ $i -lt $((wait_s * 4)) ]; do
    grep -q 'config loaded' "$(LOG "$idx")" 2>/dev/null && break
    sleep 0.25; i=$((i + 1))
  done
  sleep 0.5   # 안내 줄이 `config loaded` 보다 앞이지만 flush 여유를 둔다
  kill "$pid" 2>/dev/null
  pkill -f "tildaz --instance $idx" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 0
}

# `-e` 로 돈다 — 다이얼로그가 뜨지 않는 경로 그 자체를 재는 회차에서만 쓴다.
run_app_quiet() { # <index>
  env $SESSION_GUARD $(ENVV) "$BIN" --instance "$1" -e "true" >/dev/null 2>&1
}

# 앱이 자기 손으로 기본 config 를 만들게 한다.
mkbase() { # <index>
  run_app "$1"
  [ -f "$(CFG "$1")" ]
}

# 로그에서 `[config]` 안내 줄만 (들여쓴 목록 항목) 뽑는다.
notice_lines() { sed -n 's/^.*\[config\]   //p' "$(LOG "$IDX")" 2>/dev/null; }

# ---------------------------------------------------------------------------

# 네 갈래를 한 파일에 모두 넣는다. 각 회차가 이 함수로 같은 파일을 만든다.
break_all() {
  python3 - "$(CFG "$IDX")" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

# ① 없는 키 — [input] 섹션을 통째로 지운다
i, j = s.index('\n[input]\n'), s.index('\n[keys]\n')
s = s[:i] + s[j:]

# ③ 값 오류 — 타입 · 범위 밖 · 모르는 이름
s = re.sub(r'^auto_start\s*=.*$', 'auto_start = "yes"', s, count=1, flags=re.M)
s = re.sub(r'^width_percent\s*=.*$', 'width_percent = 1000.0', s, count=1, flags=re.M)
s = re.sub(r'^theme\s*=.*$', 'theme = "Nonesuch"', s, count=1, flags=re.M)

# ② 모르는 키 — 첫 [ 앞 (최상위) 에 넣어야 최상위 키가 된다
first_table = s.index('\n[')
s = s[:first_table] + '\nbogus_key = 1\n' + s[first_table:]

# [keys] — 읽을 수 없는 조합 하나, 그리고 앞 액션의 키를 뒤 액션이 다시 쓴다
m = re.search(r'^(\w+)\s*=\s*\[([^\]]*)\]', s[s.index('\n[keys]\n'):], flags=re.M)
first_action, first_keys = m.group(1), m.group(2)
s = re.sub(r'^(\w+)(\s*=\s*\[)([^\]]*)(\])',
           lambda mm: mm.group(0) if mm.group(1) != first_action
           else f'{mm.group(1)}{mm.group(2)}{mm.group(3)}, "ctrl+shift+nosuchkey"{mm.group(4)}',
           s, count=0, flags=re.M)
# 두 번째 액션에 첫 액션의 첫 키를 더해 충돌을 만든다
actions = re.findall(r'^(\w+)\s*=\s*\[', s[s.index('\n[keys]\n'):], flags=re.M)
second = actions[1]
first_key = first_keys.split(',')[0].strip()
s = re.sub(rf'^({second})(\s*=\s*\[)([^\]]*)(\])',
           lambda mm: f'{mm.group(1)}{mm.group(2)}{mm.group(3)}, {first_key}{mm.group(4)}',
           s, count=1, flags=re.M)

# ② 모르는 섹션 — 맨 끝 (TOML 은 헤더 소속 규칙이 있다)
s += '\n[nosuch_section]\nfoo = 1\nbar = 2\n'
open(p, 'w', encoding='utf-8').write(s)
print(f'{first_action} {second}')
PY
}

# ---------------------------------------------------------------------------

case_boots() {
  env_reset; mkbase "$IDX" || { result boots FAIL "기본 config 를 만들지 못했다"; return; }
  break_all >/dev/null || { result boots FAIL "config 를 망가뜨리지 못했다"; return; }
  rm -f "$(LOG "$IDX")"
  run_app "$IDX"
  local log; log="$(LOG "$IDX")"
  if ! grep -q 'config loaded' "$log" 2>/dev/null; then
    result boots FAIL "뜨지 않았다 — 이 이슈가 고치려는 바로 그 증상이다"
    return
  fi
  local n; n=$(sed -n 's/.*notice shown: \([0-9]*\) item.*/\1/p' "$log" | head -1)
  [ -n "${n:-}" ] && [ "$n" -ge 8 ] \
    && result boots PASS "떴고 안내 ${n} 줄" \
    || result boots FAIL "떴지만 안내가 비었거나 너무 적다 (${n:-없음})"
}

case_order() {
  env_reset; mkbase "$IDX" >/dev/null || { result order FAIL "준비 실패"; return; }
  # `[keys]` 를 헤더만 남기고 비우면 모든 액션이 "없는 키" 가 된다 — 차례를 재기 좋다.
  python3 - "$(CFG "$IDX")" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
i = s.index('\n[keys]\n')
open(p, 'w', encoding='utf-8').write(s[:i] + '\n[keys]\n')
PY
  rm -f "$(LOG "$IDX")"
  run_app "$IDX"
  # **로그를 먼저 떠 둔다.** 아래에서 기본 config 를 다시 만들려고 환경을 지우는데,
  # 로그도 그 안에 있어서 지우고 나면 읽을 것이 없다.
  local saved_log="$WORK/order.log"
  cp "$(LOG "$IDX")" "$saved_log" 2>/dev/null
  # 파일이 적은 차례 (기본 config 를 다시 만들어 읽는다) 와 안내의 차례를 맞댄다.
  local base="$WORK/order-base.toml"
  env_reset
  mkbase "$IDX" >/dev/null && cp "$(CFG "$IDX")" "$base"
  python3 - "$base" "$saved_log" <<'PY' && result order PASS "안내가 파일 차례대로다" || result order FAIL "안내 차례가 파일과 다르다 (해시 순서로 나오면 45 줄을 대조할 수 없다)"
import sys, re
base, log = sys.argv[1], sys.argv[2]
s = open(base, encoding='utf-8').read()
keys_body = s[s.index('\n[keys]\n') + len('\n[keys]\n'):]
want = [m.group(1) for m in re.finditer(r'^(\w+)\s*=', keys_body, flags=re.M)]
got = [m.group(1) for m in re.finditer(r'keys\.(\w+) -- missing', open(log, encoding='utf-8').read())]
if not want or not got:
    print('want/got 가 비었다', len(want), len(got)); sys.exit(1)
common = [k for k in want if k in got]
sys.exit(0 if got[:len(common)] == common else 1)
PY
}

case_clamp() {
  env_reset; mkbase "$IDX" >/dev/null || { result clamp FAIL "준비 실패"; return; }
  break_all >/dev/null; rm -f "$(LOG "$IDX")"; run_app "$IDX"
  # **기본값으로 되돌리지 않는다** — 경계값이어야 한다 (SPEC §7.3).
  notice_lines | grep -q 'window.width_percent -- out of range, limited to 100' \
    && result clamp PASS "1000 → 100 으로 clamp" \
    || result clamp FAIL "clamp 줄이 없다 (기본값으로 되돌렸다면 그것도 틀렸다)"
}

case_first_wins() {
  env_reset; mkbase "$IDX" >/dev/null || { result first-wins FAIL "준비 실패"; return; }
  local pair; pair=$(break_all) || { result first-wins FAIL "준비 실패"; return; }
  local first second; first=$(echo "$pair" | awk '{print $1}'); second=$(echo "$pair" | awk '{print $2}')
  rm -f "$(LOG "$IDX")"; run_app "$IDX"
  # 먼저 나온 액션이 그 조합을 지키고, 뒤엣것이 버려진다.
  notice_lines | grep -q "keys\.${second} -- .* is already used by ${first}, dropped" \
    && result first-wins PASS "${first} 가 이기고 ${second} 가 그 키를 잃었다" \
    || result first-wins FAIL "충돌 안내가 없거나 이긴 쪽이 다르다"
}

case_drop_one() {
  env_reset; mkbase "$IDX" >/dev/null || { result drop-one FAIL "준비 실패"; return; }
  local pair; pair=$(break_all) || { result drop-one FAIL "준비 실패"; return; }
  local first; first=$(echo "$pair" | awk '{print $1}')
  rm -f "$(LOG "$IDX")"; run_app "$IDX"
  # **나쁜 항목만** 버린다 — 같은 액션의 나머지 키는 살아야 한다.
  notice_lines | grep -q "keys\.${first} -- dropped \"ctrl+shift+nosuchkey\" (unknown key)" \
    && result drop-one PASS "읽을 수 없는 조합 하나만 버렸다" \
    || result drop-one FAIL "항목 단위로 버리지 않았다"
}

case_unknown() {
  env_reset; mkbase "$IDX" >/dev/null || { result unknown FAIL "준비 실패"; return; }
  break_all >/dev/null; rm -f "$(LOG "$IDX")"; run_app "$IDX"
  local out; out=$(notice_lines)
  # 모르는 **섹션** 은 안의 키를 나열하지 않고 테이블 하나로만 알린다.
  if echo "$out" | grep -qx 'nosuch_section' && echo "$out" | grep -qx 'bogus_key' \
     && ! echo "$out" | grep -q 'nosuch_section\.'; then
    result unknown PASS "모르는 키 · 섹션을 한 줄씩 (섹션 내부는 안 편다)"
  else
    result unknown FAIL "모르는 키 · 섹션 안내가 틀렸다"
  fi
}

case_font_missing() {
  env_reset; mkbase "$IDX" >/dev/null || { result font-missing FAIL "준비 실패"; return; }
  python3 - "$(CFG "$IDX")" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
i, j = s.index('\n[font]\n'), s.index('\n[input]\n')
open(p, 'w', encoding='utf-8').write(s[:i] + s[j:])
PY
  rm -f "$(LOG "$IDX")"; run_app "$IDX"
  # 예전 코드는 `root.table.get("font").?` 로 **그 자리에서 패닉**했다.
  grep -q 'config loaded' "$(LOG "$IDX")" 2>/dev/null \
    && result font-missing PASS "[font] 없이도 떴다" \
    || result font-missing FAIL "[font] 없는 config 에서 죽었다 (패닉 의심)"
}

case_quiet() {
  env_reset; mkbase "$IDX" >/dev/null || { result quiet FAIL "준비 실패"; return; }
  break_all >/dev/null
  rm -f "$(LOG stress)"
  run_app_quiet "$IDX"
  local log; log="$(LOG stress)"
  # `-e` 는 스크립트를 막으면 안 된다 — 로그에는 다 남고 다이얼로그는 안 뜬다.
  # 이 회차가 끝까지 돌아 **여기 도달한 것 자체**가 모달이 안 떴다는 증거다.
  if grep -q 'notice shown' "$log" 2>/dev/null && ! grep -qE 'notice (action|dismissed)' "$log"; then
    result quiet PASS "로그에만 남고 다이얼로그가 뜨지 않았다"
  else
    result quiet FAIL "-e 인데 로그가 비었거나 다이얼로그 상호작용이 찍혔다"
  fi
}

case_clean() {
  env_reset; mkbase "$IDX" >/dev/null || { result clean FAIL "준비 실패"; return; }
  rm -f "$(LOG "$IDX")"; run_app "$IDX"
  # **이 회차가 가장 중요하다.** 여기가 깨지면 아무 잘못 없는 사용자가 뜰 때마다
  # 다이얼로그를 본다 — 대조 기준 (`schemaReferenceToml`) 과 생성기
  # (`defaultConfigToml`) 가 갈렸다는 뜻이다.
  local n; n=$(notice_lines | wc -l | tr -d ' ')
  [ "$n" = 0 ] \
    && result clean PASS "정상 config 는 완전히 무음이다" \
    || result clean FAIL "정상 config 가 안내 ${n} 줄을 만들었다 — $(notice_lines | head -3 | tr '\n' ' ')"
}

case_hotkey() {
  env_reset
  # 낮은 index 의 config 를 먼저 만들어 두고, 9 번이 **같은 키**를 쓰게 한다.
  mkbase 0 >/dev/null || { result hotkey FAIL "준비 실패"; return; }
  mkbase "$IDX" >/dev/null || { result hotkey FAIL "준비 실패"; return; }
  local taken; taken=$(sed -n 's/^hotkey *= *"\(.*\)".*/\1/p' "$(CFG 0)" | head -1)
  [ -n "$taken" ] || { result hotkey FAIL "0 번 hotkey 를 못 읽었다"; return; }
  python3 - "$(CFG "$IDX")" "$taken" <<'PY'
import sys, re
p, hk = sys.argv[1], sys.argv[2]
s = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(re.sub(r'^hotkey\s*=.*$', f'hotkey = "{hk}"', s, count=1, flags=re.M))
PY
  rm -f "$(LOG "$IDX")"; run_app "$IDX"
  local log; log="$(LOG "$IDX")"
  # 죽지 않고 파생 기본값 F{N+1} 로 갈아탄다 (SPEC §7.3 의 유일한 예외 — 갈아탈
  # 자리까지 없을 때만 종료한다).
  if grep -q 'config loaded' "$log" && notice_lines | grep -q 'hotkey -- already used by instance 0, using '; then
    result hotkey PASS "중복을 감지하고 갈아탔다 — $(notice_lines | grep 'hotkey --')"
  else
    result hotkey FAIL "중복에서 죽었거나 갈아탔다는 안내가 없다"
  fi
}

case_truncate() {
  env_reset; mkbase "$IDX" >/dev/null || { result truncate FAIL "준비 실패"; return; }
  # 긴 이름의 모르는 키를 넣어 안내 버퍼 (16 KiB) 를 넘긴다.
  #
  # **config 파일은 64 KiB 를 넘기면 안 된다** (`Config.load` 의 `allocRemaining` 상한).
  # 넘기면 파일이 통째로 거부돼 `load failed — running with defaults` 로 빠지고 —
  # 그것도 부팅은 되니 원칙 5 에는 맞지만 — 이 회차가 재려던 잘림은 일어나지 않는다.
  # 150 × 200 자 ≈ 30 KiB 로 상한 안에 들면서 안내 버퍼만 넘긴다.
  python3 - "$(CFG "$IDX")" <<'PY'
import sys
p = sys.argv[1]
with open(p, 'a', encoding='utf-8') as f:
    f.write('\n')
    for i in range(150):
        f.write(f'{"k" * 200}{i} = 1\n')
PY
  rm -f "$(LOG "$IDX")"; run_app "$IDX"
  # 버퍼가 넘쳐도 **몇 개였는지는 정확**하고, 로그에는 전부 남는다.
  grep -q 'notice shown: [0-9]* item(s) (truncated)' "$(LOG "$IDX")" 2>/dev/null \
    && result truncate PASS "넘친 것을 잘렸다고 표시했다" \
    || result truncate FAIL "잘림 표시가 없다 — 사용자가 목록이 전부인 줄 안다"
}

CASES="boots order clamp first-wins drop-one unknown font-missing quiet clean hotkey truncate"

usage() {
  echo "회차: $CASES"
  echo
  echo "눈으로 볼 것 (로그로는 못 잰다 — 다이얼로그를 띄워서 본다):"
  echo "  · 목록이 길 때 **스크롤러**가 나오고 창이 화면을 덮지 않는다"
  echo "  · 제목 · 본문이 창 가장자리에 붙지 않는다 (좌우 · 위 여백)"
  echo "  · 앱 아이콘이 제목을 덮지 않는다"
  echo "  · \`Open Config\` 를 누르면 **창이 남은 채** 편집기가 뜨고, 그 편집기가 터미널 **앞**에 온다"
  echo "  · \`확인\` · Esc · 창 닫기로는 편집기가 뜨지 않는다 (로그의 notice action 줄로도 확인)"
  echo "  · 창을 내렸다 올려도 다시 뜨지 않는다"
}

[ ! -x "$BIN" ] && { echo "바이너리가 없다: $BIN (TILDAZ 로 지정하거나 zig build 먼저)"; exit 2; }

run="${*:-$CASES}"
[ "$run" = list ] && { usage; exit 0; }

mkdir -p "$WORK"
echo "bin=$BIN"
echo "work=$WORK"
for c in $run; do
  fn="case_$(echo "$c" | tr '-' '_')"
  if ! declare -F "$fn" >/dev/null; then
    echo "모르는 회차: $c"; usage; exit 2
  fi
  "$fn"
done

echo
if [ "$fail_count" = 0 ]; then
  echo "모든 회차 PASS. 위 '눈으로 볼 것' 은 따로 확인한다 (tool/config-notice-check.sh list)."
else
  echo "FAIL $fail_count 건."
fi
exit $([ "$fail_count" = 0 ] && echo 0 || echo 1)
