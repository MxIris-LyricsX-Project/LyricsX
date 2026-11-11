#!/usr/bin/env bash
# Archive + exportArchive into build/Export/LyricsX.app
#
# Inputs (env):
#   DEVELOPMENT_TEAM    (optional) team identifier; defaults to D5Q73692VW
#
# Requires: setup-keychain.sh must have run first to import the Developer ID
# Application identity into a temp keychain and install all three Developer ID
# .provisionprofile files (main app + helper + widget) under
# ~/Library/MobileDevice/Provisioning Profiles/.
#
# Signing model: archive signs each target with the imported Developer ID
# Application identity (overriding the Debug-default CODE_SIGN_IDENTITY =
# "Apple Development" / "Mac Developer" in the per-target xcconfig), against
# pre-installed Developer ID profiles. exportArchive then re-signs for the
# developer-id distribution method, picking the same identity + profiles
# automatically (ExportOptions.plist: method=developer-id, signingStyle=automatic).
# No `-allowProvisioningUpdates`, no ASC API contact, so no throwaway
# "Apple Development: Created via API" cert is minted per archive (which the
# previous Automatic+API-key flow used to burn one slot off the per-individual
# Apple Development cert quota of 2). Notarization (Scripts/release/notarize.sh)
# still uses the ASC API key — that is unrelated to code-signing identity
# selection.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

TEAM_ID="${DEVELOPMENT_TEAM:-D5Q73692VW}"
ARCHIVE_PATH="build/LyricsX.xcarchive"
EXPORT_PATH="build/Export"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p build

export LYRICSX_USE_LOCAL_DEPENDENCY=0

log_info "Archiving LyricsX (team=${TEAM_ID})"
# All signing settings come from per-target Config/*-Release.xcconfig — they
# pin Manual + Developer ID Application + the hardcoded asc-created profile
# Name per target. The CLI here intentionally does NOT override
# CODE_SIGN_IDENTITY / CODE_SIGN_STYLE because doing so under Automatic-style
# SPM dependency targets (MASShortcut, SnapKit, FrameworkTool*Macros, etc.)
# triggers "conflicting provisioning settings" errors — the override would
# leak into those dependency targets globally.
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
