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
# **실기 검증 상태** — Linux (KDE Plasma Wayland · Intel i5-1240P, 2026-08-07) ·
# Windows (같은 기기 · Windows 11 26200 · Git Bash, 2026-08-07) ·
# macOS (MacBook Pro M5 Pro, 2026-08-08) 모두 확인했다.
#
# Windows 검증에서 **넷 중 하나만 맞았고**, macOS 도 **둘 중 하나가 틀려 있었다** — 코드로만
# 맞춰 둔 경로는 실제로 틀린다. 자세한 내용은 각 항목 주석에 있다
# ([#381](https://github.com/ensky0/tildaz/issues/381)).
#
# | 확인한 것 | 결과 |
# |---|---|
# | Windows: `kill` 이 powershell 홀더를 죽이는지 | ✅ 죽인다 (MSYS PID 와 Windows PID 가 다른데도) |
# | Windows: CPU 를 최고 성능으로 | ❌ 레버가 틀렸다 — 구성표가 아니라 **전원 모드**다 (`hygiene_overlay_set`) |
# | Windows: 배경 앱 최소화 | ❌ 아예 없었다 — `hygiene_minimize_win32` 로 넣었다 |
# | Windows: `hygiene_check` 통과 | ❌ KDE 가 아니라는 이유만으로 **항상 실패**했다 (`hygiene_can_minimize`) |
# | macOS: `caffeinate` 가 붙는지 | ✅ 홀더가 살아 있고 `kill` 로 정리된다 |
# | macOS: 배경 앱 최소화 | ❌ 아예 없었다 — `hygiene_minimize_macos` 로 넣었다. `hygiene_can_minimize` 에도 macOS 가 빠져 **Windows 와 똑같이 항상 실패**했다 |

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
HYG_OVERLAY_SAVED=""
HYG_MINIMIZED=0
HYG_POWER="?"
HYG_REFRESH="?"
HYG_PROFILE="?"

# Windows 의 "최고 성능" 전원 모드 (overlay) GUID. 아래 `hygiene_overlay_set` 주석 참고.
HYG_OVERLAY_MAX=ded574b5-45a0-4f42-8737-46345c09c238

# KDE 인지. Linux 에서 창 최소화는 **KDE 만** 한다 (개발 중에 잠깐 쓰는 도구라 sway ·
# Hyprland · GNOME 까지 갖추지 않는다 — 사용자 결정).
hygiene_is_kde() {
    [ "$HYG_PLATFORM" = linux ] || return 1
    case "${XDG_CURRENT_DESKTOP:-}" in *KDE*) ;; *) return 1 ;; esac
    command -v gdbus >/dev/null 2>&1 || return 1
    return 0
}

# 배경 앱을 **자동으로 내릴 수 있는 환경인지.** 여기서 1 이면 사람이 직접 내려야 하므로
# `hygiene_check` 가 경고한다.
#
# Windows 를 빠뜨리면 `hygiene_check` 가 **구조적으로 항상 실패**한다 — AC 도 주사율도
# 정상인데 "KDE 가 아니다" 하나로 걸려서, `compare-terminals.sh` 가 `--ignore-hygiene`
# 없이는 아예 안 돈다. 그 플래그는 AC · 주사율 · worker 검사까지 통째로 끄니까 이 파일이
# 막으려던 오염이 그대로 돌아온다 (#381 Windows 실기).
hygiene_can_minimize() {
    hygiene_is_kde && return 0
    [ "$HYG_PLATFORM" = windows ] && return 0
    [ "$HYG_PLATFORM" = macos ] && return 0
    return 1
}

# 평소 쓰는 worker 를 이름으로 죽인다. 떠 있지 않아도 성공으로 친다 (호출자가 매번
# 분기하지 않게).
#
# `pkill` 을 POSIX 쪽에만 쓴다 — **Git Bash 에는 없다.** Windows 는 `taskkill` 이고,
# `//IM` 은 MSYS 의 경로 변환을 피하려고 슬래시를 겹친 것이다 (한 겹이면 `/IM` 이
# 경로로 바뀌어 인자가 통째로 안 먹는다 — `powercfg` 에서 실제로 그랬다).
hygiene_kill_worker() {
    if [ "$HYG_PLATFORM" = windows ]; then
        _pids=$(powershell -NoProfile -Command "(Get-Process tildaz -ErrorAction SilentlyContinue).Id -join ' '" 2>/dev/null | tr -d '\r')
        [ -n "$_pids" ] || return 0
        taskkill //IM tildaz.exe //F >/dev/null 2>&1 || true
    else
        _pids=$(pgrep -x tildaz 2>/dev/null | tr '\n' ' ')
        [ -n "$_pids" ] || return 0
        command -v pkill >/dev/null 2>&1 && pkill -x tildaz >/dev/null 2>&1 || true
    fi
    echo "평소 쓰는 TildaZ worker 를 종료했어요 (pid $_pids · 측정 위생). 끝나도 다시 띄우지 않아요."
}

# Windows 의 전원 **모드** (overlay) 를 읽고 쓴다 — Linux 의 `powerprofilesctl get` / `set`
# 에 대응한다. `powercfg` 를 쓰지 않는 이유가 둘이다 (#381 Windows 실기).
#
#   - **Windows 11 에는 고성능 전원 구성표가 없다.** `powercfg /list` 에 "균형 조정" 하나뿐이고
#     예전 코드가 쓰던 GUID `8c5e7fda-…` 는 목록에 없다. 그래서 *"설정에서 직접 골라요"* 라는
#     안내는 **존재하지 않는 항목**을 가리키고 있었다.
#   - **`powercfg` 에 overlay 명령이 없다.** `/overlaylist` 는 `매개 변수가 잘못되었습니다` 로
#     떨어지고 `powercfg /?` 에도 항목이 없다. 문서화되지 않은 `powrprof.dll` export 를 직접 부른다.
#
# 알려진 값: `00000000-…` 균형(기본) · `ded574b5-…` 최고 성능 · `961cc777-…` 최고의 전원 효율.
hygiene_overlay_get() {
    powershell -NoProfile -Command "Add-Type -Namespace H -Name G -MemberDefinition '[DllImport(\"powrprof.dll\")] public static extern uint PowerGetEffectiveOverlayScheme(out System.Guid g);'; \$g = [System.Guid]::Empty; if ([H.G]::PowerGetEffectiveOverlayScheme([ref] \$g) -eq 0) { \$g.ToString() }" 2>/dev/null | tr -d '\r\n '
}

hygiene_overlay_set() {
    powershell -NoProfile -Command "Add-Type -Namespace H -Name S -MemberDefinition '[DllImport(\"powrprof.dll\")] public static extern uint PowerSetActiveOverlayScheme(System.Guid g);'; exit ([int][H.S]::PowerSetActiveOverlayScheme([System.Guid]'$1'))" >/dev/null 2>&1
}

# 열려 있는 창을 전부 최소화한다 (Windows). KDE 쪽 `hygiene_minimize_windows` 와 같은
# 의미다. 예전 `measure-repeat.ps1` 이 자기 안에서 부르던 COM 호출을 여기로 들여왔다.
hygiene_minimize_win32() {
    powershell -NoProfile -Command "(New-Object -ComObject Shell.Application).MinimizeAll()" >/dev/null 2>&1
}

# 보이는 앱을 전부 **숨긴다** (macOS). KDE 의 `minimized = true` · Windows 의 `MinimizeAll`
# 과 같은 자리다.
#
# **최소화가 아니라 hide (Cmd+H) 인 이유** — 목적이 "창을 치우는 것" 이 아니라 **그리기를
# 멈추는 것**이다. 숨긴 앱은 화면에 없으니 갱신하지 않는다. macOS 에서 창 단위 최소화는
# 앱마다 창 목록을 뒤져야 하는데 hide 는 프로세스 단위 한 번이라 더 단순하기도 하다.
#
# **Mission Control 의 Show Desktop 을 쓰지 않는 이유는 KDE 와 같다** — 그건 상태 토글이라
# 측정 창이 뜨는 순간 해제된다. hide 는 토글이 아니라 명령이라 새로 뜨는 창에 영향이 없다.
#
# `Finder` 는 뺀다. 데스크톱을 그리는 프로세스라 숨겨도 배경은 남고, 목록에 항상 있어서
# 매번 헛일이 된다.
#
# **Automation 권한이 필요하다.** 없으면 osascript 가 실패하고 (-1743) 호출자가 경고를 낸다 —
# 시스템 설정 → 개인정보 보호 및 보안 → 자동화 에서 이 터미널에 System Events 를 허용한다.
hygiene_minimize_macos() {
    osascript -e 'tell application "System Events" to set visible of (every process whose visible is true and name is not "Finder") to false' >/dev/null 2>&1
}

# 비교 대상 터미널 중 **지금 떠 있는 것**의 이름을 낸다 (#414). 없으면 빈 문자열이다.
#
# **왜 hide 로는 부족한가.** 배경 앱 최소화 (`hygiene_minimize_*`) 는 *그리기* 를 멈추는
# 수단이지 프로세스를 없애는 게 아니다. 터미널은 사용자가 빌드 · 로그 같은 것을 띄워 둔 채
# 두는 앱이라, 숨겨도 그 안의 프로그램은 계속 CPU 를 쓴다.
#
# **그리고 둘은 hide 로 아예 못 막는다.** `Terminal.app` (`do script`) 과 `iTerm2`
# (`create window`) 는 **이미 떠 있는 앱 프로세스에 창을 붙이는** 방식이라, 우리 측정 창이
# 사용자 창과 *같은 프로세스* 안에서 그려진다. 게다가 창을 만드는 순간 그 앱의 hide 가
# 풀린다. 같은 함정을 wezterm 이 먼저 만났고 `--always-new-process` 로 피했다
# (`compare-terminals.sh` 의 wezterm 절) — 그 플래그에 해당하는 것이 이 둘에는 없다.
#
# **이름은 각 앱의 실행 파일 이름이다.** 이 머신에서 `Terminal` · `iTerm2` 는 `pgrep -x` 로
# 잡히는 것을 확인했고 (macOS, 2026-08-10), 나머지 넷은 각 앱의 표준 이름이라 **미검증**이다.
# 틀리면 검사가 조용히 통과하므로, 대상을 늘릴 때는 실기에서 한 번 찍어 본다.
#
# **conhost 는 목록에 없다** — Windows 에서 이 스크립트를 돌리는 Git Bash 자신이 conhost
# 안에서 돌아 **항상 걸린다.** conhost 측정은 회차마다 새 콘솔을 띄우므로 기존 창과 프로세스가
# 갈린다.
hygiene_running_terminals() {
    case "$HYG_PLATFORM" in
        macos)   _hyg_terms="Terminal iTerm2 kitty alacritty wezterm-gui ghostty" ;;
        linux)   _hyg_terms="alacritty kitty wezterm-gui ghostty foot" ;;
        windows) _hyg_terms="alacritty wezterm-gui WindowsTerminal" ;;
        *)       return 0 ;;
    esac
    if [ "$HYG_PLATFORM" = windows ]; then
        # 한 번에 묻는다 — 이름마다 powershell 을 띄우면 그것만으로 몇 초가 든다.
        powershell -NoProfile -Command \
            "(Get-Process $(echo "$_hyg_terms" | tr ' ' ',') -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique) -join ' '" \
            2>/dev/null | tr -d '\r'
    else
        _hyg_found=""
        for _hyg_t in $_hyg_terms; do
            pgrep -x "$_hyg_t" >/dev/null 2>&1 && _hyg_found="$_hyg_found $_hyg_t"
        done
        printf '%s' "${_hyg_found# }"
    fi
}

# --- 검사 -----------------------------------------------------------------
#
# 값을 `HYG_*` 에 채우고, 측정을 망칠 것이 있으면 경고를 stderr 로 내고 1 을 돌려준다.
# 호출자가 `--ignore-hygiene` 같은 우회를 줄지 결정한다.
hygiene_check() {
    _warn=""

    case "$HYG_PLATFORM" in
        linux)
            # **배터리가 있는 기기에서만 AC 를 따진다.** 데스크탑 · 미니PC 는
            # `/sys/class/power_supply/` 가 아예 비어 있어서 (Firebat ZY-A8 에서 실측)
            # Mains 를 못 찾고 `battery` 로 판정했고, 그 오탐 하나로 `hygiene_check` 가
            # **구조적으로 항상 실패**했다 — Windows 가 목록에서 빠져 있던 것
            # (`hygiene_can_minimize`) 과 같은 종류의 함정이다. 경고의 취지는 *"배터리
            # 스로틀링 · 패널 강등"* 인데 배터리가 없으면 그 위험 자체가 없다.
            _ac=0
            _batt_seen=0
            for _p in /sys/class/power_supply/*/; do
                [ -r "$_p/type" ] || continue
                case "$(cat "$_p/type")" in
                    Battery) _batt_seen=1; continue ;;
                    Mains) ;;
                    *) continue ;;
                esac
                [ "$(cat "$_p/online" 2>/dev/null || echo 0)" = 1 ] && _ac=1
            done
            if [ "$_batt_seen" = 0 ]; then
                HYG_POWER="AC (배터리 없음)"
            else
                HYG_POWER=$([ "$_ac" = 1 ] && echo AC || echo battery)
                [ "$_ac" = 1 ] || _warn="$_warn
AC 미연결 — 배터리에서는 스로틀링이 걸리고 패널이 낮은 주사율로 강등되기도 해요"
            fi

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
                # **최대는 "지금 쓰는 해상도" 안에서만 찾는다.** 모든 모드에서 찾으면
                # 저해상도 모드가 최대가 되어 늘 걸린다 — 3840x2160@60 인 화면이
                # `1280x1024@75.03` 때문에 *"최대는 75 Hz"* 로 잡혔다 (Firebat ZY-A8 실측).
                # 해상도를 바꾸는 건 측정 조건을 바꾸는 것이라 경고의 해법이 될 수 없다.
                _res=$(echo "$_ks" | tr ' ' '\n' | sed -n 's/^[0-9]*:\([0-9]*x[0-9]*\)@[0-9.]*\*.*$/\1/p' | head -1)
                _max=""
                [ -n "$_res" ] && _max=$(echo "$_ks" | tr ' ' '\n' |
                    sed -n "s/^[0-9]*:${_res}@\([0-9.]*\).*\$/\1/p" | sort -g | tail -1)
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
    # **우리 수치만** 최대 64 % 눌린다 (다른 넷은 +0.7~9 %). 자동화가 일부 환경에만 있다고
    # 해서 나머지에서 이 함정이 사라지는 게 아니다 — 규칙으로만 남기면 잊는다.
    if ! hygiene_can_minimize; then
        _warn="$_warn
배경 앱을 자동으로 못 내려요 (KDE · macOS · Windows 에서만 해요) — 브라우저 · 에디터를 직접 최소화해요 (우리 수치만 최대 64 % 눌려요)"
    fi

    # 비교 대상 터미널은 **떠 있으면 안 된다** (#414). 이유는 `hygiene_running_terminals`
    # 주석에 있다. 자동으로 닫지 않는다 — worker 와 달리 **사용자의 작업 창**이라 없애면
    # 안 된다 (배경 앱을 최소화만 하고 닫지 않는 것과 같은 이유다).
    _terms=$(hygiene_running_terminals)
    if [ -n "$_terms" ]; then
        _warn="$_warn
비교 대상 터미널이 떠 있어요: $_terms — 측정 전에 종료해요 (숨기는 것으로는 부족해요)"
        _warn="$_warn
  이 스크립트는 대상이 아닌 터미널에서 돌려요 (VS Code 터미널 · SSH 등)"
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
    # ⓪ 평소 쓰는 worker 를 내린다. 측정 인스턴스는 worker lock 을 잡지 않아 충돌 없이 함께
    #    뜨므로 (#382) 그냥 두면 **둘 다 떠 있는 채로** 재게 된다.
    #
    #    **검사가 아니라 종료다.** 예전에는 `hygiene_check` 가 발견하면 "먼저 내려요" 로
    #    멈췄는데, 이유가 없었다 — 이 파일을 쓰는 세 도구가 전부 내부 측정 도구라 "모르는
    #    사람의 창이 닫힌다" 는 위험이 없고, 규칙으로만 두면 실제로 잊는다 (#381 에서 그대로
    #    여러 회차를 돌렸다). 터미널 비교에서는 다른 대상에 없는 백그라운드 인스턴스가 우리에게만
    #    붙어 **공정성**이 깨지고, 배분 측정에서는 CPU · 렌더를 나눠 써 **값이 눌린다** — 형태가
    #    다를 뿐 결론이 같다.
    #
    #    **끝나고 다시 띄우지 않는다** — 필요하면 사용자가 직접 띄운다 (AGENTS.md 명시 지시).
    hygiene_kill_worker

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
            # 전원 **모드** 를 최고 성능으로. Linux 의 `powerprofilesctl` 과 같은 자리다.
            # 실패는 **조용히 넘기지 않는다** — CPU 가 안 올라간 채로 통과하면 정확히 이
            # 파일이 막으려던 종류의 오염이 된다.
            HYG_OVERLAY_SAVED=$(hygiene_overlay_get)
            if [ "$HYG_OVERLAY_SAVED" = "$HYG_OVERLAY_MAX" ]; then
                HYG_OVERLAY_SAVED=""  # 원래 그랬으니 되돌릴 것이 없다
                HYG_PROFILE=max-performance
            elif [ -n "$HYG_OVERLAY_SAVED" ] && hygiene_overlay_set "$HYG_OVERLAY_MAX"; then
                HYG_PROFILE=max-performance
            else
                HYG_OVERLAY_SAVED=""
                echo "⚠ 전원 모드를 최고 성능으로 못 바꿨어요 — 설정 → 시스템 → 전원 및 배터리 → 전원 모드 에서 직접 골라요" >&2
            fi
            ;;
        # macOS 에는 대응 경로가 없다. `?` 가 아니라 `n/a` 로 찍어서 **못 읽은 것**과
        # **원래 없는 것**을 구분한다.
        macos) HYG_PROFILE=n/a ;;
    esac

    # ③ 배경 앱 최소화 — KDE · Windows. 배경에서 그리는 앱이 있으면 **우리 수치만** 최대
    #    64 % 눌린다 (다른 넷은 +0.7~9 %). 그 함정이 실측된 머신이 Intel i5-1240P 이고,
    #    Windows 와 Linux 를 같은 기기에서 재는 이상 양쪽 다 있어야 한다.
    #
    #    **되돌리지 않는다** (사용자 결정) — 측정이 끝나면 창은 내려간 채로 두고 필요하면
    #    직접 올린다.
    #    최소화 실패는 **경고지 중단이 아니다.** 그런데 이 `if` 가 `hygiene_begin` 의 **마지막
    #    문장**이라, 예전처럼 `f && HYG_MINIMIZED=1` 로 쓰면 실패한 순간 그 값이 함수 반환값이
    #    되고 호출자의 `set -e` 가 **측정을 통째로 죽인다.** (같은 `&&` 라도 *최상위* 문장이면
    #    안 죽는다 — POSIX 는 AND-OR 리스트의 마지막이 아닌 명령만 -e 에서 빼는데, 함수 반환값은
    #    그 예외에 안 들어간다. 실측으로 갈라 확인했다.) 창이 안 내려간 건 사람이 직접 내리면
    #    되는 일이라 여기서 멈출 이유가 없다.
    if hygiene_is_kde; then
        if hygiene_minimize_windows; then HYG_MINIMIZED=1; else
            echo "⚠ 창을 자동으로 못 내렸어요 (KWin 스크립팅 실패) — 직접 최소화해요" >&2
        fi
    elif [ "$HYG_PLATFORM" = windows ]; then
        if hygiene_minimize_win32; then HYG_MINIMIZED=1; else
            echo "⚠ 창을 자동으로 못 내렸어요 (MinimizeAll 실패) — 직접 최소화해요" >&2
        fi
    elif [ "$HYG_PLATFORM" = macos ]; then
        if hygiene_minimize_macos; then HYG_MINIMIZED=1; else
            echo "⚠ 창을 자동으로 못 숨겼어요 (System Events 실패) — 시스템 설정 → 개인정보 보호 및 보안 → 자동화 에서 허용하거나 직접 숨겨요 (Cmd+Option+H)" >&2
        fi
    fi
}

# 열려 있는 일반 창을 **하나씩 최소화**한다 (KWin 스크립팅). Windows 쪽
# `hygiene_minimize_win32` 의 `Shell.Application.MinimizeAll` 과 같은 의미다.
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
    if [ -n "$HYG_OVERLAY_SAVED" ]; then
        hygiene_overlay_set "$HYG_OVERLAY_SAVED" || true
        HYG_OVERLAY_SAVED=""
    fi
    # 창은 되돌리지 않는다 (`hygiene_begin` ③ 주석). CPU 프로파일은 되돌린다 — 그건
    # 남겨 두면 배터리를 계속 먹는다.
}
