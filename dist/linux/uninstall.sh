#!/usr/bin/env bash
# tildaz Linux user-level uninstall — install.sh 의 역동작.
#
# 삭제 대상:
#   ~/.local/share/applications/tildaz.desktop
#   ~/.local/share/applications/tildaz.instanceN.desktop
#   ~/.local/share/icons/hicolor/scalable/apps/tildaz.svg
#   ~/.config/autostart/tildaz.desktop  (있으면 — autostart enabled 시)
#   ~/.local/bin/tildaz  (symlink 일 때만 — 사용자가 둔 실제 파일은 보존)
#   GNOME / Cinnamon TildaZ extension
#   ~/.config/sway/config 의 tildaz 블록 (install.sh 가 넣은 marker+exec 2줄만.
#     파일/본문은 보존, marker 없는 사용자 작성 줄은 안 건드림)
#   ~/.config/hypr/{hyprland.conf,hyprland.lua} 의 tildaz 블록 (marker + 다음 줄
#     2줄만. .conf=exec-once / .lua=hl.on, 동일 규칙. 본문 보존)
#
# 보존:
#   ~/.config/tildaz/config_N.json  (사용자 설정 — 명시 삭제 옵션 안 만들음)
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
HYPR_CONF="$HOME/.config/hypr/hyprland.conf"
HYPR_LUA="$HOME/.config/hypr/hyprland.lua"
GNOME_EXT_UUID="tildaz@ensky0.github.io"
GNOME_EXT="$HOME/.local/share/gnome-shell/extensions/$GNOME_EXT_UUID"
CINNAMON_EXT_UUID="tildaz@ensky0.github.io"
CINNAMON_EXT="$HOME/.local/share/cinnamon/extensions/$CINNAMON_EXT_UUID"
# install.sh 와 *글자 단위로 동일해야* 매칭됨. sway/hyprlang(.conf) 는 `#` 주석,
# Hyprland Lua 는 `--` 주석이라 marker 가 두 가지.
TILDAZ_MARKER="# tildaz autostart (added by install.sh — uninstall.sh removes this)"
TILDAZ_MARKER_LUA="-- tildaz autostart (added by install.sh — uninstall.sh removes this)"

removed=0
for f in "$DESKTOP" "$ICON" "$AUTOSTART"; do
    if [[ -f "$f" ]]; then
        rm "$f"
        echo "Removed: $f"
        removed=$((removed + 1))
    fi
done

# Runtime이 config_N에 맞춰 생성하는 숨김 desktop identity. 정확한 canonical
# filename만 제거하고 비슷한 이름의 사용자 파일은 보존한다.
shopt -s nullglob
for f in "$HOME/.local/share/applications"/tildaz.instance*.desktop; do
    name="$(basename "$f")"
    if [[ "$name" =~ ^tildaz\.instance(0|[1-9][0-9]*)\.desktop$ ]]; then
        rm "$f"
        echo "Removed: $f"
        removed=$((removed + 1))
    fi
done
shopt -u nullglob

# ~/.local/bin/tildaz — symlink 일 때만 제거. 사용자가 직접 둔 실제 binary 는 보존.
if [[ -L "$SYMLINK" ]]; then
    rm "$SYMLINK"
    echo "Removed: $SYMLINK (symlink)"
    removed=$((removed + 1))
elif [[ -e "$SYMLINK" ]]; then
    echo "Preserved: $SYMLINK (실제 파일 — install.sh 가 만든 게 아님)"
fi

# install.sh가 복사·활성화한 Shell extension. GNOME은 먼저 disable해 현재 session의
# signal/key grab을 해제하고, Cinnamon은 enabled-extensions 목록에서 UUID만 제거한다.
if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions disable "$GNOME_EXT_UUID" 2>/dev/null || true
fi
if [[ -d "$GNOME_EXT" ]]; then
    rm -rf "$GNOME_EXT"
    echo "Removed: $GNOME_EXT"
    removed=$((removed + 1))
fi

if command -v gsettings >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    CINNAMON_ENABLED="$(gsettings get org.cinnamon enabled-extensions 2>/dev/null || true)"
    if [[ "$CINNAMON_ENABLED" == *"'$CINNAMON_EXT_UUID'"* ]]; then
        CINNAMON_UPDATED="$(python3 - "$CINNAMON_ENABLED" "$CINNAMON_EXT_UUID" <<'PY'
import sys
cur, uuid = sys.argv[1].strip(), sys.argv[2]
i = cur.find('[')
items = []
if i >= 0:
    body = cur[i + 1:cur.rfind(']')]
    items = [x.strip().strip("'\"") for x in body.split(',') if x.strip()]
items = [x for x in items if x != uuid]
print('[' + ', '.join("'%s'" % x for x in items) + ']')
PY
)"
        gsettings set org.cinnamon enabled-extensions "$CINNAMON_UPDATED" 2>/dev/null || true
    fi
fi
if [[ -d "$CINNAMON_EXT" ]]; then
    rm -rf "$CINNAMON_EXT"
    echo "Removed: $CINNAMON_EXT"
    removed=$((removed + 1))
fi

# WM config 에서 install.sh 가 넣은 tildaz 블록(marker 줄 + 바로 다음 줄)만 제거.
# awk exact-string 비교라 정규식 escape 불필요. marker 없으면(사용자가 직접 쓴
# exec/exec-once 등) 손대지 않는다. 파일 본문/나머지는 그대로 보존. sway·Hyprland 공통.
remove_tildaz_block() {
    local cfg="$1" marker="$2" label="$3"
    if [[ -f "$cfg" ]] && grep -qF -e "$marker" "$cfg"; then
        local tmp="$cfg.tildaz-uninstall-tmp"
        awk -v m="$marker" 'skip { skip=0; next } $0 == m { skip=1; next } { print }' "$cfg" > "$tmp"
        # 블록 제거 후 남는 trailing 빈 줄 정리 → install/uninstall 반복 시 빈 줄 누적 방지.
        # $(< file) 가 trailing newline 전부 제거 + printf 가 정확히 하나 복원.
        printf '%s\n' "$(< "$tmp")" > "$cfg"
        rm -f "$tmp"
        echo "Removed: tildaz autostart block in $cfg ($label)"
        removed=$((removed + 1))
    fi
}
remove_tildaz_block "$SWAY_CFG"  "$TILDAZ_MARKER"     "marker + exec 2줄"
remove_tildaz_block "$HYPR_CONF" "$TILDAZ_MARKER"     "marker + exec-once 2줄"
remove_tildaz_block "$HYPR_LUA"  "$TILDAZ_MARKER_LUA" "marker + hl.on 2줄"

# COSMIC RON custom shortcut — marker 블록이 아니라 단일 라인이라 `Spawn("..tildaz
# --toggle N")` 매칭으로 그 줄만 제거(구형 번호 없는 항목도 포함, 다른 단축키 + 바깥 '{ }' 보존). 바이너리 경로
# 무관하게 매칭(uninstall 시 binary 가 이미 없을 수 있음).
COSMIC_CUSTOM="$HOME/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom"
if [[ -f "$COSMIC_CUSTOM" ]] && grep -qE 'Spawn\("[^"]*tildaz --toggle( [0-9]+)?"\)' "$COSMIC_CUSTOM"; then
    tmp="$COSMIC_CUSTOM.tildaz-uninstall-tmp"
    grep -vE 'Spawn\("[^"]*tildaz --toggle( [0-9]+)?"\)' "$COSMIC_CUSTOM" > "$tmp"
    mv "$tmp" "$COSMIC_CUSTOM"
    echo "Removed: tildaz hotkey shortcut in $COSMIC_CUSTOM"
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
