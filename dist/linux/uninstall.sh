#!/usr/bin/env bash
# tildaz Linux user-level uninstall — install.sh 의 역동작.
#
# 삭제 대상:
#   ~/.local/share/applications/tildaz.desktop
#   ~/.local/share/applications/tildaz.instanceN.desktop
#   ~/.local/share/icons/hicolor/scalable/apps/tildaz.svg
#   $XDG_CONFIG_HOME/autostart/tildaz.desktop  (fallback: ~/.config)
#   ~/.local/bin/tildaz  (symlink 일 때만 — 사용자가 둔 실제 파일은 보존)
#   GNOME / Cinnamon TildaZ extension
#   GNOME / Cinnamon gsettings custom keybinding tildaz-N (extension 비활성 시
#     runtime 이 등록) — 리스트 항목 + dconf 서브트리
#   KDE ~/.config/kglobalshortcutsrc 의 [tildaz.instanceN] 그룹
#   ~/.config/sway/config 의 tildaz 블록 (install.sh 가 넣은 marker+exec 2줄만.
#     파일/본문은 보존, marker 없는 사용자 작성 줄은 안 건드림)
#   ~/.config/cosmic/...Shortcuts/v1/custom 의 TildaZ 단축키 줄 (표식 있는 줄 +
#     예전 install.sh 가 쓴 표식 없는 줄. 사용자가 이름 붙인 줄은 보존)
#   ~/.config/hypr/{hyprland.conf,hyprland.lua} 의 tildaz 블록 (marker + 다음 줄
#     2줄만. .conf=exec-once / .lua=hl.on, 동일 규칙. 본문 보존)
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
        "$HOME/.local/share/applications/$id.desktop"
        "$HOME/.local/share/icons/hicolor/scalable/apps/$id.svg"
        "$CONFIG_HOME/autostart/$id.desktop"
        "$HOME/.config/autostart/$id.desktop"
    )
done
SWAY_CFG="$HOME/.config/sway/config"
HYPR_CONF="$HOME/.config/hypr/hyprland.conf"
HYPR_LUA="$HOME/.config/hypr/hyprland.lua"
# 확장 UUID 도 두 갈래다 (#654). 예전에는 하나뿐이라 **개발 빌드를 지우면 릴리즈의
# 확장까지 지워졌다** (실기 확인). 위 `TILDAZ_IDS` 와 같은 이유로 둘 다 훑는다.
TILDAZ_EXT_UUIDS=(tildaz@ensky0.github.io tildaz-dev@ensky0.github.io)
# install.sh 와 *글자 단위로 동일해야* 매칭됨. sway/hyprlang(.conf) 는 `#` 주석,
# Hyprland Lua 는 `--` 주석이라 marker 가 두 가지.
# marker 는 id 마다 하나다 (#654) — 릴리즈는 예전 그대로 `# tildaz autostart …`, dev 는
# `# tildaz-dev autostart …`. 아래 `remove_tildaz_block` 이 두 id 를 다 돈다.
marker_for() { echo "# $1 autostart (added by install.sh — uninstall.sh removes this)"; }
marker_lua_for() { echo "-- $1 autostart (added by install.sh — uninstall.sh removes this)"; }

removed=0
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
    for f in "$HOME/.local/share/applications/$id".instance*.desktop; do
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
    gnome_ext="$HOME/.local/share/gnome-shell/extensions/$ext_uuid"
    if [[ -d "$gnome_ext" ]]; then
        rm -rf "$gnome_ext"
        echo "Removed: $gnome_ext"
        removed=$((removed + 1))
    fi

    if command -v gsettings >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        for shell_schema in org.cinnamon org.gnome.shell; do
            enabled="$(gsettings get "$shell_schema" enabled-extensions 2>/dev/null || true)"
            [[ "$enabled" == *"'$ext_uuid'"* ]] || continue
            updated="$(python3 - "$enabled" "$ext_uuid" <<'PY'
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
            gsettings set "$shell_schema" enabled-extensions "$updated" 2>/dev/null || true
        done
    fi

    cinnamon_ext="$HOME/.local/share/cinnamon/extensions/$ext_uuid"
    if [[ -d "$cinnamon_ext" ]]; then
        rm -rf "$cinnamon_ext"
        echo "Removed: $cinnamon_ext"
        removed=$((removed + 1))
    fi
done

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

# KDE ~/.config/kglobalshortcutsrc 의 [<id>.instanceN] component 그룹 제거
# (#292 E2). runtime이 KGlobalAccel.setShortcutKeys(NoAutoloading)로 저장한다
# (kglobalaccel.zig). 그룹 헤더부터 다음 그룹([...]) 직전까지 삭제. 현재 세션의
# in-memory grab 은 로그아웃 시 해제되고, 다음 로그인 땐 정리된 파일을 읽는다.
#
# **두 이름을 모두 잡는다** (#654) — 파일 맨 위 `TILDAZ_IDS` 와 같은 이유다. 예전
# 정규식은 `tildaz\.instance` 라 `tildaz-dev.instance9` 를 놓쳤고, 개발 빌드를 지운 뒤에도
# 그 항목이 시스템 설정의 단축키 목록에 죽은 채 남았다 (실측).
# ⚠️ id 목록을 **정규식으로 조립해 `awk -v` 로 넘기지 않는다.** `-v` 는 값의 escape
# sequence 를 먼저 처리해서 `\[` 가 `[` 로 풀리고, 그러면 `invalid regexp` 로 awk 가
# *치명적 오류* 를 내며 `set -e` 가 uninstall 을 통째로 멈춘다 (작성 중 실측). 그래서
# 그룹 헤더를 문자열로 가르고, 숫자 판정만 리터럴 정규식으로 둔다.
KGLOBAL="$HOME/.config/kglobalshortcutsrc"
if [[ -f "$KGLOBAL" ]]; then
    tmp="$KGLOBAL.tildaz-uninstall-tmp"
    awk -v ids="${TILDAZ_IDS[*]}" '
        function is_ours(line,    rest, n, a, i, id, num) {
            if (substr(line, 1, 1) != "[" || substr(line, length(line)) != "]") return 0
            rest = substr(line, 2, length(line) - 2)
            n = split(ids, a, " ")
            for (i = 1; i <= n; i++) {
                id = a[i] ".instance"
                if (substr(rest, 1, length(id)) == id) {
                    num = substr(rest, length(id) + 1)
                    if (num ~ /^[0-9]+$/) return 1
                }
            }
            return 0
        }
        /^\[/ { skip = is_ours($0) }
        skip { next }
        { print }
    ' "$KGLOBAL" > "$tmp"
    if cmp -s "$tmp" "$KGLOBAL"; then
        rm -f "$tmp"
    else
        mv "$tmp" "$KGLOBAL"
        echo "Removed: [<id>.instanceN] groups in $KGLOBAL"
        removed=$((removed + 1))
    fi
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
for id in "${TILDAZ_IDS[@]}"; do
    remove_tildaz_block "$SWAY_CFG"  "$(marker_for "$id")"     "$id · marker + exec 2줄"
    remove_tildaz_block "$HYPR_CONF" "$(marker_for "$id")"     "$id · marker + exec-once 2줄"
    remove_tildaz_block "$HYPR_LUA"  "$(marker_lua_for "$id")" "$id · marker + hl.on 2줄"
done

# COSMIC RON custom shortcut — marker 블록이 아니라 단일 라인이라 줄 단위로 지운다.
# 지우는 것은 둘뿐이다.
#   ① 우리 표식이 붙은 줄 — `description: Some("TildaZ_<index>")` 또는 dev 판의
#      `Some("TildaZ-dev_<index>")` (#654 · `app_id.window_base`). 바이너리 경로 · 이름과
#      무관하게 우리 것이다.
#   ② 표식이 아예 없고 명령이 `tildaz --toggle[ N]` 인 줄 — 예전 install.sh 가 쓴 것
#      (#514). 지금 install.sh 는 COSMIC 항목을 쓰지 않는다.
# 사용자가 이름을 붙인 줄(`description: Some("My wrapper")`)은 명령이 겹쳐도 보존한다 —
# 명령 문자열로 판정하면 남의 항목을 지운다(#484). 바깥 '{ }' 와 다른 단축키도 보존.
# 경로를 안 보는 이유는 uninstall 시점엔 binary 가 이미 없을 수 있어서다.
COSMIC_CUSTOM="$HOME/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom"
if [[ -f "$COSMIC_CUSTOM" ]]; then
    tmp="$COSMIC_CUSTOM.tildaz-uninstall-tmp"
    awk '
        /description: Some\("TildaZ(-dev)?_[0-9]+"\)/ { next }
        /description:/ { print; next }
        /Spawn\("[^"]*tildaz --toggle( [0-9]+)?"\)/ { next }
        { print }
    ' "$COSMIC_CUSTOM" > "$tmp"
    if cmp -s "$tmp" "$COSMIC_CUSTOM"; then
        rm -f "$tmp"
    else
        mv "$tmp" "$COSMIC_CUSTOM"
        echo "Removed: tildaz hotkey shortcut in $COSMIC_CUSTOM"
        removed=$((removed + 1))
    fi
fi

if [[ "$removed" -eq 0 ]]; then
    echo "Nothing to remove (already uninstalled)."
fi

update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

echo ""
echo "Preserved (delete manually if desired):"
echo "  $TILDAZ_CONFIG_DIR/   (config)"
echo "  $TILDAZ_STATE_DIR/   (log)"
echo "  $TILDAZ_CONFIG_DIR_DEV/   (config, dev build)"
echo "  $TILDAZ_STATE_DIR_DEV/   (log, dev build)"
