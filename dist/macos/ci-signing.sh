#!/usr/bin/env bash
# GitHub-hosted macOS runner에 자체 서명 code-signing identity를 설치/정리한다.
# certificate/private key는 GitHub Actions secrets에서만 받고 RUNNER_TEMP 밖에
# 쓰지 않는다. GitHub 공식 임시 Keychain 절차를 TildaZ의 self-signed trust와
# fingerprint 검증까지 포함해 한 경로로 유지한다 (#109).

set -euo pipefail

usage() {
    echo "Usage: $0 <install|cleanup>" >&2
    exit 2
}

if [[ $# -ne 1 ]]; then
    usage
fi

ACTION="$1"
RUNNER_TEMP_DIR="${RUNNER_TEMP:-}"

if [[ -z "$RUNNER_TEMP_DIR" ]]; then
    echo "ERROR: RUNNER_TEMP is required" >&2
    exit 1
fi

KEYCHAIN_PATH="$RUNNER_TEMP_DIR/tildaz-signing.keychain-db"
KEYCHAIN_PASSWORD_PATH="$RUNNER_TEMP_DIR/tildaz-signing-keychain-password"
P12_PATH="$RUNNER_TEMP_DIR/tildaz-signing.p12"
CERTIFICATE_PATH="$RUNNER_TEMP_DIR/tildaz-signing.cer"
ORIGINAL_KEYCHAINS_PATH="$RUNNER_TEMP_DIR/tildaz-original-keychains"
SYSTEM_TRUST_MARKER_PATH="$RUNNER_TEMP_DIR/tildaz-system-trust-installed"
CLEANUP_TIMEOUT_SECONDS=20

run_cleanup_command() {
    local label="$1"
    shift
    local status

    echo "Cleanup start: $label"
    if "$@"; then
        echo "Cleanup complete: $label"
    else
        status=$?
        echo "::warning title=macOS signing cleanup::$label did not complete successfully (status $status)"
    fi
}

cleanup() {
    local original_keychains=()
    local original_keychain

    if [[ -f "$ORIGINAL_KEYCHAINS_PATH" ]]; then
        while IFS= read -r original_keychain; do
            if [[ -n "$original_keychain" ]]; then
                original_keychains+=("$original_keychain")
            fi
        done < "$ORIGINAL_KEYCHAINS_PATH"

        if [[ ${#original_keychains[@]} -gt 0 ]]; then
            run_cleanup_command \
                "restore user Keychain search list" \
                /usr/bin/perl -e 'alarm shift; exec @ARGV' \
                "$CLEANUP_TIMEOUT_SECONDS" \
                security list-keychains -d user -s "${original_keychains[@]}"
        fi
    fi

    if [[ -f "$SYSTEM_TRUST_MARKER_PATH" && -f "$CERTIFICATE_PATH" ]]; then
        run_cleanup_command \
            "remove temporary System trust" \
            sudo -n /usr/bin/perl -e 'alarm shift; exec @ARGV' \
            "$CLEANUP_TIMEOUT_SECONDS" \
            security remove-trusted-cert -d "$CERTIFICATE_PATH"
    fi
    if [[ -f "$KEYCHAIN_PATH" ]]; then
        run_cleanup_command \
            "delete temporary Keychain" \
            /usr/bin/perl -e 'alarm shift; exec @ARGV' \
            "$CLEANUP_TIMEOUT_SECONDS" \
            security delete-keychain "$KEYCHAIN_PATH"
    fi

    echo "Cleanup start: remove temporary signing files"
    rm -f \
        "$KEYCHAIN_PASSWORD_PATH" \
        "$P12_PATH" \
        "$CERTIFICATE_PATH" \
        "$ORIGINAL_KEYCHAINS_PATH" \
        "$SYSTEM_TRUST_MARKER_PATH"
    echo "Cleanup complete: remove temporary signing files"
}

install() {
    local identity="${MACOS_SIGN_IDENTITY:-}"
    local expected_sha1="${MACOS_CERTIFICATE_SHA1:-}"
    local certificate_base64="${MACOS_CERTIFICATE_P12_BASE64:-}"
    local certificate_password="${MACOS_CERTIFICATE_PASSWORD:-}"
    local keychain_password
    local certificate_metadata
    local identity_metadata
    local original_keychains=()
    local original_keychain

    if [[ -z "$identity" || -z "$expected_sha1" ]]; then
        echo "ERROR: MACOS_SIGN_IDENTITY and MACOS_CERTIFICATE_SHA1 are required" >&2
        exit 1
    fi
    if [[ ! "$expected_sha1" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        echo "ERROR: MACOS_CERTIFICATE_SHA1 must be a 40-digit SHA-1 fingerprint" >&2
        exit 1
    fi
    if [[ -z "$certificate_base64" || -z "$certificate_password" ]]; then
        echo "ERROR: macOS signing secrets are missing" >&2
        exit 1
    fi
    if [[ -e "$KEYCHAIN_PATH" || -e "$P12_PATH" ]]; then
        echo "ERROR: signing TEMP paths already exist; refusing to overwrite" >&2
        exit 1
    fi

    umask 077
    security list-keychains -d user \
        | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' \
        > "$ORIGINAL_KEYCHAINS_PATH"

    printf '%s' "$certificate_base64" | base64 --decode -o "$P12_PATH"
    if [[ ! -s "$P12_PATH" ]]; then
        echo "ERROR: decoded signing certificate is empty" >&2
        exit 1
    fi
    echo "Decoded macOS signing certificate into RUNNER_TEMP"

    keychain_password="$(openssl rand -hex 32)"
    printf '%s' "$keychain_password" > "$KEYCHAIN_PASSWORD_PATH"

    security create-keychain -p "$keychain_password" "$KEYCHAIN_PATH"
    security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
    security unlock-keychain -p "$keychain_password" "$KEYCHAIN_PATH"
    security import "$P12_PATH" \
        -P "$certificate_password" \
        -T /usr/bin/codesign \
        -t cert \
        -f pkcs12 \
        -k "$KEYCHAIN_PATH" \
        >/dev/null
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s \
        -k "$keychain_password" \
        "$KEYCHAIN_PATH" \
        >/dev/null
    echo "Imported certificate and private key into the temporary Keychain"

    security find-certificate -c "$identity" -p "$KEYCHAIN_PATH" \
        > "$CERTIFICATE_PATH"
    certificate_metadata="$(security find-certificate -c "$identity" -Z "$KEYCHAIN_PATH")"
    if [[ "$certificate_metadata" != *"SHA-1 hash: $expected_sha1"* ]]; then
        echo "ERROR: imported certificate fingerprint does not match MACOS_CERTIFICATE_SHA1" >&2
        exit 1
    fi

    # TildazLocal은 self-signed root다. GitHub-hosted macOS runner는 passwordless
    # sudo를 제공하므로 headless System Keychain에 임시 trust를 추가한다. 로컬
    # 검증은 setup-cert.sh가 이미 설치한 trust만 읽고 사용자 승인창을 띄우지 않는다.
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        sudo security add-trusted-cert \
            -d \
            -r trustRoot \
            -p codeSign \
            -k /Library/Keychains/System.keychain \
            "$CERTIFICATE_PATH"
        : > "$SYSTEM_TRUST_MARKER_PATH"
        echo "Trusted the self-signed certificate in the runner System Keychain"
    else
        echo "Using the host's existing code-signing trust (no trust changes)"
    fi

    while IFS= read -r original_keychain; do
        if [[ -n "$original_keychain" ]]; then
            original_keychains+=("$original_keychain")
        fi
    done < "$ORIGINAL_KEYCHAINS_PATH"
    security list-keychains \
        -d user \
        -s "$KEYCHAIN_PATH" "${original_keychains[@]}"
    echo "Added the temporary Keychain to the user search list"

    identity_metadata="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH")"
    if [[ "$identity_metadata" != *"$expected_sha1 \"$identity\""* ]]; then
        echo "ERROR: expected code-signing identity is not valid in the temporary Keychain" >&2
        exit 1
    fi

    unset certificate_base64
    unset certificate_password
    unset keychain_password
    echo "Installed macOS code-signing identity: $identity ($expected_sha1)"
}

case "$ACTION" in
    install) install ;;
    cleanup) cleanup ;;
    *) usage ;;
esac
