#!/bin/sh
# 측정 위생 — 검사하고, 환경을 재기 좋은 상태로 만들고, 끝나면 되돌린다.
#
# `compare-terminals.sh` 와 `measure-repeat.sh` 가 **같은 로직을 쓰도록** 빼낸 함수 모음이다.
# 실행 파일이 아니라 `.` 로 읽어서 쓴다.
#
#   . "$(dirname "$0")/hygiene.sh"
#   hygiene_check || exit 1              # worker · AC · 주사율 — 문제가 있으면 1
#   trap 'hygiene_end; 내_정리' EXIT     # ⚠️ trap 은 **호출자가** 건다 (아래 참고)
#   hygiene_begin                        # 절전 차단 · CPU 성능 · 창 최소화
#
# **왜 스크립트가 하나** — README 의 "측정 위생" 을 규칙으로만 적어 뒀더니 실제로 잊었다.
# worker 종료가 규칙에서 자동으로 옮겨간 것과 같은 사유다 ([#381](https://github.com/ensky0/tildaz/issues/381)).
# 배경 앱을 안 내린 채 30 회차를 돌린 적이 있고 (우리 수치만 최대 64 % 눌린다), CPU 가
# `balanced` (EPP `balance_performance`) 인 채로 여러 세션을 쟀다.
#
# **trap 을 여기서 안 거는 이유** — `compare-terminals.sh` 는 이미 자기 `trap ... EXIT` 로
# 터미널 정리 · 설정 복원 · `WORK_DIR` 삭제를 한다. 여기서 걸면 그것을 덮어쓴다. 그래서
# 복원 함수만 제공하고 등록은 호출자에게 맡긴다. `hygiene_end` 는 여러 번 불러도 안전하다.
#
# ⚠️ **실기 검증은 Linux (KDE Plasma Wayland · Intel i5-1240P) 에서만 했다** (2026-08-07).
# macOS · Windows 경로는 코드로만 맞춰 둔 것이라, 처음 쓸 때 아래를 확인해요.
#
# | 확인할 것 | 왜 |
# |---|---|
# | Windows: `kill` 이 powershell 홀더를 실제로 죽이는지 | Git Bash 의 MSYS PID 와 Windows PID 가 달라요. 안 죽어도 홀더는 24 시간 뒤 스스로 끝나요 |
# | Windows: 고성능 구성표로 실제로 바뀌는지 | 최신 Windows 11 은 숨겨 두기도 해요. 실패하면 경고가 떠요 |
# | macOS: `caffeinate` 가 붙는지 | 홀더 방식이라 프로세스가 남아 있어야 해요 |

# platform 판별 — `compare-terminals.sh` 와 같은 규칙이다 (Windows 는 Git Bash 라 `uname` 이
# `MINGW*` / `MSYS*` / `CYGWIN*` 를 낸다).
case "$(uname -s)" in
    Linux) HYG_PLATFORM=linux ;;
    Darwin) HYG_PLATFORM=macos ;;
    MINGW*|MSYS*|CYGWIN*) HYG_PLATFORM=windows ;;
    *) HYG_PLATFORM=unknown ;;
esac

HYG_INHIBIT_PID=""
HYG_PROFILE_SAVED=""
HYG_SCHEME_SAVED=""
HYG_MINIMIZED=0
HYG_POWER="?"
HYG_REFRESH="?"
HYG_PROFILE="?"

# KDE 인지. 창 최소화는 **KDE 만** 한다 (개발 중에 잠깐 쓰는 도구라 sway · Hyprland · GNOME
# 까지 갖추지 않는다 — 사용자 결정). 그 환경에서는 조용히 넘어가지 않고 경고한다.
hygiene_is_kde() {
    [ "$HYG_PLATFORM" = linux ] || return 1
    case "${XDG_CURRENT_DESKTOP:-}" in *KDE*) ;; *) return 1 ;; esac
    command -v gdbus >/dev/null 2>&1 || return 1
    return 0
}

# --- 검사 -----------------------------------------------------------------
#
# 값을 `HYG_*` 에 채우고, 측정을 망칠 것이 있으면 경고를 stderr 로 내고 1 을 돌려준다.
# 호출자가 `--ignore-hygiene` 같은 우회를 줄지 결정한다.
hygiene_check() {
    _warn=""

    # 평소 쓰는 worker 가 떠 있으면 렌더 · CPU 를 나눠 쓴다. 측정 인스턴스는 worker lock 을
    # 잡지 않아 충돌 없이 함께 뜨므로 (#382) 여기서 직접 봐야 한다.
    if [ "$HYG_PLATFORM" = windows ]; then
        _pids=$(powershell -NoProfile -Command "(Get-Process tildaz -ErrorAction SilentlyContinue).Id -join ' '" 2>/dev/null | tr -d '\r')
    else
        _pids=$(pgrep -x tildaz 2>/dev/null | tr '\n' ' ')
    fi
    if [ -n "$_pids" ]; then
        echo "tildaz worker 가 떠 있어요 (pid $_pids) — 먼저 내려요" >&2
        return 1
    fi

    case "$HYG_PLATFORM" in
        linux)
            _ac=0
            for _p in /sys/class/power_supply/*/; do
                [ -r "$_p/type" ] || continue
                [ "$(cat "$_p/type")" = Mains ] || continue
                [ "$(cat "$_p/online" 2>/dev/null || echo 0)" = 1 ] && _ac=1
            done
            HYG_POWER=$([ "$_ac" = 1 ] && echo AC || echo battery)
            [ "$_ac" = 1 ] || _warn="$_warn
AC 미연결 — 배터리에서는 스로틀링이 걸리고 패널이 낮은 주사율로 강등되기도 해요"

            if command -v powerprofilesctl >/dev/null 2>&1; then
                HYG_PROFILE=$(powerprofilesctl get 2>/dev/null || echo "?")
            fi

            # KDE 는 `kscreen-doctor` 로 현재 모드와 그 화면의 최대를 볼 수 있다. `*` 가 현재
            # 모드다. 다른 DE 에는 이 도구가 없어서 건너뛰고, **없는 것을 통과로 읽지 않도록**
            # `?` 를 그대로 남긴다.
            if command -v kscreen-doctor >/dev/null 2>&1; then
                # ESC 를 sed 스크립트에 리터럴로 못 적는다 — `\033` 은 GNU sed 가 안 받고
                # (`\x1b` 는 받지만 BSD sed 가 안 받는다), 색 코드가 남으면 앵커가 빗나가
                # 조용히 `?` 가 된다 (실측).
                _esc=$(printf '\033')
                _ks=$(kscreen-doctor -o 2>/dev/null | sed "s/${_esc}\[[0-9;]*m//g" || true)
                _cur=$(echo "$_ks" | tr ' ' '\n' | sed -n 's/^[0-9]*:[0-9x]*@\([0-9.]*\)\*.*$/\1/p' | head -1)
                _max=$(echo "$_ks" | tr ' ' '\n' | sed -n 's/^[0-9]*:[0-9x]*@\([0-9.]*\).*$/\1/p' | sort -g | tail -1)
                if [ -n "$_cur" ]; then
                    HYG_REFRESH="${_cur}Hz"
                    if [ -n "$_max" ] && [ "$_cur" != "$_max" ]; then
                        _warn="$_warn
주사율이 $_cur Hz 인데 이 화면의 최대는 $_max Hz 예요 — 고정 최대값을 고르거나 이 값으로 잰다고 기록해요"
                    fi
                fi
            fi
            ;;
        macos)
            if pmset -g batt 2>/dev/null | grep -q "AC Power"; then
                HYG_POWER=AC
            else
                HYG_POWER=battery
                _warn="$_warn
AC 미연결 — 배터리에서는 스로틀링이 걸려요"
            fi
            # 주사율은 `system_profiler` 에 안 나오고 셸에서 부를 API 가 없어서 확인하지
            # 않는다 (README) — 기록할 때 사람이 적는다.
            ;;
        windows)
            _batt=$(powershell -NoProfile -Command "(Get-CimInstance Win32_Battery).BatteryStatus" 2>/dev/null | tr -d '\r ')
            if [ "$_batt" = 1 ]; then
                HYG_POWER=battery
                _warn="$_warn
AC 미연결 (BatteryStatus=1) — 배터리에서는 스로틀링이 걸리고 패널이 60 Hz 로 강등되기도 해요"
            else
                HYG_POWER=AC
            fi
            _rr=$(powershell -NoProfile -Command "\$v=Get-CimInstance Win32_VideoController | Select-Object -First 1; \"\$(\$v.CurrentRefreshRate) \$(\$v.MaxRefreshRate)\"" 2>/dev/null | tr -d '\r')
            _cur=${_rr% *}; _max=${_rr#* }
            if [ -n "$_cur" ] && [ "$_cur" != "$_max" ]; then
                HYG_REFRESH="${_cur}Hz"
                _warn="$_warn
주사율이 $_cur Hz 인데 최대는 $_max Hz 예요 — 동적 새로 고침 빈도(DRR)를 끄고 고정 값을 골라요"
            elif [ -n "$_cur" ]; then
                HYG_REFRESH="${_cur}Hz"
            fi
            ;;
    esac

    # 창을 자동으로 못 내리는 환경에서는 **반드시 알린다.** 배경에서 그리는 앱이 있으면
    # **우리 수치만** 최대 64 % 눌린다 (다른 넷은 +0.7~9 %). 자동화가 KDE 에만 있다고 해서
    # 나머지 환경에서 이 함정이 사라지는 게 아니다 — 규칙으로만 남기면 잊는다.
    if ! hygiene_is_kde; then
        _warn="$_warn
배경 앱을 자동으로 못 내려요 (KDE 에서만 해요) — 브라우저 · 에디터를 직접 최소화해요 (우리 수치만 최대 64 % 눌려요)"
    fi

    if [ -n "$_warn" ]; then
        echo "$_warn" | while IFS= read -r _m; do [ -n "$_m" ] && echo "⚠ $_m" >&2; done
        return 1
    fi
    return 0
}

hygiene_status() {
    _min=$([ "$HYG_MINIMIZED" = 1 ] && echo yes || echo no)
    echo "platform=$HYG_PLATFORM  power=$HYG_POWER  refresh=$HYG_REFRESH  cpu_profile=$HYG_PROFILE  minimized=$_min"
}

# --- 준비 -----------------------------------------------------------------
hygiene_begin() {
    # ① 절전 · 잠금 차단. 잠금 화면이 뜨면 `render` 만 무너지고 `parse` 는 정상이라 결과
    #    표에 오염이 안 드러난다 (#396 에서 실제로 한 회차를 버렸다).
    #
    #    **홀더 프로세스로 잡는다.** `exec systemd-inhibit ... "$0" "$@"` 로 자기를 감싸는
    #    방식은 옵션 파싱 뒤에 두면 `shift` 가 비운 `"$@"` 로 재실행되는 함정이 있다 —
    #    #397 에서 잘못된 인자를 거절하는지 보려던 호출 하나가 20 회차 측정을 통째로
    #    실행했다. 홀더는 그 구조가 아예 없다.
    case "$HYG_PLATFORM" in
        linux)
            if command -v systemd-inhibit >/dev/null 2>&1; then
                systemd-inhibit --what=idle:sleep --who=tildaz-stress \
                    --why="throughput measurement" sleep 86400 >/dev/null 2>&1 &
                HYG_INHIBIT_PID=$!
            fi
            ;;
        macos)
            if command -v caffeinate >/dev/null 2>&1; then
                caffeinate -dims >/dev/null 2>&1 &
                HYG_INHIBIT_PID=$!
            fi
            ;;
        windows)
            # ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED = 2147483651.
            # 그 스레드가 살아 있는 동안만 유효해서 프로세스를 띄워 둔다.
            powershell -NoProfile -Command "Add-Type -Namespace T -Name P -MemberDefinition '[DllImport(\"kernel32.dll\")] public static extern uint SetThreadExecutionState(uint e);'; [void][T.P]::SetThreadExecutionState(2147483651); Start-Sleep -Seconds 86400" >/dev/null 2>&1 &
            HYG_INHIBIT_PID=$!
            ;;
    esac
    [ -n "$HYG_INHIBIT_PID" ] || echo "⚠ 절전 · 잠금을 차단할 도구가 없어요 — 화면 잠금을 직접 꺼요" >&2

    # ② CPU 를 최고 성능으로. AC 만 확인하고 프로파일은 안 봤더니 `balanced` (EPP
    #    `balance_performance`) 인 채로 여러 세션을 쟀다. `intel_pstate` 에서 실질적인
    #    레버는 EPP 다.
    case "$HYG_PLATFORM" in
        linux)
            if command -v powerprofilesctl >/dev/null 2>&1; then
                HYG_PROFILE_SAVED=$(powerprofilesctl get 2>/dev/null || echo "")
                if [ "$HYG_PROFILE_SAVED" = performance ]; then
                    HYG_PROFILE_SAVED=""  # 원래 그랬으니 되돌릴 것이 없다
                elif powerprofilesctl set performance >/dev/null 2>&1; then
                    HYG_PROFILE=performance
                else
                    HYG_PROFILE_SAVED=""
                    echo "⚠ CPU 를 performance 로 못 바꿨어요 — $HYG_PROFILE 로 재요" >&2
                fi
            fi
            ;;
        windows)
            HYG_SCHEME_SAVED=$(powercfg /getactivescheme 2>/dev/null | sed -n 's/.*GUID: \([0-9a-f-]*\).*/\1/p' | tr -d '\r')
            # 고성능 전원 관리 옵션 (Microsoft 고정 GUID). 최신 Windows 11 은 이 구성표를
            # 숨겨 두기도 해서 실패할 수 있다 — **조용히 넘기지 않는다.** 안 그러면 CPU 가
            # 안 올라간 채로 통과해서, 정확히 이 파일이 막으려던 종류의 오염이 된다.
            if powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >/dev/null 2>&1; then
                HYG_PROFILE=high-performance
            else
                HYG_SCHEME_SAVED=""
                echo "⚠ 고성능 전원 관리 옵션으로 못 바꿨어요 (숨겨진 구성표일 수 있어요) — 설정에서 직접 골라요" >&2
            fi
            ;;
        # macOS 에는 대응 경로가 없다. `?` 가 아니라 `n/a` 로 찍어서 **못 읽은 것**과
        # **원래 없는 것**을 구분한다.
        macos) HYG_PROFILE=n/a ;;
    esac

    # ③ 배경 앱 최소화 — KDE 만. 배경에서 그리는 앱이 있으면 **우리 수치만** 최대 64 %
    #    눌린다 (다른 넷은 +0.7~9 %).
    #
    #    **되돌리지 않는다** (사용자 결정). `measure-repeat.ps1` 의 `MinimizeAll` 도 같다 —
    #    측정이 끝나면 창은 내려간 채로 두고 필요하면 직접 올린다.
    if hygiene_is_kde; then
        hygiene_minimize_windows && HYG_MINIMIZED=1
    fi
}

# 열려 있는 일반 창을 **하나씩 최소화**한다 (KWin 스크립팅). `measure-repeat.ps1` 의
# `Shell.Application.MinimizeAll` 과 같은 의미다.
#
# **Show Desktop 을 쓰지 않는 이유** — 두 경로를 다 시험해서 버렸다.
#   - `org.kde.KWin.showDesktop(bool)` 은 Plasma 6 Wayland 에서 **먹지 않는다**. 호출은
#     성공하는데 `showingDesktop` 이 안 바뀐다.
#   - 단축키 (`invokeShortcut "Show Desktop"`) 는 상태가 바뀌긴 하는데, **측정 창이 뜨는
#     순간 해제된다.** 그래서 배경 앱이 다시 그려지고, 정작 막으려던 것을 못 막는다
#     (실측: 회차가 끝난 뒤 `showingDesktop` 이 false 로 돌아와 있고 사용자 창이 계속 보였다).
# 개별 최소화는 상태 토글이 아니라 **명령**이라 새로 뜨는 창에 영향이 없다.
hygiene_minimize_windows() {
    _js=$(mktemp) || return 1
    # `workspace.windowList()` 는 Plasma 6, `clientList()` 는 5 다. 둘 다 받는다.
    cat > "$_js" <<'KWINJS'
var n = 0;
var list = workspace.windowList ? workspace.windowList() : workspace.clientList();
for (var i = 0; i < list.length; i++) {
    var w = list[i];
    if (w.normalWindow && !w.minimized) { w.minimized = true; n++; }
}
print("tildaz-stress: minimized " + n);
KWINJS
    _id=$(gdbus call --session --dest org.kde.KWin --object-path /Scripting \
        --method org.kde.kwin.Scripting.loadScript "$_js" "tildazstressmin" 2>/dev/null)
    _num=$(printf '%s' "$_id" | tr -dc '0-9')
    if [ -n "$_num" ]; then
        gdbus call --session --dest org.kde.KWin --object-path "/Scripting/Script$_num" \
            --method org.kde.kwin.Script.run >/dev/null 2>&1
        # 같은 이름으로 다시 로드할 수 있게 반드시 내린다.
        gdbus call --session --dest org.kde.KWin --object-path /Scripting \
            --method org.kde.kwin.Scripting.unloadScript "tildazstressmin" >/dev/null 2>&1
    fi
    rm -f "$_js"
    [ -n "$_num" ]
}

# --- 복원 -----------------------------------------------------------------
#
# 여러 번 불러도 안전하다 (호출자의 `trap` 과 명시 호출이 겹칠 수 있다).
hygiene_end() {
    if [ -n "$HYG_INHIBIT_PID" ]; then
        kill "$HYG_INHIBIT_PID" 2>/dev/null || true
        HYG_INHIBIT_PID=""
    fi
    if [ -n "$HYG_PROFILE_SAVED" ]; then
        powerprofilesctl set "$HYG_PROFILE_SAVED" >/dev/null 2>&1 || true
        HYG_PROFILE_SAVED=""
    fi
    if [ -n "$HYG_SCHEME_SAVED" ]; then
        powercfg /setactive "$HYG_SCHEME_SAVED" >/dev/null 2>&1 || true
        HYG_SCHEME_SAVED=""
    fi
    # 창은 되돌리지 않는다 (`hygiene_begin` ③ 주석). CPU 프로파일은 되돌린다 — 그건
    # 남겨 두면 배터리를 계속 먹는다.
}
