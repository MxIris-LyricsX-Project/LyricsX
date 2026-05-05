#!/usr/bin/env bash
# Install Sparkle's sign_update CLI from a pinned upstream release.
#
# Inputs (env):
#   SPARKLE_VERSION      e.g. "2.6.4"
#
# Side effects:
#   Writes Scripts/release/bin/sign_update (git-ignored).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

require_env SPARKLE_VERSION

DEST_DIR="Scripts/release/bin"
DEST="${DEST_DIR}/sign_update"
mkdir -p "$DEST_DIR"

if [ -x "$DEST" ] && "$DEST" --help >/dev/null 2>&1; then
    log_info "sign_update already installed at $DEST"
    exit 0
fi

WORKDIR="$(mktemp -d -t sparkle-tools)"
trap 'rm -rf "$WORKDIR"' EXIT

URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
log_info "Downloading ${URL}"
curl -fsSL -o "${WORKDIR}/sparkle.tar.xz" "$URL"

log_info "Extracting"
tar -xf "${WORKDIR}/sparkle.tar.xz" -C "$WORKDIR"

SRC="$(find "$WORKDIR" -type f -name sign_update -perm -u+x | head -1)"
[ -n "$SRC" ] || die "sign_update not found in Sparkle-${SPARKLE_VERSION}.tar.xz"

cp "$SRC" "$DEST"
chmod +x "$DEST"

log_info "Verifying:"
"$DEST" --help >/dev/null || die "sign_update failed --help probe"
log_info "Installed sign_update at ${DEST}"
