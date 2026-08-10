#!/usr/bin/env bash
# tildaz 로컬 빌드용 self-signed code-signing 인증서 setup (idempotent + 자동 trust).
#
# 한 번 실행하면 끝 (신뢰 등록까지 스크립트가 직접):
#   - login keychain 에 "TildazLocal" 인증서 + private key
#   - System keychain 에 codeSign trust 등록 (sudo — 터미널에서 admin 비번)
#   - codesign partition-list (best-effort; 회사 정책이 막으면 빌드 시 '항상 허용')
#   - `~/.tildaz/` 에 p12 + crt 백업 — keychain 이 밀려도 되살릴 수 있게 (#444)
#
# 안정 signing identity + 고정 bundle id (me.ensky0.tildaz) → 코드 바꿔도 같은 앱
# 으로 인식 → Input Monitoring / Accessibility(TCC) 권한 한 번 부여 후 유지.
# ad-hoc 서명은 매 빌드 hash 가 바뀌어 TCC 가 매번 재요구 — 그걸 없애는 게 목적.
#
# **identity 가 사라졌을 때 이 스크립트를 먼저 쓰지 않아요.** 새로 만들면 서명 해시가
# 바뀌어 TCC 권한을 다시 줘야 하고 CI 의 `MACOS_CERTIFICATE_SHA1` 도 갱신해야 해요.
# 백업이 있으면 `restore-cert.sh` 로 **같은 인증서**를 되살려요 (#444).
#
# 이후 빌드:
#   ./dist/macos/build_and_install.sh
#   # 또는 설치 없이 dev 루프:
#   zig build -Dmacos-sign-identity=TildazLocal -Doptimize=ReleaseSafe && open zig-out/TildaZ.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dist/macos/cert-common.sh
source "$SCRIPT_DIR/cert-common.sh"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# 이미 유효(trusted) codesigning identity 가 있으면 아무것도 안 함 (idempotent).
if has_valid_identity; then
    echo "'$CERT_NAME' codesigning identity 가 이미 유효합니다 — 할 일 없음."
    echo "빌드:  zig build -Dmacos-sign-identity=$CERT_NAME -Doptimize=ReleaseSafe && open zig-out/TildaZ.app"
    exit 0
fi

# 백업이 있으면 새로 만들지 않는다 — 새 인증서는 TCC 권한 재부여 + secrets/CI 갱신을
# 부르므로, 같은 인증서로 되살리는 쪽이 항상 싸다 (#444).
if [[ -f "$P12_BACKUP" ]]; then
    echo "백업된 인증서가 있습니다: $P12_BACKUP" >&2
    echo "" >&2
    echo "새로 만들면 서명 해시가 바뀌어 Input Monitoring / Accessibility 권한을 다시" >&2
    echo "부여해야 하고, GitHub secrets 와 CI 의 MACOS_CERTIFICATE_SHA1 도 갱신해야 합니다." >&2
    echo "먼저 같은 인증서로 되살려 보세요:" >&2
    echo "" >&2
    echo "    $SCRIPT_DIR/restore-cert.sh" >&2
    echo "" >&2
    echo "정말 새로 만들려면 백업을 옮기거나 지운 뒤 다시 실행하세요." >&2
    exit 1
fi

# login password — unlock + partition-list 에 필요. osascript hidden input (로그 X).
PW=$(ask_login_password "codesign cert setup")
if [[ -z "$PW" ]]; then
    echo "ERROR: password 입력 안 됨." >&2
    exit 1
fi
if ! unlock_login_keychain "$PW"; then
    echo "ERROR: login keychain unlock 실패 — password 틀렸거나 경로 다름." >&2
    exit 1
fi

echo "--- 0. 기존 '$CERT_NAME' 잔재 정리 (누적/중복 방지) ---"
# 유효 identity 는 위에서 이미 걸러졌으니, 여기 오면 남은 건 untrusted 잔재뿐.
# 지우고 새로 만든다 (orphan 키가 남을 수 있으나 identity 아니라 무해).
security delete-identity -c "$CERT_NAME" >/dev/null 2>&1 || true
sudo security delete-certificate -c "$CERT_NAME" "$SYSTEM_KEYCHAIN" >/dev/null 2>&1 || true

echo "--- 1. self-signed code-signing cert 생성 ---"
# keyUsage=digitalSignature + extendedKeyUsage=codeSigning 둘 다 필수 (빠지면
# Apple codesign policy 가 "Invalid Key Usage" 로 reject).
openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR/key.pem" -out "$TMPDIR/crt.pem" \
    -days 3650 -nodes -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" 2>&1 | tail -3
openssl pkcs12 -export -inkey "$TMPDIR/key.pem" -in "$TMPDIR/crt.pem" \
    -out "$TMPDIR/cert.p12" -password "pass:$P12_PASSWORD" -name "$CERT_NAME" 2>&1 | tail -2

echo "--- 2. login keychain 에 import ---"
import_p12 "$TMPDIR/cert.p12" 2>&1 | tail -3

echo "--- 3. 백업 저장 (keychain 이 밀려도 되살릴 수 있게) ---"
save_backup "$TMPDIR/cert.p12" "$TMPDIR/crt.pem"

echo "--- 4. System keychain 에 codeSign trust 등록 (sudo — admin 비번) ---"
if register_trust "$CERT_BACKUP"; then
    echo "  trust 등록 완료."
else
    echo "  경고: 자동 trust 실패 — 아래를 수동 실행:" >&2
    echo "    sudo security add-trusted-cert -d -r trustRoot -p codeSign -k $SYSTEM_KEYCHAIN $CERT_BACKUP" >&2
fi

echo "--- 5. codesign partition-list (best-effort — 프롬프트 제거 시도) ---"
if allow_codesign_partition "$PW"; then
    echo "  OK — codesign 이 프롬프트 없이 '$CERT_NAME' 키 사용."
else
    echo "  (partition-list 실패 — 회사 정책 등. 빌드 시 키체인 dialog 뜨면 '항상 허용' 한 번.)"
fi

report_identity || true
echo ""
echo "빌드:  zig build -Dmacos-sign-identity=$CERT_NAME -Doptimize=ReleaseSafe && open zig-out/TildaZ.app"
echo "       (codesign dialog 뜨면 '항상 허용'. 첫 실행 후 손쉬운 사용/입력 모니터링 권한 한 번.)"
echo ""
echo "새 인증서라면 아래도 갱신해야 해요 (#444):"
echo "  - GitHub secrets: MACOS_CERTIFICATE_P12_BASE64 / MACOS_CERTIFICATE_PASSWORD"
echo "  - .github/workflows/{macos-signing-check,release}.yml 의 MACOS_CERTIFICATE_SHA1"
