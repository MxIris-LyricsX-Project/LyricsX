#!/usr/bin/env bash
# Notarize build/Export/LyricsX.app and staple the ticket.
#
# Inputs (env):
#   APPLE_API_KEY_P8_BASE64    base64 of App Store Connect API key .p8
#   APPLE_API_KEY_ID           10-char Key ID
#   APPLE_API_KEY_ISSUER_ID    Issuer UUID

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

require_env APPLE_API_KEY_P8_BASE64 APPLE_API_KEY_ID APPLE_API_KEY_ISSUER_ID

APP_PATH="build/Export/LyricsX.app"
[ -d "$APP_PATH" ] || die "Expected ${APP_PATH} to exist (run build.sh first)"

API_KEY_PATH="$(mktemp -t apple-api-key).p8"
SUBMIT_ZIP="build/LyricsX.notarize.zip"
SUBMIT_RESULT="build/notarize.json"

cleanup() {
    rm -f "$API_KEY_PATH"
}
trap cleanup EXIT

printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 --decode > "$API_KEY_PATH"

log_info "Creating submission zip"
rm -f "$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"

log_info "Submitting to notarytool (this may take several minutes)"
xcrun notarytool submit "$SUBMIT_ZIP" \
    --key "$API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_KEY_ISSUER_ID" \
    --wait \
    --output-format json | tee "$SUBMIT_RESULT"

STATUS=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$SUBMIT_RESULT")
SUBMISSION_ID=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$SUBMIT_RESULT")

log_info "Notarization status: ${STATUS} (submission ${SUBMISSION_ID})"

if [ "$STATUS" != "Accepted" ]; then
    log_error "Notarization failed. Fetching log:"
    xcrun notarytool log "$SUBMISSION_ID" \
        --key "$API_KEY_PATH" \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_KEY_ISSUER_ID" || true
    die "Notarization status was '${STATUS}', expected 'Accepted'"
fi

log_info "Stapling ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
log_info "Stapled and validated"
