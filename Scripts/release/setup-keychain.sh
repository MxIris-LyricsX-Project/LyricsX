#!/usr/bin/env bash
# Create a temporary macOS keychain, import the Developer ID Application cert,
# and install the Developer ID provisioning profile so xcodebuild's export
# step can find it without needing ASC API write permissions.
#
# Inputs (env):
#   APPLE_DEV_ID_CERT_P12_BASE64        base64-encoded .p12
#   APPLE_DEV_ID_CERT_PASSWORD          password for the .p12
#   KEYCHAIN_PASSWORD                   password to create the temp keychain with
#   LYRICSX_DEVID_PROFILE_BASE64        base64 of the main app's Developer ID
#                                       Application provisioning profile.
#   LYRICSX_HELPER_DEVID_PROFILE_BASE64 base64 of the embedded LyricsXHelper
#                                       login item's Developer ID profile.
#   LYRICSX_WIDGET_DEVID_PROFILE_BASE64 base64 of the LyricsXWidget extension's
#                                       Developer ID profile.
#
# All three profile env vars are required. With Scripts/release/build.sh in
# RuntimeViewer-style mode (archive skips signing via CODE_SIGNING_ALLOWED=NO,
# exportArchive runs with signingStyle=automatic + method=developer-id),
# exportArchive auto-discovers each target's profile by bundle id from the
# installed .provisionprofile files. Missing any one fails the export with
# "No profiles for <bundle id>".
#
# Side effects:
#   Creates ~/Library/Keychains/lyricsx-release.keychain-db, adds it to the
#   user's keychain search list, unlocks it, allows codesign access.
#   Installs the three Developer ID profiles under
#   ~/Library/MobileDevice/Provisioning Profiles/.
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

PROFILE_DIR="${HOME}/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILE_DIR"

# All three targets (main app, embedded LyricsXHelper login item, and the
# LyricsXWidget extension) carry capabilities that require a Developer ID
# provisioning profile (App Groups, iCloud, etc.). Each is installed here so
# Scripts/release/build.sh can archive under CODE_SIGN_STYLE=Manual without
# calling ASC API (which would mint a throwaway "Apple Development: Created
# via API" cert per archive — burns the per-individual Apple Development cert
# quota).
install_devid_profile() {
    local base64_value="$1" file_name="$2" human_name="$3"
    if [ -z "$base64_value" ]; then
        die "${human_name} profile env not set. Manual signing requires all three: LYRICSX_DEVID_PROFILE_BASE64, LYRICSX_HELPER_DEVID_PROFILE_BASE64, LYRICSX_WIDGET_DEVID_PROFILE_BASE64."
    fi
    local profile_path="${PROFILE_DIR}/${file_name}.provisionprofile"
    printf '%s' "$base64_value" | base64 --decode > "$profile_path"
    log_info "Installed ${human_name} Developer ID provisioning profile to ${profile_path}"
}

install_devid_profile "${LYRICSX_DEVID_PROFILE_BASE64:-}" "lyricsx-devid" "LyricsX"
install_devid_profile "${LYRICSX_HELPER_DEVID_PROFILE_BASE64:-}" "lyricsx-helper-devid" "LyricsXHelper"
install_devid_profile "${LYRICSX_WIDGET_DEVID_PROFILE_BASE64:-}" "lyricsx-widget-devid" "LyricsXWidget"
