#!/usr/bin/env bash
# Archive + exportArchive into build/Export/LyricsX.app
#
# Inputs (env):
#   DEVELOPMENT_TEAM        (optional) team identifier; defaults to D5Q73692VW
#   LX_MAIN_PROFILE_NAME    profile Name for the main app target
#                           (com.JH.LyricsX) — exported by setup-keychain.sh
#   LX_HELPER_PROFILE_NAME  profile Name for LyricsXHelper
#   LX_WIDGET_PROFILE_NAME  profile Name for LyricsXWidget
#
# Requires: setup-keychain.sh must have run first to import the Developer ID
# Application identity, install all three .provisionprofile files under
# ~/Library/MobileDevice/Provisioning Profiles/, and export the three
# LX_*_PROFILE_NAME env vars (or write them to $GITHUB_ENV under CI).
#
# Manual signing: the three Config/*-Release.xcconfig files pin
# CODE_SIGN_STYLE=Manual, CODE_SIGN_IDENTITY="Developer ID Application",
# PROVISIONING_PROFILE_SPECIFIER=$(LX_<target>_PROFILE_NAME). The user-defined
# settings are forwarded on the xcodebuild CLI below so the xcconfig $(...)
# substitution resolves at build time. xcodebuild does NOT contact ASC API
# during archive — no -allowProvisioningUpdates, no -authenticationKey* — so
# no throwaway "Apple Development: Created via API" cert is minted per run.
# (The Apple Developer account's per-individual Apple Development cert quota
# is only 2; the previous Automatic+API-key flow walked it down every release.)
# Notarization (Scripts/release/notarize.sh) still uses the ASC API key,
# which is unrelated to code-signing identity selection.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

require_env LX_MAIN_PROFILE_NAME LX_HELPER_PROFILE_NAME LX_WIDGET_PROFILE_NAME

TEAM_ID="${DEVELOPMENT_TEAM:-D5Q73692VW}"
ARCHIVE_PATH="build/LyricsX.xcarchive"
EXPORT_PATH="build/Export"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p build

export LYRICSX_USE_LOCAL_DEPENDENCY=0

log_info "Archiving LyricsX (team=${TEAM_ID})"
log_info "  LX_MAIN_PROFILE_NAME=${LX_MAIN_PROFILE_NAME}"
log_info "  LX_HELPER_PROFILE_NAME=${LX_HELPER_PROFILE_NAME}"
log_info "  LX_WIDGET_PROFILE_NAME=${LX_WIDGET_PROFILE_NAME}"
xcodebuild \
    -project LyricsX.xcodeproj \
    -scheme LyricsX \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    LX_MAIN_PROFILE_NAME="$LX_MAIN_PROFILE_NAME" \
    LX_HELPER_PROFILE_NAME="$LX_HELPER_PROFILE_NAME" \
    LX_WIDGET_PROFILE_NAME="$LX_WIDGET_PROFILE_NAME" \
    archive

log_info "Exporting signed .app"
# Export intentionally omits AUTH_ARGS (-allowProvisioningUpdates). The
# Developer ID profiles for the app and the embedded Helper are injected by
# setup-keychain.sh, and the CI ASC API key has no permission to create
# "Developer ID" profiles. With -allowProvisioningUpdates xcodebuild insists
# on refreshing/creating them online and fails ("Team does not have permission
# to create Developer ID provisioning profiles"); without it, it signs with the
# installed profiles as-is.
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "$EXPORT_PATH"

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
