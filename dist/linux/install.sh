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
    TILDAZ_EXE="$REPO_ROOT/zig-out/bin/tildaz"
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

echo "Installed:"
echo "  $DESKTOP_OUT  (Exec=$TILDAZ_EXE)"
echo "  $ICON_OUT"
echo ""
echo "Next:"
echo "  - KDE Plasma 6: Alt+F2 → 'TildaZ' 또는 메뉴에서 실행 (portal app_id 인식)"
echo "  - GNOME/Cinnamon/XFCE: Activities / 메뉴에서 'TildaZ' 검색 후 실행"
echo "  - config: ~/.config/tildaz/config.json 자동 생성 (없으면)"
echo "  - autostart: config.auto_start=true 면 다음 로그인부터 자동 시작"
echo "    (~/.config/autostart/tildaz.desktop)"
