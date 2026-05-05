# Release CI with Full Sparkle Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automate signed + notarized + stapled LyricsX release artifact production, publish them as published GitHub Releases (not drafts), automatically Sparkle-sign the zip, write a new `<item>` to the canonical `appcast.xml` (LyricsX repo root), and mirror the same item to the legacy organization Pages repo so already-installed `<= 1.8.1` clients keep receiving updates during the transition window.

**Architecture:** A single GitHub Actions workflow (`.github/workflows/release.yml`) orchestrates 13 independently-runnable shell/python scripts under `Scripts/release/`. Sparkle's `sign_update` is downloaded from a pinned Sparkle release tarball; the EdDSA private key, App Store Connect API key, Developer ID `.p12`, and a fine-grained PAT for the legacy Pages repo all come from GitHub Secrets. One Xcode build phase is patched so its build-number auto-increment can be skipped in CI.

**Tech Stack:** GitHub Actions, bash, python3 (macOS-shipped, stdlib only), Apple CLI tools (`security`, `xcodebuild`, `xcrun notarytool`, `xcrun stapler`, `ditto`, `PlistBuddy`), `gh` CLI, Sparkle `sign_update`.

**Design Spec:** `docs/superpowers/specs/2026-05-05-release-ci-with-sparkle-design.md`

**Testing Note:** Shell scripts are smoke-tested locally via direct invocation after each task. The complete workflow is validated end-to-end with a `dry_run=true` dispatch at the end of Task 16 (does not create a Release).

---

## File Structure

### Created

- `Scripts/release/lib.sh` — shared helpers (logging, `require_env`, version regex)
- `Scripts/release/resolve-version.sh` — tag/input → `VERSION`, `IS_PRERELEASE`
- `Scripts/release/validate.sh` — consistency gate (plist, ReleaseNotes, release exists)
- `Scripts/release/setup-keychain.sh` — temp keychain + Developer ID import (also supports `cleanup`)
- `Scripts/release/install-sparkle-tools.sh` — download pinned Sparkle release, extract `bin/sign_update`
- `Scripts/release/build.sh` — `xcodebuild archive` + `-exportArchive`
- `Scripts/release/notarize.sh` — `notarytool submit --wait` + `stapler staple`
- `Scripts/release/package.sh` — app zip + dSYMs zip
- `Scripts/release/sign-sparkle.sh` — produce EdDSA signature with `sign_update`
- `Scripts/release/compose-notes.sh` — bilingual ReleaseNotes → `body.md`
- `Scripts/release/create-release.sh` — `gh release create` (published, not draft)
- `Scripts/release/update-appcast.py` — insert new `<item>` into a target `appcast.xml`
- `Scripts/release/publish-appcast.sh` — wraps `update-appcast.py` + git for canonical/mirror modes
- `.github/workflows/release.yml` — the workflow itself

### Modified

- `LyricsX/Supporting Files/Info.plist` — `SUFeedURL` migrated to LyricsX repo Pages
- `LyricsX.xcodeproj/project.pbxproj` — Bump Build phase guarded by `LYRICSX_SKIP_BUILD_BUMP`
- `appcast.xml` (repo root) — replaced with current organization Pages content (new baseline)
- `.gitignore` — add `build/` and `Scripts/release/bin/`

### Deleted

- `.github/workflows/update-gh-pages.yml` — obsolete (had no effect on the organization Pages repo)

---

## Task 1: Migrate `appcast.xml` Baseline + Switch `SUFeedURL`

**Files:**
- Modify: `appcast.xml` (repo root)
- Modify: `LyricsX/Supporting Files/Info.plist`
- Delete: `.github/workflows/update-gh-pages.yml`

**Context:** The canonical Sparkle feed currently lives at
`https://mxiris-lyricsx-project.github.io/appcast.xml` (organization Pages repo).
We are migrating it to `https://mxiris-lyricsx-project.github.io/LyricsX/appcast.xml`
(LyricsX repo Pages, already enabled). The repo-root `appcast.xml` and the
organization Pages `appcast.xml` have diverged historically: the repo-root file
has `1.8.2` (and older 1.7.x/1.6.x) but is missing `1.7.4`, `1.8.0`, `1.8.1`,
which exist only on the legacy Pages feed. This step merges the two so the new
canonical baseline is complete.

- [ ] **Step 1: Merge legacy Pages items into repo-root appcast.xml**

Run the following one-shot merge script. It downloads the legacy feed,
unions its `<item>`s into the local `appcast.xml`, deduplicates by
`<sparkle:shortVersionString>` (or `<title>` as fallback), and re-sorts
all items in descending version order. The repo-root file wins on conflict.

```bash
/usr/bin/python3 - <<'PYEOF'
import re
import urllib.request
from pathlib import Path
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)

LEGACY_URL = "https://mxiris-lyricsx-project.github.io/appcast.xml"
LOCAL_PATH = Path("appcast.xml")

with urllib.request.urlopen(LEGACY_URL) as response:
    legacy_bytes = response.read()
legacy_root = ET.fromstring(legacy_bytes)

local_tree = ET.parse(LOCAL_PATH)
local_root = local_tree.getroot()

local_channel = local_root.find("channel")
legacy_channel = legacy_root.find("channel")
assert local_channel is not None and legacy_channel is not None

short_tag = f"{{{SPARKLE_NS}}}shortVersionString"


def item_key(item):
    return item.findtext(short_tag) or item.findtext("title") or ""


def parse_version(version_string):
    if not version_string:
        return (0, 0, 0, -2)
    base, _, pre = version_string.partition("-")
    parts = []
    for token in base.split("."):
        try:
            parts.append(int(token))
        except ValueError:
            parts.append(0)
    while len(parts) < 3:
        parts.append(0)
    pre_rank = 0 if not pre else -1
    return tuple(parts[:3]) + (pre_rank,)


existing_items = list(local_channel.findall("item"))
existing_keys = {item_key(item) for item in existing_items}

merged_items = list(existing_items)
for legacy_item in legacy_channel.findall("item"):
    legacy_key = item_key(legacy_item)
    if legacy_key and legacy_key not in existing_keys:
        merged_items.append(legacy_item)
        existing_keys.add(legacy_key)

merged_items.sort(key=lambda item: parse_version(item_key(item)), reverse=True)

for item in existing_items:
    local_channel.remove(item)
for item in merged_items:
    local_channel.append(item)

ET.indent(local_tree, space="    ")
local_tree.write(LOCAL_PATH, encoding="utf-8", xml_declaration=True)

raw = LOCAL_PATH.read_text(encoding="utf-8")

# 1. Restore the original XML declaration with standalone="yes".
expected_decl = '<?xml version="1.0" encoding="utf-8" standalone="yes"?>'
if not raw.startswith(expected_decl):
    first_newline = raw.index("\n")
    raw = expected_decl + raw[first_newline:]

# 2. Re-wrap any <description> whose body contains escaped HTML in CDATA.
#    ElementTree cannot natively emit CDATA, so it escapes &lt;/&gt;/&amp; on
#    serialization. Convert those back so Sparkle clients render markup as HTML.
desc_pattern = re.compile(r"<description>(.*?)</description>", re.DOTALL)


def restore_cdata(match):
    body = match.group(1)
    if "&lt;" not in body and "&gt;" not in body and "&amp;" not in body:
        return match.group(0)
    unescaped = body.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    return f"<description><![CDATA[{unescaped}]]></description>"


raw = desc_pattern.sub(restore_cdata, raw)

LOCAL_PATH.write_text(raw, encoding="utf-8")

print("Merged appcast versions:", [item_key(item) for item in merged_items])
PYEOF
```

- [ ] **Step 2: Verify the merged file parses and contains the expected union**

```bash
/usr/bin/python3 -c '
import xml.etree.ElementTree as ET
tree = ET.parse("appcast.xml")
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
items = tree.findall(".//item")
versions = [i.findtext("sparkle:shortVersionString", default=i.findtext("title"), namespaces=ns) for i in items]
print("Items:", versions)
for v in ["1.8.2", "1.8.1", "1.8.0", "1.7.4", "1.7.3"]:
    assert v in versions, f"Expected {v} in merged appcast"
assert versions[0] == "1.8.2", f"Expected 1.8.2 first, got {versions[0]}"
print("OK")
'
```

Expected last line: `OK`. The print shows the merged list with 1.8.2 first.

- [ ] **Step 3: Switch `SUFeedURL` in `Info.plist` to the LyricsX repo Pages URL**

Run:

```bash
/usr/libexec/PlistBuddy -c \
  'Set :SUFeedURL https://mxiris-lyricsx-project.github.io/LyricsX/appcast.xml' \
  "LyricsX/Supporting Files/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "LyricsX/Supporting Files/Info.plist"
```

Expected last line: `https://mxiris-lyricsx-project.github.io/LyricsX/appcast.xml`.

- [ ] **Step 4: Delete the obsolete `update-gh-pages.yml` workflow**

```bash
git rm .github/workflows/update-gh-pages.yml
```

- [ ] **Step 5: Commit the migration**

```bash
git add appcast.xml "LyricsX/Supporting Files/Info.plist"
git commit -m "release: migrate Sparkle feed to LyricsX repo Pages

- Replace stale 1.7.3-only appcast.xml with current organization Pages
  content (1.7.3 through 1.8.1) as the new canonical baseline.
- Switch Info.plist SUFeedURL to
  https://mxiris-lyricsx-project.github.io/LyricsX/appcast.xml
  so 1.9.0+ clients read the new feed; <=1.8.1 clients keep reading the
  legacy URL, which CI will mirror.
- Drop update-gh-pages.yml; it had no effect on the organization Pages
  repo and is obsolete after this migration."
```

---

## Task 2: Guard the Bump-Build Build Phase

**Files:**
- Modify: `LyricsX.xcodeproj/project.pbxproj`

**Context:** The existing `PBXShellScriptBuildPhase` named "Bump Build" (id `BBC1D5811E4AFE64008869EC`) unconditionally increments `CFBundleVersion` every time Xcode builds. CI sets `LYRICSX_SKIP_BUILD_BUMP=1` so the build number read by `validate.sh` matches what ends up inside `.app`.

- [ ] **Step 1: Locate the existing `shellScript` line**

```bash
grep -n 'shellScript = "buildNumber=' LyricsX.xcodeproj/project.pbxproj
```

Expected: a single hit (around line 794).

- [ ] **Step 2: Patch the shellScript string**

Open `LyricsX.xcodeproj/project.pbxproj` in your editor, locate that one line, and replace it with exactly:

```
			shellScript = "if [ \"${LYRICSX_SKIP_BUILD_BUMP:-0}\" = \"1\" ]; then\n    echo \"Skipping CFBundleVersion bump (LYRICSX_SKIP_BUILD_BUMP=1)\"\n    exit 0\nfi\nbuildNumber=$(/usr/libexec/PlistBuddy -c \"Print CFBundleVersion\" \"${PROJECT_DIR}/${INFOPLIST_FILE}\")\nbuildNumber=$(($buildNumber + 1))\n/usr/libexec/PlistBuddy -c \"Set :CFBundleVersion $buildNumber\" \"${PROJECT_DIR}/${INFOPLIST_FILE}\"\n# Sync widget extension build number\nWIDGET_PLIST=\"${PROJECT_DIR}/LyricsXWidget/Info.plist\"\nif [ -f \"$WIDGET_PLIST\" ]; then\n    /usr/libexec/PlistBuddy -c \"Set :CFBundleVersion $buildNumber\" \"$WIDGET_PLIST\"\nfi\n";
```

- [ ] **Step 3: Verify the patched project file parses**

```bash
plutil -lint LyricsX.xcodeproj/project.pbxproj
```

Expected: `LyricsX.xcodeproj/project.pbxproj: OK`.

- [ ] **Step 4: Verify CI-mode skip works (no build-number change)**

```bash
BEFORE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "LyricsX/Supporting Files/Info.plist")
echo "Before: $BEFORE"

LYRICSX_SKIP_BUILD_BUMP=1 xcodebuild \
  -project LyricsX.xcodeproj \
  -scheme LyricsX \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -10

AFTER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "LyricsX/Supporting Files/Info.plist")
echo "After:  $AFTER"

[ "$BEFORE" = "$AFTER" ] && echo "OK: build number unchanged ($BEFORE)" || { echo "FAIL: $BEFORE -> $AFTER"; exit 1; }
```

Expected last line: `OK: build number unchanged (<N>)`.

- [ ] **Step 5: Commit**

```bash
git add LyricsX.xcodeproj/project.pbxproj
git commit -m "build: guard Bump Build phase with LYRICSX_SKIP_BUILD_BUMP"
```

---

## Task 3: Ignore CI Build Output Directories

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Append `build/` and `Scripts/release/bin/` to `.gitignore`**

Edit `.gitignore` so its final state is:

```
Product
build/
Scripts/release/bin/
.DS_Store
xcuserdata
project.xcworkspace/**
!project.xcworkspace/xcshareddata/
!project.xcworkspace/xcshareddata/swiftpm/
!project.xcworkspace/xcshareddata/swiftpm/Package.resolved
.claude
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: ignore build/ and Scripts/release/bin/ (release CI artifacts)"
```

---

## Task 4: Scaffold `Scripts/release/lib.sh`

**Files:**
- Create: `Scripts/release/lib.sh`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p Scripts/release
```

- [ ] **Step 2: Write `Scripts/release/lib.sh`**

```bash
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
```

- [ ] **Step 3: Make it executable**

```bash
chmod +x Scripts/release/lib.sh
```

- [ ] **Step 4: Smoke test the helpers**

```bash
bash -c '
set -euo pipefail
source Scripts/release/lib.sh
log_info "hello"
validate_version_format 1.9.0
validate_version_format 1.9.0-beta.1
# die() exits the shell, so wrap in a sub-shell so exit-1 is observable as a non-zero status.
if ( validate_version_format "bad-value" ) 2>/dev/null; then echo "FAIL: should have rejected bad-value"; exit 1; fi
if is_prerelease_version 1.9.0; then echo "FAIL: 1.9.0 should not be prerelease"; exit 1; fi
if ! is_prerelease_version 1.9.0-beta.1; then echo "FAIL: 1.9.0-beta.1 should be prerelease"; exit 1; fi
echo OK
'
```

Expected last line: `OK`.

- [ ] **Step 5: Commit**

```bash
git add Scripts/release/lib.sh
git commit -m "build(release): add shared shell helpers"
```

---

## Task 5: `Scripts/release/resolve-version.sh`

**Files:**
- Create: `Scripts/release/resolve-version.sh`

**Responsibility:** Given either `GITHUB_REF_NAME` (for tag push) or `INPUT_VERSION` (for `workflow_dispatch`), produce `VERSION` and `IS_PRERELEASE`. Append them to `$GITHUB_ENV` if set, and always print to stdout.

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/resolve-version.sh
```

- [ ] **Step 3: Smoke test all three paths**

```bash
GITHUB_EVENT_NAME=push GITHUB_REF_NAME=v1.9.0 bash Scripts/release/resolve-version.sh
GITHUB_EVENT_NAME=push GITHUB_REF_NAME=v1.9.0-beta.1 bash Scripts/release/resolve-version.sh
GITHUB_EVENT_NAME=workflow_dispatch INPUT_VERSION=1.9.0-rc.2 bash Scripts/release/resolve-version.sh

if GITHUB_EVENT_NAME=push GITHUB_REF_NAME=master \
   bash Scripts/release/resolve-version.sh 2>/dev/null; then
  echo "FAIL: should have rejected non-v ref"; exit 1
fi
echo OK
```

Expected: each happy-path call prints `VERSION=...` and `IS_PRERELEASE=...` to stdout; final line is `OK`.

- [ ] **Step 4: Commit**

```bash
git add Scripts/release/resolve-version.sh
git commit -m "build(release): add resolve-version.sh"
```

---

## Task 6: `Scripts/release/validate.sh`

**Files:**
- Create: `Scripts/release/validate.sh`

**Responsibility:** Enforce the consistency checks from design spec §9.

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/validate.sh
```

- [ ] **Step 3: Smoke test against current `Info.plist`**

```bash
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "LyricsX/Supporting Files/Info.plist")
echo "Current plist version: $CURRENT_VERSION"

mkdir -p ReleaseNotes
[ -f "ReleaseNotes/${CURRENT_VERSION}_en.md" ] || printf '# %s\n\n- test\n' "$CURRENT_VERSION" > "ReleaseNotes/${CURRENT_VERSION}_en.md"
[ -f "ReleaseNotes/${CURRENT_VERSION}_zh.md" ] || printf '# %s\n\n- 测试\n' "$CURRENT_VERSION" > "ReleaseNotes/${CURRENT_VERSION}_zh.md"

SKIP_RELEASE_EXISTS_CHECK=1 \
VERSION="$CURRENT_VERSION" IS_PRERELEASE=false GITHUB_EVENT_NAME=workflow_dispatch \
  bash Scripts/release/validate.sh

if SKIP_RELEASE_EXISTS_CHECK=1 \
   VERSION=99.99.99 IS_PRERELEASE=false GITHUB_EVENT_NAME=workflow_dispatch \
   bash Scripts/release/validate.sh 2>/dev/null; then
  echo "FAIL: 99.99.99 should have failed (wrong shortVersion)"; exit 1
fi
echo OK
```

Expected last line: `OK`.

- [ ] **Step 4: Remove any dummy ReleaseNotes you don't want to ship**

```bash
git status ReleaseNotes
# If you created ReleaseNotes/<current_version>_*.md as dummies, delete them now.
```

- [ ] **Step 5: Commit**

```bash
git add Scripts/release/validate.sh
git commit -m "build(release): add validate.sh consistency gate"
```

---

## Task 7: `Scripts/release/setup-keychain.sh`

**Files:**
- Create: `Scripts/release/setup-keychain.sh`

**Responsibility:** Create a temporary macOS keychain, import the Developer ID Application `.p12`, and add it to the search list so `xcodebuild` finds the identity. Also supports a `cleanup` argument used by the workflow's always-run cleanup step.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Create a temporary macOS keychain and import the Developer ID Application cert.
#
# Inputs (env):
#   APPLE_DEV_ID_CERT_P12_BASE64  base64-encoded .p12
#   APPLE_DEV_ID_CERT_PASSWORD    password for the .p12
#   KEYCHAIN_PASSWORD             password to create the temp keychain with
#
# Side effects:
#   Creates ~/Library/Keychains/lyricsx-release.keychain-db and adds it to the
#   user's keychain search list. Unlocks it and allows codesign access.
#
# To clean up, call this script with the "cleanup" argument.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

KEYCHAIN_NAME="lyricsx-release.keychain-db"
KEYCHAIN_PATH="${HOME}/Library/Keychains/${KEYCHAIN_NAME}"

cleanup() {
    if [ -f "$KEYCHAIN_PATH" ]; then
        log_info "Deleting temp keychain $KEYCHAIN_PATH"
        security delete-keychain "$KEYCHAIN_PATH" || true
    fi
}

if [ "${1:-}" = "cleanup" ]; then
    cleanup
    exit 0
fi

require_env APPLE_DEV_ID_CERT_P12_BASE64 APPLE_DEV_ID_CERT_PASSWORD KEYCHAIN_PASSWORD

cleanup

P12_PATH="$(mktemp -t lyricsx-cert).p12"
trap 'rm -f "$P12_PATH"' EXIT

printf '%s' "$APPLE_DEV_ID_CERT_P12_BASE64" | base64 --decode > "$P12_PATH"

log_info "Creating temp keychain"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

log_info "Importing Developer ID Application certificate"
security import "$P12_PATH" \
    -k "$KEYCHAIN_PATH" \
    -P "$APPLE_DEV_ID_CERT_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" >/dev/null

ORIGINAL_LIST=$(security list-keychains -d user | tr -d '"' | tr -d ' ')
security list-keychains -d user -s "$KEYCHAIN_PATH" $ORIGINAL_LIST

log_info "Installed identities:"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/setup-keychain.sh
```

- [ ] **Step 3: Smoke test the missing-env failure path**

```bash
if bash Scripts/release/setup-keychain.sh 2>/dev/null; then
  echo "FAIL: should have errored on missing env"; exit 1
fi
echo OK
```

Expected: `OK`. (Full happy path requires a real certificate and is deferred to Task 16 CI validation.)

- [ ] **Step 4: Commit**

```bash
git add Scripts/release/setup-keychain.sh
git commit -m "build(release): add setup-keychain.sh"
```

---

## Task 8: `Scripts/release/install-sparkle-tools.sh`

**Files:**
- Create: `Scripts/release/install-sparkle-tools.sh`

**Responsibility:** Download a pinned Sparkle release tarball, extract `bin/sign_update`, and place it at `Scripts/release/bin/sign_update` (git-ignored). Verify the binary runs.

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/install-sparkle-tools.sh
```

- [ ] **Step 3: Smoke test (downloads ~5MB; OK to run on a network-connected dev box)**

```bash
SPARKLE_VERSION=2.6.4 bash Scripts/release/install-sparkle-tools.sh
ls -la Scripts/release/bin/sign_update
Scripts/release/bin/sign_update --help >/dev/null && echo "OK: sign_update runnable"
echo OK
```

Expected: `Scripts/release/bin/sign_update` exists; `--help` exits 0; final line is `OK`.

- [ ] **Step 4: Commit**

```bash
git add Scripts/release/install-sparkle-tools.sh
git commit -m "build(release): add install-sparkle-tools.sh"
```

---

## Task 9: `Scripts/release/build.sh`

**Files:**
- Create: `Scripts/release/build.sh`

**Responsibility:** Archive and export a signed `.app` using the Developer ID Application identity that `setup-keychain.sh` installed.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Archive + exportArchive into build/Export/LyricsX.app
#
# Inputs (env):
#   DEVELOPMENT_TEAM  (optional) team identifier; defaults to D5Q73692VW
#
# Requires: setup-keychain.sh must have run first so the Developer ID
# Application identity is in the keychain search list.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

TEAM_ID="${DEVELOPMENT_TEAM:-D5Q73692VW}"
ARCHIVE_PATH="build/LyricsX.xcarchive"
EXPORT_PATH="build/Export"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p build

export LYRICSX_SKIP_BUILD_BUMP=1
export LYRICSX_USE_LOCAL_DEPENDENCY=0

log_info "Archiving LyricsX (team=${TEAM_ID})"
xcodebuild \
    -project LyricsX.xcodeproj \
    -scheme LyricsX \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    archive

log_info "Exporting signed .app"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "$EXPORT_PATH"

if [ ! -d "${EXPORT_PATH}/LyricsX.app" ]; then
    die "Export did not produce ${EXPORT_PATH}/LyricsX.app"
fi

log_info "Built ${EXPORT_PATH}/LyricsX.app"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/build.sh
```

- [ ] **Step 3: Commit (no local smoke test — requires a real Developer ID identity)**

```bash
git add Scripts/release/build.sh
git commit -m "build(release): add build.sh archive + exportArchive"
```

---

## Task 10: `Scripts/release/notarize.sh`

**Files:**
- Create: `Scripts/release/notarize.sh`

**Responsibility:** Submit the built `.app` to Apple notarization using App Store Connect API Key auth, wait for the result, and staple the ticket.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Notarize build/Export/LyricsX.app and staple the ticket.
#
# Inputs (env):
#   APPLE_API_KEY_P8_BASE64    base64 of App Store Connect API key .p8
#   APPLE_API_KEY_ID           10-char Key ID
#   APPLE_API_KEY_ISSUER_ID    Issuer UUID

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

require_env APPLE_API_KEY_P8_BASE64 APPLE_API_KEY_ID APPLE_API_KEY_ISSUER_ID

APP_PATH="build/Export/LyricsX.app"
[ -d "$APP_PATH" ] || die "Expected ${APP_PATH} to exist (run build.sh first)"

API_KEY_PATH="$(mktemp -t apple-api-key).p8"
SUBMIT_ZIP="build/LyricsX.notarize.zip"
SUBMIT_RESULT="build/notarize.json"

cleanup() {
    rm -f "$API_KEY_PATH"
}
trap cleanup EXIT

printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 --decode > "$API_KEY_PATH"

log_info "Creating submission zip"
rm -f "$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"

log_info "Submitting to notarytool (this may take several minutes)"
xcrun notarytool submit "$SUBMIT_ZIP" \
    --key "$API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_KEY_ISSUER_ID" \
    --wait \
    --output-format json | tee "$SUBMIT_RESULT"

STATUS=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$SUBMIT_RESULT")
SUBMISSION_ID=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$SUBMIT_RESULT")

log_info "Notarization status: ${STATUS} (submission ${SUBMISSION_ID})"

if [ "$STATUS" != "Accepted" ]; then
    log_error "Notarization failed. Fetching log:"
    xcrun notarytool log "$SUBMISSION_ID" \
        --key "$API_KEY_PATH" \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_KEY_ISSUER_ID" || true
    die "Notarization status was '${STATUS}', expected 'Accepted'"
fi

log_info "Stapling ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
log_info "Stapled and validated"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/notarize.sh
```

- [ ] **Step 3: Smoke test "missing env" failure path**

```bash
if bash Scripts/release/notarize.sh 2>/dev/null; then
  echo "FAIL: should have errored on missing env"; exit 1
fi
echo OK
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add Scripts/release/notarize.sh
git commit -m "build(release): add notarize.sh"
```

---

## Task 11: `Scripts/release/package.sh`

**Files:**
- Create: `Scripts/release/package.sh`

**Responsibility:** Produce the two final zip artifacts that get attached to the GitHub Release.

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/package.sh
```

- [ ] **Step 3: Smoke test missing-prereq failure path**

```bash
rm -rf build/
if VERSION=1.0.0 BUILD=1 bash Scripts/release/package.sh 2>/dev/null; then
  echo "FAIL: should have errored on missing build artifact"; exit 1
fi
echo OK
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add Scripts/release/package.sh
git commit -m "build(release): add package.sh"
```

---

## Task 12: `Scripts/release/sign-sparkle.sh`

**Files:**
- Create: `Scripts/release/sign-sparkle.sh`

**Responsibility:** Run Sparkle's `sign_update` against the app zip, parse out the `sparkle:edSignature` and `length` values, and export them via `$GITHUB_ENV`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Sparkle-sign build/LyricsX_<VERSION>+<BUILD>.zip and emit
# ED_SIGNATURE + ZIP_LENGTH into $GITHUB_ENV (and stdout).
#
# Inputs (env):
#   VERSION, BUILD                  identify the zip
#   SPARKLE_ED_PRIVATE_KEY          the literal string produced by
#                                   `generate_keys -x` (Sparkle ed25519 priv)
#   GITHUB_ENV                      (optional) GitHub Actions env file

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
cd "$(repo_root)"

require_env VERSION BUILD SPARKLE_ED_PRIVATE_KEY

APP_ZIP="build/LyricsX_${VERSION}+${BUILD}.zip"
[ -f "$APP_ZIP" ] || die "Missing ${APP_ZIP} (run package.sh first)"

SIGN_TOOL="Scripts/release/bin/sign_update"
[ -x "$SIGN_TOOL" ] || die "Missing ${SIGN_TOOL} (run install-sparkle-tools.sh first)"

KEY_FILE="$(mktemp -t sparkle-key)"
trap 'rm -f "$KEY_FILE"' EXIT

printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$KEY_FILE"

log_info "Signing ${APP_ZIP}"
SIGN_OUTPUT="$("$SIGN_TOOL" --ed-key-file "$KEY_FILE" "$APP_ZIP")"

ED_SIGNATURE="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
ZIP_LENGTH="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"

[ -n "$ED_SIGNATURE" ] || die "Failed to parse sparkle:edSignature from sign_update output: ${SIGN_OUTPUT}"
[ -n "$ZIP_LENGTH" ]  || die "Failed to parse length from sign_update output: ${SIGN_OUTPUT}"

log_info "ED_SIGNATURE=${ED_SIGNATURE}"
log_info "ZIP_LENGTH=${ZIP_LENGTH}"

printf 'ED_SIGNATURE=%s\n' "$ED_SIGNATURE"
printf 'ZIP_LENGTH=%s\n' "$ZIP_LENGTH"

if [ -n "${GITHUB_ENV:-}" ]; then
    {
        printf 'ED_SIGNATURE=%s\n' "$ED_SIGNATURE"
        printf 'ZIP_LENGTH=%s\n' "$ZIP_LENGTH"
    } >> "$GITHUB_ENV"
fi
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/sign-sparkle.sh
```

- [ ] **Step 3: Smoke test missing-env failure path**

```bash
if bash Scripts/release/sign-sparkle.sh 2>/dev/null; then
  echo "FAIL: should have errored on missing env"; exit 1
fi
echo OK
```

Expected: `OK`. (Full happy path requires a real key + zip and is exercised in CI.)

- [ ] **Step 4: Commit**

```bash
git add Scripts/release/sign-sparkle.sh
git commit -m "build(release): add sign-sparkle.sh"
```

---

## Task 13: `Scripts/release/compose-notes.sh`

**Files:**
- Create: `Scripts/release/compose-notes.sh`

**Responsibility:** Join `ReleaseNotes/<VERSION>_en.md` and `_zh.md` into `build/body.md` using a plain `---` separator.

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/compose-notes.sh
```

- [ ] **Step 3: Smoke test against existing 1.8.0 notes**

```bash
VERSION=1.8.0 bash Scripts/release/compose-notes.sh
head -5 build/body.md
echo "---"
grep -c '^---$' build/body.md
```

Expected: `grep -c` count is `1`; `head -5` shows the English block start.

- [ ] **Step 4: Commit**

```bash
git add Scripts/release/compose-notes.sh
git commit -m "build(release): add compose-notes.sh"
```

---

## Task 14: `Scripts/release/create-release.sh`

**Files:**
- Create: `Scripts/release/create-release.sh`

**Responsibility:** Create a **published** GitHub Release (not a draft) with both zip assets. Sets `--prerelease` when `IS_PRERELEASE=true`.

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/create-release.sh
```

- [ ] **Step 3: Smoke test missing-prereq failure path**

```bash
rm -f build/LyricsX_*.zip build/body.md
if VERSION=0.0.0 BUILD=1 IS_PRERELEASE=false \
   bash Scripts/release/create-release.sh 2>/dev/null; then
  echo "FAIL: should have errored on missing artifacts"; exit 1
fi
echo OK
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add Scripts/release/create-release.sh
git commit -m "build(release): add create-release.sh (published, not draft)"
```

---

## Task 15: `Scripts/release/update-appcast.py` + `publish-appcast.sh`

**Files:**
- Create: `Scripts/release/update-appcast.py`
- Create: `Scripts/release/publish-appcast.sh`

**Responsibility:** `update-appcast.py` is a pure file edit — it inserts a new `<item>` at the top of `<channel>` in the file at `APPCAST_PATH`. It is idempotent (no-op when an item with the same `<sparkle:shortVersionString>` already exists). `publish-appcast.sh` wraps it with the git operations needed for the canonical repo (current checkout) or the legacy mirror (cloned via fine-grained PAT).

- [ ] **Step 1: Write `Scripts/release/update-appcast.py`**

```python
#!/usr/bin/env python3
"""Insert a new <item> into a Sparkle appcast.xml file.

Idempotent: if an <item> with the same <sparkle:shortVersionString> already
exists, the file is left untouched and the script exits 0.

Inputs (env):
    APPCAST_PATH            path to the appcast.xml file to modify
    VERSION                 e.g. "1.9.0"
    BUILD                   e.g. "2925"
    ED_SIGNATURE            value for sparkle:edSignature attribute
    ZIP_LENGTH              value for length attribute (string of integer)
    MIN_SYSTEM_VERSION      (optional) defaults to "11.0"
    RELEASE_NOTES_PATH      (optional) defaults to ReleaseNotes/<VERSION>_en.md
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)


def require(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        sys.exit(f"[ERROR] Required env var missing: {name}")
    return value


def rfc822_now() -> str:
    return datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")


def main() -> int:
    appcast_path = Path(require("APPCAST_PATH"))
    version = require("VERSION")
    build = require("BUILD")
    ed_signature = require("ED_SIGNATURE")
    zip_length = require("ZIP_LENGTH")
    min_system_version = os.environ.get("MIN_SYSTEM_VERSION", "11.0")
    release_notes_path = Path(
        os.environ.get("RELEASE_NOTES_PATH", f"ReleaseNotes/{version}_en.md")
    )

    if not appcast_path.exists():
        sys.exit(f"[ERROR] APPCAST_PATH does not exist: {appcast_path}")
    if not release_notes_path.exists():
        sys.exit(f"[ERROR] RELEASE_NOTES_PATH does not exist: {release_notes_path}")

    tree = ET.parse(appcast_path)
    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        sys.exit(f"[ERROR] No <channel> element in {appcast_path}")

    short_tag = f"{{{SPARKLE_NS}}}shortVersionString"
    for existing in channel.findall("item"):
        existing_short = existing.findtext(short_tag)
        if existing_short == version:
            print(f"[INFO] {appcast_path}: item {version} already present, no change.")
            return 0

    enclosure_url = (
        "https://github.com/MxIris-LyricsX-Project/LyricsX/releases/download/"
        f"v{version}/LyricsX_{version}+{build}.zip"
    )
    description = release_notes_path.read_text(encoding="utf-8").strip()

    item = ET.Element("item")
    ET.SubElement(item, "title").text = version
    ET.SubElement(item, "pubDate").text = rfc822_now()
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = build
    ET.SubElement(item, short_tag).text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = min_system_version

    desc = ET.SubElement(item, "description")
    # ElementTree cannot natively emit CDATA. Use a unique placeholder here
    # and post-process the serialized output below to wrap it in CDATA.
    DESC_PLACEHOLDER = "@@LYRICSX_DESC_CDATA_PLACEHOLDER@@"
    desc.text = DESC_PLACEHOLDER

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", enclosure_url)
    enclosure.set("length", zip_length)
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{{{SPARKLE_NS}}}edSignature", ed_signature)

    # Insert as first child of <channel> so newest is on top.
    # Find the index after any leading non-item children (title, description, language).
    insert_index = 0
    for index, child in enumerate(list(channel)):
        if child.tag == "item":
            insert_index = index
            break
        insert_index = index + 1
    channel.insert(insert_index, item)

    # Pretty-print: ElementTree.indent (Python 3.9+) gives nice 4-space output.
    ET.indent(tree, space="    ")

    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)

    # Post-process serialized file:
    # 1. Replace ET's XML declaration (which uses single quotes and lacks
    #    standalone="yes") with the canonical declaration the original file used.
    # 2. Replace the description placeholder with a real CDATA section so
    #    Sparkle clients can render the markdown as-is.
    raw = appcast_path.read_text(encoding="utf-8")
    expected_decl = '<?xml version="1.0" encoding="utf-8" standalone="yes"?>'
    if not raw.startswith(expected_decl):
        first_newline = raw.index("\n")
        raw = expected_decl + raw[first_newline:]
    raw = raw.replace(DESC_PLACEHOLDER, f"<![CDATA[{description}]]>")
    appcast_path.write_text(raw, encoding="utf-8")

    print(f"[INFO] {appcast_path}: inserted item for v{version} (build {build}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/update-appcast.py
```

- [ ] **Step 3: Smoke test idempotency + insertion against a fixture**

```bash
mkdir -p /tmp/appcast-test
cp appcast.xml /tmp/appcast-test/appcast.xml
mkdir -p /tmp/appcast-test/ReleaseNotes
printf '# 9.9.9\n\n- smoke test entry\n' > /tmp/appcast-test/ReleaseNotes/9.9.9_en.md

# First insert
APPCAST_PATH=/tmp/appcast-test/appcast.xml \
VERSION=9.9.9 BUILD=99999 \
ED_SIGNATURE=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
ZIP_LENGTH=12345 \
RELEASE_NOTES_PATH=/tmp/appcast-test/ReleaseNotes/9.9.9_en.md \
  python3 Scripts/release/update-appcast.py

# Second invocation should be a no-op
APPCAST_PATH=/tmp/appcast-test/appcast.xml \
VERSION=9.9.9 BUILD=99999 \
ED_SIGNATURE=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
ZIP_LENGTH=12345 \
RELEASE_NOTES_PATH=/tmp/appcast-test/ReleaseNotes/9.9.9_en.md \
  python3 Scripts/release/update-appcast.py

# Verify exactly one 9.9.9 item exists
COUNT=$(grep -c '<title>9.9.9</title>' /tmp/appcast-test/appcast.xml)
[ "$COUNT" = "1" ] && echo "OK: exactly one 9.9.9 item present" || { echo "FAIL: count=$COUNT"; exit 1; }

# Verify enclosure URL
grep -q 'releases/download/v9.9.9/LyricsX_9.9.9+99999.zip' /tmp/appcast-test/appcast.xml \
    && echo "OK: enclosure URL present" \
    || { echo "FAIL: enclosure URL missing"; exit 1; }

# Verify file still parses as XML
python3 -c 'import xml.etree.ElementTree as ET; ET.parse("/tmp/appcast-test/appcast.xml")' \
    && echo "OK: XML parses" \
    || { echo "FAIL: XML broken"; exit 1; }

# Verify description was wrapped in CDATA
grep -q '<description><!\[CDATA\[' /tmp/appcast-test/appcast.xml \
    && echo "OK: CDATA present" \
    || { echo "FAIL: CDATA missing"; exit 1; }
```

Expected: four `OK:` lines.

- [ ] **Step 4: Write `Scripts/release/publish-appcast.sh`**

```bash
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
            python3 Scripts/release/update-appcast.py

        if git diff --quiet -- appcast.xml; then
            log_info "appcast.xml unchanged — nothing to commit."
            exit 0
        fi

        git_id
        git add appcast.xml
        git commit -m "release: update appcast.xml for v${VERSION}"
        git pull --rebase origin master
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
```

- [ ] **Step 5: Make it executable**

```bash
chmod +x Scripts/release/publish-appcast.sh
```

- [ ] **Step 6: Smoke test missing-arg + prerelease no-op paths**

The canonical/mirror modes touch git remote state and are deferred to the CI
end-to-end test (Task 17). Locally, only verify the cheap branches:

```bash
# Missing mode arg
if bash Scripts/release/publish-appcast.sh 2>/dev/null; then
  echo "FAIL: should have required mode arg"; exit 1
fi

# Missing required env (no VERSION etc.)
if bash Scripts/release/publish-appcast.sh canonical 2>/dev/null; then
  echo "FAIL: should have required VERSION/BUILD/etc."; exit 1
fi

# Prerelease early-exit (no git operations, no file writes)
VERSION=1.0.0-beta.1 BUILD=1 IS_PRERELEASE=true ED_SIGNATURE=x ZIP_LENGTH=1 \
  bash Scripts/release/publish-appcast.sh canonical

# Confirm working tree is still clean
git diff --quiet -- appcast.xml && echo "OK: appcast unchanged" \
    || { echo "FAIL: appcast.xml dirty after prerelease no-op"; git checkout -- appcast.xml; exit 1; }
```

Expected last line: `OK: appcast unchanged`.

- [ ] **Step 7: Commit**

```bash
git add Scripts/release/update-appcast.py Scripts/release/publish-appcast.sh
git commit -m "build(release): add update-appcast.py + publish-appcast.sh"
```

---

## Task 16: The Workflow File

**Files:**
- Create: `.github/workflows/release.yml`

**Responsibility:** Glue all scripts together, inject secrets, expose triggers and the `dry_run` input.

- [ ] **Step 1: Write the workflow**

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:
    inputs:
      version:
        description: 'Version (e.g. 1.9.0 or 1.9.0-beta.1)'
        required: true
        type: string
      dry_run:
        description: 'Stop after build (no notarize, no release, no appcast)'
        required: false
        default: false
        type: boolean

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-26
    env:
      LYRICSX_SKIP_BUILD_BUMP: "1"
      LYRICSX_USE_LOCAL_DEPENDENCY: "0"
      SPARKLE_VERSION: "2.6.4"
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Resolve version
        env:
          INPUT_VERSION: ${{ inputs.version }}
        run: bash Scripts/release/resolve-version.sh

      - name: Validate
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: bash Scripts/release/validate.sh

      - name: Setup keychain
        env:
          APPLE_DEV_ID_CERT_P12_BASE64: ${{ secrets.APPLE_DEV_ID_CERT_P12_BASE64 }}
          APPLE_DEV_ID_CERT_PASSWORD: ${{ secrets.APPLE_DEV_ID_CERT_PASSWORD }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: bash Scripts/release/setup-keychain.sh

      - name: Install Sparkle tools
        run: bash Scripts/release/install-sparkle-tools.sh

      - name: Build
        run: bash Scripts/release/build.sh

      - name: Upload xcresult on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: xcresult
          path: |
            build/LyricsX.xcarchive
            ~/Library/Developer/Xcode/DerivedData/**/Logs/Build/*.xcresult
          if-no-files-found: ignore
          retention-days: 7

      - name: Notarize
        if: ${{ !inputs.dry_run }}
        env:
          APPLE_API_KEY_P8_BASE64: ${{ secrets.APPLE_API_KEY_P8_BASE64 }}
          APPLE_API_KEY_ID: ${{ secrets.APPLE_API_KEY_ID }}
          APPLE_API_KEY_ISSUER_ID: ${{ secrets.APPLE_API_KEY_ISSUER_ID }}
        run: bash Scripts/release/notarize.sh

      - name: Package
        if: ${{ !inputs.dry_run }}
        run: bash Scripts/release/package.sh

      - name: Sparkle sign
        if: ${{ !inputs.dry_run }}
        env:
          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
        run: bash Scripts/release/sign-sparkle.sh

      - name: Compose release notes
        if: ${{ !inputs.dry_run }}
        run: bash Scripts/release/compose-notes.sh

      - name: Create published release
        if: ${{ !inputs.dry_run }}
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: bash Scripts/release/create-release.sh

      - name: Update canonical appcast
        if: ${{ !inputs.dry_run && env.IS_PRERELEASE == 'false' }}
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: bash Scripts/release/publish-appcast.sh canonical

      - name: Mirror to legacy Pages repo
        if: ${{ !inputs.dry_run && env.IS_PRERELEASE == 'false' }}
        env:
          PAGES_MIRROR_TOKEN: ${{ secrets.PAGES_MIRROR_TOKEN }}
        run: bash Scripts/release/publish-appcast.sh mirror

      - name: Upload body.md artifact
        if: ${{ !inputs.dry_run && always() }}
        uses: actions/upload-artifact@v4
        with:
          name: release-body
          path: build/body.md
          if-no-files-found: ignore
          retention-days: 7

      - name: Cleanup keychain
        if: always()
        run: bash Scripts/release/setup-keychain.sh cleanup
```

- [ ] **Step 2: Lint the workflow syntactically**

```bash
/usr/bin/python3 -c 'import yaml,sys; yaml.safe_load(open(".github/workflows/release.yml"))' && echo OK
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add release workflow with full Sparkle automation"
```

---

## Task 17: Configure Secrets and Validate End-to-End

**Files:** None — this task runs entirely on GitHub and produces no local diff.

- [ ] **Step 1: Generate a keychain password for the CI runner**

```bash
openssl rand -hex 24
```

Copy the output — paste into `KEYCHAIN_PASSWORD` in Step 3.

- [ ] **Step 2: Prepare base64-encoded certificates and API keys**

```bash
# Developer ID Application .p12 (exported from Keychain Access)
base64 -i /path/to/developer-id.p12 | pbcopy
# paste into APPLE_DEV_ID_CERT_P12_BASE64

# App Store Connect API key .p8 (downloaded from App Store Connect)
base64 -i /path/to/AuthKey_XXXXXXXXXX.p8 | pbcopy
# paste into APPLE_API_KEY_P8_BASE64
```

- [ ] **Step 3: Export the Sparkle EdDSA private key**

If you don't have it on disk:

```bash
# Sparkle generate_keys -x writes the key to a file
/path/to/Sparkle-2.6.4/bin/generate_keys -x ~/.sparkle-ed-priv
cat ~/.sparkle-ed-priv | pbcopy
# paste into SPARKLE_ED_PRIVATE_KEY (raw string content, not base64)
```

If your private key is currently in macOS Keychain, run `generate_keys -x <path>` once and Sparkle will export it from the keychain into the file.

- [ ] **Step 4: Create a fine-grained PAT for the legacy Pages repo**

Visit `https://github.com/settings/personal-access-tokens/new`:

- Resource owner: `MxIris-LyricsX-Project`
- Repository access: only select `MxIris-LyricsX-Project/MxIris-LyricsX-Project.github.io`
- Permissions → Repository permissions: `Contents: Read and write`
- Expiration: pick a reasonable horizon (90 days or 1 year — calendar-track expiry)

Copy the token; paste into `PAGES_MIRROR_TOKEN` in Step 5.

- [ ] **Step 5: Add all eight secrets in GitHub**

Visit `https://github.com/MxIris-LyricsX-Project/LyricsX/settings/secrets/actions` and create:

| Name | Value |
|---|---|
| `APPLE_DEV_ID_CERT_P12_BASE64` | output of `base64 -i developer-id.p12` |
| `APPLE_DEV_ID_CERT_PASSWORD` | password set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | output from Step 1 |
| `APPLE_API_KEY_P8_BASE64` | output of `base64 -i AuthKey_*.p8` |
| `APPLE_API_KEY_ID` | 10-char Key ID from App Store Connect |
| `APPLE_API_KEY_ISSUER_ID` | Issuer UUID from App Store Connect |
| `SPARKLE_ED_PRIVATE_KEY` | content of `~/.sparkle-ed-priv` (raw string, not base64) |
| `PAGES_MIRROR_TOKEN` | fine-grained PAT from Step 4 |

- [ ] **Step 6: Push the branch and trigger a `dry_run`**

```bash
git push origin HEAD
```

Make sure `ReleaseNotes/<current_version>_en.md` and `_zh.md` exist for the
current `CFBundleShortVersionString` (or create temporary stubs you'll delete after).

On GitHub → Actions → **Release** → **Run workflow**:
- Branch: the branch you just pushed
- `version`: current `CFBundleShortVersionString` (e.g. `1.9.0`)
- `dry_run`: `true`

- [ ] **Step 7: Inspect the dry-run outcome**

Expected:
- Steps 1–6 (Checkout, Resolve, Validate, Setup keychain, Install Sparkle tools, Build) run green.
- Steps 7–14 (Notarize through Mirror) all show as **skipped**.
- **Cleanup keychain** runs.
- No GitHub Release is created.
- If Build fails, download the `xcresult` artifact for inspection.

- [ ] **Step 8: First real release test**

Bump `CFBundleShortVersionString` in `Info.plist` to a safely unused value (e.g. `0.0.1-ci-test`), write `ReleaseNotes/0.0.1-ci-test_en.md` and `_zh.md` stubs, commit, push, and dispatch again without `dry_run`.

Verify:
- Workflow run is green.
- A **published** release `v0.0.1-ci-test` exists, marked as `Pre-release`.
- Both `LyricsX_0.0.1-ci-test+<BUILD>.zip` and `LyricsX_0.0.1-ci-test+<BUILD>.dSYMs.zip` are attached.
- Body contains both English and Chinese notes separated by `---`.
- `appcast.xml` was **not** updated (because prerelease).
- The legacy Pages repo `appcast.xml` was **not** updated.

Delete the prerelease and revert the version bump commit once satisfied.

- [ ] **Step 9: First real stable-release test (optional staging)**

Same as Step 8 but with a non-prerelease version (e.g. `0.0.1`):

Verify:
- Published release `v0.0.1` exists, **not** marked as prerelease.
- LyricsX repo root `appcast.xml` has a new `<item>` at top with `<title>0.0.1</title>`.
- Legacy Pages repo `appcast.xml` has the same new `<item>` at top.
- Both pushes are visible in commit history.
- `https://mxiris-lyricsx-project.github.io/LyricsX/appcast.xml` serves the new content within ~1 minute (Pages rebuild).
- `https://mxiris-lyricsx-project.github.io/appcast.xml` serves the new content within ~1 minute.

Delete the test release, revert both `appcast.xml` updates (in LyricsX repo and Pages repo), and revert the version bump.

- [ ] **Step 10: Document release procedure**

For future releases:

1. Bump `CFBundleShortVersionString` in `LyricsX/Supporting Files/Info.plist`, commit.
2. Write `ReleaseNotes/<version>_en.md` and `ReleaseNotes/<version>_zh.md`, commit.
3. `git push origin master && git tag v<version> && git push origin v<version>`.
4. Wait for the workflow. Outcome:
   - Published GitHub Release with both zips and bilingual notes.
   - LyricsX repo root `appcast.xml` updated and pushed to `master`.
   - Legacy Pages repo `appcast.xml` mirror updated.
5. Sparkle clients pick up the update on their next poll.

To retire the legacy mirror around 2.0.0:

1. Remove the `Mirror to legacy Pages repo` step from `.github/workflows/release.yml`.
2. Delete the `PAGES_MIRROR_TOKEN` secret.
3. Optionally archive the `MxIris-LyricsX-Project.github.io` repo.

---

## Spec Coverage Check

| Spec section | Task |
|---|---|
| §2 In scope / out of scope | Whole plan honors boundaries |
| §3 Inputs and Triggers | Task 16 workflow + Task 5 `resolve-version.sh` |
| §4 File Layout | Tasks 4–15 (one or two files each) |
| §5 Sparkle Feed Migration | Task 1 |
| §6 Xcode Build Phase Edit | Task 2 |
| §7 Secrets | Task 17 Steps 1–5 |
| §8 Workflow Steps | Task 16 |
| §9 Validation Rules | Task 6 `validate.sh` |
| §10 Build/Notarize/Package | Tasks 9, 10, 11 |
| §11 Sparkle Tool Installation | Task 8 |
| §12 Sparkle Signing | Task 12 |
| §13 Release Notes Composition | Task 13 |
| §14 GitHub Release Creation | Task 14 |
| §15 Appcast Item Insertion | Task 15 (`update-appcast.py`) |
| §16 Publish Appcast | Task 15 (`publish-appcast.sh`) |
| §17 Pre-release Behavior | Task 16 workflow `if:` guards + Task 15 prerelease early-exit |
| §18 Error Handling | Every script uses `set -euo pipefail` + `die`; Task 16 uploads `xcresult` and `body.md` artifacts |
| §19 Local Reproduction | Each task's smoke-test step demonstrates standalone invocation |
| §20 Maintainer Workflow | Task 17 Step 10 documents it |
| §21 Risks | Validation gates (Task 6) + `xcresult` upload (Task 16) + keychain cleanup (Task 16 + Task 7 cleanup arg) + idempotent appcast (Task 15) |
| §22 Non-Requirements | Plan stays within scope |
| §23 Resolved Decisions | Encoded in Tasks 1, 14, 15, 16 |
