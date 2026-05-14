#!/usr/bin/env bash
# Run update-appcast.py against the canonical or mirror appcast and push.
#
# Modes (positional arg):
#   canonical  - edit ./appcast.xml in the current checkout, commit, push to LyricsX master
#   mirror     - clone MxIris-LyricsX-Project.github.io, edit appcast.xml, push back
#
# Inputs (env):
#   VERSION, BUILD, IS_PRERELEASE, ED_SIGNATURE, ZIP_LENGTH
#   PAGES_MIRROR_TOKEN  (only required for mode=mirror) fine-grained PAT for the legacy Pages repo

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

MODE="${1:-}"
[ -n "$MODE" ] || die "Usage: publish-appcast.sh canonical|mirror"

require_env VERSION BUILD IS_PRERELEASE ED_SIGNATURE ZIP_LENGTH

if [ "$IS_PRERELEASE" = "true" ]; then
    log_info "IS_PRERELEASE=true — skipping appcast update."
    exit 0
fi

# minimumSystemVersion mirrors the app's deployment target. project.pbxproj
# carries a low project-level baseline plus per-target overrides; the app's
# effective floor is the highest MACOSX_DEPLOYMENT_TARGET among them.
MIN_SYSTEM_VERSION="$(
    grep -E 'MACOSX_DEPLOYMENT_TARGET = ' LyricsX.xcodeproj/project.pbxproj \
        | sed -E 's/.*= *//; s/;.*//' \
        | sort -V | tail -1
)"
[ -n "$MIN_SYSTEM_VERSION" ] || die "Could not read MACOSX_DEPLOYMENT_TARGET from project.pbxproj"
log_info "minimumSystemVersion=${MIN_SYSTEM_VERSION}"

git_id() {
    git config user.name  "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
}

case "$MODE" in
    canonical)
        log_info "Updating canonical appcast.xml in current checkout"
        APPCAST_PATH="appcast.xml" \
        VERSION="$VERSION" BUILD="$BUILD" \
        ED_SIGNATURE="$ED_SIGNATURE" ZIP_LENGTH="$ZIP_LENGTH" \
        MIN_SYSTEM_VERSION="$MIN_SYSTEM_VERSION" \
            python3 Scripts/release/update-appcast.py

        if git diff --quiet -- appcast.xml; then
            log_info "appcast.xml unchanged — nothing to commit."
            exit 0
        fi

        git_id
        git add appcast.xml
        git commit -m "release: update appcast.xml for v${VERSION}"
        # --autostash: the archive step leaves unrelated working-tree churn
        # (e.g. a re-resolved Package.resolved); only appcast.xml is staged
        # into the commit, so carry the rest across the rebase untouched.
        git pull --rebase --autostash origin master
        git push origin HEAD:master
        ;;

    mirror)
        require_env PAGES_MIRROR_TOKEN

        MIRROR_DIR="build/legacy-pages"
        rm -rf "$MIRROR_DIR"
        mkdir -p build

        REPO_URL="https://x-access-token:${PAGES_MIRROR_TOKEN}@github.com/MxIris-LyricsX-Project/MxIris-LyricsX-Project.github.io.git"

        log_info "Cloning legacy Pages repo"
        git clone --depth 1 "$REPO_URL" "$MIRROR_DIR"

        log_info "Updating mirror appcast.xml"
        APPCAST_PATH="${MIRROR_DIR}/appcast.xml" \
        VERSION="$VERSION" BUILD="$BUILD" \
        ED_SIGNATURE="$ED_SIGNATURE" ZIP_LENGTH="$ZIP_LENGTH" \
        MIN_SYSTEM_VERSION="$MIN_SYSTEM_VERSION" \
            python3 Scripts/release/update-appcast.py

        if (cd "$MIRROR_DIR" && git diff --quiet -- appcast.xml); then
            log_info "Mirror appcast.xml unchanged — nothing to commit."
            exit 0
        fi

        (
            cd "$MIRROR_DIR"
            git_id
            git add appcast.xml
            git commit -m "release: mirror v${VERSION} for legacy clients"
            git push
        )
        ;;

    *)
        die "Unknown mode: ${MODE} (expected canonical|mirror)"
        ;;
esac

log_info "Appcast (${MODE}) push complete."
