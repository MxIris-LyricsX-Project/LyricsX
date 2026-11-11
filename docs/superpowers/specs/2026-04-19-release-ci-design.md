# Release CI Design

- **Date:** 2026-04-19
- **Owner:** Mx-Iris
- **Status:** Draft (awaiting user review)

## 1. Goal

Automate the production of signed, notarized, stapled LyricsX release
artifacts and publish them as GitHub Releases (draft) with bilingual
release notes and dSYM bundles. Sparkle EdDSA signing and
`appcast.xml` updates remain a manual local step performed by the
maintainer.

## 2. Scope

### In scope

- A single GitHub Actions workflow at `.github/workflows/release.yml`.
- A set of shell scripts under `Scripts/release/` that implement each
  stage of the pipeline and are usable both in CI and locally.
- A small edit to the Xcode build phase that currently bumps
  `CFBundleVersion`, so it can be skipped in CI via an environment
  variable.

### Out of scope

- Sparkle EdDSA signing (done locally by the maintainer after the
  draft release is produced).
- Updating `appcast.xml` (done locally).
- Publishing the draft release (done locally once Sparkle signing and
  appcast update are committed).
- Automated tag creation (tags are pushed manually).
- Bumping the build number in CI (CI consumes whatever value is in
  `Info.plist`).
- DMG packaging (zip only).

## 3. Inputs and Triggers

Two triggers:

1. `push` on tags matching `v*`.
2. `workflow_dispatch` with inputs:
   - `version` (string, required): e.g. `1.9.0` or `1.9.0-beta.1`.
   - `dry_run` (boolean, default `false`): when `true`, the workflow
     stops after the `build` step and does not notarize, package, or
     create a release. Used to validate secrets / certificate setup.

### Version contract

- A version string matches
  `^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$`.
- A version with a `-<suffix>` portion is treated as a **prerelease**
  (`IS_PRERELEASE=true`).
- `Info.plist` `CFBundleShortVersionString` must exactly match the
  requested version, including any `-<suffix>` (prerelease builds
  carry the full version string in `Info.plist`).
- Artifact file name format:
  `LyricsX_<VERSION>+<BUILD>.zip` (e.g.
  `LyricsX_1.9.0-beta.1+2930.zip`).

## 4. File Layout

```text
.github/
  workflows/
    release.yml

Scripts/
  release/
    lib.sh                # shared helpers: logging, require_env, version regex
    resolve-version.sh    # tag or input -> VERSION, IS_PRERELEASE
    validate.sh           # VERSION <-> Info.plist <-> ReleaseNotes consistency
    setup-keychain.sh     # create temp keychain, import Developer ID .p12
    build.sh              # xcodebuild archive + exportArchive
    notarize.sh           # ditto to zip, notarytool submit --wait, stapler staple
    package.sh            # produce app zip + dSYMs zip
    compose-notes.sh      # join en + zh ReleaseNotes into body.md
    create-release.sh     # gh release create --draft [--prerelease]
```

## 5. Xcode Build Phase Edit

The existing `PBXShellScriptBuildPhase` in
`LyricsX.xcodeproj/project.pbxproj` that increments `CFBundleVersion`
is updated so it can be skipped:

```bash
if [ "${LYRICSX_SKIP_BUILD_BUMP:-0}" = "1" ]; then
    echo "Skipping CFBundleVersion bump (LYRICSX_SKIP_BUILD_BUMP=1)"
    exit 0
fi

buildNumber=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "${PROJECT_DIR}/${INFOPLIST_FILE}")
buildNumber=$(($buildNumber + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $buildNumber" "${PROJECT_DIR}/${INFOPLIST_FILE}"

WIDGET_PLIST="${PROJECT_DIR}/LyricsXWidget/Info.plist"
if [ -f "$WIDGET_PLIST" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $buildNumber" "$WIDGET_PLIST"
fi
```

The workflow declares `LYRICSX_SKIP_BUILD_BUMP: "1"` at the job level,
so in CI the build number read from `Info.plist` is stable across all
steps and matches what gets embedded into the produced `.app`.

## 6. Secrets

Configured in GitHub Settings → Secrets and variables → Actions:

| Secret | Purpose |
|---|---|
| `APPLE_DEV_ID_CERT_P12_BASE64` | Developer ID Application certificate (incl. private key), base64-encoded `.p12` |
| `APPLE_DEV_ID_CERT_PASSWORD` | Password for the `.p12` above |
| `KEYCHAIN_PASSWORD` | Password for the temporary keychain created in CI |
| `APPLE_API_KEY_P8_BASE64` | App Store Connect API Key, base64-encoded `.p8` |
| `APPLE_API_KEY_ID` | 10-character Key ID from App Store Connect |
| `APPLE_API_KEY_ISSUER_ID` | Issuer UUID from App Store Connect |

`GITHUB_TOKEN` is auto-injected by GitHub Actions; the workflow
declares `permissions: contents: write` so `gh release create` works.

## 7. Workflow Steps

Single job, `runs-on: macos-26`, job-level `env` includes
`LYRICSX_SKIP_BUILD_BUMP: "1"` and `LYRICSX_USE_LOCAL_DEPENDENCY: "0"`.

| # | Step | Script / Action | Purpose |
|---|---|---|---|
| 1 | Checkout | `actions/checkout@v4` with `fetch-depth: 0` | Full history so `gh` can resolve the tag |
| 2 | Resolve version | `Scripts/release/resolve-version.sh` | Derive `VERSION`, `IS_PRERELEASE` from `github.ref_name` or `inputs.version`, write to `$GITHUB_ENV` |
| 3 | Validate | `Scripts/release/validate.sh` | Enforce consistency; write `BUILD` and `ARTIFACT_NAME` to `$GITHUB_ENV` |
| 4 | Setup keychain | `Scripts/release/setup-keychain.sh` | Create temp keychain, import p12, `set-key-partition-list`, add to search list |
| 5 | Build | `Scripts/release/build.sh` | `xcodebuild archive` + `exportArchive` using `ExportOptions.plist` |
| 6 | Notarize | `Scripts/release/notarize.sh` | `ditto` to submission zip, `notarytool submit --wait`, `stapler staple LyricsX.app` |
| 7 | Package | `Scripts/release/package.sh` | Produce `LyricsX_<VERSION>+<BUILD>.zip` and `LyricsX_<VERSION>+<BUILD>.dSYMs.zip` |
| 8 | Compose notes | `Scripts/release/compose-notes.sh` | Read `ReleaseNotes/<VERSION>_en.md` + `_zh.md`, join as `body.md` (format 1, see §9) |
| 9 | Create release | `Scripts/release/create-release.sh` | `gh release create v<VERSION> --draft [--prerelease] --notes-file body.md` uploads both zip assets |
| 10 | Cleanup keychain | always()-guarded step | Delete temp keychain regardless of success/failure |

When `dry_run=true`, steps 6-10 are skipped (the workflow stops after
step 5).

## 8. Validation Rules (`validate.sh`)

Executed in order. Any failure exits with code 1 and a specific error
message before the expensive build starts.

| # | Check | Failure message |
|---|---|---|
| 1 | `VERSION` matches `^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$` | `Invalid version format: '<VERSION>'. Expected e.g. 1.9.0 or 1.9.0-beta.1` |
| 2 | `ReleaseNotes/<VERSION>_en.md` exists | `Missing release notes: ReleaseNotes/<VERSION>_en.md. Write it before releasing.` |
| 3 | `ReleaseNotes/<VERSION>_zh.md` exists | `Missing release notes: ReleaseNotes/<VERSION>_zh.md. Write it before releasing.` |
| 4 | `LyricsX/Supporting Files/Info.plist` `CFBundleShortVersionString` equals `<VERSION>` | `Info.plist CFBundleShortVersionString ('<plist>') doesn't match version ('<VERSION>'). Bump Info.plist and commit first.` |
| 5 | `CFBundleVersion` is a positive integer | `Info.plist CFBundleVersion ('<build>') is not a positive integer.` |
| 6 | Tag trigger only: `git tag -l "v<VERSION>"` is non-empty | `Tag v<VERSION> not found. Did the push fail?` |
| 7 | Both triggers: `gh release view v<VERSION>` must fail (release does not exist yet) | `Release v<VERSION> already exists. Bump version first or delete the existing draft.` |

Outputs written to `$GITHUB_ENV`:

- `VERSION`
- `BUILD`
- `IS_PRERELEASE` (`true` / `false`)
- `ARTIFACT_NAME=LyricsX_<VERSION>+<BUILD>.zip`

## 9. Release Notes Composition (`compose-notes.sh`)

Format 1 (plain separator):

```text
<content of ReleaseNotes/<VERSION>_en.md>

---

<content of ReleaseNotes/<VERSION>_zh.md>
```

Script also ensures a trailing newline on the English block so the
separator renders correctly on GitHub.

## 10. Build Step Details (`build.sh`)

- Working directory: repo root.
- Commands:
  ```bash
  xcodebuild \
    -project LyricsX.xcodeproj \
    -scheme LyricsX \
    -configuration Release \
    -archivePath build/LyricsX.xcarchive \
    -destination 'generic/platform=macOS' \
    archive

  xcodebuild \
    -exportArchive \
    -archivePath build/LyricsX.xcarchive \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath build/Export
  ```
- Env:
  - `LYRICSX_SKIP_BUILD_BUMP=1` (skip the Xcode build phase's plist bump)
  - `LYRICSX_USE_LOCAL_DEPENDENCY=0` (force `LyricsKit` / `MusicPlayer` SPM dependencies to remote)
- Produces:
  - `build/LyricsX.xcarchive` (holds app + dSYMs)
  - `build/Export/LyricsX.app` (signed with Developer ID Application)
- On failure, the `.xcresult` bundle is uploaded as a GitHub Actions
  run artifact for download.

## 11. Notarization Details (`notarize.sh`)

1. Decode `APPLE_API_KEY_P8_BASE64` to a temp file.
2. Create a notarization submission zip:
   ```bash
   ditto -c -k --keepParent build/Export/LyricsX.app build/LyricsX.notarize.zip
   ```
3. Submit and wait:
   ```bash
   xcrun notarytool submit build/LyricsX.notarize.zip \
     --key "$API_KEY_PATH" \
     --key-id "$APPLE_API_KEY_ID" \
     --issuer "$APPLE_API_KEY_ISSUER_ID" \
     --wait \
     --output-format json
   ```
4. If status is not `Accepted`, call
   `xcrun notarytool log <submission-id>` and exit 1.
5. Staple the ticket:
   ```bash
   xcrun stapler staple build/Export/LyricsX.app
   ```

The `.p8` file is deleted at script exit via a `trap`.

## 12. Packaging Details (`package.sh`)

```bash
ditto -c -k --sequesterRsrc --keepParent \
  build/Export/LyricsX.app \
  "build/LyricsX_${VERSION}+${BUILD}.zip"

ditto -c -k --sequesterRsrc --keepParent \
  build/LyricsX.xcarchive/dSYMs \
  "build/LyricsX_${VERSION}+${BUILD}.dSYMs.zip"
```

Both zips are attached to the GitHub Release.

## 13. Release Creation Details (`create-release.sh`)

```bash
flags=(--draft)
if [ "$IS_PRERELEASE" = "true" ]; then
  flags+=(--prerelease)
fi

gh release create "v${VERSION}" \
  "${flags[@]}" \
  --title "LyricsX ${VERSION}" \
  --notes-file build/body.md \
  --target "$GITHUB_SHA" \
  "build/LyricsX_${VERSION}+${BUILD}.zip" \
  "build/LyricsX_${VERSION}+${BUILD}.dSYMs.zip"
```

## 14. Error Handling

- All scripts start with `set -euo pipefail`.
- `lib.sh` exposes `log_info`, `log_warn`, `log_error`, `require_env`
  helpers.
- Errors print the specific missing file / mismatched value / failing
  command before exiting; CI logs are the sole observability surface.
- `xcresult` bundles and `body.md` are uploaded as workflow artifacts
  (7-day retention) for post-mortem.
- Notarization rejections dump the full `notarytool log` JSON to CI
  logs.
- The temp keychain is always deleted via a cleanup step guarded by
  `if: always()`.

## 15. Local Reproduction

Every script can be invoked standalone from the repo root, given the
same env vars the workflow supplies:

```bash
VERSION=1.9.0-beta.1 bash Scripts/release/validate.sh

VERSION=1.9.0-beta.1 BUILD=2930 bash Scripts/release/package.sh

VERSION=1.9.0-beta.1 BUILD=2930 IS_PRERELEASE=true \
  bash Scripts/release/create-release.sh
```

This enables the maintainer to rerun a failed stage locally without
repeating the full workflow.

## 16. Post-Release Manual Steps (Maintainer)

Once the draft release exists:

1. Download `LyricsX_<VERSION>+<BUILD>.zip` from the draft release.
2. Run Sparkle's `sign_update` locally to produce the EdDSA signature.
3. Edit `appcast.xml` to add the new `<item>` with the signature,
   version, build, and enclosure URL.
4. Commit `appcast.xml` (and push to whichever branch hosts the
   appcast).
5. Click **Publish release** on GitHub to flip the draft to public.

## 17. Non-Requirements (YAGNI)

- No `shellcheck` CI step.
- No multi-job parallelism.
- No Slack / email notifications (Actions email on failure is enough).
- No automated tagging.
- No build-number bump in CI.
- No touching `appcast.xml`.
- No DMG packaging.

## 18. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Expired or revoked Developer ID certificate | Rotate `.p12`; `setup-keychain.sh` fails fast with `security` return code |
| Notarization regression (new Apple rules) | `notarize.sh` prints the full `notarytool log` JSON on rejection |
| Tag version drifts from `Info.plist` | `validate.sh` check #4 blocks the build |
| Missing release notes for a hotfix | `validate.sh` checks #2 and #3 block the build |
| API key leak in logs | `set +x` kept off; API key file is decoded only to a scratch path and deleted via `trap` |
| dSYM bundle not produced (Xcode config regressions) | `package.sh` fails if `build/LyricsX.xcarchive/dSYMs` is empty or missing |
