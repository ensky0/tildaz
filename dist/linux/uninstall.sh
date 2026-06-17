#!/usr/bin/env bash
# tildaz Linux user-level uninstall — install.sh 의 역동작.
#
# 삭제 대상:
#   ~/.local/share/applications/tildaz.desktop
#   ~/.local/share/icons/hicolor/scalable/apps/tildaz.svg
#   ~/.config/autostart/tildaz.desktop  (있으면 — autostart enabled 시)
#   ~/.local/bin/tildaz  (symlink 일 때만 — 사용자가 둔 실제 파일은 보존)
#   ~/.config/sway/config 의 tildaz 블록 (install.sh 가 넣은 marker+exec 2줄만.
#     파일/본문은 보존, marker 없는 사용자 작성 줄은 안 건드림)
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
SYMLINK="$HOME/.local/bin/tildaz"
SWAY_CFG="$HOME/.config/sway/config"
# install.sh 와 *글자 단위로 동일해야* 매칭됨 (블록 식별 marker).
SWAY_MARKER="# tildaz autostart (added by install.sh — uninstall.sh removes this)"

removed=0
for f in "$DESKTOP" "$ICON" "$AUTOSTART"; do
    if [[ -f "$f" ]]; then
        rm "$f"
        echo "Removed: $f"
        removed=$((removed + 1))
    fi
done

# ~/.local/bin/tildaz — symlink 일 때만 제거. 사용자가 직접 둔 실제 binary 는 보존.
if [[ -L "$SYMLINK" ]]; then
    rm "$SYMLINK"
    echo "Removed: $SYMLINK (symlink)"
    removed=$((removed + 1))
elif [[ -e "$SYMLINK" ]]; then
    echo "Preserved: $SYMLINK (실제 파일 — install.sh 가 만든 게 아님)"
fi

# ~/.config/sway/config — install.sh 가 넣은 tildaz 블록(marker 줄 + 바로 다음
# exec 줄)만 제거. awk 의 exact-string 비교라 정규식 escape 불필요. marker 없으면
# (사용자가 직접 쓴 exec 등) 손대지 않는다. 파일 본문/나머지는 그대로 보존.
if [[ -f "$SWAY_CFG" ]] && grep -qF "$SWAY_MARKER" "$SWAY_CFG"; then
    tmp="$SWAY_CFG.tildaz-uninstall-tmp"
    awk -v m="$SWAY_MARKER" 'skip { skip=0; next } $0 == m { skip=1; next } { print }' "$SWAY_CFG" > "$tmp"
    mv "$tmp" "$SWAY_CFG"
    echo "Removed: tildaz autostart block in $SWAY_CFG (marker + exec 2줄)"
    removed=$((removed + 1))
fi

if [[ "$removed" -eq 0 ]]; then
    echo "Nothing to remove (already uninstalled)."
fi

update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

echo ""
echo "Preserved (delete manually if desired):"
echo "  ~/.config/tildaz/        (config)"
echo "  ~/.local/state/tildaz/   (log)"
