#!/usr/bin/env bash
# Compose bilingual release notes into build/body.md.
#
# Inputs (env):
#   VERSION

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

require_env VERSION

EN="ReleaseNotes/${VERSION}_en.md"
ZH="ReleaseNotes/${VERSION}_zh.md"
OUT="build/body.md"

[ -f "$EN" ] || die "Missing ${EN}"
[ -f "$ZH" ] || die "Missing ${ZH}"

mkdir -p build

{
    cat "$EN"
    printf '\n\n---\n\n'
    cat "$ZH"
} > "$OUT"

log_info "Wrote ${OUT} ($(wc -l < "$OUT" | tr -d ' ') lines)"
