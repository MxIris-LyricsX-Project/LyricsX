#!/usr/bin/env bash
# Resolve VERSION and IS_PRERELEASE from either the pushed tag or the dispatch input.
#
# Inputs (env):
#   GITHUB_EVENT_NAME    "push" | "workflow_dispatch"
#   GITHUB_REF_NAME      e.g. "v1.9.0" (when GITHUB_EVENT_NAME=push)
#   INPUT_VERSION        e.g. "1.9.0" (when GITHUB_EVENT_NAME=workflow_dispatch)
#   GITHUB_ENV           (optional) path to GitHub Actions env file
#
# Outputs:
#   Appends VERSION=<v> and IS_PRERELEASE=<true|false> to $GITHUB_ENV if set,
#   and always prints them to stdout in KEY=VALUE form.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

require_env GITHUB_EVENT_NAME

case "$GITHUB_EVENT_NAME" in
    push)
        require_env GITHUB_REF_NAME
        case "$GITHUB_REF_NAME" in
            v*) VERSION="${GITHUB_REF_NAME#v}" ;;
            *)  die "Tag '${GITHUB_REF_NAME}' does not start with 'v'" ;;
        esac
        ;;
    workflow_dispatch)
        require_env INPUT_VERSION
        VERSION="$INPUT_VERSION"
        ;;
    *)
        die "Unsupported GITHUB_EVENT_NAME: '${GITHUB_EVENT_NAME}'"
        ;;
esac

validate_version_format "$VERSION"

if is_prerelease_version "$VERSION"; then
    IS_PRERELEASE="true"
else
    IS_PRERELEASE="false"
fi

log_info "Resolved VERSION=${VERSION} IS_PRERELEASE=${IS_PRERELEASE}"

printf 'VERSION=%s\n' "$VERSION"
printf 'IS_PRERELEASE=%s\n' "$IS_PRERELEASE"

if [ -n "${GITHUB_ENV:-}" ]; then
    {
        printf 'VERSION=%s\n' "$VERSION"
        printf 'IS_PRERELEASE=%s\n' "$IS_PRERELEASE"
    } >> "$GITHUB_ENV"
fi
