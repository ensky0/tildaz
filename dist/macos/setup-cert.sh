#!/usr/bin/env bash
# tildaz 로컬 빌드용 self-signed code-signing 인증서 setup (idempotent + 자동 trust).
#
# 한 번 실행하면 끝 (신뢰 등록까지 스크립트가 직접):
#   - login keychain 에 "TildazLocal" 인증서 + private key
#   - System keychain 에 codeSign trust 등록 (sudo — 터미널에서 admin 비번)
#   - codesign partition-list (best-effort; 회사 정책이 막으면 빌드 시 '항상 허용')
#
# 안정 signing identity + 고정 bundle id (me.ensky0.tildaz) → 코드 바꿔도 같은 앱
# 으로 인식 → Input Monitoring / Accessibility(TCC) 권한 한 번 부여 후 유지.
# ad-hoc 서명은 매 빌드 hash 가 바뀌어 TCC 가 매번 재요구 — 그걸 없애는 게 목적.
#
# 이후 빌드:
#   ./dist/macos/build_and_install.sh
#   # 또는 설치 없이 dev 루프:
#   zig build -Dmacos-sign-identity=TildazLocal -Doptimize=ReleaseSafe && open zig-out/TildaZ.app

set -euo pipefail

CERT_NAME="TildazLocal"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"
CERT_OUT="$HOME/.tildaz/${CERT_NAME}.crt"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# 이미 유효(trusted) codesigning identity 가 있으면 아무것도 안 함 (idempotent).
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "'$CERT_NAME' codesigning identity 가 이미 유효합니다 — 할 일 없음."
    echo "빌드:  zig build -Dmacos-sign-identity=$CERT_NAME -Doptimize=ReleaseSafe && open zig-out/TildaZ.app"
    exit 0
fi

# login password — unlock + partition-list 에 필요. osascript hidden input (로그 X).
PW=$(osascript -e 'display dialog "TildaZ: macOS 로그인 password (codesign cert setup)" default answer "" with hidden answer with icon caution' -e 'return text returned of result' 2>/dev/null)
if [[ -z "$PW" ]]; then
    echo "ERROR: password 입력 안 됨." >&2
    exit 1
fi
if ! security unlock-keychain -p "$PW" "$KEYCHAIN" 2>/dev/null; then
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
    -out "$TMPDIR/cert.p12" -password pass:tildaz -name "$CERT_NAME" 2>&1 | tail -2

echo "--- 2. login keychain 에 import ---"
security import "$TMPDIR/cert.p12" -P tildaz -A -T /usr/bin/codesign -k "$KEYCHAIN" 2>&1 | tail -3
mkdir -p "$HOME/.tildaz"
cp "$TMPDIR/crt.pem" "$CERT_OUT"

echo "--- 3. System keychain 에 codeSign trust 등록 (sudo — admin 비번) ---"
if sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "$SYSTEM_KEYCHAIN" "$CERT_OUT"; then
    echo "  trust 등록 완료."
else
    echo "  경고: 자동 trust 실패 — 아래를 수동 실행:" >&2
    echo "    sudo security add-trusted-cert -d -r trustRoot -p codeSign -k $SYSTEM_KEYCHAIN $CERT_OUT" >&2
fi

echo "--- 4. codesign partition-list (best-effort — 프롬프트 제거 시도) ---"
if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "  OK — codesign 이 프롬프트 없이 '$CERT_NAME' 키 사용."
else
    echo "  (partition-list 실패 — 회사 정책 등. 빌드 시 키체인 dialog 뜨면 '항상 허용' 한 번.)"
fi

echo ""
echo "=== 결과 확인 ==="
if security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME"; then
    echo "성공 — 위에 '$CERT_NAME' 가 valid 로 보입니다."
else
    echo "아직 안 보임 — 3번 trust 단계가 실패했을 수 있음 (위 경고 확인)." >&2
fi
echo ""
echo "빌드:  zig build -Dmacos-sign-identity=$CERT_NAME -Doptimize=ReleaseSafe && open zig-out/TildaZ.app"
echo "       (codesign dialog 뜨면 '항상 허용'. 첫 실행 후 손쉬운 사용/입력 모니터링 권한 한 번.)"
