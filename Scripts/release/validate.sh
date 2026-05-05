#!/usr/bin/env bash
# Consistency gate. Fails fast before any expensive build starts.
#
# Inputs (env):
#   VERSION              resolved earlier by resolve-version.sh
#   IS_PRERELEASE        "true" | "false"
#   GITHUB_EVENT_NAME    "push" | "workflow_dispatch"
#   GITHUB_ENV           (optional) path to GitHub Actions env file
#   SKIP_RELEASE_EXISTS_CHECK  (optional) "1" to skip gh-release check (useful locally)
#
# Outputs:
#   Appends BUILD=<n> and ARTIFACT_NAME=<name> to $GITHUB_ENV if set,
#   and always prints them to stdout.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

require_env VERSION IS_PRERELEASE GITHUB_EVENT_NAME

# 1. Version format
validate_version_format "$VERSION"

# 2. + 3. Release notes exist
EN_NOTES="ReleaseNotes/${VERSION}_en.md"
ZH_NOTES="ReleaseNotes/${VERSION}_zh.md"
[ -f "$EN_NOTES" ] || die "Missing release notes: ${EN_NOTES}. Write it before releasing."
[ -f "$ZH_NOTES" ] || die "Missing release notes: ${ZH_NOTES}. Write it before releasing."

# 4. Info.plist shortVersion matches VERSION
PLIST_VERSION=$(plist_buddy -c 'Print CFBundleShortVersionString' "$INFO_PLIST_PATH")
if [ "$PLIST_VERSION" != "$VERSION" ]; then
    die "Info.plist CFBundleShortVersionString ('${PLIST_VERSION}') doesn't match version ('${VERSION}'). Bump Info.plist and commit first."
fi

# 5. CFBundleVersion is a positive integer
BUILD=$(plist_buddy -c 'Print CFBundleVersion' "$INFO_PLIST_PATH")
if ! [[ "$BUILD" =~ ^[1-9][0-9]*$ ]]; then
    die "Info.plist CFBundleVersion ('${BUILD}') is not a positive integer."
fi

# 6. Tag exists when triggered by a tag push
if [ "$GITHUB_EVENT_NAME" = "push" ]; then
    if ! git tag -l "v${VERSION}" | grep -qx "v${VERSION}"; then
        die "Tag v${VERSION} not found locally. Did fetch-depth: 0 work?"
    fi
fi

# 7. GitHub Release does not yet exist
if [ "${SKIP_RELEASE_EXISTS_CHECK:-0}" != "1" ]; then
    if command -v gh >/dev/null 2>&1; then
        if gh release view "v${VERSION}" >/dev/null 2>&1; then
            die "Release v${VERSION} already exists. Bump version first or delete the existing draft."
        fi
    else
        log_warn "gh CLI not available — skipping release-exists check."
    fi
fi

ARTIFACT_NAME="LyricsX_${VERSION}+${BUILD}.zip"

log_info "Validated. VERSION=${VERSION} BUILD=${BUILD} IS_PRERELEASE=${IS_PRERELEASE}"

printf 'BUILD=%s\n' "$BUILD"
printf 'ARTIFACT_NAME=%s\n' "$ARTIFACT_NAME"

if [ -n "${GITHUB_ENV:-}" ]; then
    {
        printf 'BUILD=%s\n' "$BUILD"
        printf 'ARTIFACT_NAME=%s\n' "$ARTIFACT_NAME"
    } >> "$GITHUB_ENV"
fi
