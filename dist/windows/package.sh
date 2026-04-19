#!/usr/bin/env bash
# tildaz Windows 릴리즈 번들 zip + SHA256 sidecar 생성.
#
# zig-out/bin/ 의 3 파일 (tildaz.exe / conpty.dll / OpenConsole.exe) 과
# dist/windows/README.txt 를 스테이징 폴더에 모아서
#   zig-out/release/tildaz-v<ver>-win-x64.zip
#   zig-out/release/tildaz-v<ver>-win-x64.zip.sha256
# 를 만들어요.
#
# sha256 파일은 GNU coreutils 'sha256sum -c' 호환 포맷
# (`<hex>  <filename>`, LF 줄바꿈).
#
# zip 생성은 OS 에 따라 분기:
#   Windows Git Bash (MINGW/MSYS/CYGWIN)  → PowerShell Compress-Archive
#   macOS / Linux                         → zip 커맨드
#
# 사용법:
#   dist/windows/package.sh --version 0.2.9
#   dist/windows/package.sh --version 0.2.9 --clean

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION=""
CLEAN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --clean)   CLEAN=1; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "ERROR: --version is required (e.g. --version 0.2.9)" >&2
    exit 2
fi

SRC_BIN="$REPO_ROOT/zig-out/bin"
SRC_README="$SCRIPT_DIR/README.txt"
RELEASE_ROOT="$REPO_ROOT/zig-out/release"
NAME="tildaz-v${VERSION}-win-x64"
STAGE="$RELEASE_ROOT/$NAME"
ZIP="$RELEASE_ROOT/${NAME}.zip"
SHA256="${ZIP}.sha256"

# 필수 아티팩트 확인
for f in tildaz.exe conpty.dll OpenConsole.exe; do
    if [[ ! -f "$SRC_BIN/$f" ]]; then
        echo "ERROR: missing artifact '$f' at $SRC_BIN" >&2
        echo "       run 'zig build' first." >&2
        exit 1
    fi
done
if [[ ! -f "$SRC_README" ]]; then
    echo "ERROR: missing README at $SRC_README" >&2
    exit 1
fi

# staging
if [[ "$CLEAN" -eq 1 && -d "$RELEASE_ROOT" ]]; then
    echo "--- Wiping $RELEASE_ROOT ---"
    rm -rf "$RELEASE_ROOT"
fi
mkdir -p "$RELEASE_ROOT"
rm -rf "$STAGE" "$ZIP" "$SHA256"
mkdir -p "$STAGE"

echo "--- Staging to $STAGE ---"
cp "$SRC_BIN/tildaz.exe"      "$STAGE/"
cp "$SRC_BIN/conpty.dll"      "$STAGE/"
cp "$SRC_BIN/OpenConsole.exe" "$STAGE/"
cp "$SRC_README"              "$STAGE/README.txt"
ls -l "$STAGE"

# zip 생성 — OS 분기
echo "--- Creating $ZIP ---"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        # Windows: PowerShell Compress-Archive 호출.
        # cygpath 로 UNIX path → Windows path 변환.
        WIN_STAGE=$(cygpath -w "$STAGE")
        WIN_ZIP=$(cygpath -w "$ZIP")
        powershell.exe -NoProfile -Command \
            "Compress-Archive -Path '$WIN_STAGE\\*' -DestinationPath '$WIN_ZIP' -CompressionLevel Optimal"
        ;;
    *)
        # macOS / Linux: 표준 zip.
        (cd "$STAGE" && zip -r -9 "$ZIP" .)
        ;;
esac

# SHA256 sidecar — 'sha256sum -c' 호환 포맷
echo "--- Creating $SHA256 ---"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$ZIP")" && sha256sum "$(basename "$ZIP")") > "$SHA256"
elif command -v shasum >/dev/null 2>&1; then
    # macOS 기본 환경 fallback
    (cd "$(dirname "$ZIP")" && shasum -a 256 "$(basename "$ZIP")") > "$SHA256"
else
    echo "ERROR: neither sha256sum nor shasum found" >&2
    exit 1
fi

echo "--- Output ---"
ls -l "$ZIP" "$SHA256"
cat "$SHA256"
