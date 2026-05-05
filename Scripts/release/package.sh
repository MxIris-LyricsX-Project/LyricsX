#!/usr/bin/env bash
# Produce build/LyricsX_<VERSION>+<BUILD>.zip and the dSYMs zip.
#
# Inputs (env):
#   VERSION, BUILD

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

require_env VERSION BUILD

APP_PATH="build/Export/LyricsX.app"
DSYMS_DIR="build/LyricsX.xcarchive/dSYMs"
APP_ZIP="build/LyricsX_${VERSION}+${BUILD}.zip"
DSYMS_ZIP="build/LyricsX_${VERSION}+${BUILD}.dSYMs.zip"

[ -d "$APP_PATH" ]   || die "Expected ${APP_PATH}"
[ -d "$DSYMS_DIR" ]  || die "Expected ${DSYMS_DIR}"
if [ -z "$(ls -A "$DSYMS_DIR" 2>/dev/null)" ]; then
    die "${DSYMS_DIR} is empty — no dSYMs were produced"
fi

log_info "Packaging app → ${APP_ZIP}"
rm -f "$APP_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$APP_ZIP"

log_info "Packaging dSYMs → ${DSYMS_ZIP}"
rm -f "$DSYMS_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$DSYMS_DIR" "$DSYMS_ZIP"

log_info "Produced:"
ls -lh "$APP_ZIP" "$DSYMS_ZIP"
