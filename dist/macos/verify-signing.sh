#!/usr/bin/env bash
# 최종 macOS app이 기대한 identity/fingerprint로 유효하게 서명됐는지 검증한다.

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <app-path> <identity> <sha1-fingerprint>" >&2
    exit 2
fi

APP_PATH="$1"
EXPECTED_IDENTITY="$2"
EXPECTED_SHA1="$3"

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: app bundle not found: $APP_PATH" >&2
    exit 1
fi
if [[ ! "$EXPECTED_SHA1" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo "ERROR: expected SHA-1 must be a 40-digit fingerprint" >&2
    exit 1
fi

EXPECTED_SHA1_LOWER="$(printf '%s' "$EXPECTED_SHA1" | tr '[:upper:]' '[:lower:]')"
SIGNING_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
DESIGNATED_REQUIREMENT="$(codesign -dr - "$APP_PATH" 2>&1)"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if ! grep -Fqx "Authority=$EXPECTED_IDENTITY" <<< "$SIGNING_DETAILS"; then
    echo "ERROR: app signer is not $EXPECTED_IDENTITY" >&2
    exit 1
fi
if ! grep -Fqx 'Identifier=me.ensky0.tildaz' <<< "$SIGNING_DETAILS"; then
    echo "ERROR: app bundle identifier is not me.ensky0.tildaz" >&2
    exit 1
fi
if [[ "$DESIGNATED_REQUIREMENT" != *"certificate leaf = H\"$EXPECTED_SHA1_LOWER\""* ]]; then
    echo "ERROR: designated requirement does not contain the expected certificate fingerprint" >&2
    exit 1
fi

echo "Verified macOS signature: $EXPECTED_IDENTITY ($EXPECTED_SHA1)"
