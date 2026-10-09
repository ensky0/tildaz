#!/usr/bin/env bash
# tildaz Linux user-level install — `~/.local` 과 데스크톱 설정만 건드림 (no sudo).
#
# 산출물:
#   $XDG_DATA_HOME (기본 ~/.local/share)/applications/tildaz.desktop
#     ← dist/linux/tildaz.desktop 의 __TILDAZ_EXE__ 를 binary 절대 경로로 치환
#   $XDG_DATA_HOME (기본 ~/.local/share)/icons/hicolor/scalable/apps/tildaz.svg
#     ← docs/favicon.svg 그대로 복사 (mac AppIcon.icns / Windows tildaz.ico 와
#       동일 출처)
#   ~/.local/bin/tildaz  → binary symlink (PATH 노출 — dmenu 등 launcher 에서
#     `tildaz` 로 실행/재실행). ln -sf 라 재실행 idempotent.
#   sway · Hyprland 자동실행은 이 스크립트가 넣지 않는다 — TildaZ 를 처음 띄울 때 launcher 가
#     넣는다 (#701). 이 스크립트는 사용자 설정을 직접 고치지 않는다.
#
# desktop database / icon cache refresh 는 best-effort (없으면 skip).
#
# 저장소에서는 선택한 종류로 빌드한 뒤 설치한다. 기본 dev, --release 만 릴리즈다.
# tarball에서는 이미 빌드된 릴리즈를 설치한다 (--release 필수).
# --exe 는 tarball 바이너리를 다른 디렉터리로 옮긴 경우에만 쓴다.
#
# 사용법:
#   bash dist/linux/install.sh                    # dev 빌드 + 설치
#   bash dist/linux/install.sh --release          # 릴리즈 빌드 + 설치
#   ./install.sh --release                        # 릴리즈 tarball 설치
#   ./install.sh --release --exe /usr/local/bin/tildaz
#
# KDE Plasma 6 환경: install 후 KRunner (Alt+F2) 또는 Application Menu 에서
# "TildaZ" 검색 + 실행 → launcher desktop entry의 Exec 호출. Worker별
# portal identity는 실행 후 생성되는 tildaz.instanceN.desktop/systemd scope가 담당
# (SPEC.md §1.2, §7.1 참조).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
TILDAZ_EXE=""
IS_DEV=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --exe)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                echo "ERROR: --exe requires a path" >&2; exit 2
            fi
            TILDAZ_EXE="$2"; shift 2 ;;
        --release) IS_DEV=0; shift ;;
        -h|--help)
            echo "Usage: $0 [--release] [--exe <path>]"
            echo "Build and install dev by default; --release selects the release identity."
            echo "Release archives require --release. --exe is only for a relocated archive binary."
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ "$IS_DEV" -eq 1 ]]; then
    TILDAZ_ID="tildaz-dev"
    TILDAZ_LABEL="TildaZ (dev)"
    # 창 제목 접두어 — `src/app_id.zig` 의 `window_title_prefix` 와 같은 값. 확장이 이것으로
    # worker 창을 찾는다 (#654).
    TILDAZ_TITLE_PREFIX="TildaZ-dev-"
else
    TILDAZ_ID="tildaz"
    TILDAZ_LABEL="TildaZ"
    TILDAZ_TITLE_PREFIX="TildaZ-"
fi
# 앱이 읽는 config 디렉터리도 같은 이름을 탄다 — 안내 문구에 쓴다.
TILDAZ_CONFIG_DIR="$CONFIG_HOME/$TILDAZ_ID"

# 경로는 소스/배포물의 위치를 찾는 데만 쓴다. dev 여부는 위 옵션 하나가 정한다.
if [[ -f "$REPO_ROOT/build.zig" && -f "$REPO_ROOT/src/main.zig" ]]; then
    if [[ -n "$TILDAZ_EXE" ]]; then
        echo "ERROR: --exe is only supported in a release archive; repository installs build from source." >&2
        exit 2
    fi
    RELEASE_VALUE=false
    BUILD_KIND=dev
    if [[ "$IS_DEV" -eq 0 ]]; then RELEASE_VALUE=true; BUILD_KIND=release; fi
    # symlink 대상이 다음 릴리즈 빌드로 바뀌지 않게 설치용 산출물을 판별로 나눈다.
    INSTALL_PREFIX="$REPO_ROOT/zig-out/install-$BUILD_KIND"
    (cd "$REPO_ROOT" && zig build "-Drelease=$RELEASE_VALUE" -Doptimize=ReleaseFast -Dsimd=true -p "$INSTALL_PREFIX")
    TILDAZ_EXE="$INSTALL_PREFIX/bin/tildaz"
else
    if [[ "$IS_DEV" -eq 1 ]]; then
        echo "ERROR: this archive contains a release build. Run ./install.sh --release." >&2
        exit 2
    fi
    TILDAZ_EXE="${TILDAZ_EXE:-$SCRIPT_DIR/tildaz}"
fi
if [[ ! -x "$TILDAZ_EXE" ]]; then
    echo "ERROR: tildaz binary not found at: $TILDAZ_EXE" >&2
    exit 1
fi
TILDAZ_EXE="$(realpath "$TILDAZ_EXE")"

# 개발판 분리 (#654) 이전의 install.sh 는 개발 빌드도 **릴리즈 이름** (`tildaz`) 으로 깔았다.
# 그 잔재가 남으면 `~/.local/bin/tildaz` 가 PATH 에서 `/usr/bin/tildaz` 를 가려
# `which tildaz` 가 개발 빌드를 가리키고, `tildaz.desktop` 은 패키지 항목을 통째로
# 가린다 — 이 이슈가 없애려던 shadowing 그 자체다.
#
# **옛 기본 경로 `zig-out/bin/tildaz`만 정리한다.** 새 `install-release` 경로까지 지우면
# dev 재설치가 정상 릴리즈 설치를 없애므로 넓은 `zig-out/*` 판정은 쓰지 않는다. 이 경로면
# 확실하고, 사용자가 릴리즈 tarball 로 깐 정상 설치 (Exec 이 압축 해제 폴더) 는 그대로
# 남는다. 이 조건은 옛 잔재 정리 전용이고 새 설치의 dev 판정에는 쓰지 않는다. 아이콘 (`tildaz.svg`) 은 dev·릴리즈
# 구별 근거가 없어 건드리지 않는다 — 항목이 없으면 아이콘만 남아도 무해하다.
remove_stale_dev_entry() {
    local kind="$1" path="$2"
    case "$kind" in
        link)
            [[ -L "$path" ]] || return 0
            local target
            target="$(readlink -f "$path" 2>/dev/null || true)"
            [[ "$target" == */zig-out/bin/tildaz ]] || return 0
            ;;
        desktop)
            [[ -f "$path" ]] || return 0
            grep -qE '^Exec=("?)[^"]*/zig-out/bin/tildaz("|[[:space:]]|$)' "$path" || return 0
            ;;
    esac
    rm -f "$path"
    STALE_REMOVED+=("$path")
}

STALE_REMOVED=()
if [[ "$IS_DEV" -eq 1 ]]; then
    remove_stale_dev_entry link    "$HOME/.local/bin/tildaz"
    remove_stale_dev_entry desktop "$DATA_HOME/applications/tildaz.desktop"
    remove_stale_dev_entry desktop "$CONFIG_HOME/autostart/tildaz.desktop"
fi

APP_DIR="$DATA_HOME/applications"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
mkdir -p "$APP_DIR" "$ICON_DIR"

DESKTOP_OUT="$APP_DIR/$TILDAZ_ID.desktop"
ICON_OUT="$ICON_DIR/$TILDAZ_ID.svg"

ESCAPED_EXE="${TILDAZ_EXE//\\/\\\\}"
ESCAPED_EXE="${ESCAPED_EXE//&/\\&}"
ESCAPED_EXE="${ESCAPED_EXE//|/\\|}"
sed -e "s|__TILDAZ_EXE__|$ESCAPED_EXE|" \
    -e "s|__TILDAZ_NAME__|$TILDAZ_LABEL|" \
    -e "s|__TILDAZ_ICON__|$TILDAZ_ID|" \
    -e "s|__TILDAZ_WMCLASS__|$TILDAZ_ID|" \
    "$SCRIPT_DIR/tildaz.desktop" > "$DESKTOP_OUT"
if grep -qF '__TILDAZ_' "$DESKTOP_OUT" || ! grep -qxF "Exec=$TILDAZ_EXE" "$DESKTOP_OUT"; then
    echo "ERROR: failed to resolve desktop Exec path: $DESKTOP_OUT" >&2
    exit 1
fi
chmod 644 "$DESKTOP_OUT"

if [[ -f "$SCRIPT_DIR/tildaz.svg" ]]; then
    # Portable release bundle: icon is packaged next to install.sh.
    ICON_SRC="$SCRIPT_DIR/tildaz.svg"
elif [[ -f "$REPO_ROOT/docs/favicon.svg" ]]; then
    # Repository development install.
    ICON_SRC="$REPO_ROOT/docs/favicon.svg"
else
    echo "ERROR: TildaZ icon not found next to install.sh or in docs/favicon.svg" >&2
    exit 1
fi
cp "$ICON_SRC" "$ICON_OUT"
chmod 644 "$ICON_OUT"

# best-effort cache refresh — 없거나 실패해도 install 자체는 성공.
update-desktop-database "$APP_DIR" 2>/dev/null || true
gtk-update-icon-cache -t "$DATA_HOME/icons/hicolor" 2>/dev/null || true

# ~/.local/bin/tildaz symlink — dmenu 등 launcher 는 `.desktop` 이 아니라 $PATH
# 의 실행파일만 나열하므로, PATH 의 이 symlink 가 있어야 `tildaz` 로 실행/재실행
# 된다. ln -sf 라 재실행 idempotent.
BIN_LINK="$HOME/.local/bin/$TILDAZ_ID"
mkdir -p "$HOME/.local/bin"
ln -sf "$TILDAZ_EXE" "$BIN_LINK"

# sway · Hyprland 자동실행은 여기서 넣지 않는다 — TildaZ 를 처음 띄울 때 launcher 가 넣는다
# (#701). 패키지 (deb · rpm · Arch pkg · AppImage) 에는 이 스크립트가 없어서, 여기서 넣으면
# tar.gz 사용자만 자동실행이 걸렸다. 이제 모든 형식이 같은 길을 탄다 — KDE Plasma · Cinnamon ·
# COSMIC 의 XDG 자동 시작도 launcher 가 넣는다. 지금 세션이 sway · Hyprland 일 때만 넣고,
# 사용자 설정에는 우리 파일을 불러오는 줄 하나만 둔다. 규칙은 `src/desktop_setup/sway_hyprland.zig`
# 머리 주석에 있다. 손으로 넣으려면 `tildaz --desktop add` 다 (제거는 `uninstall.sh` 가
# `tildaz --desktop remove` 로 한다).

# COSMIC hotkey 는 여기서 등록하지 않는다 — TildaZ 가 실행될 때 등록한다.
# 예전에는 이 자리에서 RON custom shortcut(`~/.config/cosmic/...Shortcuts/v1/custom`)
# 을 직접 썼는데, 그 줄에는 우리 표식(`description: Some("TildaZ_<index>")`)이 없어서
# launcher 가 자기 항목으로 알아보지 못하고 하나 더 썼다 — 같은 hotkey 가 두 번
# 등록됐다 ([#514](https://github.com/ensky0/tildaz/issues/514)). writer 를 둘 두면
# 표식이 갈라지고, 갈라지면 같은 단축키가 둘 남는다(#484 — COSMIC 은 뒤의 것만 쓴다. #700 조사).
# Hyprland 도 같은 이유로 hotkey 를 런타임 등록으로 옮겼다 (옛 정적 줄은 launcher 가 자동실행을 넣을 때 옮긴다).
# 이 스크립트가 예전에 남긴 줄은 TildaZ 가 처음 실행될 때 흡수한다
# (`src/shortcut_sync/linux.zig` 의 `legacyInstallScriptEntryIndex`).
# GNOME Shell extension — GNOME(mutter) 은 wlr-layer-shell 미지원이라 drop-down
# placement / lifecycle(launch·show·hide) 을 extension 이 담당한다 (#228). GNOME
# 환경에서만 의미(다른 DE 는 gnome-shell 이 없어 무시). 복사는 항상, enable 은
# gnome-extensions 명령이 있을 때. Wayland 는 enable 후 로그아웃/로그인해야 적용.
# 확장 소스는 레포에 **한 벌**이고 `__TILDAZ_*__` 토큰을 담는다 (#654) — 개발 빌드와
# 릴리즈가 각자의 UUID 로 깔리도록 복사하면서 치환한다. `src/host/linux/shell_extension.zig`
# 의 `substitutions` 와 **같은 토큰**이어야 한다 (앱도 기동 때 같은 파일을 쓴다).
# 소스 디렉터리 이름은 릴리즈 UUID 로 고정돼 있다 (git 에 담긴 이름).
EXT_SRC_UUID="tildaz@ensky0.github.io"
if [[ "$IS_DEV" -eq 1 ]]; then
    EXT_UUID="tildaz-dev@ensky0.github.io"
    EXT_NAME="TildaZ Drop-down (dev)"
else
    EXT_UUID="tildaz@ensky0.github.io"
    EXT_NAME="TildaZ Drop-down"
fi
EXT_SCHEMA="org.gnome.shell.extensions.$TILDAZ_ID"

# 확장 리소스를 토큰 치환하며 복사한다. gschema 는 파일 이름도 스키마 id 를 따라간다 —
# `glib-compile-schemas` 가 디렉터리를 통째로 읽으므로 이름이 겹치면 서로를 덮어쓴다.
render_extension() {
    local src="$1" dst="$2" rel out
    mkdir -p "$dst"
    while IFS= read -r -d '' f; do
        rel="${f#"$src"/}"
        case "$rel" in
            schemas/*.gschema.xml) out="$dst/schemas/$EXT_SCHEMA.gschema.xml" ;;
            *) out="$dst/$rel" ;;
        esac
        mkdir -p "$(dirname "$out")"
        sed -e "s|__TILDAZ_EXT_UUID__|$EXT_UUID|g" \
            -e "s|__TILDAZ_EXT_SCHEMA__|$EXT_SCHEMA|g" \
            -e "s|__TILDAZ_EXT_NAME__|$EXT_NAME|g" \
            -e "s|__TILDAZ_TITLE_PREFIX__|$TILDAZ_TITLE_PREFIX|g" \
            -e "s|__TILDAZ_APP__|$TILDAZ_ID|g" \
            "$f" > "$out"
        # 토큰이 남으면 셸이 그 확장을 못 읽고 그 실패는 조용하다 — 여기서 세운다.
        if grep -qE '__TILDAZ_[A-Z_]+__' "$out"; then
            echo "ERROR: unresolved __TILDAZ_ token in $out" >&2
            exit 1
        fi
    done < <(find "$src" -type f -print0)
}

# gsettings 의 문자열 목록 (strv) 에 항목을 더하거나 뺀다. `@as []` 와 `['a', 'b']` 를 둘 다 읽고,
# 바뀐 것이 없으면 쓰지 않는다. 키가 없거나 (예: `org.cinnamon` 에는 `disabled-extensions` 가 없다)
# gsettings · python3 이 없으면 1 을 돌려준다 — 호출부가 안내 문구로 갈라 쓴다.
gsettings_strv_edit() {   # <schema> <key> add|remove <value>
    local schema="$1" key="$2" op="$3" value="$4" cur new
    command -v gsettings >/dev/null 2>&1 || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    gsettings writable "$schema" "$key" >/dev/null 2>&1 || return 1
    cur="$(gsettings get "$schema" "$key" 2>/dev/null || echo '@as []')"
    new="$(python3 - "$cur" "$op" "$value" <<'PY'
import sys
cur, op, value = sys.argv[1].strip(), sys.argv[2], sys.argv[3]
i = cur.find('[')
items = []
if i >= 0:
    body = cur[i + 1:cur.rfind(']')]
    items = [x.strip().strip("'\"") for x in body.split(',') if x.strip()]
if op == 'add' and value not in items:
    items.append(value)
if op == 'remove':
    items = [x for x in items if x != value]
print('[' + ', '.join("'%s'" % x for x in items) + ']')
PY
)"
    [[ -n "$new" ]] || return 1
    [[ "$new" == "$cur" ]] && return 0
    gsettings set "$schema" "$key" "$new" 2>/dev/null
}

EXT_SRC="$SCRIPT_DIR/gnome-extension/$EXT_SRC_UUID"
EXT_MSG=""
if [[ -d "$EXT_SRC" ]]; then
    EXT_DST="$DATA_HOME/gnome-shell/extensions/$EXT_UUID"
    render_extension "$EXT_SRC" "$EXT_DST"
    if command -v glib-compile-schemas >/dev/null 2>&1 && [[ -d "$EXT_DST/schemas" ]]; then
        glib-compile-schemas "$EXT_DST/schemas" 2>/dev/null || true
    fi
    # `gnome-extensions enable` 을 쓰지 않는다 (#654 GNOME 실기). 셸은 재로그인 전에는 새로 깐
    # 확장 디렉터리를 읽지 않아서, 그 UUID 로 enable 을 걸면 **"확장 기능이 없습니다" (exit 2)**
    # 로 실패한다. 예전 코드는 그것을 `|| true` 로 삼키고 "(enabled)" 라고 적었는데, 실제로는
    # `enabled-extensions` 에 들어가지 못해 **재로그인 뒤에도 켜지지 않았다.** Cinnamon 경로처럼
    # gsettings 를 직접 쓴다 — 로그인 때 셸이 그 목록을 읽어 켠다.
    #
    # `disabled-extensions` 에서도 뺀다. `uninstall.sh` 가 부르는 `gnome-extensions disable` 이 거기
    # UUID 를 남기고, GNOME 은 그 목록을 `enabled-extensions` 보다 **우선**한다 (실측: 양쪽에 있으면
    # 확장이 INITIALIZED 에 멈추고 켜지지 않는다). 재설치가 켜지려면 여기서 치워야 한다.
    if gsettings_strv_edit org.gnome.shell enabled-extensions add "$EXT_UUID"; then
        gsettings_strv_edit org.gnome.shell disabled-extensions remove "$EXT_UUID" || true
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
CIN_UUID="$EXT_UUID"   # GNOME 과 같은 UUID 규칙 (#654) — 셸만 다르다.
CIN_SRC="$SCRIPT_DIR/cinnamon-extension/$EXT_SRC_UUID"
CIN_MSG=""
if [[ -d "$CIN_SRC" ]]; then
    CIN_DST="$DATA_HOME/cinnamon/extensions/$CIN_UUID"
    render_extension "$CIN_SRC" "$CIN_DST"
    # GNOME 과 같은 함수 (`gsettings_strv_edit`) 로 켠다 — 두 셸의 목록 편집 로직을 한 곳에 둔다.
    if gsettings_strv_edit org.cinnamon enabled-extensions add "$CIN_UUID"; then
        CIN_MSG="$CIN_DST  (enabled — Cinnamon 이 바로 읽음. 앱은 메뉴에서 실행하거나 다음 로그인의 autostart 로)"
    else
        CIN_MSG="$CIN_DST  (복사됨 — Cinnamon 아님/gsettings·python3 미설치, 시스템 설정 > 확장에서 활성화 + 재로그인)"
    fi
fi

if [[ ${#STALE_REMOVED[@]} -gt 0 ]]; then
    echo "Removed stale entries from a pre-dev install (they pointed at zig-out):"
    for f in "${STALE_REMOVED[@]}"; do echo "  $f"; done
    echo ""
fi

echo "Installed:"
echo "  $DESKTOP_OUT  (Exec=$TILDAZ_EXE)"
echo "  $ICON_OUT"
echo "  $BIN_LINK -> $TILDAZ_EXE"
[[ -n "$EXT_MSG" ]] && echo "  $EXT_MSG"
[[ -n "$CIN_MSG" ]] && echo "  $CIN_MSG"
echo ""
echo "Next:"
echo "  - KDE Plasma 6: Alt+F2 → 'TildaZ' 또는 메뉴에서 실행 (portal app_id 인식)"
echo "  - GNOME: 위 extension 이 drop-down 위치/단축키/자동시작을 담당."
echo "           Wayland 라 로그아웃→로그인해야 extension 이 활성화됨."
echo "  - Cinnamon: 위 extension 이 drop-down 위치/단축키를 담당 (Cinnamon on Wayland)."
echo "              extension 은 재로그인 없이 바로 켜짐 (#654 실측). 앱은 메뉴에서 실행하거나"
echo "              다음 로그인의 autostart 로 뜸. X11 세션엔 tildaz 안 뜸."
echo "  - sway: sway 세션에서 TildaZ 를 한 번 띄우면 ~/.config/sway/$TILDAZ_ID.conf 의 exec 로"
echo "          자동실행이 걸림 (sway 설정이 그 파일을 include). 로그인 후 hotkey(기본 F1) 토글."
echo "  - Hyprland: layer-shell drop-down. hotkey 는 실행 시 config_N별 hyprctl bind→'tildaz --toggle N'."
echo "          Hyprland 세션에서 TildaZ 를 한 번 띄우면 ~/.config/hypr/$TILDAZ_ID.lua(.conf) 로 자동실행이 걸림."
echo "          설정을 다시 읽어도 단축키는 다시 걸림."
echo "  - COSMIC: layer-shell drop-down. hotkey 는 실행 시 config_N별 RON shortcut→'tildaz --toggle N'(portal 우회)."
echo "          TildaZ 를 한 번 띄우면 ~/.config/cosmic/...Shortcuts/v1/custom 에 등록됨 → cosmic-comp 가 live 반영(안 되면 재로그인)."
echo "          자동실행은 config.auto_start=true 면 XDG autostart 로 동작."
echo "  - 기타 wlroots: layer-shell drop-down. 자동실행은 compositor 의 exec 류로 직접."
echo "  - config: $TILDAZ_CONFIG_DIR/config_N.toml (instance별 auto_start/hidden_start/hotkey/위치)"
echo "  - autostart: 비-GNOME 은 config.auto_start=true 면 $CONFIG_HOME/autostart/"
echo "    $TILDAZ_ID.desktop 자동 생성. GNOME 은 NotShowIn으로 건너뛰고 extension이 담당."
