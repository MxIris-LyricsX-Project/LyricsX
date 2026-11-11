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

# Encode a marketing version (e.g. "1.9.0-beta.5") into a monotonic integer
# build number suitable for CFBundleVersion. The encoding preserves the
# semantic-version ordering across channels, so a stable hot-fix bumped
# after a beta will not falsely look "newer" by build number.
#
#   build = MAJOR * 10_000_000
#         + MINOR * 100_000
#         + PATCH * 1_000
#         + sublabel
#
# sublabel ordering: alpha.N (1..99) < beta.N (101..199) < rc.N (201..299) < stable (999).
# Each prerelease counter N is constrained to 1..99.
#
# Examples:
#   1.8.7         -> 10_807_999
#   1.9.0-beta.5  -> 10_900_105
#   1.9.0-rc.1    -> 10_900_201
#   1.9.0         -> 10_900_999
#   1.8.8         -> 10_808_999  (hot fix after beta — beta still wins by build number)
#   1.9.1-beta.1  -> 10_901_101
encode_build_number() {
    local version="$1"
    validate_version_format "$version"

    local base="${version%%-*}"
    local suffix=""
    if [[ "$version" == *-* ]]; then
        suffix="${version#*-}"
    fi

    local major minor patch
    IFS='.' read -r major minor patch <<< "$base"

    local sublabel
    if [ -z "$suffix" ]; then
        sublabel=999
    elif [[ "$suffix" =~ ^alpha\.([1-9][0-9]?)$ ]]; then
        sublabel=$((10#${BASH_REMATCH[1]}))
    elif [[ "$suffix" =~ ^beta\.([1-9][0-9]?)$ ]]; then
        sublabel=$((100 + 10#${BASH_REMATCH[1]}))
    elif [[ "$suffix" =~ ^rc\.([1-9][0-9]?)$ ]]; then
        sublabel=$((200 + 10#${BASH_REMATCH[1]}))
    else
        die "Unsupported prerelease suffix in version '${version}': '${suffix}'. Supported forms: alpha.N, beta.N, rc.N (with N in 1..99)."
    fi

    printf '%d' $((10#${major} * 10000000 + 10#${minor} * 100000 + 10#${patch} * 1000 + sublabel))
}

plist_buddy() {
    /usr/libexec/PlistBuddy "$@"
}

repo_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

export INFO_PLIST_PATH="LyricsX/Supporting Files/Info.plist"
