#!/usr/bin/env bash
# Stable local signing identity로 ReleaseFast app을 빌드해 /Applications에 설치.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIGN_IDENTITY="${TILDAZ_SIGN_IDENTITY:-TildazLocal}"
INSTALL_PATH="${TILDAZ_INSTALL_PATH:-/Applications/TildaZ.app}"

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
echo "--- Build TildaZ (ReleaseFast, identity: $SIGN_IDENTITY) ---"
zig build \
    "-Dmacos-sign-identity=$SIGN_IDENTITY" \
    -Doptimize=ReleaseFast

echo "--- Install $INSTALL_PATH ---"
mkdir -p "$(dirname "$INSTALL_PATH")"
ditto "zig-out/TildaZ.app" "$INSTALL_PATH"

echo "--- Verify signature ---"
codesign --verify --deep --strict "$INSTALL_PATH"
codesign -dv "$INSTALL_PATH" 2>&1 | grep -i 'authority\|identifier' || true

echo "Installed: $INSTALL_PATH"
echo "Open TildaZ from Applications to refresh its LaunchAgent path if auto-start is enabled."
