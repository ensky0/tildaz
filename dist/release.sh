#!/usr/bin/env bash
# tildaz 릴리즈 오케스트레이터 (local entry-point).
#
# 일반 흐름:
#   1. repo 클린 상태 & 버전 일치 확인
#   2. zig build package  → zip + sha256 생성
#   3. git tag v<ver> && git push origin v<ver>
#      → GitHub Actions 의 release 워크플로우가 자동 트리거되어
#        Release 초안을 만들고 zip / sha256 을 업로드
#
# --dry-run 이면 1-2 만 수행하고 tag push 는 skip.
# --local-upload 이면 Actions 를 거치지 않고 여기서 직접 'gh release create'
# (Actions 가 없거나 다운됐을 때의 비상용).
#
# 사전 조건:
#   - build.zig.zon 의 version 이 --version 과 일치
#   - 정식 버전은 dist/release-notes/v<ver>.md 파일 존재 (prerelease는 optional)
#   - git working tree clean
#
# 사용법:
#   dist/release.sh --version 0.6.2-dev.1
#   dist/release.sh --version 0.6.2-dev.1 --dry-run
#   dist/release.sh --version 0.6.2-dev.1 --local-upload

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=""
DRY_RUN=0
LOCAL_UPLOAD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      VERSION="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --local-upload) LOCAL_UPLOAD=1; shift ;;
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

cd "$REPO_ROOT"

# ----- 1. 사전 체크 -----

echo "=== 1/4 Pre-flight checks ==="

# 1a. git clean
if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree is not clean. Commit or stash first." >&2
    git status --short >&2
    exit 1
fi

# 1b. build.zig.zon version 일치
ZON_VER=$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)",[[:space:]]*$/\1/p' build.zig.zon)
if [[ -z "$ZON_VER" ]]; then
    echo "ERROR: could not parse version from build.zig.zon" >&2
    exit 1
fi
if [[ "$ZON_VER" != "$VERSION" ]]; then
    echo "ERROR: build.zig.zon version ($ZON_VER) != --version ($VERSION)." >&2
    echo "       Update build.zig.zon first, then re-run." >&2
    exit 1
fi

# 1c. 정식 버전은 release-notes 파일 필수. prerelease test는 optional.
NOTES_FILE="dist/release-notes/v${VERSION}.md"
if [[ ! -f "$NOTES_FILE" && "$VERSION" != *-* ]]; then
    echo "ERROR: release notes not found at $NOTES_FILE" >&2
    echo "       Create it first (see dist/release-notes/v0.2.8.md for format)." >&2
    exit 1
fi

# 1d. tag 중복
if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 0 ]]; then
        echo "ERROR: tag v${VERSION} already exists locally" >&2
        exit 1
    else
        echo "WARN: tag v${VERSION} already exists (dry-run: ignoring)" >&2
    fi
fi

# 1e. origin 에 tag 중복 (best-effort)
if git ls-remote --tags origin "refs/tags/v${VERSION}" | grep -q .; then
    if [[ "$DRY_RUN" -eq 0 ]]; then
        echo "ERROR: tag v${VERSION} already exists on origin" >&2
        exit 1
    else
        echo "WARN: tag v${VERSION} already exists on origin (dry-run: ignoring)" >&2
    fi
fi

echo "  build.zig.zon version: $ZON_VER ✓"
if [[ -f "$NOTES_FILE" ]]; then
    echo "  release notes       : $NOTES_FILE ✓"
else
    echo "  release notes       : omitted for prerelease ✓"
fi
echo "  git working tree    : clean ✓"
echo "  tag v${VERSION}     : available ✓"

# ----- 2. build + package -----

echo ""
echo "=== 2/4 zig build package ==="
zig build package

# Local platform 의 artifact 만 검증 — Actions runner 가 다른 platform 빌드.
# macOS host 는 universal DMG, Linux host 는 (호스트 arch) tar.gz, Windows host
# 는 zip + ConPTY 동봉. (Linux 호스트에선 `zig build package` 기본 format 이
# tar.gz 라 그 파일을 확인 — 이전엔 Linux 케이스가 없어 `*)` 로 떨어져 win-x64.zip
# 을 기대해 "package output missing" 으로 멈췄음.)
case "$(uname -s)" in
    Darwin)
        ARTIFACT="zig-out/release/tildaz-v${VERSION}-macos.dmg"
        ARTIFACT_LABEL="dmg"
        ;;
    Linux)
        ARTIFACT="zig-out/release/tildaz-v${VERSION}-linux-$(uname -m).tar.gz"
        ARTIFACT_LABEL="tar.gz"
        ;;
    *)
        ARTIFACT="zig-out/release/tildaz-v${VERSION}-win-x64.zip"
        ARTIFACT_LABEL="zip"
        ;;
esac
SHA256="${ARTIFACT}.sha256"
if [[ ! -f "$ARTIFACT" || ! -f "$SHA256" ]]; then
    echo "ERROR: package output missing. Expected $ARTIFACT and $SHA256" >&2
    exit 1
fi
echo "  ${ARTIFACT_LABEL}     : $ARTIFACT"
echo "  sha256  : $SHA256"
echo "  content : $(cat "$SHA256")"

# ----- 3. dry-run 종료점 -----

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    echo "=== DRY-RUN complete ==="
    echo "  Would run: git tag v${VERSION} && git push origin v${VERSION}"
    if [[ "$LOCAL_UPLOAD" -eq 1 ]]; then
        if [[ -f "$NOTES_FILE" ]]; then
            echo "  Would then: gh release create v${VERSION} --notes-file $NOTES_FILE ..."
        else
            echo "  Would then: gh release create v${VERSION} ..."
        fi
    fi
    exit 0
fi

# ----- 4. tag + push (+ optional local upload) -----

echo ""
echo "=== 3/4 git tag + push ==="
git tag "v${VERSION}"
git push origin "v${VERSION}"
echo "  Pushed tag v${VERSION} to origin."

if [[ "$LOCAL_UPLOAD" -eq 1 ]]; then
    echo ""
    echo "=== 4/4 gh release create (local upload) ==="
    RELEASE_ARGS=("v${VERSION}" "$ARTIFACT" "$SHA256" --title "v${VERSION}")
    if [[ -f "$NOTES_FILE" ]]; then
        RELEASE_ARGS+=(--notes-file "$NOTES_FILE")
    fi
    gh release create "${RELEASE_ARGS[@]}"
    echo "  Release created: $(gh release view "v${VERSION}" --json url -q .url)"
else
    echo ""
    echo "=== 4/4 Waiting for GitHub Actions ==="
    echo "  The 'release' workflow should trigger on this tag."
    echo "  Watch at: https://github.com/ensky0/tildaz/actions"
    echo "  (If no workflow exists yet, re-run this script with --local-upload)"
fi

echo ""
echo "Done. v${VERSION} released."
