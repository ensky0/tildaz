#!/usr/bin/env bash
# tildaz Linux user-level uninstall — install.sh 의 역동작.
#
# 삭제 대상:
#   $XDG_DATA_HOME (기본 ~/.local/share)/applications/tildaz.desktop
#   $XDG_DATA_HOME (기본 ~/.local/share)/applications/tildaz.instanceN.desktop
#   $XDG_DATA_HOME (기본 ~/.local/share)/icons/hicolor/scalable/apps/tildaz.svg
#   $XDG_CONFIG_HOME/autostart/tildaz.desktop  (fallback: ~/.config)
#   ~/.local/bin/tildaz  (symlink 일 때만 — 사용자가 둔 실제 파일은 보존)
#   GNOME / Cinnamon TildaZ extension
#   GNOME / Cinnamon 이전판의 gsettings custom keybinding tildaz-N
#     — 리스트 항목 + dconf 서브트리
#   sway · Hyprland 자동실행 · COSMIC 단축키 — `tildaz --desktop remove` 가 지운다 (#700).
#     이 스크립트는 그 사용자 설정 파일을 직접 고치지 않는다. 실행 파일을 지우기 **전에**
#     부르고, 실행 파일이 없으면 손으로 지울 것을 안내한다.
#
# 보존:
#   $XDG_CONFIG_HOME/tildaz/config_N.toml  (fallback: ~/.config, 사용자 설정)
#   $XDG_STATE_HOME/tildaz/               (fallback: ~/.local/state, log)
#
# 사용법:
#   bash dist/linux/uninstall.sh

set -euo pipefail

if [[ "${XDG_CONFIG_HOME:-}" == /* ]]; then
    CONFIG_HOME="$XDG_CONFIG_HOME"
else
    CONFIG_HOME="$HOME/.config"
fi
# #700 — desktop 항목 · 아이콘 · GNOME · Cinnamon 확장은 XDG data 폴더에 둔다. 앱
# (`paths.dataHome`) 과 같은 규칙이다 — 비었거나 상대 경로면 무시한다. 두 셸 모두
# `g_get_user_data_dir()` 로 사용자 확장을 찾는다.
if [[ "${XDG_DATA_HOME:-}" == /* ]]; then
    DATA_HOME="$XDG_DATA_HOME"
else
    DATA_HOME="$HOME/.local/share"
fi
if [[ "${XDG_STATE_HOME:-}" == /* ]]; then
    STATE_HOME="$XDG_STATE_HOME"
else
    STATE_HOME="$HOME/.local/state"
fi
# 릴리즈 판과 개발 판 (`-dev`) 을 **둘 다** 치운다 (#654). uninstall 시점에는 바이너리가
# 이미 없을 수 있어 어느 쪽으로 깔았는지 판별할 수 없고, 사용자가 원하는 것은 "내가 깐
# 것을 지워라" 이기 때문이다. `/usr` 아래 시스템 패키지는 예전처럼 건드리지 않는다.
TILDAZ_IDS=(tildaz tildaz-dev)

TILDAZ_CONFIG_DIR="$CONFIG_HOME/tildaz"
TILDAZ_STATE_DIR="$STATE_HOME/tildaz"
TILDAZ_CONFIG_DIR_DEV="$CONFIG_HOME/tildaz-dev"
TILDAZ_STATE_DIR_DEV="$STATE_HOME/tildaz-dev"

USER_FILES=()
for id in "${TILDAZ_IDS[@]}"; do
    USER_FILES+=(
        "$DATA_HOME/applications/$id.desktop"
        "$DATA_HOME/icons/hicolor/scalable/apps/$id.svg"
        "$CONFIG_HOME/autostart/$id.desktop"
        "$HOME/.config/autostart/$id.desktop"
    )
done
# 확장 UUID 도 두 갈래다 (#654). 예전에는 하나뿐이라 **개발 빌드를 지우면 릴리즈의
# 확장까지 지워졌다** (실기 확인). 위 `TILDAZ_IDS` 와 같은 이유로 둘 다 훑는다.
TILDAZ_EXT_UUIDS=(tildaz@ensky0.github.io tildaz-dev@ensky0.github.io)
removed=0

# 사용자 데스크톱 설정은 tildaz 가 지운다 (#700) — sway · Hyprland 자동실행 (우리 파일과 불러오는
# 줄, 예전 이 스크립트 쌍이 넣은 블록), COSMIC 단축키, KDE 전역 단축키 (kglobalaccel 이 떠 있으면
# D-Bus, 아니면 kglobalshortcutsrc), desktop 항목. 예전에는 여기서 셸이 그 파일들을 줄 단위로
# 고쳤다 (#681 — COSMIC 파일이 깨졌다). 실행 파일을 지우기 **전에** 부른다 — 아래에서
# `~/.local/bin/<id>` 를 지우면 부를 것이 없다.
for id in "${TILDAZ_IDS[@]}"; do
    exe=""
    if [[ -L "$HOME/.local/bin/$id" ]]; then
        exe="$(readlink -f "$HOME/.local/bin/$id" 2>/dev/null || true)"
    fi
    if [[ -n "$exe" && -x "$exe" ]]; then
        if out="$("$exe" --desktop remove 2>&1)"; then
            if [[ -n "$out" ]]; then
                printf '%s\n' "$out"
                removed=$((removed + 1))
            fi
        else
            printf '%s\n' "$out"
            echo "WARNING: '$exe --desktop remove' failed — see the TildaZ log."
        fi
        continue
    fi
    # 실행 파일이 없다 — 남은 흔적이 있으면 손으로 지울 것을 알린다. 흔적을 이 스크립트가
    # 지우지 않는 이유는 위와 같다 (사용자 설정 파일을 셸이 고치지 않는다).
    left=()
    for f in "$CONFIG_HOME/sway/$id.conf" "$CONFIG_HOME/hypr/$id.lua" "$CONFIG_HOME/hypr/$id.conf"; do
        [[ -e "$f" ]] && left+=("$f")
    done
    # KDE 단축키 파일은 kglobalaccel 이 떠 있는 동안 직접 고치면 되돌아간다 (#700 D4) — 시스템
    # 설정 > 단축키에서 지우도록 안내한다.
    if [[ -f "$CONFIG_HOME/kglobalshortcutsrc" ]] && grep -qE "^\[$id\.instance[0-9]+\]" "$CONFIG_HOME/kglobalshortcutsrc"; then
        left+=("System Settings > Shortcuts: the TildaZ entries ($id.instanceN)")
    fi
    for f in "$HOME/.sway/config" "$CONFIG_HOME/sway/config" "$CONFIG_HOME/hypr/hyprland.lua" "$CONFIG_HOME/hypr/hyprland.conf"; do
        [[ -f "$f" ]] && grep -qF -e "$id autostart" -e "$id.conf" -e "require, \"$id\")" "$f" && left+=("$f (the $id autostart lines)")
    done
    if [[ ${#left[@]} -gt 0 ]]; then
        echo "The $id executable is gone, so its desktop settings were not removed. Remove these by hand:"
        for f in "${left[@]}"; do echo "  $f"; done
    fi
done
for f in "${USER_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        rm "$f"
        echo "Removed: $f"
        removed=$((removed + 1))
    fi
done

# Runtime이 config_N에 맞춰 생성하는 숨김 desktop identity. 정확한 canonical
# filename만 제거하고 비슷한 이름의 사용자 파일은 보존한다.
shopt -s nullglob
for id in "${TILDAZ_IDS[@]}"; do
    for f in "$DATA_HOME/applications/$id".instance*.desktop; do
        name="$(basename "$f")"
        if [[ "$name" =~ ^"$id"\.instance(0|[1-9][0-9]*)\.desktop$ ]]; then
            rm "$f"
            echo "Removed: $f"
            removed=$((removed + 1))
        fi
    done
done
shopt -u nullglob

# ~/.local/bin/<id> — symlink 일 때만 제거. 사용자가 직접 둔 실제 binary 는 보존한다.
# `-L` 로 보는 것이 중요하다: 가리키던 빌드가 이미 지워진 **깨진 심링크**도 우리가 만든
# 것이라 치워야 하는데, `-f` 로는 그것을 놓친다.
for id in "${TILDAZ_IDS[@]}"; do
    link="$HOME/.local/bin/$id"
    if [[ -L "$link" ]]; then
        rm "$link"
        echo "Removed: $link (symlink)"
        removed=$((removed + 1))
    elif [[ -e "$link" ]]; then
        echo "Preserved: $link (실제 파일 — install.sh 가 만든 게 아님)"
    fi
done

# install.sh가 복사·활성화한 Shell extension. GNOME은 먼저 disable해 현재 session의
# signal/key grab을 해제하고, Cinnamon은 enabled-extensions 목록에서 UUID만 제거한다.
# 두 UUID 를 모두 훑는다 — 어느 쪽으로 깔았는지 uninstall 시점에는 알 수 없다.
for ext_uuid in "${TILDAZ_EXT_UUIDS[@]}"; do
    if command -v gnome-extensions >/dev/null 2>&1; then
        gnome-extensions disable "$ext_uuid" 2>/dev/null || true
    fi
    gnome_ext="$DATA_HOME/gnome-shell/extensions/$ext_uuid"
    if [[ -d "$gnome_ext" ]]; then
        rm -rf "$gnome_ext"
        echo "Removed: $gnome_ext"
        removed=$((removed + 1))
    fi

    # 두 셸의 `enabled-extensions` 에서 빼고, GNOME 은 `disabled-extensions` 에서도 뺀다. 위
    # `gnome-extensions disable` 이 거기 UUID 를 **남기는데**, 지운 확장이 그 목록에 남으면 다음
    # `install.sh` 가 `enabled-extensions` 에 넣어도 GNOME 이 disabled 를 우선해 켜지지 않는다
    # (#654 GNOME 실기 — 양쪽에 있으면 INITIALIZED 에 멈춘다). 키가 없는 셸 (`disabled-extensions`
    # 는 `org.cinnamon` 에 없다) 은 `gsettings writable` 이 거절해 조용히 건너뛴다.
    if command -v gsettings >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        for pair in "org.cinnamon enabled-extensions" "org.gnome.shell enabled-extensions" "org.gnome.shell disabled-extensions"; do
            read -r shell_schema shell_key <<< "$pair"
            gsettings writable "$shell_schema" "$shell_key" >/dev/null 2>&1 || continue
            current="$(gsettings get "$shell_schema" "$shell_key" 2>/dev/null || true)"
            [[ "$current" == *"'$ext_uuid'"* ]] || continue
            updated="$(python3 - "$current" "$ext_uuid" <<'PY'
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
            gsettings set "$shell_schema" "$shell_key" "$updated" 2>/dev/null || true
        done
    fi

    cinnamon_ext="$DATA_HOME/cinnamon/extensions/$ext_uuid"
    if [[ -d "$cinnamon_ext" ]]; then
        rm -rf "$cinnamon_ext"
        echo "Removed: $cinnamon_ext"
        removed=$((removed + 1))
    fi
done

# GNOME / Cinnamon 이전 버전이 영구 저장한 custom keybinding 제거 (#292 E2,
# #676). 현재 버전은 Shell extension만 쓰지만, uninstall이 옛 항목을 안 지우면
# 삭제된 binary를 가리키는 hotkey grab이 남는다.
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



if [[ "$removed" -eq 0 ]]; then
    echo "Nothing to remove (already uninstalled)."
fi

update-desktop-database "$DATA_HOME/applications" 2>/dev/null || true
gtk-update-icon-cache -t "$DATA_HOME/icons/hicolor" 2>/dev/null || true

echo ""
echo "Preserved (delete manually if desired):"
echo "  $TILDAZ_CONFIG_DIR/   (config)"
echo "  $TILDAZ_STATE_DIR/   (log)"
echo "  $TILDAZ_CONFIG_DIR_DEV/   (config, dev build)"
echo "  $TILDAZ_STATE_DIR_DEV/   (log, dev build)"
