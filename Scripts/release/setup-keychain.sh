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
#                                       Application provisioning profile
#                                       (.provisionprofile).
#   LYRICSX_HELPER_DEVID_PROFILE_BASE64 base64 of the embedded LyricsXHelper
#                                       login item's Developer ID profile —
#                                       carries the App Groups entitlement.
#   LYRICSX_WIDGET_DEVID_PROFILE_BASE64 base64 of the LyricsXWidget extension's
#                                       Developer ID profile — carries App
#                                       Groups + iCloud (CloudDocuments)
#                                       entitlements shared with the main app.
#
# All three profile env vars are required for the Manual-signed archive in
# Scripts/release/build.sh to find a profile per target; missing one will fail
# the archive with "No profiles for <bundle id>".
#
# Side effects:
#   Creates ~/Library/Keychains/lyricsx-release.keychain-db and adds it to the
#   user's keychain search list. Unlocks it and allows codesign access.
#   Installs the three Developer ID profiles under
#   ~/Library/MobileDevice/Provisioning Profiles/.
#   Extracts each profile's Name field (used by xcodebuild's
#   PROVISIONING_PROFILE_SPECIFIER) and appends to $GITHUB_ENV as
#   LX_MAIN_PROFILE_NAME / LX_HELPER_PROFILE_NAME / LX_WIDGET_PROFILE_NAME so
#   subsequent build steps can reference them per-target via xcconfig.
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

# Extract each profile's Name field — that's what xcodebuild's
# PROVISIONING_PROFILE_SPECIFIER expects to identify the profile under Manual
# signing. The per-target Config/*Release.xcconfig files reference these as
# $(LX_*_PROFILE_NAME); build.sh forwards them on the xcodebuild CLI as
# user-defined settings so the xcconfig substitution resolves at build time.
extract_profile_name() {
    local profile_path="$1"
    local decoded_plist
    decoded_plist="$(mktemp -t lyricsx-prof).plist"
    security cms -D -i "$profile_path" > "$decoded_plist" 2>/dev/null
    local profile_name
    profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$decoded_plist" 2>/dev/null)"
    rm -f "$decoded_plist"
    printf '%s' "$profile_name"
}

export_profile_name() {
    local environment_variable_name="$1" profile_file_path="$2" human_name="$3"
    local profile_name
    profile_name="$(extract_profile_name "$profile_file_path")"
    [ -n "$profile_name" ] || die "${human_name}: failed to extract Name from ${profile_file_path}"
    log_info "${environment_variable_name}=${profile_name}"
    if [ -n "${GITHUB_ENV:-}" ]; then
        printf '%s=%s\n' "$environment_variable_name" "$profile_name" >> "$GITHUB_ENV"
    fi
}

export_profile_name "LX_MAIN_PROFILE_NAME"   "${PROFILE_DIR}/lyricsx-devid.provisionprofile"        "LyricsX"
export_profile_name "LX_HELPER_PROFILE_NAME" "${PROFILE_DIR}/lyricsx-helper-devid.provisionprofile" "LyricsXHelper"
export_profile_name "LX_WIDGET_PROFILE_NAME" "${PROFILE_DIR}/lyricsx-widget-devid.provisionprofile" "LyricsXWidget"
