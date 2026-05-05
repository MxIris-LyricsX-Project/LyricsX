#!/usr/bin/env bash
# Create a published GitHub Release and upload both artifact zips.
#
# Inputs (env):
#   VERSION, BUILD, IS_PRERELEASE
#   GH_TOKEN or GITHUB_TOKEN  (gh CLI reads either)
#   GITHUB_SHA                (optional — used as --target)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

require_env VERSION BUILD IS_PRERELEASE

APP_ZIP="build/LyricsX_${VERSION}+${BUILD}.zip"
DSYMS_ZIP="build/LyricsX_${VERSION}+${BUILD}.dSYMs.zip"
BODY="build/body.md"

[ -f "$APP_ZIP" ]   || die "Missing ${APP_ZIP}"
[ -f "$DSYMS_ZIP" ] || die "Missing ${DSYMS_ZIP}"
[ -f "$BODY" ]      || die "Missing ${BODY}"

FLAGS=()
if [ "$IS_PRERELEASE" = "true" ]; then
    FLAGS+=(--prerelease)
fi
if [ -n "${GITHUB_SHA:-}" ]; then
    FLAGS+=(--target "$GITHUB_SHA")
fi

log_info "Creating published release v${VERSION} (prerelease=${IS_PRERELEASE})"
gh release create "v${VERSION}" \
    "${FLAGS[@]}" \
    --title "LyricsX ${VERSION}" \
    --notes-file "$BODY" \
    "$APP_ZIP" \
    "$DSYMS_ZIP"

log_info "Published release v${VERSION}. Enclosure URL is now anonymously reachable."
