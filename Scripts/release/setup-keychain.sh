#!/usr/bin/env bash
# Create a temporary macOS keychain, import the Developer ID Application cert,
# and install the Developer ID provisioning profile so xcodebuild's export
# step can find it without needing ASC API write permissions.
#
# Inputs (env):
#   APPLE_DEV_ID_CERT_P12_BASE64    base64-encoded .p12
#   APPLE_DEV_ID_CERT_PASSWORD      password for the .p12
#   KEYCHAIN_PASSWORD               password to create the temp keychain with
#   LYRICSX_DEVID_PROFILE_BASE64    (optional) base64 of the LyricsX
#                                   Developer ID Application provisioning
#                                   profile (.provisionprofile). When present,
#                                   it is decoded into the user's local
#                                   provisioning-profile directory so export
#                                   can sign with Developer ID without trying
#                                   to fetch a profile from App Store Connect.
#
# Side effects:
#   Creates ~/Library/Keychains/lyricsx-release.keychain-db and adds it to the
#   user's keychain search list. Unlocks it and allows codesign access.
#   Installs LyricsX Developer ID profile when its env var is set.
#
# To clean up, call this script with the "cleanup" argument.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

KEYCHAIN_NAME="lyricsx-release.keychain-db"
KEYCHAIN_PATH="${HOME}/Library/Keychains/${KEYCHAIN_NAME}"

cleanup() {
    if [ -f "$KEYCHAIN_PATH" ]; then
        log_info "Deleting temp keychain $KEYCHAIN_PATH"
        security delete-keychain "$KEYCHAIN_PATH" || true
    fi
}

if [ "${1:-}" = "cleanup" ]; then
    cleanup
    exit 0
fi

require_env APPLE_DEV_ID_CERT_P12_BASE64 APPLE_DEV_ID_CERT_PASSWORD KEYCHAIN_PASSWORD

cleanup

P12_PATH="$(mktemp -t lyricsx-cert).p12"
trap 'rm -f "$P12_PATH"' EXIT

printf '%s' "$APPLE_DEV_ID_CERT_P12_BASE64" | base64 --decode > "$P12_PATH"

log_info "Creating temp keychain"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

log_info "Importing Developer ID Application certificate"
security import "$P12_PATH" \
    -k "$KEYCHAIN_PATH" \
    -P "$APPLE_DEV_ID_CERT_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" >/dev/null

ORIGINAL_LIST=$(security list-keychains -d user | tr -d '"' | tr -d ' ')
security list-keychains -d user -s "$KEYCHAIN_PATH" $ORIGINAL_LIST

log_info "Installed identities:"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"

if [ -n "${LYRICSX_DEVID_PROFILE_BASE64:-}" ]; then
    PROFILE_DIR="${HOME}/Library/MobileDevice/Provisioning Profiles"
    mkdir -p "$PROFILE_DIR"
    PROFILE_PATH="${PROFILE_DIR}/lyricsx-devid.provisionprofile"
    printf '%s' "$LYRICSX_DEVID_PROFILE_BASE64" | base64 --decode > "$PROFILE_PATH"
    log_info "Installed LyricsX Developer ID provisioning profile to ${PROFILE_PATH}"
else
    log_warn "LYRICSX_DEVID_PROFILE_BASE64 not set; xcodebuild export may fail with 'No profiles for ...'"
fi
