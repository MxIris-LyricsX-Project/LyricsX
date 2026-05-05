#!/usr/bin/env bash
# Sparkle-sign build/LyricsX_<VERSION>+<BUILD>.zip and emit
# ED_SIGNATURE + ZIP_LENGTH into $GITHUB_ENV (and stdout).
#
# Inputs (env):
#   VERSION, BUILD                  identify the zip
#   SPARKLE_ED_PRIVATE_KEY          the literal string produced by
#                                   `generate_keys -x` (Sparkle ed25519 priv)
#   GITHUB_ENV                      (optional) GitHub Actions env file

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

require_env VERSION BUILD SPARKLE_ED_PRIVATE_KEY

APP_ZIP="build/LyricsX_${VERSION}+${BUILD}.zip"
[ -f "$APP_ZIP" ] || die "Missing ${APP_ZIP} (run package.sh first)"

SIGN_TOOL="Scripts/release/bin/sign_update"
[ -x "$SIGN_TOOL" ] || die "Missing ${SIGN_TOOL} (run install-sparkle-tools.sh first)"

KEY_FILE="$(mktemp -t sparkle-key)"
trap 'rm -f "$KEY_FILE"' EXIT

printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$KEY_FILE"

log_info "Signing ${APP_ZIP}"
SIGN_OUTPUT="$("$SIGN_TOOL" --ed-key-file "$KEY_FILE" "$APP_ZIP")"

ED_SIGNATURE="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
ZIP_LENGTH="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"

[ -n "$ED_SIGNATURE" ] || die "Failed to parse sparkle:edSignature from sign_update output: ${SIGN_OUTPUT}"
[ -n "$ZIP_LENGTH" ]  || die "Failed to parse length from sign_update output: ${SIGN_OUTPUT}"

log_info "ED_SIGNATURE=${ED_SIGNATURE}"
log_info "ZIP_LENGTH=${ZIP_LENGTH}"

printf 'ED_SIGNATURE=%s\n' "$ED_SIGNATURE"
printf 'ZIP_LENGTH=%s\n' "$ZIP_LENGTH"

if [ -n "${GITHUB_ENV:-}" ]; then
    {
        printf 'ED_SIGNATURE=%s\n' "$ED_SIGNATURE"
        printf 'ZIP_LENGTH=%s\n' "$ZIP_LENGTH"
    } >> "$GITHUB_ENV"
fi
