#!/usr/bin/env bash
# tildaz macOS 릴리즈 universal binary + DMG 생성 (#133).
#
# 두 target 빌드 → lipo 로 universal binary 합침 → .app 번들 조립 →
# codesign → hdiutil 로 DMG (마운트 후 Applications 로 드래그하는 표준 흐름)
# → SHA256.
#
# 산출물:
#   zig-out/release/tildaz-v<ver>-macos.dmg
#   zig-out/release/tildaz-v<ver>-macos.dmg.sha256
#
# 사용자 첫 실행:
#   - DMG 더블클릭 → Finder 에 가상 디스크 마운트
#   - .app 을 Applications 폴더 alias 로 드래그
#   - 첫 실행 시 macOS 가 ad-hoc 서명에 대해 차단 → 우클릭 \"Open\" 또는
#     `xattr -d com.apple.quarantine /Applications/TildaZ.app`
#   - Input Monitoring + Accessibility 권한 한 번 부여
#
# 사용법:
#   bash dist/macos/package.sh --version 0.2.13
#
# 옵션:
#   --version <ver>    필수. release 파일 이름에 사용.
#   --sign-identity <id>  codesign identity. default `-` (ad-hoc).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION=""
SIGN_IDENTITY="-"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --sign-identity) SIGN_IDENTITY="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "ERROR: --version is required (e.g. --version 0.2.13)" >&2
    exit 2
fi

# Xcode SDK path. cross-compile (host arch != target arch) 시 zig 가 system
# library 자동 검색 안 해서 build.zig 가 -Dmacos-sdk= 로 받음.
SDK="$(xcrun --show-sdk-path)"
if [[ -z "$SDK" ]]; then
    echo "ERROR: xcrun --show-sdk-path returned empty (Xcode / Command Line Tools 설치 필요)" >&2
    exit 1
fi

ARM_PREFIX="$REPO_ROOT/zig-out/macos-arm64"
X86_PREFIX="$REPO_ROOT/zig-out/macos-x86_64"
RELEASE_ROOT="$REPO_ROOT/zig-out/release"
APP_NAME="TildaZ.app"
UNIVERSAL_APP="$REPO_ROOT/zig-out/$APP_NAME"
DMG_STAGING="$REPO_ROOT/zig-out/dmg-staging"
DMG="$RELEASE_ROOT/tildaz-v${VERSION}-macos.dmg"
SHA256="${DMG}.sha256"

cd "$REPO_ROOT"

echo "--- 1. Build aarch64-macos (Apple Silicon) ---"
rm -rf "$ARM_PREFIX"
zig build -Dtarget=aarch64-macos "-Dmacos-sdk=$SDK" \
    "-Dmacos-sign-identity=$SIGN_IDENTITY" \
    -p "$ARM_PREFIX"

echo "--- 2. Build x86_64-macos (Intel) ---"
rm -rf "$X86_PREFIX"
zig build -Dtarget=x86_64-macos "-Dmacos-sdk=$SDK" \
    "-Dmacos-sign-identity=$SIGN_IDENTITY" \
    -p "$X86_PREFIX"

echo "--- 3. Universal binary via lipo ---"
rm -rf "$UNIVERSAL_APP"
mkdir -p "$UNIVERSAL_APP/Contents/MacOS"
lipo -create \
    "$ARM_PREFIX/$APP_NAME/Contents/MacOS/tildaz" \
    "$X86_PREFIX/$APP_NAME/Contents/MacOS/tildaz" \
    -output "$UNIVERSAL_APP/Contents/MacOS/tildaz"
cp "$ARM_PREFIX/$APP_NAME/Contents/Info.plist" "$UNIVERSAL_APP/Contents/Info.plist"
echo "Universal binary architectures:"
lipo -info "$UNIVERSAL_APP/Contents/MacOS/tildaz"

echo "--- 4. Re-codesign universal .app (lipo 후 서명 다시) ---"
codesign --force --sign "$SIGN_IDENTITY" "$UNIVERSAL_APP"
codesign -dv "$UNIVERSAL_APP" 2>&1 | grep -i 'authority\|identifier' || true

echo "--- 5. DMG staging dir (.app + Applications alias) ---"
rm -rf "$DMG_STAGING"
mkdir "$DMG_STAGING"
cp -R "$UNIVERSAL_APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

echo "--- 6. hdiutil create DMG ($DMG) ---"
mkdir -p "$RELEASE_ROOT"
rm -f "$DMG" "$SHA256"
# UDZO = compressed read-only. 사용자 마운트 후 .app 드래그만 하면 됨.
hdiutil create \
    -volname "TildaZ" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG"

echo "--- 7. SHA256 sidecar ---"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$RELEASE_ROOT" && sha256sum "$(basename "$DMG")") > "$SHA256"
else
    (cd "$RELEASE_ROOT" && shasum -a 256 "$(basename "$DMG")") > "$SHA256"
fi

echo "--- Output ---"
ls -l "$DMG" "$SHA256"
cat "$SHA256"
