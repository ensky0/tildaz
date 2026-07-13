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
#   GNOME / Cinnamon gsettings custom keybinding tildaz-N (extension 비활성 시
#     runtime 이 등록) — 리스트 항목 + dconf 서브트리
#   KDE ~/.config/kglobalshortcutsrc 의 [tildaz.instanceN] 그룹
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

# GNOME / Cinnamon 이 영구 저장하는 custom keybinding 제거 (#292 E2). runtime
# 이 extension 비활성 fallback 으로 gsettings 에 등록(gsettings_hotkey.zig)한 뒤
# uninstall 이 안 지우면 삭제된 binary 를 가리키는 hotkey grab 이 남는다.
# 리스트(custom-keybindings / custom-list)에서 tildaz 항목만 빼고, 해당 dconf
# 서브트리(`.../custom-keybindings/tildaz-N/`)를 reset 한다. install↔uninstall 대칭.
# 리스트 요소는 GNOME=full dconf path, Cinnamon=id(tildaz-N) 로 형식이 다르다.
clean_gsettings_keybindings() {
    local schema="$1" key="$2" mode="$3" label="$4"
    command -v gsettings >/dev/null 2>&1 || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    command -v dconf >/dev/null 2>&1 || return 0
    local cur
    cur="$(gsettings get "$schema" "$key" 2>/dev/null || true)"
    [[ -n "$cur" ]] || return 0
    [[ "$cur" == *tildaz* ]] || return 0
    # python3: 1행=남길 리스트(GVariant 표기), 이후 각 행=reset 할 dconf path.
    local out
    out="$(python3 - "$cur" "$mode" <<'PY'
import sys
cur, mode = sys.argv[1].strip(), sys.argv[2]
i = cur.find('[')
items = []
if i >= 0:
    body = cur[i + 1:cur.rfind(']')]
    items = [x.strip().strip("'\"") for x in body.split(',') if x.strip()]
keep, resets = [], []
for it in items:
    if mode == 'gnome':
        is_tildaz = '/custom-keybindings/tildaz-' in it
        path = it  # GNOME 리스트 요소가 이미 full dconf path
    else:  # cinnamon: 요소는 id(tildaz-N), path 는 조립
        is_tildaz = it.startswith('tildaz-')
        path = '/org/cinnamon/desktop/keybindings/custom-keybindings/%s/' % it
    if is_tildaz:
        if not path.endswith('/'):
            path += '/'
        resets.append(path)
    else:
        keep.append(it)
print('[' + ', '.join("'%s'" % x for x in keep) + ']')
for p in resets:
    print(p)
PY
)"
    [[ -n "$out" ]] || return 0
    # mapfile 로 줄 분리 — `printf | head/tail` 는 pipefail(set -o) 에서 SIGPIPE
    # 로 스크립트를 죽일 수 있어 회피. lines[0]=남길 리스트, lines[1..]=reset path.
    local lines=()
    mapfile -t lines <<< "$out"
    [[ ${#lines[@]} -ge 1 && -n "${lines[0]}" ]] || return 0
    gsettings set "$schema" "$key" "${lines[0]}" 2>/dev/null || true
    local k
    for ((k = 1; k < ${#lines[@]}; k++)); do
        [[ -n "${lines[k]}" ]] || continue
        dconf reset -f "${lines[k]}" 2>/dev/null || true
    done
    echo "Removed: tildaz custom keybindings in gsettings ($label)"
    removed=$((removed + 1))
}
clean_gsettings_keybindings "org.gnome.settings-daemon.plugins.media-keys" "custom-keybindings" "gnome" "GNOME"
clean_gsettings_keybindings "org.cinnamon.desktop.keybindings" "custom-list" "cinnamon" "Cinnamon"

# KDE ~/.config/kglobalshortcutsrc 의 [tildaz.instanceN] component 그룹 제거
# (#292 E2). runtime 이 KGlobalAccel.setShortcut(NoAutoloading) 로 영구 저장한다
# (portal.zig). 그룹 헤더부터 다음 그룹([...]) 직전까지 삭제. 현재 세션의
# in-memory grab 은 로그아웃 시 해제되고, 다음 로그인 땐 정리된 파일을 읽는다.
KGLOBAL="$HOME/.config/kglobalshortcutsrc"
if [[ -f "$KGLOBAL" ]] && grep -qE '^\[tildaz\.instance[0-9]+\]' "$KGLOBAL"; then
    tmp="$KGLOBAL.tildaz-uninstall-tmp"
    awk '
        /^\[/ { skip = ($0 ~ /^\[tildaz\.instance[0-9]+\]$/) }
        skip { next }
        { print }
    ' "$KGLOBAL" > "$tmp"
    mv "$tmp" "$KGLOBAL"
    echo "Removed: [tildaz.instanceN] groups in $KGLOBAL"
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
