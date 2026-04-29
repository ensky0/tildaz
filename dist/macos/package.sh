#!/usr/bin/env bash
# tildaz macOS 릴리즈 번들 zip + SHA256 sidecar 생성.
#
# zig-out/TildaZ.app (ad-hoc 서명된 .app 번들) 을 그대로 zip 으로 묶어
#   zig-out/release/tildaz-v<ver>-macos-aarch64.zip
#   zig-out/release/tildaz-v<ver>-macos-aarch64.zip.sha256
# 를 만들어요.
#
# Apple Developer ID 인증서가 없어 ad-hoc 서명만 — 사용자가 처음 다운로드
# 후 한 번:
#   xattr -d com.apple.quarantine ./TildaZ.app
# 를 실행하거나 시스템 설정 → 개인정보 보호 및 보안 → "확인되지 않은 개발자
# 허용" 으로 우회. CI 빌드의 ad-hoc identity 는 빌드마다 일정해서, 권한 (Input
# Monitoring + Accessibility) 도 한 번만 부여하면 다음 릴리즈에서도 유지됨.
#
# zip 은 ditto 사용 — 표준 zip 과 달리 macOS metadata (resource fork, codesign)
# 를 깨지 않고 보존. 일반 zip 은 .app 의 codesign 을 깨뜨려 사용 불가.
#
# 사용법:
#   dist/macos/package.sh --version 0.2.13

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
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

APP_BUNDLE="$REPO_ROOT/zig-out/TildaZ.app"
RELEASE_ROOT="$REPO_ROOT/zig-out/release"
NAME="tildaz-v${VERSION}-macos-aarch64"
ZIP="$RELEASE_ROOT/${NAME}.zip"
SHA256="${ZIP}.sha256"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: missing $APP_BUNDLE — run 'zig build' first" >&2
    exit 1
fi

mkdir -p "$RELEASE_ROOT"
rm -f "$ZIP" "$SHA256"

# ditto 가 codesign / extended attributes 보존. 일반 zip 은 .app 깨뜨림.
echo "--- Creating $ZIP via ditto ---"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"

# SHA256 (sha256sum 우선, 없으면 shasum)
echo "--- Creating $SHA256 ---"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$ZIP")" && sha256sum "$(basename "$ZIP")") > "$SHA256"
else
    (cd "$(dirname "$ZIP")" && shasum -a 256 "$(basename "$ZIP")") > "$SHA256"
fi

echo "--- Output ---"
ls -l "$ZIP" "$SHA256"
cat "$SHA256"
