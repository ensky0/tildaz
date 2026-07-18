#!/usr/bin/env bash
# tildaz macOS uninstall — build_and_install.sh / setup-cert.sh / 런타임이 만든
# 것들을 되돌림. Linux dist/linux/uninstall.sh 와 같은 정책:
#
#   기본     : 앱 · 자동실행(LaunchAgent) · state(cache) 삭제.
#              config · log · 코드서명 인증서는 보존 (경로만 출력).
#   --purge  : 위 + config · log · 코드서명 인증서 · TCC 권한까지 전부 삭제.
#
# 사용법:
#   bash dist/macos/uninstall.sh            # 기본 (설정/로그/인증서 보존)
#   bash dist/macos/uninstall.sh --purge    # 전부 삭제

set -euo pipefail

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help)
            echo "사용법: $0 [--purge]"
            echo "  (기본)   앱·자동실행·state 삭제, config·log·인증서 보존"
            echo "  --purge  config·log·인증서·TCC 권한까지 전부 삭제"
            exit 0 ;;
        *) echo "알 수 없는 인자: $arg" >&2; exit 1 ;;
    esac
done

# 설치 경로는 build_and_install.sh 와 동일 env 로 override 가능.
APP="${TILDAZ_INSTALL_PATH:-/Applications/TildaZ.app}"
LAUNCH_LABEL="com.tildaz.app"                                   # autostart/macos.zig
LAUNCH_AGENT="$HOME/Library/LaunchAgents/${LAUNCH_LABEL}.plist"
CACHE="$HOME/Library/Caches/TildaZ"                             # paths.zig lockDir
if [[ "${XDG_CONFIG_HOME:-}" == /* ]]; then
    CONFIG_DIR="$XDG_CONFIG_HOME/tildaz"
else
    CONFIG_DIR="$HOME/.config/tildaz"
fi
CERT_NAME="TildazLocal"
CERT_CRT="$HOME/.tildaz/${CERT_NAME}.crt"
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"
BUNDLE_ID="me.ensky0.tildaz"                                    # Info.plist / tccutil

removed=0

# --- 자동실행 (LaunchAgent) — 안 지우면 삭제된 바이너리를 로그인 때 실행하려 함 ---
# 현재 세션에 로드돼 있으면 먼저 bootout (best-effort), 그다음 plist 삭제.
launchctl bootout "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null || true
if [[ -f "$LAUNCH_AGENT" ]]; then
    rm -f "$LAUNCH_AGENT"
    echo "Removed: $LAUNCH_AGENT (autostart)"
    removed=$((removed + 1))
fi

# --- 앱 번들 ---
if [[ -d "$APP" ]]; then
    rm -rf "$APP"
    echo "Removed: $APP"
    removed=$((removed + 1))
fi

# --- state (lock / run cache) ---
if [[ -d "$CACHE" ]]; then
    rm -rf "$CACHE"
    echo "Removed: $CACHE (state)"
    removed=$((removed + 1))
fi

if [[ "$PURGE" == "1" ]]; then
    # --- config ($XDG_CONFIG_HOME/tildaz, fallback ~/.config/tildaz) ---
    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        echo "Removed: $CONFIG_DIR (config)"
        removed=$((removed + 1))
    fi

    # --- log (~/Library/Logs/tildaz_N.log) ---
    shopt -s nullglob
    for f in "$HOME/Library/Logs"/tildaz_*.log; do
        rm -f "$f"
        echo "Removed: $f (log)"
        removed=$((removed + 1))
    done
    shopt -u nullglob

    # --- 코드서명 인증서 (login + System keychain) + export 파일 ---
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
        security delete-identity -c "$CERT_NAME" >/dev/null 2>&1 || true
        sudo security delete-certificate -c "$CERT_NAME" "$SYSTEM_KEYCHAIN" >/dev/null 2>&1 || true
        echo "Removed: code-signing cert '$CERT_NAME' (login + System keychain)"
        removed=$((removed + 1))
    fi
    if [[ -f "$CERT_CRT" ]]; then
        rm -f "$CERT_CRT"
        rmdir "$HOME/.tildaz" 2>/dev/null || true
        echo "Removed: $CERT_CRT"
        removed=$((removed + 1))
    fi

    # --- TCC 권한 (손쉬운 사용 / 입력 모니터링) reset ---
    # ListenEvent = Input Monitoring, Accessibility = 손쉬운 사용.
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "Reset: TCC (Accessibility / Input Monitoring) for $BUNDLE_ID"
fi

if [[ "$removed" -eq 0 ]]; then
    echo "Nothing to remove (already uninstalled)."
fi

if [[ "$PURGE" != "1" ]]; then
    echo ""
    echo "Preserved (--purge 로 지울 수 있음):"
    echo "  $CONFIG_DIR/                  (config)"
    echo "  ~/Library/Logs/tildaz_*.log   (log)"
    echo "  code-signing cert '$CERT_NAME' (재빌드 시 유지)"
fi
