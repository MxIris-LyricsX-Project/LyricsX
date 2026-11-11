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

# Prereleases are no longer skipped. They land in the same appcast as stable
# items, tagged with <sparkle:channel>beta</sparkle:channel>, and only reach
# clients that opted in via the "Receive beta updates" preference.
if [ "$IS_PRERELEASE" = "true" ]; then
    log_info "IS_PRERELEASE=true — publishing as beta-channel item."
fi

# minimumSystemVersion mirrors the MAIN APP's deployment target so Sparkle
# decides update eligibility against the main app's floor — not against any
# extension's higher floor. The LyricsXWidget extension is intentionally at
# 15.0 (uses WidgetKit APIs that need macOS 14+), but the main app still runs
# on macOS 12+, and macOS 12-14 users should still receive updates (the
# widget just won't load for them).
#
# After the 216a99e xcconfig refactor, build settings no longer live in
# project.pbxproj — read from the main app's xcconfig stack instead. The
# project-level baseline (Project-Release.xcconfig) is the floor; the main
# app's xcconfig (LyricsX.xcconfig) may override upward. Take the max of
# those two, deliberately excluding LyricsXWidget.xcconfig (15.0).
MIN_SYSTEM_VERSION="$(
    grep -E 'MACOSX_DEPLOYMENT_TARGET = ' \
            Config/Project-Release.xcconfig \
            Config/LyricsX/LyricsX.xcconfig \
        | sed -E 's/.*= *//; s/;.*//' \
        | sort -V | tail -1
)"
[ -n "$MIN_SYSTEM_VERSION" ] || die "Could not read MACOSX_DEPLOYMENT_TARGET from main-app xcconfig stack"
log_info "minimumSystemVersion=${MIN_SYSTEM_VERSION}"

git_id() {
    git config user.name  "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
}

case "$MODE" in
    canonical)
        CANONICAL_DIRECTORY="build/canonical-appcast"
        rm -rf "$CANONICAL_DIRECTORY"
        mkdir -p build

        CANONICAL_REPOSITORY_URL="$(git remote get-url origin)"
        CANONICAL_REPOSITORY_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
        if [ -n "$CANONICAL_REPOSITORY_TOKEN" ]; then
            CANONICAL_REPOSITORY_URL="https://x-access-token:${CANONICAL_REPOSITORY_TOKEN}@github.com/MxIris-LyricsX-Project/LyricsX.git"
        fi

        log_info "Cloning canonical master appcast branch"
        git clone --depth 1 --branch master "$CANONICAL_REPOSITORY_URL" "$CANONICAL_DIRECTORY"

        log_info "Updating canonical appcast.xml"
        APPCAST_PATH="${CANONICAL_DIRECTORY}/appcast.xml" \
        VERSION="$VERSION" BUILD="$BUILD" \
        ED_SIGNATURE="$ED_SIGNATURE" ZIP_LENGTH="$ZIP_LENGTH" \
        MIN_SYSTEM_VERSION="$MIN_SYSTEM_VERSION" \
        IS_PRERELEASE="$IS_PRERELEASE" \
            python3 Scripts/release/update-appcast.py

        if (cd "$CANONICAL_DIRECTORY" && git diff --quiet -- appcast.xml); then
            log_info "appcast.xml unchanged — nothing to commit."
            exit 0
        fi

        (
            cd "$CANONICAL_DIRECTORY"
            git_id
            git add appcast.xml
            git commit -m "release: update appcast.xml for v${VERSION}"
            git push origin HEAD:master
        )
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
        IS_PRERELEASE="$IS_PRERELEASE" \
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
