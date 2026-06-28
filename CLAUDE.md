# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LyricsX is a macOS menu-bar application (`LSUIElement`) that automatically searches, downloads, and displays synchronized lyrics for the currently playing song. It supports multiple music players and lyrics sources, with desktop karaoke overlay and menu-bar lyrics display. This is a personally maintained fork of `ddddxxx/LyricsX`.

- **Platform**: macOS 11+ only
- **Language**: Swift 5 (project setting), Swift 6.2 toolchain (Package.swift)
- **Bundle ID**: `com.JH.LyricsX`

## Build Commands

**Prefer workspace build when available.** If `../MxIris-LyricsX-Project.xcworkspace` exists (the umbrella workspace that aggregates `LyricsKit`, `MusicPlayer`, `mediaremote-adapter`, and this project), build via `-workspace ../MxIris-LyricsX-Project.xcworkspace` instead of `-project LyricsX.xcodeproj`. This resolves all sibling packages as local checkouts. Fall back to the project-only commands below when the workspace is absent.

```bash
# Workspace build (preferred when ../MxIris-LyricsX-Project.xcworkspace exists)
xcodebuild -workspace ../MxIris-LyricsX-Project.xcworkspace -scheme LyricsX -configuration Debug build 2>&1 | xcsift

# Project-only build (fallback — Debug)
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift

# Project-only build (fallback — Release)
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Release build 2>&1 | xcsift

# Archive (triggers post-archive export + notarization script)
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Release archive
```

There are no automated tests configured in the Xcode scheme. The `LyricsXPackage` has an empty test target `LyricsXFoundationTests`.

## Linting & Formatting

```bash
# SwiftLint (configured in .swiftlint.yml, line_length: 150)
swiftlint

# SwiftFormat (configured in .swiftformat, 4-space indent, LF line breaks)
swiftformat .
```

## Release Workflow

A LyricsX release is triggered by pushing a `v*` tag (e.g. `v1.9.0-beta.7`),
which fires `.github/workflows/release.yml`. CI sets
`LYRICSX_USE_LOCAL_DEPENDENCY=0`, so it resolves SPM dependencies from
their **remote tags** (not local checkouts). If a dependency's tag is
stale relative to its `main`/`master` HEAD, CI will pull an outdated
version that may be missing products LyricsX needs.

**Before every LyricsX release, audit these three sibling repos and
tag any that have unreleased commits — in this order, because
MusicPlayer depends on mediaremote-adapter, and LyricsX depends on
both LyricsKit and MusicPlayer:**

1. **mediaremote-adapter** (`MxIris-LyricsX-Project/mediaremote-adapter`)
   — check `master`/`main` vs latest `v*` tag.
2. **LyricsKit** (`MxIris-LyricsX-Project/LyricsKit`, branch `main`)
   — check `main` vs latest `v*` tag.
3. **MusicPlayer** (`MxIris-LyricsX-Project/MusicPlayer`, branch `master`)
   — check `master` vs latest `v*` tag.

For each repo that has unreleased commits:

1. Decide the next version (minor bump for additive product/API, patch
   for bug fix only, major for breaking changes).
2. `git tag -a vX.Y.Z -m "X.Y.Z"` and `git push origin vX.Y.Z` in that
   repo.

Then in **this** repo:

3. Bump the SPM `from:` requirement in `LyricsXPackage/Package.swift`
   if needed (only when the new tag is below the existing floor, or to
   pin a known-good major).
4. Run `xcodebuild -resolvePackageDependencies` (or
   *Update to Latest Package Versions* in Xcode) to refresh
   `LyricsX.xcodeproj/.../Package.resolved`.
5. Commit the updated `Package.resolved` and (if changed)
   `Package.swift`.
6. Bump `CFBundleShortVersionString` (marketing version) in
   `LyricsX/Supporting Files/Info.plist` and
   `LyricsXWidget/Supporting Files/Info.plist` if the new version's base
   (`X.Y.Z` portion, stripping any `-beta.N` / `-rc.N` suffix) differs
   from what's committed. **`CFBundleVersion` does not need to be
   touched** — `Scripts/release/validate.sh` derives it from VERSION using
   the encoded scheme (see `Documentations/BuildNumberScheme.md`) and
   overwrites both plists at CI time, so the value committed in the repo
   is informational only.
7. Add `ReleaseNotes/<version>_en.md` and `ReleaseNotes/<version>_zh.md`,
   following the conventions below.
8. Push the branch, then tag and push `v<version>` to trigger the
   release workflow.

### Release notes conventions

- The GitHub Release **title** is the version string with a `v` prefix
  (e.g. `v1.9.0-beta.7`). The `Scripts/release/create-release.sh`
  script passes `--title "v${VERSION}"` to `gh release create`.
- The version is shown **only** in the title — neither the English
  nor the Chinese notes file should repeat the version number or
  the project name "LyricsX" anywhere. Refer to the app implicitly
  ("a new switch", "the toggle"), not by name.
- Top-level H1 in each notes file is the language-neutral section
  label only:
  - `ReleaseNotes/<version>_en.md` → `# What's New`
  - `ReleaseNotes/<version>_zh.md` → `# 更新内容`
- Use H2 for grouping inside each file (`## New`, `## 新增`,
  `## Fixes`, `## 修复`, etc.).
- **Do not hard-wrap paragraph text.** Each bullet's body should be
  a single long line — let the renderer (GitHub Releases, the
  Sparkle update window) wrap visually. Only insert a line break
  between separate list items.
- The two notes files are concatenated by
  `Scripts/release/compose-notes.sh` with a `---` separator, so the
  English file goes first.

If you skip step 1-2 and a dependency is missing a needed product, CI
fails fast in `Build` with
`product 'X' required by package 'lyricsxpackage' target 'LyricsXFoundation' not found in package 'Y'`
— treat that as the signal to go back and tag the dependency, not as a
LyricsX-side bug.

## Architecture

### Build System

Hybrid Xcode project + Swift Package Manager. The Xcode project (`LyricsX.xcodeproj`) is the primary build entry point. It integrates `LyricsXPackage/` as a local Swift package, and all third-party dependencies are managed via Xcode's SPM integration (no CocoaPods/Carthage).

#### Build settings live in `Config/*.xcconfig`, not the pbxproj

All build settings are split out of `LyricsX.xcodeproj/project.pbxproj` into a layered set of `.xcconfig` files under `Config/`. The 8 `XCBuildConfiguration` entries in the pbxproj keep empty `buildSettings = { }` blocks and only carry a `baseConfigurationReference` pointing at the corresponding xcconfig. Edit `Config/**/*.xcconfig` to change settings — do not add settings back into the pbxproj.

```
Config/
├── Shared.xcconfig                # cross-target, cross-config base (warnings, SDK, SWIFT_VERSION, code signing, hardened runtime, etc.)
├── Shared-Debug.xcconfig          # includes Shared; adds Debug optimization, -DDEBUG, LX_BUNDLE_ID_PREFIX = dev.JH, ...
├── Shared-Release.xcconfig        # includes Shared; adds Release optimization, -DRELEASE, LX_BUNDLE_ID_PREFIX = com.JH, ...
├── Project-Debug.xcconfig         # includes Shared-Debug; project-wide Debug (MACOSX_DEPLOYMENT_TARGET = 12.0, asset symbols)
├── Project-Release.xcconfig       # includes Shared-Release; project-wide Release
├── LyricsX/
│   ├── LyricsX.xcconfig           # main app: Info.plist, app icon, framework search paths, REGISTER_APP_GROUPS, MACOSX_DEPLOYMENT_TARGET = 12.0
│   ├── LyricsX-Debug.xcconfig     # includes LyricsX.xcconfig; entitlements, PRODUCT_BUNDLE_IDENTIFIER = $(LX_BUNDLE_ID_PREFIX).LyricsX, PRODUCT_NAME = LyricsX-Debug
│   └── LyricsX-Release.xcconfig   # includes LyricsX.xcconfig; entitlements, PRODUCT_BUNDLE_IDENTIFIER, PRODUCT_NAME = LyricsX
├── LyricsXHelper/
│   ├── LyricsXHelper.xcconfig
│   ├── LyricsXHelper-Debug.xcconfig
│   └── LyricsXHelper-Release.xcconfig
└── LyricsXWidget/
    ├── LyricsXWidget.xcconfig     # widget keeps MACOSX_DEPLOYMENT_TARGET = 15.0 separately (independent of project's 12.0)
    ├── LyricsXWidget-Debug.xcconfig
    └── LyricsXWidget-Release.xcconfig
```

Setting evaluation order (high overrides low): target xcconfig → project xcconfig → Xcode platform defaults. Debug vs Release bundle identifiers are produced via the `$(LX_BUNDLE_ID_PREFIX)` variable defined in `Shared-Debug.xcconfig` / `Shared-Release.xcconfig`; the entitlements files live in `<Target>/Supporting Files/*-Debug.entitlements` and `*-Release.entitlements`.

### Targets

| Target | Purpose |
|---|---|
| `LyricsX` | Main macOS app |
| `LyricsXHelper` | LoginItem helper embedded in `Contents/Library/LoginItems/`, watches for music player launch and auto-starts the main app |
| `SwiftLint` | Aggregate target for running SwiftLint |

### Core Dependencies (via SPM)

- **LyricsKit** (`MxIris-LyricsX-Project/LyricsKit`, branch: main) — lyrics search/parsing engine
- **MusicPlayer** (`MxIris-LyricsX-Project/MusicPlayer`, branch: master) — music player abstraction layer
- **mediaremote-adapter** (`MxIris-LyricsX-Project/mediaremote-adapter`) — transitive dependency of MusicPlayer; provides the `MediaRemoteAdapter` product used by `SystemMedia` to bridge the private MediaRemote APIs
- **LyricsXFoundation** (local package in `LyricsXPackage/`) — thin re-export wrapper: `@_exported import LyricsKit`

### App Internal Structure (`LyricsX/`)

The app uses a **Combine-driven reactive architecture** with shared singletons:

- **`Component/`** — Core singletons: `AppController` (central lyrics search/management hub), `AppDelegate`, `SelectedPlayer` (player adapter). `AppController` listens for track changes via Combine publishers, runs async lyrics searches (`AsyncSequence`), and distributes results to display layers.
- **`Controller/`** — Display controllers: `KaraokeLyricsController` (desktop karaoke overlay), `MenuBarLyricsController` (menu bar text), `TouchBarLyricsController`
- **`LyricsHUD/`** — Floating lyrics panel (`LyricsHUDViewController`)
- **`Preferences/`** — Preference pane ViewControllers (General, Display, Filter, Shortcut, Source, Lab)
- **`View/`** — Custom views: `KaraokeLabel`, `KaraokeLyricsView`, `ScrollLyricsView`
- **`Utility/`** — Global constants (`Global.swift`), extensions, Combine utilities (`CXExtensions/`)

### Data Flow

1. `MusicPlayers.Selected.shared` publishes current track/playback state
2. `AppController.shared` subscribes, triggers async lyrics search on track change
3. Found lyrics stored as `@Published var currentLyrics`
4. Display controllers (`KaraokeLyricsController`, `MenuBarLyricsController`, etc.) subscribe to lyrics + playback position to render synchronized output

### Localization

- Managed via `.xcstrings` (Xcode String Catalogs) and legacy `.strings` files
- BartyCrouch (`.bartycrouch.toml`) syncs storyboard strings
- Crowdin (`crowdin.yml`) for collaborative translation

### Local Development with Dependencies

`LyricsXPackage/Package.swift` supports switching to local checkouts of `LyricsKit` and `MusicPlayer` via `local:` path overrides (disabled by default with `isEnabled: false`). Toggle these when developing against local forks of these libraries.
