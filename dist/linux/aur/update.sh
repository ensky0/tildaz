#!/usr/bin/env bash
# AUR `tildaz-bin` 을 한 릴리즈 판으로 갱신한다 (#862).
#
# 하는 일
#   1. GitHub Release 의 Linux tarball `.sha256` 두 개 (x86_64 · aarch64) 를 받는다.
#   2. 같은 폴더의 `PKGBUILD` 틀에 판 · sha256 을 채운다.
#   3. `makepkg --printsrcinfo` 로 `.SRCINFO` 를 만들고, 이 기기 아키텍처로 한 번
#      묶어 본다 (tarball 을 실제로 받아 sha256 · 압축 안 구성을 확인).
#   4. AUR 저장소를 받아 두 파일을 바꾸고 커밋 · push 한다.
#
# 사용법
#   dist/linux/aur/update.sh --version 0.10.10 [--dry-run]
#
#   --dry-run  push 하지 않는다. 커밋할 diff 만 보여 준다. SSH 키가 없어도 돈다
#              (받기는 익명 https).
#
# 환경 변수
#   AUR_SSH_KEY_FILE  push 에 쓸 개인 키 파일. 없으면 ssh 기본 설정 (~/.ssh/config)
#
# 요구: bash · curl · git · ssh · makepkg (Arch base-devel 또는 Debian
# pacman-package-manager) · bsdtar. makepkg 는 root 로 돌지 않으므로 이 스크립트도
# 일반 사용자로 부른다.
#
# 정식 판만 받는다 — `-dev.N` 같은 prerelease 를 AUR 사용자에게 보내지 않는다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/PKGBUILD"

REPO_URL="https://github.com/ensky0/tildaz"
AUR_PKG="tildaz-bin"
AUR_PULL="https://aur.archlinux.org/${AUR_PKG}.git"
AUR_PUSH="ssh://aur@aur.archlinux.org/${AUR_PKG}.git"
# AUR 홈페이지가 알리는 ed25519 지문 SHA256:RFzBCUItH9LZS0cKB5UE6ceAYhBD5C8GeOBip8Z11+4
# 의 키예요 (2026-11-12 ssh-keyscan 으로 받아 지문을 대조). 서버 키가 바뀌면 push 가
# 멈춰요 — 홈페이지 지문을 다시 확인하고 이 줄을 고쳐요.
AUR_HOST_KEY="aur.archlinux.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEuBKrPzbawxA/k2g6NcyV5jmqwJ2s+zpgZGZ7tpLIcN"
COMMIT_NAME="ensky0"
COMMIT_EMAIL="ensky0@gmail.com"

VERSION=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,/^$/s/^# \?//p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown option '$1'" >&2; exit 2 ;;
    esac
done

VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: --version must be a release version like 0.10.10 (got '$VERSION')." >&2
    echo "       Prereleases are not published to the AUR." >&2
    exit 2
fi
if [[ "$(id -u)" -eq 0 ]]; then
    echo "ERROR: run as a regular user — makepkg refuses root." >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tildaz-aur.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 1. sha256
sha_for() {
    local arch="$1" url line sum
    url="$REPO_URL/releases/download/v$VERSION/tildaz-v$VERSION-linux-$arch.tar.gz.sha256"
    line="$(curl -fsSL --retry 3 "$url")"
    sum="${line%% *}"
    if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
        echo "ERROR: bad checksum file at $url: '$line'" >&2
        exit 1
    fi
    printf '%s' "$sum"
}
SHA_X86_64="$(sha_for x86_64)"
SHA_AARCH64="$(sha_for aarch64)"
echo "sha256 x86_64  $SHA_X86_64"
echo "sha256 aarch64 $SHA_AARCH64"

# 2. PKGBUILD
mkdir -p "$WORK/build"
sed -e "s|@PKGVER@|$VERSION|" \
    -e "s|@SHA256_X86_64@|$SHA_X86_64|" \
    -e "s|@SHA256_AARCH64@|$SHA_AARCH64|" \
    "$TEMPLATE" > "$WORK/build/PKGBUILD"
if grep -n '@[A-Z0-9_]*@' "$WORK/build/PKGBUILD"; then
    echo "ERROR: unfilled placeholder in PKGBUILD" >&2
    exit 1
fi

# 3. .SRCINFO + 시험 빌드
(
    cd "$WORK/build"
    makepkg --printsrcinfo > .SRCINFO
    # 이 기기 아키텍처로 묶어 본다. 실패하면 AUR 에 올리지 않는다.
    PKGDEST="$WORK/build" makepkg -f --nodeps --nosign >/dev/null
)
PKG_FILE="$(find "$WORK/build" -maxdepth 1 -name "$AUR_PKG-$VERSION-1-*.pkg.tar.*" | head -1)"
if [[ -z "$PKG_FILE" ]]; then
    echo "ERROR: makepkg did not produce a package" >&2
    exit 1
fi
FILES="$(bsdtar -tf "$PKG_FILE")"
for f in usr/bin/tildaz usr/share/applications/tildaz.desktop \
         usr/share/icons/hicolor/scalable/apps/tildaz.svg \
         "usr/share/licenses/$AUR_PKG/LICENSE"; do
    grep -qxF "$f" <<< "$FILES" || { echo "ERROR: package is missing $f" >&2; exit 1; }
done
DESKTOP="$(bsdtar -xOf "$PKG_FILE" usr/share/applications/tildaz.desktop)"
if grep -q '__TILDAZ_' <<< "$DESKTOP" || ! grep -qxF 'Exec=/usr/bin/tildaz' <<< "$DESKTOP"; then
    echo "ERROR: desktop entry was not filled:" >&2
    grep -E '^(Name|Exec|Icon|StartupWMClass)=' <<< "$DESKTOP" >&2
    exit 1
fi
echo "test build ok: $(basename "$PKG_FILE")"

# 4. AUR 저장소
printf '%s\n' "$AUR_HOST_KEY" > "$WORK/known_hosts"
SSH_CMD="ssh -o UserKnownHostsFile=$WORK/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes"
if [[ -n "${AUR_SSH_KEY_FILE:-}" ]]; then
    SSH_CMD="$SSH_CMD -i $AUR_SSH_KEY_FILE -o IdentitiesOnly=yes"
fi
export GIT_SSH_COMMAND="$SSH_CMD"

git clone -q "$AUR_PULL" "$WORK/aur" 2>/dev/null || true   # 빈 저장소면 경고만 낸다
cd "$WORK/aur"
git checkout -q -B master
cp "$WORK/build/PKGBUILD" "$WORK/build/.SRCINFO" .
git add PKGBUILD .SRCINFO

if git diff --cached --quiet; then
    echo "AUR $AUR_PKG is already at $VERSION — nothing to push."
    exit 0
fi
# 같은 판인데 내용이 다르면 pkgrel 을 올려야 해요. 자동으로 정하지 않고 멈춰요.
if git rev-parse -q --verify HEAD >/dev/null &&
   git show HEAD:.SRCINFO 2>/dev/null | grep -qxF $'\tpkgver = '"$VERSION"; then
    echo "ERROR: AUR already has $VERSION with different files." >&2
    echo "       Bump pkgrel by hand if the PKGBUILD itself changed." >&2
    git --no-pager diff --cached >&2
    exit 1
fi

git -c user.name="$COMMIT_NAME" -c user.email="$COMMIT_EMAIL" \
    commit -q -m "Update to $VERSION"
git --no-pager show --stat --format='%h %an <%ae>%n%s' HEAD

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "--- dry run: not pushed. Diff:"
    git --no-pager show --format= HEAD
    exit 0
fi
git push -q "$AUR_PUSH" master
echo "pushed $AUR_PKG $VERSION to the AUR"
