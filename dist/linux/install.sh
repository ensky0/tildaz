#!/usr/bin/env bash
# tildaz Linux user-level install — `~/.local` 과 (sway 사용 시) `~/.config/sway`
# 만 건드림 (no sudo).
#
# 산출물:
#   ~/.local/share/applications/tildaz.desktop
#     ← dist/linux/tildaz.desktop 의 __TILDAZ_EXE__ 를 binary 절대 경로로 치환
#   ~/.local/share/icons/hicolor/scalable/apps/tildaz.svg
#     ← docs/favicon.svg 그대로 복사 (mac AppIcon.icns / Windows tildaz.ico 와
#       동일 출처)
#   ~/.local/bin/tildaz  → binary symlink (PATH 노출 — dmenu 등 launcher 에서
#     `tildaz` 로 실행/재실행). ln -sf 라 재실행 idempotent.
#   ~/.config/sway/config  (sway 는 XDG autostart 미지원 → sway 세션 자동실행엔
#     이 파일의 exec 가 필요. 없으면 stock 상속(include)+tildaz 블록 생성, 있으면
#     tildaz 블록(marker+exec 2줄)만 append. 기존 본문은 덮지 않음)
#   ~/.config/hypr/{hyprland.lua|hyprland.conf}  (Hyprland 자동실행 + hotkey bind —
#     Lua 면 hl.on+hl.bind, hyprlang 이면 exec-once+bind append. 둘 다 없으면
#     `Hyprland --verify-config` 로 기본 config 생성 후 append. 미설치면 안내. 본문 안 덮음)
#
# desktop database / icon cache refresh 는 best-effort (없으면 skip).
#
# binary 자체는 build 결과물이거나 사용자가 PATH 위치로 옮긴 것 — 이 script 는
# 옮기지 않는다. `--exe` 옵션으로 명시 가능, 없으면 `realpath zig-out/bin/tildaz`
# 시도.
#
# 사용법:
#   bash dist/linux/install.sh                    # repo zig-out/bin/tildaz
#   bash dist/linux/install.sh --exe /usr/bin/tildaz
#
# KDE Plasma 6 환경: install 후 KRunner (Alt+F2) 또는 Application Menu 에서
# "TildaZ" 검색 + 실행 → portal-kde 가 app_id=tildaz 인식. terminal 직접 실행
# 시 portal GlobalShortcuts 동작 안 함 (LINUX.md "KDE Plasma 6 install" 섹션).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TILDAZ_EXE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --exe) TILDAZ_EXE="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$TILDAZ_EXE" ]]; then
    # tar.gz release tarball 안 install.sh — binary 가 script 와 같은 폴더에 있음.
    # repo dev 환경 — zig-out/bin/tildaz.
    if [[ -x "$SCRIPT_DIR/tildaz" ]]; then
        TILDAZ_EXE="$SCRIPT_DIR/tildaz"
    else
        TILDAZ_EXE="$REPO_ROOT/zig-out/bin/tildaz"
    fi
fi

if [[ ! -x "$TILDAZ_EXE" ]]; then
    echo "ERROR: tildaz binary not found at: $TILDAZ_EXE" >&2
    echo "       Build first (zig build) or pass --exe /path/to/tildaz" >&2
    exit 1
fi
TILDAZ_EXE="$(realpath "$TILDAZ_EXE")"

APP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
mkdir -p "$APP_DIR" "$ICON_DIR"

DESKTOP_OUT="$APP_DIR/tildaz.desktop"
ICON_OUT="$ICON_DIR/tildaz.svg"

sed "s|__TILDAZ_EXE__|$TILDAZ_EXE|" "$SCRIPT_DIR/tildaz.desktop" > "$DESKTOP_OUT"
chmod 644 "$DESKTOP_OUT"

cp "$REPO_ROOT/docs/favicon.svg" "$ICON_OUT"
chmod 644 "$ICON_OUT"

# best-effort cache refresh — 없거나 실패해도 install 자체는 성공.
update-desktop-database "$APP_DIR" 2>/dev/null || true
gtk-update-icon-cache -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

# ~/.local/bin/tildaz symlink — dmenu 등 launcher 는 `.desktop` 이 아니라 $PATH
# 의 실행파일만 나열하므로, PATH 의 이 symlink 가 있어야 `tildaz` 로 실행/재실행
# 된다. ln -sf 라 재실행 idempotent.
BIN_LINK="$HOME/.local/bin/tildaz"
mkdir -p "$HOME/.local/bin"
ln -sf "$TILDAZ_EXE" "$BIN_LINK"

# ~/.config/sway/config — sway 는 XDG autostart(~/.config/autostart) 를 native 로
# 안 읽으므로 (설계상 autostart 부재), sway 세션 자동실행엔 sway config 의 `exec`
# 한 줄이 필요하다. 이 파일은 sway 만 읽어 Plasma/GNOME 등 다른 DE 세션에선 무시 —
# install 시점 세션 감지 없이 DE 왕복에 안전하고, 다른 DE 의 autostart 와 공존.
#
# tildaz 자동실행 블록 = marker 주석 + `exec` 2줄. marker 로 표시해 두면
# uninstall.sh 가 이 2줄만 정확히 찾아 제거하고 사용자 본문은 안 건드린다.
#   - config 없음 → stock 상속(`include`) + tildaz 블록 생성. `include` 필수 —
#     user config 가 생기면 sway 는 /etc 를 안 읽어, 빠지면 키바인딩 없는 먹통.
#   - config 있음 + tildaz 줄(marker 또는 exec) 없음 → tildaz 2줄 append
#     (`include` 는 안 붙임 — 기존 config 엔 이미 stock 설정이 있으므로).
#   - config 있음 + 이미 있음 → 변경 없음 (중복 방지). 기존 본문은 절대 안 덮음.
# 자동실행 블록 식별 marker — install.sh ↔ uninstall.sh 글자 단위 동일해야 매칭됨.
# sway/Hyprland 두 config 에 같은 marker 를 쓴다(파일은 따로 처리).
TILDAZ_MARKER="# tildaz autostart (added by install.sh — uninstall.sh removes this)"
SWAY_CFG="$HOME/.config/sway/config"
if [[ ! -e "$SWAY_CFG" ]]; then
    mkdir -p "$(dirname "$SWAY_CFG")"
    cat > "$SWAY_CFG" <<EOF
include /etc/sway/config
$TILDAZ_MARKER
exec $TILDAZ_EXE
EOF
    SWAY_MSG="$SWAY_CFG  (생성 — stock 상속 + tildaz 자동실행 블록)"
elif grep -qF -e "$TILDAZ_MARKER" "$SWAY_CFG" || grep -qE '^[[:space:]]*exec[[:space:]].*tildaz' "$SWAY_CFG"; then
    SWAY_MSG="$SWAY_CFG  (이미 tildaz 자동실행 줄 있음 — 변경 없음)"
else
    printf '\n%s\nexec %s\n' "$TILDAZ_MARKER" "$TILDAZ_EXE" >> "$SWAY_CFG"
    SWAY_MSG="$SWAY_CFG  (기존 config 에 tildaz 자동실행 2줄 append)"
fi

# ~/.config/hypr/ — Hyprland 자동실행(`exec-once`/`hl.on`) + hotkey bind. Hyprland 은
# XDG autostart 미지원이고 GlobalShortcuts portal 도 DE 전환에 불안정(#244)+anonymous
# shortcut 이라, hotkey 는 sway 처럼 compositor bind→`tildaz --toggle`(portal 우회)로 건다.
# Hyprland 0.55+ 는 기본 config 가 Lua(hyprland.lua), 구버전/사용자는 hyprlang(.conf):
#   - .conf → `exec-once = <bin>` + `bind = <mods>,<key>,exec,<bin> --toggle`            (주석 #)
#   - .lua  → `hl.on(...exec_cmd)` + `hl.bind("<key>", hl.dsp.exec_cmd("<bin> --toggle"))` (주석 --)
#   - 둘 다 없음 → Hyprland 설치돼 있으면 `Hyprland --verify-config` 로 기본 config 생성
#     (세션 안 띄움) 후 append. 미설치면 안내만 (`command -v` 로 먼저 걸러 안 깨짐).
# 기존 본문 안 건드리고 append 만. 각 줄 앞에 marker — uninstall 이 marker+다음줄 제거.
HYPR_DIR="$HOME/.config/hypr"
HYPR_CONF="$HYPR_DIR/hyprland.conf"
HYPR_LUA="$HYPR_DIR/hyprland.lua"
TILDAZ_MARKER_LUA="-- tildaz autostart (added by install.sh — uninstall.sh removes this)"

# tildaz config.hotkey ("f1" / "ctrl+grave" / "super+a" …, '+' 구분) → Hyprland bind 형식.
#   HYPR_BIND_CONF = hyprlang 1번 필드 "<mods>,<key>" (mods 공백구분)
#   HYPR_BIND_LUA  = lua "<mod + … + key>"
hypr_translate_hotkey() {
    local cfg="$HOME/.config/tildaz/config.json" hk="f1" v=""
    if [[ -f "$cfg" ]]; then
        v="$(grep -oE '"hotkey"[[:space:]]*:[[:space:]]*"[^"]*"' "$cfg" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)"$/\1/' || true)"
        if [[ -n "$v" ]]; then hk="$v"; fi
    fi
    local -a parts=() mods=(); local key="" tok hkey m
    IFS='+' read -ra parts <<< "$hk"
    for tok in "${parts[@]}"; do
        case "${tok,,}" in
            ctrl|control) mods+=("CTRL") ;;
            shift) mods+=("SHIFT") ;;
            alt) mods+=("ALT") ;;
            super|meta|logo|win) mods+=("SUPER") ;;
            "") ;;
            *) key="$tok" ;;
        esac
    done
    hkey="$key"
    if [[ "$key" =~ ^[a-zA-Z]$ || "$key" =~ ^[fF][0-9]+$ ]]; then hkey="${key^^}"; fi
    local conf_mods="" lua_combo=""
    for m in "${mods[@]}"; do conf_mods+="${conf_mods:+ }$m"; lua_combo+="$m + "; done
    HYPR_BIND_CONF="${conf_mods},${hkey}"
    HYPR_BIND_LUA="${lua_combo}${hkey}"
}

# config 에 marker+line 을 idempotent append (needle 정규식이 이미 있으면 skip → return 1).
append_marked() {
    local cfg="$1" marker="$2" needle="$3" line="$4"
    grep -qE "$needle" "$cfg" && return 1
    printf '\n%s\n%s\n' "$marker" "$line" >> "$cfg"
    return 0
}

hypr_translate_hotkey
HYPR_MSG=""
if [[ ! -f "$HYPR_CONF" && ! -f "$HYPR_LUA" ]]; then
    if command -v Hyprland >/dev/null 2>&1; then
        mkdir -p "$HYPR_DIR"
        Hyprland --verify-config >/dev/null 2>&1 || true   # config 없으면 기본 생성
    else
        HYPR_MSG="Hyprland 자동실행: Hyprland 미설치 — 나중에 Hyprland 설치해 쓸 거면 tildaz 를 다시 설치하면 자동실행+단축키가 구성됩니다."
    fi
fi
hypr_added=()
if [[ -f "$HYPR_CONF" ]]; then
    # autogenerated 경고 배너(상단 빨간 overlay)가 top-anchored 드롭다운 위를 가리므로
    # hyprlang 의 `autogenerated = 1` 플래그 줄을 제거한다 (.lua 의 hl.config 배너와 동일
    # 처리). 이 줄은 Hyprland 자동생성 config 에만 있고 사용자가 손댄 config 엔 없다
    # (배너 안내대로 지웠을 것) → "생성된 config 한정" 충족. 제거는 idempotent.
    if grep -qE '^[[:space:]]*autogenerated[[:space:]]*=' "$HYPR_CONF"; then
        sed -i '/^[[:space:]]*autogenerated[[:space:]]*=/d' "$HYPR_CONF"
        hypr_added+=("배너제거")
    fi
    if append_marked "$HYPR_CONF" "$TILDAZ_MARKER" '^[[:space:]]*exec-once[[:space:]]*=.*tildaz' "exec-once = $TILDAZ_EXE"; then hypr_added+=("autostart"); fi
    if append_marked "$HYPR_CONF" "$TILDAZ_MARKER" '^[[:space:]]*bind[[:space:]]*=.*tildaz' "bind = ${HYPR_BIND_CONF},exec,$TILDAZ_EXE --toggle"; then hypr_added+=("hotkey"); fi
    if [[ ${#hypr_added[@]} -gt 0 ]]; then HYPR_MSG="$HYPR_CONF  (hyprlang ${hypr_added[*]} 추가)"; else HYPR_MSG="$HYPR_CONF  (이미 설정됨 — 변경 없음)"; fi
elif [[ -f "$HYPR_LUA" ]]; then
    # autogenerated 경고 배너(상단 overlay)가 top-anchored 드롭다운 위를 가리므로
    # 그 플래그 줄을 제거한다. 이 줄(`hl.config({ autogenerated = true }) -- remove
    # this line ...`)은 Hyprland 자동생성물에만 있고 사용자가 손댄 config 엔 없다
    # (배너 안내대로 지웠을 것) → "생성된 config 한정" 충족. 제거는 idempotent.
    if grep -qE 'hl\.config\(.*autogenerated' "$HYPR_LUA"; then
        sed -i '/hl\.config(.*autogenerated/d' "$HYPR_LUA"
        hypr_added+=("배너제거")
    fi
    if append_marked "$HYPR_LUA" "$TILDAZ_MARKER_LUA" 'hl\.on\(.*tildaz' "hl.on(\"hyprland.start\", function() hl.exec_cmd(\"$TILDAZ_EXE\") end)"; then hypr_added+=("autostart"); fi
    if append_marked "$HYPR_LUA" "$TILDAZ_MARKER_LUA" 'hl\.bind\(.*tildaz' "hl.bind(\"$HYPR_BIND_LUA\", hl.dsp.exec_cmd(\"$TILDAZ_EXE --toggle\"))"; then hypr_added+=("hotkey"); fi
    if [[ ${#hypr_added[@]} -gt 0 ]]; then HYPR_MSG="$HYPR_LUA  (Lua ${hypr_added[*]} 추가)"; else HYPR_MSG="$HYPR_LUA  (이미 설정됨 — 변경 없음)"; fi
fi

# GNOME Shell extension — GNOME(mutter) 은 wlr-layer-shell 미지원이라 drop-down
# placement / lifecycle(launch·show·hide) 을 extension 이 담당한다 (#228). GNOME
# 환경에서만 의미(다른 DE 는 gnome-shell 이 없어 무시). 복사는 항상, enable 은
# gnome-extensions 명령이 있을 때. Wayland 는 enable 후 로그아웃/로그인해야 적용.
EXT_UUID="tildaz@ensky0.github.io"
EXT_SRC="$SCRIPT_DIR/gnome-extension/$EXT_UUID"
EXT_MSG=""
if [[ -d "$EXT_SRC" ]]; then
    EXT_DST="$HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
    mkdir -p "$EXT_DST"
    cp -r "$EXT_SRC/." "$EXT_DST/"
    if command -v glib-compile-schemas >/dev/null 2>&1 && [[ -d "$EXT_DST/schemas" ]]; then
        glib-compile-schemas "$EXT_DST/schemas" 2>/dev/null || true
    fi
    if command -v gnome-extensions >/dev/null 2>&1; then
        gnome-extensions enable "$EXT_UUID" 2>/dev/null || true
        EXT_MSG="$EXT_DST  (enabled — GNOME 로그아웃/로그인 후 적용)"
    else
        EXT_MSG="$EXT_DST  (복사됨 — GNOME 세션에서: gnome-extensions enable $EXT_UUID + 재로그인)"
    fi
fi

# Cinnamon extension — Cinnamon(muffin) 도 wlr-layer-shell 미지원이라 drop-down
# placement / hotkey 토글을 extension 이 담당한다 (#229, GNOME 과 동일 패턴, Cjs).
# Cinnamon on Wayland 세션에서만 의미 (tildaz=Wayland client → X11 Cinnamon 세션엔
# 못 뜸; 다른 DE 는 cinnamon 셸이 없어 무시). 복사는 항상, enable 은 gsettings
# org.cinnamon enabled-extensions 에 uuid 추가 (스키마 있을 때만). 재로그인 후 적용.
CIN_UUID="tildaz@ensky0.github.io"
CIN_SRC="$SCRIPT_DIR/cinnamon-extension/$CIN_UUID"
CIN_MSG=""
if [[ -d "$CIN_SRC" ]]; then
    CIN_DST="$HOME/.local/share/cinnamon/extensions/$CIN_UUID"
    mkdir -p "$CIN_DST"
    cp -r "$CIN_SRC/." "$CIN_DST/"
    if command -v gsettings >/dev/null 2>&1 && gsettings writable org.cinnamon enabled-extensions >/dev/null 2>&1; then
        CUR="$(gsettings get org.cinnamon enabled-extensions 2>/dev/null || echo '@as []')"
        if [[ "$CUR" == *"'$CIN_UUID'"* ]]; then
            CIN_MSG="$CIN_DST  (이미 enabled — Cinnamon Wayland 재로그인 후 적용)"
        elif command -v python3 >/dev/null 2>&1; then
            # 기존 목록 보존 + uuid 추가 (gsettings 의 @as [] / ['a','b'] 둘 다 파싱).
            NEW="$(python3 - "$CUR" "$CIN_UUID" <<'PY'
import sys
cur, uuid = sys.argv[1].strip(), sys.argv[2]
i = cur.find('[')
items = []
if i >= 0:
    body = cur[i + 1:cur.rfind(']')]
    items = [x.strip().strip("'\"") for x in body.split(',') if x.strip()]
if uuid not in items:
    items.append(uuid)
print('[' + ', '.join("'%s'" % x for x in items) + ']')
PY
)"
            if gsettings set org.cinnamon enabled-extensions "$NEW" 2>/dev/null; then
                CIN_MSG="$CIN_DST  (enabled — Cinnamon Wayland 세션 재로그인 후 적용)"
            else
                CIN_MSG="$CIN_DST  (복사됨 — 시스템 설정 > 확장에서 활성화 + 재로그인)"
            fi
        else
            CIN_MSG="$CIN_DST  (복사됨 — python3 없음, 시스템 설정 > 확장에서 활성화 + 재로그인)"
        fi
    else
        CIN_MSG="$CIN_DST  (복사됨 — Cinnamon 아님/gsettings 미설치, 다른 DE 에선 무시)"
    fi
fi

echo "Installed:"
echo "  $DESKTOP_OUT  (Exec=$TILDAZ_EXE)"
echo "  $ICON_OUT"
echo "  $BIN_LINK -> $TILDAZ_EXE"
echo "  $SWAY_MSG"
[[ -n "$HYPR_MSG" ]] && echo "  $HYPR_MSG"
[[ -n "$EXT_MSG" ]] && echo "  $EXT_MSG"
[[ -n "$CIN_MSG" ]] && echo "  $CIN_MSG"
echo ""
echo "Next:"
echo "  - KDE Plasma 6: Alt+F2 → 'TildaZ' 또는 메뉴에서 실행 (portal app_id 인식)"
echo "  - GNOME: 위 extension 이 drop-down 위치/단축키/자동시작을 담당."
echo "           Wayland 라 로그아웃→로그인해야 extension 이 활성화됨."
echo "  - Cinnamon: 위 extension 이 drop-down 위치/단축키를 담당 (Cinnamon on Wayland)."
echo "              Wayland 라 로그아웃→로그인해야 활성화됨. X11 세션엔 tildaz 안 뜸."
echo "  - sway: ~/.config/sway/config 의 exec 로 자동실행(없으면 위에서 생성)."
echo "          로그인 후 hotkey(기본 F1) 토글. exit 후 재실행은 launcher 에서 'tildaz'."
echo "  - Hyprland: layer-shell drop-down. hotkey 는 config bind→'tildaz --toggle'(portal 우회, #244 무관)."
echo "          위에서 hyprland.lua/.conf 에 자동실행+단축키 추가 → 적용하려면 'hyprctl reload' 또는 재로그인."
echo "  - 기타 wlroots: layer-shell drop-down. 자동실행은 compositor 의 exec 류로 직접."
echo "  - config: ~/.config/tildaz/config.json (auto_start/hidden_start/hotkey/위치)"
echo "  - autostart: 비-GNOME 은 config.auto_start=true 면 ~/.config/autostart/"
echo "    tildaz.desktop 자동 생성. GNOME 은 extension 이 담당하므로 그 파일을 삭제함."
