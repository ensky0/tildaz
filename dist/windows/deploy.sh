#!/usr/bin/env bash
# (로컬 테스트 보조) 방금 빌드한 tildaz.exe / tildaz.pdb 를 외부 디렉토리로 복사.
#
# 개발자 로컬 검증 편의용 — 예를 들어 WSL UNC 경로 (\\wsl.localhost\...) 에서
# 직접 실행하는 대신 Windows 로컬 디렉토리로 복사해 돌릴 때 사용해요.
# 릴리즈 파이프라인과는 무관합니다 (릴리즈 zip 은 dist/windows/package.sh 가 담당).
#
# 사용법:
#   dist/windows/deploy.sh --dest C:/tildaz_win/zig-out/bin
#   dist/windows/deploy.sh --dest /c/tildaz_win/zig-out/bin   # Git Bash 경로도 OK

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest) DEST="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$DEST" ]]; then
    echo "ERROR: --dest is required" >&2
    exit 2
fi

SRC_BIN="$REPO_ROOT/zig-out/bin"
if [[ ! -d "$SRC_BIN" ]]; then
    echo "ERROR: $SRC_BIN not found. Run 'zig build' first." >&2
    exit 1
fi

mkdir -p "$DEST"
for f in tildaz.exe tildaz.pdb; do
    if [[ -f "$SRC_BIN/$f" ]]; then
        cp -f "$SRC_BIN/$f" "$DEST/"
    else
        echo "WARN: $f not found in $SRC_BIN (skip)" >&2
    fi
done

ls -l "$DEST/tildaz.exe" "$DEST/tildaz.pdb" 2>/dev/null || true
