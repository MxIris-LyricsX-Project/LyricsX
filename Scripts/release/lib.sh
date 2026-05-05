#!/usr/bin/env bash
# Shared helpers for Scripts/release/*.sh

VERSION_REGEX='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

log_info() {
    printf '\033[0;34m[INFO]\033[0m %s\n' "$*" >&2
}

log_warn() {
    printf '\033[0;33m[WARN]\033[0m %s\n' "$*" >&2
}

log_error() {
    printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

require_env() {
    local name
    for name in "$@"; do
        if [ -z "${!name:-}" ]; then
            die "Required environment variable is empty or unset: ${name}"
        fi
    done
}

is_prerelease_version() {
    local version="$1"
    case "$version" in
        *-*) return 0 ;;
        *)   return 1 ;;
    esac
}

validate_version_format() {
    local version="$1"
    if ! [[ "$version" =~ $VERSION_REGEX ]]; then
        die "Invalid version format: '${version}'. Expected e.g. 1.9.0 or 1.9.0-beta.1"
    fi
}

plist_buddy() {
    /usr/libexec/PlistBuddy "$@"
}

repo_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

export INFO_PLIST_PATH="LyricsX/Supporting Files/Info.plist"
