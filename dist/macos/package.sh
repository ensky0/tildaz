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
#   - Developer ID/notarization이 없어 macOS가 첫 실행을 차단하면 우클릭 \"Open\" 또는
#     `xattr -d com.apple.quarantine /Applications/TildaZ.app`
#   - Input Monitoring + Accessibility 권한 한 번 부여
#
# 사용법:
#   bash dist/macos/package.sh --version 0.6.2-dev.1 --simd true
#
# 옵션:
#   --version <ver>    필수. release 파일 이름에 사용.
#   --sign-identity <id>  두 architecture와 최종 app의 codesign identity.
#                         default `-` (ad-hoc).
#   --simd <true|false>   두 architecture의 ghostty VT SIMD. default false.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION=""
SIGN_IDENTITY="-"
SIMD="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --sign-identity) SIGN_IDENTITY="$2"; shift 2 ;;
        --simd)
            [[ $# -ge 2 ]] || { echo "ERROR: --simd requires true or false" >&2; exit 2; }
            SIMD="$2"
            shift 2
            ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "ERROR: --version is required (e.g. --version 0.6.2-dev.1)" >&2
    exit 2
fi
case "$SIMD" in
    true|false) ;;
    *) echo "ERROR: --simd must be 'true' or 'false' (got '$SIMD')" >&2; exit 2 ;;
esac

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
    -Doptimize=ReleaseFast \
    "-Dsimd=$SIMD" \
    -p "$ARM_PREFIX"

echo "--- 2. Build x86_64-macos (Intel) ---"
rm -rf "$X86_PREFIX"
zig build -Dtarget=x86_64-macos "-Dmacos-sdk=$SDK" \
    "-Dmacos-sign-identity=$SIGN_IDENTITY" \
    -Doptimize=ReleaseFast \
    "-Dsimd=$SIMD" \
    -p "$X86_PREFIX"

echo "--- 3. Universal binary via lipo ---"
rm -rf "$UNIVERSAL_APP"
mkdir -p "$UNIVERSAL_APP/Contents/MacOS"
lipo -create \
    "$ARM_PREFIX/$APP_NAME/Contents/MacOS/tildaz" \
    "$X86_PREFIX/$APP_NAME/Contents/MacOS/tildaz" \
    -output "$UNIVERSAL_APP/Contents/MacOS/tildaz"
cp "$ARM_PREFIX/$APP_NAME/Contents/Info.plist" "$UNIVERSAL_APP/Contents/Info.plist"
mkdir -p "$UNIVERSAL_APP/Contents/Resources"
cp "$ARM_PREFIX/$APP_NAME/Contents/Resources/AppIcon.icns" "$UNIVERSAL_APP/Contents/Resources/AppIcon.icns"
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

# LICENSE + THIRD-PARTY-NOTICES.md 를 DMG 루트에 둔다 (#486).
#
# .app 번들 안 (Contents/Resources) 이 아니라 번들 *밖* 인 이유가 두 가지다.
# (1) 위 4단계가 lipo 후 universal .app 을 다시 codesign 하므로, 그 뒤에 번들
#     안으로 파일을 넣으면 서명이 깨진다. 순서 의존을 만들지 않는다.
# (2) 마운트하면 .app 과 나란히 바로 보인다 — 고지의 목적에 맞다.
#
# 조용한 skip 을 두지 않는다: 고지 없는 아티팩트는 라이선스 준수 결함이다.
for legal_src in "$REPO_ROOT/LICENSE" "$REPO_ROOT/THIRD-PARTY-NOTICES.md"; do
    if [[ ! -f "$legal_src" ]]; then
        echo "ERROR: legal document missing at $legal_src" >&2
        exit 1
    fi
    install -m 644 "$legal_src" "$DMG_STAGING/$(basename "$legal_src")"
done

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
