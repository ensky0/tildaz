#!/usr/bin/env bash
# TildazLocal code-signing identity 를 다루는 공통 함수.
# `setup-cert.sh` (새로 만들기) 와 `restore-cert.sh` (백업에서 되살리기) 가 source 한다.
# 단독 실행용이 아니다.
#
# 백업 파일 (`~/.tildaz/TildazLocal.p12`) 을 남기는 이유와 보안 판단은
# https://github.com/ensky0/tildaz/issues/444 에 있다. 요약하면 — login keychain 이
# 밀리면 (2026-08-10 실제 발생, 두 번째) 같은 인증서를 되살릴 길이 없고, 새로 만들면
# Input Monitoring / Accessibility 권한을 매번 다시 줘야 한다.

CERT_NAME="${TILDAZ_SIGN_IDENTITY:-TildazLocal}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"
BACKUP_DIR="$HOME/.tildaz"
CERT_BACKUP="$BACKUP_DIR/${CERT_NAME}.crt"
P12_BACKUP="$BACKUP_DIR/${CERT_NAME}.p12"

# 백업 p12 의 password. 파일 권한 (600) 에 의존하는 고정값이다 — self-signed 이고
# trust 등록이 이 머신의 System keychain 에만 있어서, 다른 머신에서는 이 서명이
# 의미가 없다 (#444 의 보안 판단 절).
P12_PASSWORD="tildaz"

# 이미 서명에 쓸 수 있는 (= trust 까지 된) identity 가 있는지.
has_valid_identity() {
    security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""
}

# 로그인 password 를 hidden input 으로 받는다 (터미널 로그에 남기지 않기 위해).
# keychain unlock 과 partition-list 두 곳에서 필요하다.
ask_login_password() {
    local reason="$1"
    osascript \
        -e "display dialog \"TildaZ: macOS 로그인 password ($reason)\" default answer \"\" with hidden answer with icon caution" \
        -e 'return text returned of result' 2>/dev/null
}

unlock_login_keychain() {
    local pw="$1"
    security unlock-keychain -p "$pw" "$KEYCHAIN" 2>/dev/null
}

# p12 (인증서 + private key) 를 login keychain 에 넣는다.
# `-T /usr/bin/codesign` 으로 codesign 이 이 키를 쓸 수 있게 미리 허용한다.
import_p12() {
    local p12="$1"
    security import "$p12" -P "$P12_PASSWORD" -A -T /usr/bin/codesign -k "$KEYCHAIN"
}

# Apple 의 codesign policy 는 self-signed cert 를 System keychain 의 codeSign trust
# 없이는 거부한다. sudo 가 필요한 유일한 단계다.
register_trust() {
    local crt="$1"
    sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "$SYSTEM_KEYCHAIN" "$crt"
}

# 빌드마다 keychain dialog 가 뜨는 것을 없앤다 (회사 정책이 막으면 실패해도 무해 —
# 그 경우 빌드 중 dialog 에서 '항상 허용' 을 한 번 누르면 된다).
allow_codesign_partition() {
    local pw="$1"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$KEYCHAIN" >/dev/null 2>&1
}

# 백업을 남긴다. p12 는 private key 를 담으므로 권한 600 으로 만든다.
save_backup() {
    local p12_src="$1" crt_src="$2"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    install -m 600 "$p12_src" "$P12_BACKUP"
    install -m 644 "$crt_src" "$CERT_BACKUP"
    echo "  백업: $P12_BACKUP (권한 600) + $CERT_BACKUP"
}

# 결과 확인 + 지문 출력. 지문은 CI 의 MACOS_CERTIFICATE_SHA1 과 대조하는 값이다.
report_identity() {
    echo ""
    echo "=== 결과 확인 ==="
    if security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME"; then
        echo "성공 — 위에 '$CERT_NAME' 가 valid 로 보입니다."
        echo ""
        echo "인증서 지문 (CI 의 MACOS_CERTIFICATE_SHA1 과 같아야 함):"
        security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null | grep "SHA-1 hash"
        return 0
    fi
    echo "아직 안 보임 — trust 등록 단계가 실패했을 수 있습니다 (위 경고 확인)." >&2
    return 1
}
