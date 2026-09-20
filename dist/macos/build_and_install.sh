#!/usr/bin/env bash
# Stable local signing identity로 ReleaseFast app을 빌드해 /Applications에 설치.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIGN_IDENTITY="${TILDAZ_SIGN_IDENTITY:-TildazLocal}"
# 이 스크립트는 **개발 설치**다 — dmg 로 깐 릴리즈와 나란히 두려면 번들 이름과 bundle id
# 가 달라야 한다 (#654). `--release` 로 릴리즈 판을 만들 수도 있다 (그때는 릴리즈 번들을
# 덮어쓰므로 이름도 TildaZ.app 이다).
TILDAZ_DEV="${TILDAZ_DEV:-1}"
for arg in "$@"; do
    case "$arg" in
        --release) TILDAZ_DEV=0 ;;
        --dev) TILDAZ_DEV=1 ;;
    esac
done
if [[ "$TILDAZ_DEV" -eq 1 ]]; then
    BUNDLE_NAME="TildaZ-dev.app"
    DEV_FLAG="-Ddev=true"
else
    BUNDLE_NAME="TildaZ.app"
    DEV_FLAG="-Ddev=false"
fi
INSTALL_PATH="${TILDAZ_INSTALL_PATH:-/Applications/$BUNDLE_NAME}"

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

# zig 가 번들로 들고 있는 float.h 가 macOS 27 SDK 의 __need_infinity_nan 규약을 모르면
# -Dsimd=true 가 libc++ sub-compilation 에서 깨진다 (#665). 위 서명 identity 와 마찬가지로
# "기기마다 한 번 고쳐 두면 되는 것" 이라 같은 자리에서 자동으로 처리한다.
FLOATH_PATCH="$REPO_ROOT/tool/zig-floath-patch_macos.sh"
if [ -x "$FLOATH_PATCH" ] && ! "$FLOATH_PATCH" --check >/dev/null 2>&1; then
    echo "--- zig's bundled float.h predates the macOS 27 SDK protocol (#665) ---"
    echo "Patching the zig installation once (revert: $FLOATH_PATCH --revert)"
    "$FLOATH_PATCH" || echo "WARNING: the float.h patch did not apply; continuing." >&2
fi

echo "--- Build $BUNDLE_NAME (ReleaseFast + SIMD, identity: $SIGN_IDENTITY) ---"
if ! zig build \
    "-Dmacos-sign-identity=$SIGN_IDENTITY" \
    "$DEV_FLAG" \
    -Doptimize=ReleaseFast \
    -Dsimd=true; then
    # 폴백 — 로컬 설치는 릴리즈 아티팩트가 아니므로 (릴리즈는 GitHub Actions 가 만든다)
    # SIMD 없이라도 설치까지 끝낸다. 잃는 것은 이 기기에서의 SIMD 성능 측정뿐이다.
    echo "WARNING: the SIMD build failed; retrying without SIMD (#665)." >&2
    echo "         A local install is not a release artifact, so only SIMD" >&2
    echo "         performance work on this machine is affected." >&2
    zig build \
        "-Dmacos-sign-identity=$SIGN_IDENTITY" \
        "$DEV_FLAG" \
        -Doptimize=ReleaseFast
fi

echo "--- Install $INSTALL_PATH ---"
mkdir -p "$(dirname "$INSTALL_PATH")"
ditto "zig-out/$BUNDLE_NAME" "$INSTALL_PATH"

echo "--- Verify signature ---"
codesign --verify --deep --strict "$INSTALL_PATH"
codesign -dv "$INSTALL_PATH" 2>&1 | grep -i 'authority\|identifier' || true

echo "Installed: $INSTALL_PATH"
echo "Open it from Applications to refresh its LaunchAgent path if auto-start is enabled."
if [[ "$TILDAZ_DEV" -eq 1 ]]; then
    echo
    echo "This is a dev build: bundle id me.ensky0.tildaz.dev, config/logs under tildaz-dev."
    echo "macOS treats it as a separate app, so grant Input Monitoring and"
    echo "Device Control and Data Access (Accessibility before macOS 27) once."
fi
