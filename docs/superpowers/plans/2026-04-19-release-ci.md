# Release CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automate signed + notarized + stapled LyricsX release artifact production, and publish them as draft GitHub Releases with bilingual release notes and dSYM bundles.

**Architecture:** A single GitHub Actions workflow (`.github/workflows/release.yml`) orchestrates nine independently-runnable shell scripts under `Scripts/release/`. Sparkle EdDSA signing and `appcast.xml` updates remain manual local steps. One Xcode build phase is patched so its build-number auto-increment can be skipped in CI.

**Tech Stack:** GitHub Actions, bash, Apple CLI tools (`security`, `xcodebuild`, `xcrun notarytool`, `xcrun stapler`, `ditto`, `PlistBuddy`), `gh` CLI.

**Design Spec:** `docs/superpowers/specs/2026-04-19-release-ci-design.md`

**Testing Note:** Shell scripts are smoke-tested locally via direct invocation after each task. The complete workflow is validated end-to-end with a `dry_run=true` dispatch at the end of Task 13 (does not create a Release).

---

## File Structure

### Created

- `Scripts/release/lib.sh` — shared helpers (logging, `require_env`, version regex)
- `Scripts/release/resolve-version.sh` — tag/input → `VERSION`, `IS_PRERELEASE`
- `Scripts/release/validate.sh` — consistency gate (plist, ReleaseNotes, release exists)
- `Scripts/release/setup-keychain.sh` — temp keychain + Developer ID import
- `Scripts/release/build.sh` — `xcodebuild archive` + `-exportArchive`
- `Scripts/release/notarize.sh` — `notarytool submit --wait` + `stapler staple`
- `Scripts/release/package.sh` — app zip + dSYMs zip
- `Scripts/release/compose-notes.sh` — bilingual ReleaseNotes → `body.md`
- `Scripts/release/create-release.sh` — `gh release create --draft`
- `.github/workflows/release.yml` — the workflow itself

### Modified

- `LyricsX.xcodeproj/project.pbxproj` — Bump Build phase guarded by `LYRICSX_SKIP_BUILD_BUMP`
- `.gitignore` — add `build/` (scripts write intermediate artifacts there)

---

## Task 1: Guard the Bump-Build Build Phase

**Files:**
- Modify: `LyricsX.xcodeproj/project.pbxproj:794`

**Context:** The existing `PBXShellScriptBuildPhase` named "Bump Build" (id `BBC1D5811E4AFE64008869EC`) unconditionally increments `CFBundleVersion` every time Xcode builds. CI will set `LYRICSX_SKIP_BUILD_BUMP=1` to disable it so the build number read by `validate.sh` matches what ends up inside `.app`.

- [ ] **Step 1: Patch the shellScript string**

Open `LyricsX.xcodeproj/project.pbxproj`, locate the line that starts with `shellScript = "buildNumber=$(/usr/libexec/PlistBuddy -c \"Print CFBundleVersion\"` (around line 794). Replace that one line with exactly:

```
			shellScript = "if [ \"${LYRICSX_SKIP_BUILD_BUMP:-0}\" = \"1\" ]; then\n    echo \"Skipping CFBundleVersion bump (LYRICSX_SKIP_BUILD_BUMP=1)\"\n    exit 0\nfi\nbuildNumber=$(/usr/libexec/PlistBuddy -c \"Print CFBundleVersion\" \"${PROJECT_DIR}/${INFOPLIST_FILE}\")\nbuildNumber=$(($buildNumber + 1))\n/usr/libexec/PlistBuddy -c \"Set :CFBundleVersion $buildNumber\" \"${PROJECT_DIR}/${INFOPLIST_FILE}\"\n# Sync widget extension build number\nWIDGET_PLIST=\"${PROJECT_DIR}/LyricsXWidget/Info.plist\"\nif [ -f \"$WIDGET_PLIST\" ]; then\n    /usr/libexec/PlistBuddy -c \"Set :CFBundleVersion $buildNumber\" \"$WIDGET_PLIST\"\nfi\n";
```

- [ ] **Step 2: Verify the patched script parses**

Run:

```bash
plutil -lint LyricsX.xcodeproj/project.pbxproj
```

Expected: `LyricsX.xcodeproj/project.pbxproj: OK`

- [ ] **Step 3: Verify CI-mode skip works (no build-number change)**

Capture the current `CFBundleVersion`, then do a Release build with the skip flag and confirm it does NOT change:

```bash
BEFORE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "LyricsX/Supporting Files/Info.plist")
echo "Before: $BEFORE"

LYRICSX_SKIP_BUILD_BUMP=1 xcodebuild \
  -project LyricsX.xcodeproj \
  -scheme LyricsX \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -20

AFTER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "LyricsX/Supporting Files/Info.plist")
echo "After:  $AFTER"

if [ "$BEFORE" = "$AFTER" ]; then
  echo "OK: build number unchanged ($BEFORE)"
else
  echo "FAIL: build number changed ($BEFORE -> $AFTER)"
  exit 1
fi
```

Expected: `OK: build number unchanged (<N>)`.

- [ ] **Step 4: Commit**

```bash
git add LyricsX.xcodeproj/project.pbxproj
git commit -m "build: guard Bump Build phase with LYRICSX_SKIP_BUILD_BUMP"
```

---

## Task 2: Ignore the CI Build Output Directory

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Append `build/` to `.gitignore`**

Edit `.gitignore` and add the line `build/` after the existing `Product` line. Final file should read:

```
Product
build/
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
git commit -m "chore: ignore build/ (used by release scripts)"
```

---

## Task 3: Scaffold `Scripts/release/lib.sh`

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
if validate_version_format "bad-value" 2>/dev/null; then
  echo "FAIL: should have rejected bad-value"
  exit 1
fi
if is_prerelease_version 1.9.0; then echo "FAIL: 1.9.0 should not be prerelease"; exit 1; fi
if ! is_prerelease_version 1.9.0-beta.1; then echo "FAIL: 1.9.0-beta.1 should be prerelease"; exit 1; fi
echo OK
' 2>&1
```

Expected last line: `OK`.

- [ ] **Step 5: Commit**

```bash
git add Scripts/release/lib.sh
git commit -m "build(release): add shared shell helpers"
```

---

## Task 4: `Scripts/release/resolve-version.sh`

**Files:**
- Create: `Scripts/release/resolve-version.sh`

**Responsibility:** Given either `GITHUB_REF_NAME` (for tag push) or `INPUT_VERSION` (for `workflow_dispatch`), produce `VERSION` and `IS_PRERELEASE` and append them to `$GITHUB_ENV` if set, otherwise print to stdout.

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
#   and always prints them to stdout in the same KEY=VALUE form.

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
# stdout should contain: VERSION=1.9.0 and IS_PRERELEASE=false

GITHUB_EVENT_NAME=push GITHUB_REF_NAME=v1.9.0-beta.1 bash Scripts/release/resolve-version.sh
# stdout: VERSION=1.9.0-beta.1 IS_PRERELEASE=true

GITHUB_EVENT_NAME=workflow_dispatch INPUT_VERSION=1.9.0-rc.2 bash Scripts/release/resolve-version.sh
# stdout: VERSION=1.9.0-rc.2 IS_PRERELEASE=true

if GITHUB_EVENT_NAME=push GITHUB_REF_NAME=master \
   bash Scripts/release/resolve-version.sh 2>/dev/null; then
  echo "FAIL: should have rejected non-v ref"
  exit 1
fi
echo OK
```

Expected last line: `OK`.

- [ ] **Step 4: Commit**

```bash
git add Scripts/release/resolve-version.sh
git commit -m "build(release): add resolve-version.sh"
```

---

## Task 5: `Scripts/release/validate.sh`

**Files:**
- Create: `Scripts/release/validate.sh`

**Responsibility:** Enforce all consistency checks from design spec §8.

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
#   SKIP_RELEASE_EXISTS_CHECK  (optional) "1" to skip gh-release check (useful locally without gh auth)
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

- [ ] **Step 3: Smoke-test against the current `Info.plist`**

Read the current plist version, and run validate against it (you need a release-notes file for that version to exist — create a dummy if missing). Then run with an intentionally-wrong version and confirm it fails:

```bash
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "LyricsX/Supporting Files/Info.plist")
echo "Current plist version: $CURRENT_VERSION"

# Ensure dummy ReleaseNotes exist for the current version
mkdir -p ReleaseNotes
[ -f "ReleaseNotes/${CURRENT_VERSION}_en.md" ] || printf '# %s\n\n- test\n' "$CURRENT_VERSION" > "ReleaseNotes/${CURRENT_VERSION}_en.md"
[ -f "ReleaseNotes/${CURRENT_VERSION}_zh.md" ] || printf '# %s\n\n- 测试\n' "$CURRENT_VERSION" > "ReleaseNotes/${CURRENT_VERSION}_zh.md"

# Happy path (skip the gh release-exists check locally)
SKIP_RELEASE_EXISTS_CHECK=1 \
VERSION="$CURRENT_VERSION" IS_PRERELEASE=false GITHUB_EVENT_NAME=workflow_dispatch \
  bash Scripts/release/validate.sh

# Wrong version should fail
if SKIP_RELEASE_EXISTS_CHECK=1 \
   VERSION=99.99.99 IS_PRERELEASE=false GITHUB_EVENT_NAME=workflow_dispatch \
   bash Scripts/release/validate.sh 2>/dev/null; then
  echo "FAIL: 99.99.99 should have failed (wrong shortVersion)"
  exit 1
fi

echo OK
```

Expected last line: `OK`.

- [ ] **Step 4: Remove any dummy release notes that you don't want to ship**

```bash
git status ReleaseNotes
# If any of the ReleaseNotes/*.md files were dummies you created in Step 3,
# delete them now so they don't get committed.
```

- [ ] **Step 5: Commit**

```bash
git add Scripts/release/validate.sh
git commit -m "build(release): add validate.sh consistency gate"
```

---

## Task 6: `Scripts/release/setup-keychain.sh`

**Files:**
- Create: `Scripts/release/setup-keychain.sh`

**Responsibility:** Create a temporary keychain, import the Developer ID Application `.p12`, and add it to the search list so `xcodebuild` can find the identity. Works only on macOS.

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

# If a stale temp keychain exists, delete it first (idempotent).
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

# Allow codesign to use the key without UI prompt
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" >/dev/null

# Add to the default search list while keeping the login keychain too
ORIGINAL_LIST=$(security list-keychains -d user | tr -d '"' | tr -d ' ')
security list-keychains -d user -s "$KEYCHAIN_PATH" $ORIGINAL_LIST

log_info "Installed identities:"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/setup-keychain.sh
```

- [ ] **Step 3: Smoke test "missing env" failure path**

With no env vars set, the script must fail fast. Run:

```bash
if bash Scripts/release/setup-keychain.sh 2>/dev/null; then
  echo "FAIL: should have errored on missing env"; exit 1
fi
echo OK
```

Expected: `OK`.

(Full happy path requires a real certificate and is deferred to Task 13 CI validation.)

- [ ] **Step 4: Commit**

```bash
git add Scripts/release/setup-keychain.sh
git commit -m "build(release): add setup-keychain.sh"
```

---

## Task 7: `Scripts/release/build.sh`

**Files:**
- Create: `Scripts/release/build.sh`

**Responsibility:** Archive and export a signed `.app` using the Developer ID Application certificate that `setup-keychain.sh` installed. Overrides automatic signing on the command line so Xcode doesn't try to log in to an Apple ID.

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

## Task 8: `Scripts/release/notarize.sh`

**Files:**
- Create: `Scripts/release/notarize.sh`

**Responsibility:** Submit the built `.app` to Apple's notary service using App Store Connect API Key auth, wait for the result, and staple the ticket.

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

## Task 9: `Scripts/release/package.sh`

**Files:**
- Create: `Scripts/release/package.sh`

**Responsibility:** Produce the two final zip artifacts that will be attached to the GitHub Release.

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

- [ ] **Step 3: Smoke test the missing-prereq failure path**

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

## Task 10: `Scripts/release/compose-notes.sh`

**Files:**
- Create: `Scripts/release/compose-notes.sh`

**Responsibility:** Join `ReleaseNotes/<VERSION>_en.md` and `_zh.md` into `build/body.md` using format 1 (plain `---` separator).

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
    # Always emit a blank line before the separator. If the English file
    # already ends with a newline, the extra blank line is harmless in Markdown.
    printf '\n\n---\n\n'
    cat "$ZH"
} > "$OUT"

log_info "Wrote ${OUT} ($(wc -l < "$OUT" | tr -d ' ') lines)"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/release/compose-notes.sh
```

- [ ] **Step 3: Smoke-test against the existing `1.8.0` notes**

```bash
VERSION=1.8.0 bash Scripts/release/compose-notes.sh
head -5 build/body.md
echo "---"
grep -c '^---$' build/body.md
```

Expected: the `grep -c '^---$'` count is `1`, and `head -5` shows the English block starting.

- [ ] **Step 4: Commit**

```bash
git add Scripts/release/compose-notes.sh
git commit -m "build(release): add compose-notes.sh"
```

---

## Task 11: `Scripts/release/create-release.sh`

**Files:**
- Create: `Scripts/release/create-release.sh`

**Responsibility:** Create a draft GitHub Release with both zip assets. Sets the `--prerelease` flag when `IS_PRERELEASE=true`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Create a draft GitHub Release and upload both artifact zips.
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

FLAGS=(--draft)
if [ "$IS_PRERELEASE" = "true" ]; then
    FLAGS+=(--prerelease)
fi
if [ -n "${GITHUB_SHA:-}" ]; then
    FLAGS+=(--target "$GITHUB_SHA")
fi

log_info "Creating draft release v${VERSION} (prerelease=${IS_PRERELEASE})"
gh release create "v${VERSION}" \
    "${FLAGS[@]}" \
    --title "LyricsX ${VERSION}" \
    --notes-file "$BODY" \
    "$APP_ZIP" \
    "$DSYMS_ZIP"

log_info "Draft release ready. Review and publish manually after Sparkle signing."
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
git commit -m "build(release): add create-release.sh"
```

---

## Task 12: The Workflow File

**Files:**
- Create: `.github/workflows/release.yml`

**Responsibility:** Glue all scripts together, inject secrets, and expose both triggers and the `dry_run` input.

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
        description: 'Stop after build (no notarize, no release)'
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
        run: bash Scripts/release/validate.sh

      - name: Setup keychain
        env:
          APPLE_DEV_ID_CERT_P12_BASE64: ${{ secrets.APPLE_DEV_ID_CERT_P12_BASE64 }}
          APPLE_DEV_ID_CERT_PASSWORD: ${{ secrets.APPLE_DEV_ID_CERT_PASSWORD }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: bash Scripts/release/setup-keychain.sh

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

      - name: Compose release notes
        if: ${{ !inputs.dry_run }}
        run: bash Scripts/release/compose-notes.sh

      - name: Create draft release
        if: ${{ !inputs.dry_run }}
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: bash Scripts/release/create-release.sh

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
git commit -m "ci: add release workflow"
```

---

## Task 13: Configure Secrets and Validate End-to-End

**Files:** None — this task runs entirely on GitHub and produces no local diff.

- [ ] **Step 1: Generate a keychain password for the CI runner**

```bash
openssl rand -hex 24
```

Copy the output — you'll paste it into `KEYCHAIN_PASSWORD` in Step 3.

- [ ] **Step 2: Prepare the base64-encoded certificates and API key**

```bash
# Developer ID Application .p12 (you exported this from Keychain Access)
base64 -i /path/to/developer-id.p12 | pbcopy
# paste into APPLE_DEV_ID_CERT_P12_BASE64

# App Store Connect API key .p8 (downloaded from App Store Connect)
base64 -i /path/to/AuthKey_XXXXXXXXXX.p8 | pbcopy
# paste into APPLE_API_KEY_P8_BASE64
```

- [ ] **Step 3: Add all six secrets in GitHub**

Visit `https://github.com/MxIris-LyricsX-Project/LyricsX/settings/secrets/actions` and create:

| Name | Value |
|---|---|
| `APPLE_DEV_ID_CERT_P12_BASE64` | output of `base64 -i developer-id.p12` |
| `APPLE_DEV_ID_CERT_PASSWORD` | password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | output from Step 1 |
| `APPLE_API_KEY_P8_BASE64` | output of `base64 -i AuthKey_*.p8` |
| `APPLE_API_KEY_ID` | 10-char Key ID from App Store Connect |
| `APPLE_API_KEY_ISSUER_ID` | Issuer UUID from App Store Connect |

- [ ] **Step 4: Push the branch and trigger a `dry_run`**

```bash
git push origin HEAD
```

Then on GitHub → Actions → **Release** workflow → **Run workflow** dropdown:
- Branch: the branch you just pushed
- `version`: current `CFBundleShortVersionString` (e.g. `1.9.0`)
- `dry_run`: `true`

Make sure ReleaseNotes for that version exist (or create temporary ones you'll remove after).

- [ ] **Step 5: Inspect the run**

Expected outcome:
- Steps run through **Build**, then all later steps (Notarize, Package, Compose, Create release) are skipped with a green "skipped" marker.
- **Cleanup keychain** runs.
- No GitHub Release is created.
- If Build fails, download the `xcresult` artifact from the run summary to inspect.

- [ ] **Step 6: First real release test**

Bump `CFBundleShortVersionString` in `Info.plist` to something safely unused (e.g. `0.0.1-ci-test`), write `ReleaseNotes/0.0.1-ci-test_en.md` and `_zh.md` stubs, commit, push, and dispatch again without `dry_run`.

Verify:
- A **draft** release `v0.0.1-ci-test` appears on GitHub Releases
- It is marked as `Pre-release`
- Both `LyricsX_0.0.1-ci-test+<BUILD>.zip` and `LyricsX_0.0.1-ci-test+<BUILD>.dSYMs.zip` are attached
- The release body contains both English and Chinese notes separated by `---`

Delete the draft release and revert the test version bump commit once satisfied.

- [ ] **Step 7: Document release procedure**

Verify that when you next want to ship:
1. Bump `CFBundleShortVersionString` in `Info.plist`, commit.
2. Write `ReleaseNotes/<version>_en.md` and `_zh.md`, commit.
3. Push a tag: `git tag v<version> && git push origin v<version>`.
4. Wait for the workflow; a draft release appears.
5. Download the app zip; run `sign_update` locally; update `appcast.xml`; commit and push.
6. On GitHub, click **Publish release** on the draft.

---

## Spec Coverage Check

| Spec section | Task |
|---|---|
| §2 In scope / out of scope | Whole plan honors boundaries (no Sparkle, no appcast) |
| §3 Inputs and Triggers | Task 12 workflow + Task 4 `resolve-version.sh` |
| §4 File Layout | Tasks 3–12 (one file each) |
| §5 Xcode Build Phase Edit | Task 1 |
| §6 Secrets | Task 13 steps 1–3 |
| §7 Workflow Steps | Task 12 |
| §8 Validation Rules | Task 5 `validate.sh` |
| §9 Release Notes Composition | Task 10 `compose-notes.sh` |
| §10 Build Step Details | Task 7 `build.sh` |
| §11 Notarization Details | Task 8 `notarize.sh` |
| §12 Packaging Details | Task 9 `package.sh` |
| §13 Release Creation Details | Task 11 `create-release.sh` |
| §14 Error Handling | Every script uses `set -euo pipefail` + `die`; Task 12 uploads `xcresult` and `body.md` artifacts |
| §15 Local Reproduction | Each task's Step 3 demonstrates standalone invocation |
| §16 Post-Release Manual Steps | Task 13 Step 7 documents it |
| §17 Non-Requirements | Plan stays within scope |
| §18 Risks | Validation gates (Task 5) + `xcresult` upload (Task 12) + keychain cleanup (Task 12 + Task 6 cleanup arg) |
