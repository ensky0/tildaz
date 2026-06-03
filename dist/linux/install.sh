#!/usr/bin/env bash
# tildaz Linux user-level install — `~/.local/share` 만 건드림 (no sudo).
#
# 산출물:
#   ~/.local/share/applications/tildaz.desktop
#     ← dist/linux/tildaz.desktop 의 __TILDAZ_EXE__ 를 binary 절대 경로로 치환
#   ~/.local/share/icons/hicolor/scalable/apps/tildaz.svg
#     ← docs/favicon.svg 그대로 복사 (mac AppIcon.icns / Windows tildaz.ico 와
#       동일 출처)
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
[[ -n "$EXT_MSG" ]] && echo "  $EXT_MSG"
[[ -n "$CIN_MSG" ]] && echo "  $CIN_MSG"
echo ""
echo "Next:"
echo "  - KDE Plasma 6: Alt+F2 → 'TildaZ' 또는 메뉴에서 실행 (portal app_id 인식)"
echo "  - GNOME: 위 extension 이 drop-down 위치/단축키/자동시작을 담당."
echo "           Wayland 라 로그아웃→로그인해야 extension 이 활성화됨."
echo "  - Cinnamon: 위 extension 이 drop-down 위치/단축키를 담당 (Cinnamon on Wayland)."
echo "              Wayland 라 로그아웃→로그인해야 활성화됨. X11 세션엔 tildaz 안 뜸."
echo "  - sway/Hyprland/wlroots: layer-shell 로 바로 drop-down (extension 불요)"
echo "  - config: ~/.config/tildaz/config.json (auto_start/hidden_start/hotkey/위치)"
echo "  - autostart: 비-GNOME 은 config.auto_start=true 면 ~/.config/autostart/"
echo "    tildaz.desktop 자동 생성. GNOME 은 extension 이 담당하므로 그 파일을 삭제함."
