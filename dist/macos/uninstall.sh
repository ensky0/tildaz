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
# 릴리즈 판과 개발 판 (`-dev`) 을 **둘 다** 치운다 (#654) — 어느 쪽으로 깔았는지
# uninstall 시점에는 알 수 없고, 사용자가 원하는 것은 "내가 깐 것을 지워라" 다.
TILDAZ_IDS=(tildaz tildaz-dev)
APPS=("/Applications/TildaZ.app" "/Applications/TildaZ-dev.app")
[[ -n "${TILDAZ_INSTALL_PATH:-}" ]] && APPS=("$TILDAZ_INSTALL_PATH")
APP="${APPS[0]}"
# launchd label 은 bundle id 와 같은 값이다 (src/app_id.zig · autostart/macos.zig).
LAUNCH_LABELS=("me.ensky0.tildaz" "me.ensky0.tildaz.dev" "com.tildaz.app")
CONFIG_BASE="$HOME/.config"
[[ "${XDG_CONFIG_HOME:-}" == /* ]] && CONFIG_BASE="$XDG_CONFIG_HOME"
CERT_NAME="TildazLocal"
CERT_CRT="$HOME/.tildaz/${CERT_NAME}.crt"
CERT_P12="$HOME/.tildaz/${CERT_NAME}.p12"        # private key 백업 (cert-common.sh, #444)
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"
BUNDLE_IDS=("me.ensky0.tildaz" "me.ensky0.tildaz.dev")          # Info.plist / tccutil
BUNDLE_ID="${BUNDLE_IDS[0]}"

removed=0

# --- 자동실행 (LaunchAgent) — 안 지우면 삭제된 바이너리를 로그인 때 실행하려 함 ---
# 현재 세션에 로드돼 있으면 먼저 bootout (best-effort), 그다음 plist 삭제.
# `com.tildaz.app` 은 #654 이전의 label 이다 — 옛 설치본이 남겼을 수 있어 함께 본다.
for label in "${LAUNCH_LABELS[@]}"; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    agent="$HOME/Library/LaunchAgents/${label}.plist"
    if [[ -f "$agent" ]]; then
        rm -f "$agent"
        echo "Removed: $agent (autostart)"
        removed=$((removed + 1))
    fi
done

# --- 앱 번들 ---
for app in "${APPS[@]}"; do
    if [[ -d "$app" ]]; then
        rm -rf "$app"
        echo "Removed: $app"
        removed=$((removed + 1))
    fi
done

# --- state (lock / run cache) ---
# 예전에는 `~/Library/Caches/TildaZ` (대문자 · `/run` 없음) 였다 (#654 ⓐⓑ).
for dir in "$HOME/Library/Caches/TildaZ" "$HOME/Library/Caches/tildaz" "$HOME/Library/Caches/tildaz-dev"; do
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        echo "Removed: $dir (state)"
        removed=$((removed + 1))
    fi
done

if [[ "$PURGE" == "1" ]]; then
    # --- config ($XDG_CONFIG_HOME/<id>, fallback ~/.config/<id>) ---
    for id in "${TILDAZ_IDS[@]}"; do
        dir="$CONFIG_BASE/$id"
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            echo "Removed: $dir (config)"
            removed=$((removed + 1))
        fi
    done

    # --- log (~/Library/Logs/<id>/) ---
    # 예전 판은 `~/Library/Logs/tildaz_N.log` 로 앱 디렉터리 없이 두었다 (#654 ⓓ).
    # 그 자리에 남은 파일도 함께 치운다.
    shopt -s nullglob
    for id in "${TILDAZ_IDS[@]}"; do
        dir="$HOME/Library/Logs/$id"
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            echo "Removed: $dir/ (log)"
            removed=$((removed + 1))
        fi
    done
    for f in "$HOME/Library/Logs"/tildaz_*.log; do
        rm -f "$f"
        echo "Removed: $f (log, pre-#654 layout)"
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
    # p12 는 private key 를 담은 복구용 백업 — 남겨 두면 인증서를 지웠다면서 서명 수단이
    # 그대로 있는 셈이라 함께 지운다 (#444).
    for f in "$CERT_CRT" "$CERT_P12"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            echo "Removed: $f"
            removed=$((removed + 1))
        fi
    done
    rmdir "$HOME/.tildaz" 2>/dev/null || true

    # --- TCC 권한 (손쉬운 사용 / 입력 모니터링) reset ---
    # ListenEvent = Input Monitoring, Accessibility = 손쉬운 사용.
    # 두 신원 모두 — dev 판은 bundle id 가 달라 TCC 상 별개 앱이다 (#654).
    for id in "${BUNDLE_IDS[@]}"; do
        tccutil reset Accessibility "$id" >/dev/null 2>&1 || true
        tccutil reset ListenEvent "$id" >/dev/null 2>&1 || true
        echo "Reset: TCC (Accessibility / Input Monitoring) for $id"
    done
fi

if [[ "$removed" -eq 0 ]]; then
    echo "Nothing to remove (already uninstalled)."
fi

if [[ "$PURGE" != "1" ]]; then
    echo ""
    echo "Preserved (--purge 로 지울 수 있음):"
    for id in "${TILDAZ_IDS[@]}"; do
        echo "  $CONFIG_BASE/$id/          (config)"
        echo "  ~/Library/Logs/$id/          (log)"
    done
    echo "  ~/Library/Logs/tildaz_*.log   (log, pre-#654 layout)"
    echo "  code-signing cert '$CERT_NAME' (재빌드 시 유지)"
fi
