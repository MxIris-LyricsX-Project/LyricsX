# Release CI with Full Sparkle Automation — Design

- **Date:** 2026-05-05
- **Owner:** Mx-Iris
- **Status:** Draft (awaiting user review)
- **Supersedes (in scope of Sparkle automation):** `2026-04-19-release-ci-design.md`

## 1. Goal

Fully automate the LyricsX release pipeline end to end:

1. Build, sign (Developer ID), notarize, staple, and package the app.
2. Sign the release zip with the Sparkle EdDSA private key.
3. Publish a GitHub Release (not draft) carrying the app zip and the dSYMs zip.
4. Insert a new `<item>` into the canonical `appcast.xml` (LyricsX repo root) and
   commit + push.
5. Mirror the same `<item>` into the legacy organization Pages repo
   `MxIris-LyricsX-Project/MxIris-LyricsX-Project.github.io` so already-installed
   clients (`<= 1.8.1`) keep receiving updates during the transition window.

The maintainer's only manual responsibilities are: bumping `CFBundleShortVersionString`,
writing bilingual release notes, and pushing a `v*` tag.

## 2. Scope

### In scope

- A single GitHub Actions workflow at `.github/workflows/release.yml`.
- Shell scripts under `Scripts/release/` that implement each stage of the pipeline,
  usable both in CI and locally.
- An edit to the Xcode "Bump Build" build phase so its auto-increment can be
  skipped via `LYRICSX_SKIP_BUILD_BUMP=1` in CI.
- A migration of the canonical Sparkle feed from
  `https://mxiris-lyricsx-project.github.io/appcast.xml` (organization Pages repo)
  to `https://mxiris-lyricsx-project.github.io/LyricsX/appcast.xml`
  (LyricsX repo Pages).
- A transitional mirror that keeps the legacy URL up to date until the maintainer
  decides to retire it (planned around the 2.0.0 milestone).

### Out of scope

- Automated tag creation (the maintainer pushes tags by hand).
- Automated build-number bumping in CI (CI consumes whatever value is in
  `Info.plist`).
- DMG packaging (zip only).
- Sparkle channel support (beta channels in `appcast.xml`). Pre-release tags
  produce a published `--prerelease` GitHub Release but are **not** written
  into `appcast.xml`.
- Automated retirement of the legacy mirror — that is a one-line manual
  edit to `release.yml` when the maintainer decides the time has come.

## 3. Inputs and Triggers

Two triggers:

1. `push` on tags matching `v*`.
2. `workflow_dispatch` with inputs:
   - `version` (string, required): e.g. `1.9.0` or `1.9.0-beta.1`.
   - `dry_run` (boolean, default `false`): when `true`, the workflow stops
     after the `build` step.

### Version contract

- A version string matches `^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$`.
- A version with a `-<suffix>` portion is a **prerelease** (`IS_PRERELEASE=true`).
- `Info.plist` `CFBundleShortVersionString` must exactly match the requested
  version, including any `-<suffix>`.
- Artifact name format: `LyricsX_<VERSION>+<BUILD>.zip`,
  e.g. `LyricsX_1.9.0-beta.1+2930.zip`.

## 4. File Layout

```text
.github/
  workflows/
    release.yml

Scripts/
  release/
    lib.sh                    # shared helpers: logging, require_env, version regex
    resolve-version.sh        # tag or input -> VERSION, IS_PRERELEASE
    validate.sh               # VERSION <-> Info.plist <-> ReleaseNotes consistency
    setup-keychain.sh         # create temp keychain, import Developer ID .p12
    install-sparkle-tools.sh  # download pinned Sparkle release, extract bin/sign_update
    build.sh                  # xcodebuild archive + exportArchive
    notarize.sh               # ditto to zip, notarytool submit --wait, stapler staple
    package.sh                # produce app zip + dSYMs zip
    sign-sparkle.sh           # run sign_update, capture ED_SIGNATURE + ZIP_LENGTH
    compose-notes.sh          # join en + zh ReleaseNotes into body.md
    create-release.sh         # gh release create (published; --prerelease for beta)
    update-appcast.py         # insert new <item> into a target appcast.xml (Python, stdlib only)
    publish-appcast.sh        # wraps update-appcast.py + git commit/push for canonical and mirror modes
```

## 5. Sparkle Feed Migration (one-time, performed in the same PR as this work)

1. Replace LyricsX repo root `appcast.xml` with the current contents of
   `https://mxiris-lyricsx-project.github.io/appcast.xml` so the new canonical
   feed has all historical items (1.7.3 through 1.8.1) as its baseline.
2. Edit `LyricsX/Supporting Files/Info.plist`:
   - `SUFeedURL` → `https://mxiris-lyricsx-project.github.io/LyricsX/appcast.xml`
3. Delete `.github/workflows/update-gh-pages.yml` (had no effect on the
   organization Pages repo and is now obsolete).

After 1.9.0 ships:

- LyricsX 1.9.0+ clients read the new URL (LyricsX repo Pages).
- LyricsX `<= 1.8.1` clients keep reading the old URL; the CI mirror keeps that
  feed current.

## 6. Xcode Build Phase Edit

The existing `PBXShellScriptBuildPhase` ("Bump Build") in
`LyricsX.xcodeproj/project.pbxproj` is wrapped so it can be skipped by env var:

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

The workflow declares `LYRICSX_SKIP_BUILD_BUMP: "1"` at job level so the build
number read by `validate.sh` matches what gets embedded into the produced `.app`.

## 7. Secrets

Configured in GitHub Settings → Secrets and variables → Actions of the
**LyricsX** repo:

| Secret | Purpose |
|---|---|
| `APPLE_DEV_ID_CERT_P12_BASE64` | Developer ID Application certificate (incl. private key), base64-encoded `.p12` |
| `APPLE_DEV_ID_CERT_PASSWORD` | Password for the `.p12` above |
| `KEYCHAIN_PASSWORD` | Password for the temporary keychain created in CI |
| `APPLE_API_KEY_P8_BASE64` | App Store Connect API Key, base64-encoded `.p8` |
| `APPLE_API_KEY_ID` | 10-character Key ID from App Store Connect |
| `APPLE_API_KEY_ISSUER_ID` | Issuer UUID from App Store Connect |
| `SPARKLE_ED_PRIVATE_KEY` | EdDSA private key as exported by Sparkle's `generate_keys -x` (base64 string) |
| `PAGES_MIRROR_TOKEN` | Fine-grained PAT, scoped to repo `MxIris-LyricsX-Project/MxIris-LyricsX-Project.github.io`, permission `Contents: read and write` |

`GITHUB_TOKEN` is auto-injected. The workflow declares
`permissions: contents: write` so it can push to the LyricsX repo and create
releases.

## 8. Workflow Steps

`runs-on: macos-26`. Job-level `env`:

```yaml
LYRICSX_SKIP_BUILD_BUMP: "1"
LYRICSX_USE_LOCAL_DEPENDENCY: "0"
SPARKLE_VERSION: "2.6.4"   # pinned tool version, see §11
```

| # | Step | Script / Action | Skipped on `dry_run`? | Skipped on prerelease? |
|---|---|---|---|---|
| 1 | Checkout (`fetch-depth: 0`) | `actions/checkout@v4` | no | no |
| 2 | Resolve version | `Scripts/release/resolve-version.sh` | no | no |
| 3 | Validate | `Scripts/release/validate.sh` | no | no |
| 4 | Setup keychain | `Scripts/release/setup-keychain.sh` | no | no |
| 5 | Install Sparkle tools | `Scripts/release/install-sparkle-tools.sh` | no | no |
| 6 | Build (archive + exportArchive) | `Scripts/release/build.sh` | no | no |
| 7 | Upload xcresult on failure | `actions/upload-artifact@v4` (`if: failure()`) | n/a | n/a |
| 8 | Notarize + staple | `Scripts/release/notarize.sh` | yes | no |
| 9 | Package (app zip + dSYMs zip) | `Scripts/release/package.sh` | yes | no |
| 10 | Sparkle sign | `Scripts/release/sign-sparkle.sh` | yes | no |
| 11 | Compose release notes | `Scripts/release/compose-notes.sh` | yes | no |
| 12 | Create GitHub Release (**published**, `--prerelease` if applicable) | `Scripts/release/create-release.sh` | yes | no |
| 13 | Update canonical appcast | `Scripts/release/publish-appcast.sh canonical` (calls `update-appcast.py`, commits, pushes to LyricsX `master`) | yes | yes |
| 14 | Mirror to legacy Pages repo | `Scripts/release/publish-appcast.sh mirror` (clones legacy repo, calls `update-appcast.py`, pushes back) | yes | yes |
| 15 | Cleanup keychain (`if: always()`) | `Scripts/release/setup-keychain.sh cleanup` | no | no |

### Why step 12 must precede steps 13-14

`appcast.xml`'s `<enclosure url>` points to
`https://github.com/MxIris-LyricsX-Project/LyricsX/releases/download/v<VERSION>/<file>.zip`.
That URL is anonymously reachable **only after** the GitHub Release is in the
"published" state (drafts return 404 to the public). If the appcast were
published first, every Sparkle client would 404 until the GitHub Release flipped
to public.

## 9. Validation Rules (`validate.sh`)

Executed in order. Any failure exits with code 1 and a specific message before
the expensive build starts.

| # | Check | Failure message |
|---|---|---|
| 1 | `VERSION` matches the regex | `Invalid version format: '<VERSION>'. Expected e.g. 1.9.0 or 1.9.0-beta.1` |
| 2 | `ReleaseNotes/<VERSION>_en.md` exists | `Missing release notes: ReleaseNotes/<VERSION>_en.md.` |
| 3 | `ReleaseNotes/<VERSION>_zh.md` exists | `Missing release notes: ReleaseNotes/<VERSION>_zh.md.` |
| 4 | `Info.plist` `CFBundleShortVersionString` equals `<VERSION>` | `Info.plist CFBundleShortVersionString ('<plist>') doesn't match version ('<VERSION>').` |
| 5 | `CFBundleVersion` is a positive integer | `Info.plist CFBundleVersion ('<build>') is not a positive integer.` |
| 6 | Tag trigger only: `v<VERSION>` tag exists locally | `Tag v<VERSION> not found locally. Did fetch-depth: 0 work?` |
| 7 | Both triggers: `gh release view v<VERSION>` must fail | `Release v<VERSION> already exists. Bump version first or delete the existing draft.` |

Outputs to `$GITHUB_ENV`:

- `VERSION`, `BUILD`, `IS_PRERELEASE`, `ARTIFACT_NAME=LyricsX_<VERSION>+<BUILD>.zip`

## 10. Build, Notarize, Package — Same as Existing Spec

These three scripts (`build.sh`, `notarize.sh`, `package.sh`) are identical to
the existing `2026-04-19-release-ci-design.md` definitions and are not repeated
here. The workflow uses the new `validate.sh`, but `build.sh`, `notarize.sh`,
and `package.sh` carry over verbatim.

## 11. Sparkle Tool Installation (`install-sparkle-tools.sh`)

Sparkle ships precompiled `sign_update` inside its binary release tarballs.
The script:

1. `curl -L -o /tmp/sparkle.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz`
2. `tar -xf /tmp/sparkle.tar.xz -C /tmp/sparkle/`
3. Copies `/tmp/sparkle/bin/sign_update` to `Scripts/release/bin/sign_update`,
   sets executable bit.
4. Verifies `sign_update --version` runs.

`Scripts/release/bin/` is git-ignored. Pinning `SPARKLE_VERSION` (workflow env)
gives reproducibility; bumping it is a one-line change.

## 12. Sparkle Signing (`sign-sparkle.sh`)

```bash
require_env SPARKLE_ED_PRIVATE_KEY VERSION BUILD

APP_ZIP="build/LyricsX_${VERSION}+${BUILD}.zip"
[ -f "$APP_ZIP" ] || die "Missing ${APP_ZIP}"

KEY_FILE="$(mktemp -t sparkle-key)"
trap 'rm -f "$KEY_FILE"' EXIT

# SPARKLE_ED_PRIVATE_KEY is the literal string produced by `generate_keys -x`.
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$KEY_FILE"

# sign_update prints something like:
#   sparkle:edSignature="..."  length="..."
SIGN_OUTPUT="$(./Scripts/release/bin/sign_update --ed-key-file "$KEY_FILE" "$APP_ZIP")"

ED_SIGNATURE="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
ZIP_LENGTH="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"

[ -n "$ED_SIGNATURE" ] || die "Failed to parse sparkle:edSignature from sign_update output"
[ -n "$ZIP_LENGTH" ]  || die "Failed to parse length from sign_update output"

{
    printf 'ED_SIGNATURE=%s\n' "$ED_SIGNATURE"
    printf 'ZIP_LENGTH=%s\n'  "$ZIP_LENGTH"
} | tee -a "${GITHUB_ENV:-/dev/null}"
```

The private key file is in a `mktemp` path on the runner-local disk and removed
by `trap`. CI logs never echo the secret; `set +x` is the default in our
scripts (we never `set -x`).

## 13. Release Notes Composition (`compose-notes.sh`)

Same as existing spec (format 1, plain `---` separator):

```text
<content of ReleaseNotes/<VERSION>_en.md>

---

<content of ReleaseNotes/<VERSION>_zh.md>
```

Output: `build/body.md`.

## 14. GitHub Release Creation (`create-release.sh`)

```bash
flags=()                         # NOT --draft
if [ "$IS_PRERELEASE" = "true" ]; then
    flags+=(--prerelease)
fi
if [ -n "${GITHUB_SHA:-}" ]; then
    flags+=(--target "$GITHUB_SHA")
fi

gh release create "v${VERSION}" \
    "${flags[@]}" \
    --title "LyricsX ${VERSION}" \
    --notes-file "build/body.md" \
    "build/LyricsX_${VERSION}+${BUILD}.zip" \
    "build/LyricsX_${VERSION}+${BUILD}.dSYMs.zip"
```

The release is **published immediately** so the enclosure URL is anonymously
downloadable when `appcast.xml` lands.

## 15. Appcast Item Insertion (`update-appcast.py`)

A small Python script (uses the macOS-shipped `python3` and stdlib `xml.etree`,
no third-party deps). Pure file edit — no git operations live here.

### Inputs (env)

`VERSION`, `BUILD`, `IS_PRERELEASE`, `ED_SIGNATURE`, `ZIP_LENGTH`,
`MIN_SYSTEM_VERSION` (default `11.0`), and `APPCAST_PATH` (target file to
modify).

### Behavior

- Refuses to run when `IS_PRERELEASE=true` (defense in depth — the workflow
  also gates this step).
- Loads `APPCAST_PATH`, finds `<channel>`, builds a new `<item>` with:
  - `<title>${VERSION}</title>`
  - `<pubDate>` in RFC-822 format using current UTC time
  - `<sparkle:version>${BUILD}</sparkle:version>`
  - `<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>`
  - `<sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>`
  - `<description><![CDATA[<en release notes>]]></description>`
    (read from `ReleaseNotes/${VERSION}_en.md`)
  - `<enclosure url="https://github.com/MxIris-LyricsX-Project/LyricsX/releases/download/v${VERSION}/LyricsX_${VERSION}+${BUILD}.zip" length="${ZIP_LENGTH}" type="application/octet-stream" sparkle:edSignature="${ED_SIGNATURE}"/>`
- Inserts the new `<item>` as the **first child** of `<channel>` (so newest
  appears first; matches the existing convention).
- Writes back with the original XML declaration and the
  `xmlns:sparkle` / `xmlns:dc` namespaces preserved.
- Idempotent: if an `<item>` with the same `<sparkle:shortVersionString>`
  already exists, the script exits 0 without modifying the file (so re-running
  the workflow is safe).

## 16. Publish Appcast (`publish-appcast.sh`)

Two modes selected by argument:

### `publish-appcast.sh canonical`

- Working tree is the LyricsX repo checkout from step 1.
- Runs `python3 Scripts/release/update-appcast.py` with `APPCAST_PATH=appcast.xml`.
- `git config user.name "github-actions[bot]"` /
  `user.email "github-actions[bot]@users.noreply.github.com"`.
- `git add appcast.xml && git commit -m "release: update appcast.xml for v${VERSION}"`.
- `git pull --rebase origin master` (cheap insurance against concurrent commits;
  expected no-op).
- `git push origin HEAD:master`.

### `publish-appcast.sh mirror`

- Requires `PAGES_MIRROR_TOKEN`.
- `git clone --depth 1 https://x-access-token:${PAGES_MIRROR_TOKEN}@github.com/MxIris-LyricsX-Project/MxIris-LyricsX-Project.github.io.git build/legacy-pages`.
- Runs `python3 Scripts/release/update-appcast.py` with `APPCAST_PATH=build/legacy-pages/appcast.xml`.
- `git -C build/legacy-pages add appcast.xml`.
- `git -C build/legacy-pages commit -m "release: mirror v${VERSION} for legacy clients"`.
- `git -C build/legacy-pages push`.

Mirror failure fails the whole job. Re-running the workflow is safe because
`update-appcast.py` is idempotent (§15).

## 17. Pre-release Behavior

When `IS_PRERELEASE=true`:

- Steps 1–12 run normally (build, notarize, package, sign, GitHub Release with
  `--prerelease`).
- Steps 13–14 are skipped, so `appcast.xml` is **not** updated. End users on
  stable will not be auto-prompted to upgrade to a beta.
- Beta testers either subscribe to GitHub Releases manually or download
  the prerelease zip themselves.

A future Sparkle "channels" feature can add a separate `<sparkle:channel>beta</sparkle:channel>`
flow without disturbing this design.

## 18. Error Handling

- All shell scripts start with `set -euo pipefail`.
- `lib.sh` exposes `log_info`, `log_warn`, `log_error`, `die`, `require_env`.
- Errors print the specific missing file / mismatched value before exiting.
- On `xcodebuild` failure, the `xcresult` and the partial `xcarchive` are
  uploaded as the `xcresult` workflow artifact (7-day retention).
- On notarization rejection, `xcrun notarytool log` JSON is dumped to CI logs.
- The temp keychain is always deleted via the cleanup step guarded by
  `if: always()`.
- Sparkle private key, App Store Connect `.p8`, and the Developer ID `.p12`
  are decoded only to scratch paths and removed via `trap`.

## 19. Local Reproduction

Each script is invocable from the repo root with the same env vars the
workflow uses. Examples:

```bash
VERSION=1.9.0 IS_PRERELEASE=false GITHUB_EVENT_NAME=workflow_dispatch \
SKIP_RELEASE_EXISTS_CHECK=1 \
  bash Scripts/release/validate.sh

VERSION=1.9.0 BUILD=2925 \
SPARKLE_ED_PRIVATE_KEY="$(cat ~/.sparkle/ed_priv)" \
  bash Scripts/release/sign-sparkle.sh

VERSION=1.9.0 BUILD=2925 IS_PRERELEASE=false \
ED_SIGNATURE=... ZIP_LENGTH=8668838 APPCAST_PATH=appcast.xml \
  python3 Scripts/release/update-appcast.py
```

This makes failed pipeline stages reproducible without retriggering the full
workflow.

## 20. Maintainer Workflow After This Lands

To ship a release:

1. Bump `CFBundleShortVersionString` in `LyricsX/Supporting Files/Info.plist`,
   commit.
2. Write `ReleaseNotes/<version>_en.md` and `ReleaseNotes/<version>_zh.md`,
   commit.
3. `git tag v<version> && git push origin master v<version>`.
4. Wait for the workflow. On success: published GitHub Release exists,
   `appcast.xml` updated in both repos, Sparkle clients pick up the update on
   their next poll.
5. (Optional, only if dispatching) From Actions UI, click **Run workflow**,
   set `version`, optionally `dry_run=true` for a smoke test.

To retire the legacy mirror after 2.0.0:

1. Remove the `Mirror to legacy Pages repo` step from `release.yml`.
2. Delete the `PAGES_MIRROR_TOKEN` secret.
3. Optionally archive `MxIris-LyricsX-Project.github.io` repo.

## 21. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| EdDSA private key leak in logs | `set +x` default; key only in `mktemp` file; `trap` cleanup; `sign_update` output filtered through `sed` not `cat` |
| Auto-publish a broken release | `validate.sh` blocks pre-build; notarize/staple failures fail the job; `xcresult` uploaded for post-mortem; idempotent appcast script + manual `gh release delete` recovery path |
| Mirror push fails after canonical push succeeded | Whole job fails; idempotent `update-appcast.sh` lets a re-run safely fix the mirror |
| 1.8.1 user reads stale legacy feed because `PAGES_MIRROR_TOKEN` expired | PAT expiry is calendar-tracked; `setup-keychain.sh`-style fail-fast on auth error |
| Concurrent commit to LyricsX `master` race | `git pull --rebase` before push; single-maintainer workflow makes this rare |
| Sparkle tool URL or layout changes between versions | `SPARKLE_VERSION` is pinned; bumping it is a single env edit; install script verifies `sign_update --version` |
| Tag exists but no `Info.plist` bump | `validate.sh` check #4 |
| Release notes missing | `validate.sh` checks #2/#3 |
| dSYMs not produced | `package.sh` fails on empty/missing `dSYMs` directory |

## 22. Non-Requirements (YAGNI)

- No `shellcheck` CI step.
- No multi-job parallelism.
- No Slack / email notifications (Actions email on failure is enough).
- No automated tag creation.
- No build-number bump in CI.
- No DMG packaging.
- No Sparkle channels / beta feed (pre-release goes to GitHub only).
- No automated retirement of the legacy mirror.

## 23. Open Decisions Resolved During Brainstorm

| Decision | Choice |
|---|---|
| Scope of Sparkle automation | Full automation (sign + appcast + push) |
| `appcast.xml` location | Migrate canonical to LyricsX repo; transitional mirror to legacy Pages repo |
| Cross-repo auth | Fine-grained PAT (`PAGES_MIRROR_TOKEN`) |
| Mirror retirement trigger | Version milestone (around 2.0.0); maintainer-driven, no automation |
| GitHub Release status | Published (not draft) — required by the auto-update flow |
| Pre-release behavior | Published GitHub Release with `--prerelease`; **no** appcast update |
| Sparkle tool acquisition | Download pinned `Sparkle-<ver>.tar.xz` from sparkle-project releases, extract `bin/sign_update` |
| `sign_update` binary in git | No, `Scripts/release/bin/` is git-ignored |
