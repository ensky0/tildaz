#!/usr/bin/env bash
# tildaz Windows 빌드 스크립트.
#
# Git Bash (Windows) / macOS / Linux 모두에서 같은 방식으로 실행돼요.
# 실제 빌드는 zig 가 담당하고, 이 스크립트는 인자 파싱 + 캐시 디렉토리
# 관리 + clean 옵션 처리만 해요.
#
# zig 가 WSL UNC 경로 (\\wsl.localhost\...) 를 source root 로 받을 때
# Windows 로컬 캐시가 있어야 속도가 나오므로 Windows 에서는 기본 캐시를
# C:/ziglang/tildaz-cache 로 잡아요. Linux/macOS 는 zig 기본 캐시 위치
# (.zig-cache) 를 그대로 씀.
#
# 사용법:
#   dist/windows/build.sh
#   dist/windows/build.sh --clean
#   dist/windows/build.sh --optimize Debug
#   dist/windows/build.sh --cache-dir /tmp/zig-cache

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CLEAN=0
OPTIMIZE="ReleaseFast"
# Windows 에서는 로컬 캐시 기본, 그 외엔 zig 기본 (.zig-cache)
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) CACHE_DIR="C:/ziglang/tildaz-cache" ;;
    *)                    CACHE_DIR="" ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)      CLEAN=1; shift ;;
        --optimize)   OPTIMIZE="$2"; shift 2 ;;
        --cache-dir)  CACHE_DIR="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

cd "$REPO_ROOT"

echo "--- Pre-build zig-out/bin ---"
if [[ -d zig-out/bin ]]; then
    ls -l zig-out/bin
else
    echo "(no zig-out/bin)"
fi

if [[ "$CLEAN" -eq 1 ]]; then
    echo "--- Wiping zig-out/ and cache ---"
    rm -rf zig-out
    if [[ -n "$CACHE_DIR" && -d "$CACHE_DIR" ]]; then
        rm -rf "$CACHE_DIR"
    fi
fi

echo "--- zig build -Doptimize=$OPTIMIZE ---"
if [[ -n "$CACHE_DIR" ]]; then
    zig build "-Doptimize=$OPTIMIZE" --cache-dir "$CACHE_DIR"
else
    zig build "-Doptimize=$OPTIMIZE"
fi

echo "--- Post-build zig-out/bin ---"
if [[ -d zig-out/bin ]]; then
    ls -l zig-out/bin
else
    echo "(no zig-out/bin produced!)" >&2
    exit 1
fi
