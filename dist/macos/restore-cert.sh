#!/usr/bin/env bash
# 백업된 p12 로 TildazLocal code-signing identity 를 **같은 인증서로** 되살린다 (#444).
#
# 언제 쓰나 — `security find-identity -v -p codesigning` 에 `TildazLocal` 이 안 보이고
# `build_and_install.sh` 가 서명 단계에서 멈출 때. login keychain 이 밀리면 (macOS 가
# `login_renamed_N.keychain-db` 로 밀어내고 새로 만드는 경우, 2026-08-10 실제 발생)
# 인증서와 private key 가 함께 사라진다.
#
# 왜 `setup-cert.sh` 로 새로 만들지 않나 — 새 인증서는 서명 해시를 바꾼다. 그러면
# Input Monitoring / Accessibility (TCC) 권한을 다시 부여해야 전역 hotkey 가 돌아오고,
# GitHub secrets 와 CI 의 `MACOS_CERTIFICATE_SHA1` 도 갱신해야 한다. 같은 인증서로
# 되살리면 그 전부가 그대로다.
#
# 필요한 입력: 로그인 password (keychain unlock · partition-list) + admin password
# (`sudo security add-trusted-cert`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dist/macos/cert-common.sh
source "$SCRIPT_DIR/cert-common.sh"

if has_valid_identity; then
    echo "'$CERT_NAME' codesigning identity 가 이미 유효합니다 — 할 일 없음."
    report_identity || true
    exit 0
fi

if [[ ! -f "$P12_BACKUP" ]]; then
    echo "ERROR: 백업이 없습니다 — $P12_BACKUP" >&2
    echo "" >&2
    echo "되살릴 원본이 없으니 새로 만들어야 합니다:" >&2
    echo "    $SCRIPT_DIR/setup-cert.sh" >&2
    echo "" >&2
    echo "새 인증서는 TCC 권한 재부여 + GitHub secrets / CI SHA1 갱신이 함께 필요합니다 (#444)." >&2
    exit 1
fi

echo "--- 복구 대상 확인 ---"
echo "  백업: $P12_BACKUP"
# 지문을 먼저 보여준다 — CI 의 MACOS_CERTIFICATE_SHA1 과 같은지 눈으로 대조할 수 있게.
if openssl pkcs12 -in "$P12_BACKUP" -passin "pass:$P12_PASSWORD" -nokeys -clcerts 2>/dev/null |
    openssl x509 -noout -fingerprint -sha1 -subject 2>/dev/null; then
    :
else
    echo "  (지문 확인 실패 — p12 password 가 다르거나 형식이 예상과 다릅니다. 계속 시도합니다.)" >&2
fi

PW=$(ask_login_password "signing identity 복구")
if [[ -z "$PW" ]]; then
    echo "ERROR: password 입력 안 됨." >&2
    exit 1
fi
if ! unlock_login_keychain "$PW"; then
    echo "ERROR: login keychain unlock 실패 — password 틀렸거나 경로 다름." >&2
    exit 1
fi

echo "--- 1. 잔재 정리 ---"
# 유효 identity 는 위에서 걸러졌으니 남은 건 untrusted 잔재뿐. 지우고 다시 넣는다.
security delete-identity -c "$CERT_NAME" >/dev/null 2>&1 || true

echo "--- 2. login keychain 에 백업 p12 import ---"
import_p12 "$P12_BACKUP" 2>&1 | tail -3

echo "--- 3. System keychain 에 codeSign trust 등록 (sudo — admin 비번) ---"
# crt 백업이 없으면 p12 에서 공개 인증서만 뽑아 쓴다.
if [[ ! -f "$CERT_BACKUP" ]]; then
    echo "  crt 백업이 없어 p12 에서 추출합니다."
    openssl pkcs12 -in "$P12_BACKUP" -passin "pass:$P12_PASSWORD" -nokeys -clcerts \
        -out "$CERT_BACKUP" 2>/dev/null
    chmod 644 "$CERT_BACKUP"
fi
if register_trust "$CERT_BACKUP"; then
    echo "  trust 등록 완료."
else
    echo "  경고: 자동 trust 실패 — 아래를 수동 실행:" >&2
    echo "    sudo security add-trusted-cert -d -r trustRoot -p codeSign -k $SYSTEM_KEYCHAIN $CERT_BACKUP" >&2
fi

echo "--- 4. codesign partition-list (best-effort) ---"
if allow_codesign_partition "$PW"; then
    echo "  OK — codesign 이 프롬프트 없이 '$CERT_NAME' 키 사용."
else
    echo "  (partition-list 실패 — 빌드 시 키체인 dialog 뜨면 '항상 허용' 한 번.)"
fi

report_identity
echo ""
echo "지문이 CI 의 MACOS_CERTIFICATE_SHA1 과 같으면 secrets / 워크플로우는 갱신할 필요가 없어요."
echo "빌드:  ./dist/macos/build_and_install.sh"
