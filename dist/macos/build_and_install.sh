#!/usr/bin/env bash
# Stable local signing identity로 `fast` app을 빌드해 /Applications에 설치.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIGN_IDENTITY="${TILDAZ_SIGN_IDENTITY:-TildazLocal}"
# 세 OS 공통: 기본 dev, --release 를 명시한 경우만 릴리즈 (#654).
IS_DEV=1
for arg in "$@"; do
    case "$arg" in
        --release) IS_DEV=0 ;;
        -h|--help)
            echo "Usage: $0 [--release]"
            echo "Build and install dev by default; --release selects the release identity."
            exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done
if [[ "$IS_DEV" -eq 1 ]]; then
    BUNDLE_NAME="TildaZ-dev.app"
    RELEASE_FLAG="-Drelease=false"
else
    BUNDLE_NAME="TildaZ.app"
    RELEASE_FLAG="-Drelease=true"
fi
INSTALL_PATH="${TILDAZ_INSTALL_PATH:-/Applications/$BUNDLE_NAME}"
# 설치 위치를 바꾸더라도 다른 판의 번들을 덮어쓰면 안 된다.
if [[ "$(basename "$INSTALL_PATH")" != "$BUNDLE_NAME" ]]; then
    echo "ERROR: install path must end in $BUNDLE_NAME" >&2
    exit 2
fi

has_identity() {
    security find-identity -v -p codesigning 2>/dev/null |
        grep -Fq "\"$SIGN_IDENTITY\""
}

if ! has_identity; then
    echo "Code-signing identity '$SIGN_IDENTITY' was not found."
    echo "Starting the one-time certificate setup..."
    "$SCRIPT_DIR/setup-cert.sh"
fi

if ! has_identity; then
    echo "ERROR: '$SIGN_IDENTITY' is not yet a valid code-signing identity." >&2
    echo "Complete the trust command printed by setup-cert.sh, then run this script again." >&2
    exit 1
fi

cd "$REPO_ROOT"

# SIMD 빌드가 실패하면 그 자리에서 멈춘다 (set -e). 예전에는 SIMD 없이 다시 빌드해 설치까지
# 끝냈는데 (#665), 그러면 로컬 측정이 SIMD 없는 판으로 조용히 돌 수 있어 뺐다.
echo "--- Build $BUNDLE_NAME (fast + SIMD, identity: $SIGN_IDENTITY) ---"
zig build \
    "-Dmacos-sign-identity=$SIGN_IDENTITY" \
    "$RELEASE_FLAG" \
    -Doptimize=fast \
    -Dsimd=true

echo "--- Install $INSTALL_PATH ---"
mkdir -p "$(dirname "$INSTALL_PATH")"
ditto "zig-out/$BUNDLE_NAME" "$INSTALL_PATH"

echo "--- Verify signature ---"
codesign --verify --deep --strict "$INSTALL_PATH"
codesign -dv "$INSTALL_PATH" 2>&1 | grep -i 'authority\|identifier' || true

echo "Installed: $INSTALL_PATH"
echo "Open it from Applications to refresh its LaunchAgent path if auto-start is enabled."
if [[ "$IS_DEV" -eq 1 ]]; then
    echo
    echo "This is a dev build: bundle id me.ensky0.tildaz.dev, config/logs under tildaz-dev."
    echo "macOS treats it as a separate app, so grant Input Monitoring and"
    echo "Device Control and Data Access (Accessibility before macOS 27) once."
fi
