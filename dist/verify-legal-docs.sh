#!/usr/bin/env bash
# 릴리즈 아티팩트를 실제로 열어 LICENSE / THIRD-PARTY-NOTICES.md 가 들어갔는지
# 확인한다 (#486).
#
# 왜 필요한가: 배포 바이너리는 정적 링크라 uucode (MIT) 와 Google Highway
# (Apache-2.0) 의 컴파일된 코드를 담는다. MIT 는 사본 배포 시 저작권 고지 포함을,
# Apache-2.0 §4(a) 는 라이선스 사본 제공을 요구한다. 패키징 스크립트에 파일 복사를
# 추가하는 것만으로는 부족하다 — 나중 리팩터링에서 조용히 빠져도 릴리즈가 그대로
# 나가기 때문이다. 산출물을 열어 확인하는 이 검사가 회귀를 막는 자리다.
#
# 사용:
#   dist/verify-legal-docs.sh --artifact <path> --format tar.gz|deb|rpm|AppImage|pkg|dmg
#
# 참고: Windows zip 은 이 스크립트를 쓰지 않는다 — release.yml 의 Windows
# verify step 이 PowerShell 로 직접 확인한다 (runner 의 bash 에 unzip 이 없다).

set -euo pipefail

ARTIFACT=""
FORMAT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifact) ARTIFACT="$2"; shift 2 ;;
        --format)   FORMAT="$2";   shift 2 ;;
        -h|--help)  sed -n '2,/^$/s/^# \?//p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -z "$ARTIFACT" ]] && { echo "ERROR: --artifact required" >&2; exit 2; }
[[ -z "$FORMAT" ]] && { echo "ERROR: --format required" >&2; exit 2; }
[[ -f "$ARTIFACT" ]] || { echo "ERROR: artifact not found: $ARTIFACT" >&2; exit 1; }

# 포맷별 기대 경로. deb 은 Debian 관례로 라이선스 본문을 `copyright` 로 둔다.
case "$FORMAT" in
    tar.gz)   EXPECT=("LICENSE" "THIRD-PARTY-NOTICES.md") ;;
    deb)      EXPECT=("usr/share/doc/tildaz/copyright" "usr/share/doc/tildaz/THIRD-PARTY-NOTICES.md") ;;
    rpm)      EXPECT=("usr/share/licenses/tildaz/LICENSE" "usr/share/doc/tildaz/THIRD-PARTY-NOTICES.md") ;;
    pkg)      EXPECT=("usr/share/licenses/tildaz/LICENSE" "usr/share/licenses/tildaz/THIRD-PARTY-NOTICES.md") ;;
    dmg)      EXPECT=("LICENSE" "THIRD-PARTY-NOTICES.md") ;;
    AppImage)
        # AppImage type 2 는 ELF + squashfs 라 내용 목록을 얻으려면 payload
        # offset 이 필요하고, offset 조회는 그 AppImage 를 *실행* 해야 한다
        # (--appimage-offset). x86_64 runner 에서 aarch64 AppImage 는 실행할 수
        # 없어 cross-arch 검증이 불가능하다. magic 을 직접 스캔하는 우회는 두지
        # 않는다.
        #
        # 대신 package.sh 의 build_appimage 가 AppDir 단계에서
        # validate_legal_docs 로 확인한다 — appimagetool 은 AppDir 전체를
        # 담으므로 그 지점이 실질적 보증이다. 여기서는 커버 못 하는 사실을
        # 명시하고 넘어간다.
        echo "SKIP: AppImage 내용 검사는 cross-arch 로 불가 (payload offset 조회에 실행이 필요)."
        echo "      AppDir 단계에서 dist/linux/package.sh 의 validate_legal_docs 가 확인함."
        exit 0
        ;;
    *) echo "ERROR: unsupported --format '$FORMAT'" >&2; exit 2 ;;
esac

# 아티팩트 내용 목록을 표준출력으로 낸다.
list_contents() {
    case "$FORMAT" in
        tar.gz) tar -tzf "$ARTIFACT" ;;
        deb)
            command -v dpkg-deb >/dev/null 2>&1 || {
                echo "ERROR: dpkg-deb not found — cannot inspect .deb" >&2; exit 1; }
            dpkg-deb -c "$ARTIFACT" | awk '{print $NF}'
            ;;
        rpm)
            command -v rpm2cpio >/dev/null 2>&1 || {
                echo "ERROR: rpm2cpio not found — cannot inspect .rpm" >&2; exit 1; }
            rpm2cpio "$ARTIFACT" | cpio -t 2>/dev/null
            ;;
        pkg) tar -tf "$ARTIFACT" ;;
        dmg)
            local mnt
            mnt=$(mktemp -d)
            hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$ARTIFACT" >/dev/null
            # detach 는 실패해도 검증 결과를 덮지 않도록 trap 으로 분리.
            trap 'hdiutil detach "$mnt" >/dev/null 2>&1 || true; rm -rf "$mnt"' RETURN
            (cd "$mnt" && find . -maxdepth 1 -type f | sed 's|^\./||')
            ;;
    esac
}

CONTENTS=$(list_contents)

echo "--- $FORMAT: $ARTIFACT ---"
MISSING=0
for want in "${EXPECT[@]}"; do
    # 경로 앞에 `./` 나 tarball 최상위 디렉터리가 붙을 수 있어 접미 일치로 본다.
    if printf '%s\n' "$CONTENTS" | grep -qE "(^|/)${want//./\\.}$"; then
        echo "  OK      $want"
    else
        echo "  MISSING $want"
        MISSING=1
    fi
done

if [[ "$MISSING" -ne 0 ]]; then
    echo "ERROR: legal documents missing from $FORMAT artifact: $ARTIFACT" >&2
    echo "--- artifact contents ---" >&2
    printf '%s\n' "$CONTENTS" >&2
    exit 1
fi

echo "  → LICENSE + THIRD-PARTY-NOTICES.md 확인됨"
