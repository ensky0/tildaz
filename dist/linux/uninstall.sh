#!/usr/bin/env bash
# tildaz Linux user-level uninstall — install.sh 의 역동작.
#
# 삭제 대상:
#   ~/.local/share/applications/tildaz.desktop
#   ~/.local/share/icons/hicolor/scalable/apps/tildaz.svg
#   ~/.local/share/autostart/tildaz.desktop  (있으면 — autostart enabled 시)
#
# 보존:
#   ~/.config/tildaz/config.json   (사용자 설정 — 명시 삭제 옵션 안 만들음)
#   ~/.local/state/tildaz/         (log)
#
# 사용법:
#   bash dist/linux/uninstall.sh

set -euo pipefail

DESKTOP="$HOME/.local/share/applications/tildaz.desktop"
ICON="$HOME/.local/share/icons/hicolor/scalable/apps/tildaz.svg"
AUTOSTART="$HOME/.config/autostart/tildaz.desktop"

removed=0
for f in "$DESKTOP" "$ICON" "$AUTOSTART"; do
    if [[ -f "$f" ]]; then
        rm "$f"
        echo "Removed: $f"
        removed=$((removed + 1))
    fi
done

if [[ "$removed" -eq 0 ]]; then
    echo "Nothing to remove (already uninstalled)."
fi

update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

echo ""
echo "Preserved (delete manually if desired):"
echo "  ~/.config/tildaz/        (config)"
echo "  ~/.local/state/tildaz/   (log)"
