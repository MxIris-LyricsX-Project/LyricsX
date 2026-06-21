#!/usr/bin/env bash
# Archive + exportArchive into build/Export/LyricsX.app
#
# Inputs (env):
#   DEVELOPMENT_TEAM            (optional) team identifier; defaults to D5Q73692VW
#   APPLE_API_KEY_P8_BASE64     (optional) base64 ASC API key, enables auto profile fetch
#   APPLE_API_KEY_ID            (optional) ASC API Key ID
#   APPLE_API_KEY_ISSUER_ID     (optional) ASC API Issuer UUID
#
# Requires: setup-keychain.sh must have run first so the Developer ID
# Application identity is in the keychain search list.
#
# When APPLE_API_KEY_* are present, xcodebuild auto-fetches the Developer ID
# provisioning profile (needed because LyricsX entitlements include iCloud and
# other restricted capabilities). Without them, manual profile install would be
# required.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

TEAM_ID="${DEVELOPMENT_TEAM:-D5Q73692VW}"
ARCHIVE_PATH="build/LyricsX.xcarchive"
EXPORT_PATH="build/Export"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p build

export LYRICSX_SKIP_BUILD_BUMP=1
export LYRICSX_USE_LOCAL_DEPENDENCY=0

AUTH_ARGS=()
if [ -n "${APPLE_API_KEY_P8_BASE64:-}" ] && \
   [ -n "${APPLE_API_KEY_ID:-}" ] && \
   [ -n "${APPLE_API_KEY_ISSUER_ID:-}" ]; then
    API_KEY_PATH="$(mktemp -t lyricsx-build-key).p8"
    trap 'rm -f "$API_KEY_PATH"' EXIT
    printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 --decode > "$API_KEY_PATH"
    AUTH_ARGS=(
        -allowProvisioningUpdates
        -authenticationKeyPath "$API_KEY_PATH"
        -authenticationKeyID "$APPLE_API_KEY_ID"
        -authenticationKeyIssuerID "$APPLE_API_KEY_ISSUER_ID"
    )
    log_info "Auto-fetching provisioning profile via App Store Connect API key"
else
    log_warn "APPLE_API_KEY_* not set; xcodebuild will use only locally-installed profiles"
fi

log_info "Archiving LyricsX (team=${TEAM_ID})"
# Use Automatic signing in archive: combined with -allowProvisioningUpdates
# and an App Store Connect API key, xcodebuild downloads (or with App Manager
# role, creates) the matching Developer ID provisioning profile for every
# target. ExportOptions.plist (method=developer-id) re-signs the export with
# the correct distribution identity.
xcodebuild \
    -project LyricsX.xcodeproj \
    -scheme LyricsX \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    "${AUTH_ARGS[@]}" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    archive

log_info "Exporting signed .app"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "$EXPORT_PATH" \
    "${AUTH_ARGS[@]}"

if [ ! -d "${EXPORT_PATH}/LyricsX.app" ]; then
    die "Export did not produce ${EXPORT_PATH}/LyricsX.app"
fi

# Both the main app and the embedded LyricsXHelper carry the App Groups
# entitlement — it backs the cross-process groupDefaults that drives
# launch-with-player. If their embedded provisioning profile doesn't authorize
# App Groups, taskgated rejects the entitlement on other machines and the
# feature silently breaks (the exact bug that shipped in 1.8.6). Fail here
# instead of shipping a broken signature.
verify_app_groups_profile() {
    local app_path="$1" human_name="$2"
    local profile_path="${app_path}/Contents/embedded.provisionprofile"
    [ -f "$profile_path" ] || die "${human_name}: missing embedded.provisionprofile (App Groups would be unsigned)."
    local decoded_plist
    decoded_plist="$(mktemp -t lyricsx-prof).plist"
    security cms -D -i "$profile_path" > "$decoded_plist" 2>/dev/null
    if ! /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups' "$decoded_plist" >/dev/null 2>&1; then
        rm -f "$decoded_plist"
        die "${human_name}: provisioning profile does not authorize com.apple.security.application-groups."
    fi
    rm -f "$decoded_plist"
    log_info "${human_name}: embedded profile authorizes App Groups"
}

MAIN_APP="${EXPORT_PATH}/LyricsX.app"
verify_app_groups_profile "$MAIN_APP" "LyricsX"
verify_app_groups_profile "${MAIN_APP}/Contents/Library/LoginItems/LyricsXHelper.app" "LyricsXHelper"

log_info "Built ${EXPORT_PATH}/LyricsX.app"
