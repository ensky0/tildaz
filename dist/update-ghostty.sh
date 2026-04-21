#!/usr/bin/env bash
# ghostty 의존성을 upstream main HEAD 의 특정 커밋으로 갱신하는 스크립트.
#
# build.zig.zon 의 .ghostty dependency 는 반드시 특정 SHA URL 로 pin 해야 한다:
#   - rolling `refs/heads/main.tar.gz` 는 upstream 이 움직이면 CI 의 zig fetch 가
#     해시 불일치로 실패 (과거 c41a9ef pin → e7c3942 회귀 → v0.2.10 에서 재핀).
#   - .github/workflows/release.yml 의 sanity check 가 rolling URL 을 거부함.
#
# 이 스크립트는 그 pin 을 안전하게 갱신해 준다. 실행 예:
#
#   ./dist/update-ghostty.sh
#
# 요구사항:
#   - zig (PATH 에 있어야 함; Windows 에서는 `cmd.exe /c 'where zig'`)
#   - gh   (upstream main HEAD sha 조회)

set -euo pipefail

cd "$(dirname "$0")/.."

command -v zig >/dev/null 2>&1 || { echo "ERROR: zig 가 PATH 에 없습니다" >&2; exit 1; }
command -v gh  >/dev/null 2>&1 || { echo "ERROR: gh 가 PATH 에 없습니다"  >&2; exit 1; }

echo "ghostty-org/ghostty main HEAD 조회..."
SHA=$(gh api repos/ghostty-org/ghostty/commits/main --jq .sha)
if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: upstream sha 가 40자 16진이 아님: $SHA" >&2
  exit 1
fi
echo "  → $SHA"

URL="https://github.com/ghostty-org/ghostty/archive/$SHA.tar.gz"
echo ""
echo "zig fetch --save=ghostty $URL"
zig fetch --save=ghostty "$URL"

echo ""
echo "build.zig.zon 변경:"
if command -v git >/dev/null 2>&1; then
  git --no-pager diff -- build.zig.zon || true
fi

echo ""
echo "완료. 'zig build' 로 검증 후 커밋하세요."
