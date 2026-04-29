#!/usr/bin/env bash
# tildaz 로컬 빌드용 self-signed code-signing 인증서 setup.
#
# 한 번만 실행해요. 결과:
#   - login keychain 에 "tildaz Local" 인증서 + private key 추가
#   - codesign 이 dialog 없이 사용 가능 (partition-list 설정)
#   - codeSign trust 추가 (find-identity -p codesigning 에 valid 로)
#
# 이후 빌드:
#   zig build -Dmacos-sign-identity="tildaz Local"
#
# 매 빌드마다 ad-hoc 의 hash 가 바뀌어 macOS TCC 가 권한 재요구하던 짜증 해결.
# signing identity + bundle identifier (me.ensky0.tildaz) 가 stable 이라 코드
# 변경해도 같은 앱으로 인식 → Input Monitoring + Accessibility 권한 한 번 부여
# 후 계속 유지.

set -euo pipefail

# 공백 없이 — `zig build -Dmacos-sign-identity=TildazLocal` 의 shell quoting
# 단순화. find-identity / codesign 도 같은 이름.
CERT_NAME="TildazLocal"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# 사용자 login password — partition-list set + unlock-keychain 에 필요.
# osascript 로 GUI dialog — terminal log 에 안 남고 hidden input.
PW=$(osascript -e 'display dialog "tildaz: macOS 로그인 password (codesign cert setup)" default answer "" with hidden answer with icon caution' -e 'return text returned of result' 2>/dev/null)
if [[ -z "$PW" ]]; then
    echo "ERROR: password 입력 안 됨." >&2
    exit 1
fi

# 검증.
if ! security unlock-keychain -p "$PW" "$KEYCHAIN" 2>/dev/null; then
    echo "ERROR: login keychain unlock 실패 — password 틀렸거나 keychain 경로 다름." >&2
    exit 1
fi

echo "--- 1. self-signed code-signing cert 생성 ---"
# keyUsage=digitalSignature + extendedKeyUsage=codeSigning 둘 다 필수.
# keyUsage 빠지면 Apple codesign policy 가 "Invalid Key Usage" 로 reject.
openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR/key.pem" -out "$TMPDIR/crt.pem" \
    -days 3650 -nodes \
    -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" 2>&1 | tail -3

# .p12 확장자 필수 — security import 가 PKCS12 detect 시 확장자 본다.
# 확장자 없으면 "Unknown format in import" 로 실패.
openssl pkcs12 -export -inkey "$TMPDIR/key.pem" -in "$TMPDIR/crt.pem" \
    -out "$TMPDIR/cert.p12" -password pass:tildaz -name "$CERT_NAME" 2>&1 | tail -2

echo "--- 2. login keychain 에 import (any-app 접근) ---"
# -A = allow any app to access without prompt. 일반적으로 -T <path> 와 partition-list 패턴이 더 안전하지만
# partition-list 는 keychain key-level password 가 별도 set 된 경우 fail (아직 진단 못 함).
# 로컬 dev cert 라 -A 로 단순화.
security import "$TMPDIR/cert.p12" -P tildaz -A -k "$KEYCHAIN" 2>&1 | tail -3

echo "--- 3. cert 파일을 영구 위치로 export ---"
# system trust 추가는 sudo 필요 — script 가 직접 호출 시 환경에 따라 GUI
# dialog 못 띄울 수 있어 별도 명령으로 안내.
mkdir -p "$HOME/.tildaz"
CERT_OUT="$HOME/.tildaz/${CERT_NAME}.crt"
cp "$TMPDIR/crt.pem" "$CERT_OUT"
echo "cert: $CERT_OUT"

echo ""
echo "=========================================================="
echo "다음 명령을 별도 터미널에서 실행 (admin password 입력):"
echo ""
echo "  sudo security add-trusted-cert -d -r trustRoot -p codeSign \\"
echo "    -k /Library/Keychains/System.keychain \\"
echo "    $CERT_OUT"
echo ""
echo "그 후 검증:"
echo "  security find-identity -v -p codesigning"
echo ""
echo "'$CERT_NAME' 가 (Invalid 없이) 보이면 성공. 빌드:"
echo "  zig build -Dmacos-sign-identity=$CERT_NAME"
echo "=========================================================="

echo ""
echo "위 출력에 \"$CERT_NAME\" 가 (Invalid Key Usage 없이) 나오면 OK."
echo ""
echo "빌드 명령:"
echo "  zig build -Dmacos-sign-identity=\"$CERT_NAME\""
