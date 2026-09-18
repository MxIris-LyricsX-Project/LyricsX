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

**Building needs the Metal toolchain installed.** `AppleMusicLyricsPanel`
compiles `ArtworkGradientShaders.metal`, and from Xcode 26 the Metal toolchain
is a separately downloadable component rather than part of Xcode itself, so a
fresh machine fails with `cannot execute tool 'metal' due to missing Metal
Toolchain`. Install it once with `xcodebuild -downloadComponent MetalToolchain`.
`release.yml` does the same check before its build step, because the GitHub
macOS runner images have had the component come and go depending on the pinned
Xcode version.

There are no automated tests configured in the Xcode scheme, and no GitHub
Actions workflow runs on pull requests — `release.yml` is tag-triggered only, so
the package tests below are the only automated gate and they have to be run by
hand.

`LyricsXPackage` has two suites. `LyricsXFoundationTests` covers the pure
policies — lyrics storage destinations, editing eligibility, HUD window
configuration, playback-position preservation, candidate-pool ordering, the
manual-selection override table, and the source-ordering modes (including the
property tests that keep the ordering transitive) — and is fast and headless
enough to run on every change. `AppleMusicLyricsPanelTests` is a real probe suite that
renders the Apple Music lyrics engine offscreen through `CARenderer` and asserts
its animation geometry and karaoke colour (no clipping, bounded lift, sweep
actually paints white, no position drift):

```bash
# Policy tests — run these on any change under LyricsXFoundation (<1s)
cd LyricsXPackage && swift test --filter LyricsXFoundationTests

# Offscreen probe tests for the Apple Music lyrics engine (~8s, needs a GPU session)
cd LyricsXPackage && swift test --filter LineEmphasisProbes

# Same, dumping every rendered frame as a PNG for eyeballing
APPLE_MUSIC_LYRICS_PROBE_FRAME_DIRECTORY=/tmp/probe-frames swift test --filter LineEmphasisProbes

# Music's per-syllable lift on structured lyrics: a line of short words rises
# syllable by syllable on the soft spring, and only a word Music would swell
# gets the per-glyph schedule. Red on the old per-word lift.
swift test --filter SyllableLiftProbes

# Inline-tag ([tt]) lyrics — Kugou, QQ Music, some NetEase — take the same
# per-segment lift: Kugou's STAY line with its real per-word timing rises on
# the soft spring, never swells or glows, and stays up; a 1.46 s held word
# swells by Music's factor; the fullEmphasis policy keeps the legacy look.
# Red on the old full-emphasis inline path.
swift test --filter InlineTagSyllableLiftProbes

# Wrapped rows on screen: a two-row lyric mounted in a window (inside the real
# container and on its own), each visual row projected into the window's root
# layer. Red whenever the content layer's effective orientation comes out y-up.
swift test --filter WrappedRowOrderProbes

# A real Apple Music line (structured timing plus a translation) through the
# whole SyncedLyricsLineView: the translation must not change the glyph
# motion, and sung glyphs must stay lifted until the line resets.
# APPLE_MUSIC_LYRICS_TRACE_DIRECTORY writes the per-glyph tracks as TSV (this
# suite and the ripple probe above). The probe suites sample real time, so run
# them one at a time or pass --no-parallel — two of them side by side contend
# for the main thread and the 0.5 pt trace comparison starts to jitter.
swift test --filter TranslatedLineEmphasisProbes

# Feed real downloaded .lrcx files (from ~/Music/LyricsX) through the whole
# panel: parse → layout → container rows → publisher-injected view controller.
# Skips itself when no library exists; APPLE_MUSIC_LYRICS_FIXTURE_DIRECTORY
# points it elsewhere, APPLE_MUSIC_LYRICS_FIXTURE_SWEEP_LIMIT (default 40)
# widens the sweep to the whole library.
swift test --filter LyricsLibraryFixtureProbes

# The line-change scroll: asserts the clip travels on a real CASpringAnimation
# with Music's own mass/stiffness/damping, rather than being stepped by hand
# from the display link. Offscreen and synthetic — no recording, no player.
swift test --filter ScrollSpringProbes

# The panel backdrop: Music 26's Now Playing pipeline (`mediaCoreUI26`, the
# default) and the MiniPlayer pipeline kept as `legacyTSL`. Real offscreen
# Metal rendering read back pixel by pixel, plus the uniform layout, mesh
# tables and orientation table. LYRICSX_BACKDROP_PREVIEW_DIRECTORY dumps the
# full-frame test's PNGs.
swift test --filter "NowPlayingBackdrop|ArtworkBackdrop|ArtworkGradient|ArtworkRendering"
```

`LyricsXWidgetShared`'s `WidgetDataStoreTests` has a pre-existing parallel-execution race (two tests share one store file), so a bare `swift test` may show its failures — they are unrelated to the panel probes.

Standalone `swift build` / `swift test` in `LyricsXPackage/` resolves `LyricsKit`/`MusicPlayer` from their pinned remote tags by default; set `LYRICSX_USE_LOCAL_DEPENDENCY=1` to use the sibling checkouts instead. The `LyricsXPackage/Package.resolved` it writes is gitignored — the canonical pins live in the Xcode project.

## Linting & Formatting

```bash
# SwiftFormat (configured in .swiftformat, 4-space indent, LF line breaks)
swiftformat .
```

SwiftLint is **not** part of this project any more: `.swiftlint.yml` and the
`SwiftLint` aggregate target were both removed in `2adf685`. Running `swiftlint`
by hand still works but falls back to its built-in defaults (e.g. `line_length`
120), which do not reflect this codebase's conventions — treat its output as
advisory, not as a gate. The build is the gate.

## Release Workflow

A LyricsX release is triggered by pushing a `v*` tag (e.g. `v1.9.0-beta.7`),
which fires `.github/workflows/release.yml`. CI sets
`LYRICSX_USE_LOCAL_DEPENDENCY=0`, so it resolves the three sibling packages
from their **published tags**, not from local checkouts.

All three are pinned to an **exact version**: `LyricsXPackage/Package.swift`
carries `exact: "1.12.0"` for LyricsKit and `exact: "1.10.0"` for MusicPlayer,
and MusicPlayer's own `Package.swift` carries `exact: "0.1.7"` for
mediaremote-adapter. So nothing moves underneath a release — a dependency
changes only when someone edits one of those strings, which puts every
dependency change in `git log`. They used to be `branch:` requirements, where
a push to the upstream branch silently changed what the next resolve pulled
and left only a bare SHA in `Package.resolved` to show for it.

**There is therefore no "audit for stale tags" step any more.** Picking up new
dependency work is deliberate, and goes in this order, because MusicPlayer
depends on mediaremote-adapter and LyricsX depends on both LyricsKit and
MusicPlayer:

1. **mediaremote-adapter** (`MxIris-LyricsX-Project/mediaremote-adapter`)
   — default branch `master`; its tags carry **no** `v` prefix (`0.1.7`).
2. **LyricsKit** (`MxIris-LyricsX-Project/LyricsKit`) — LyricsX tracks its
   `develop`, which runs ahead of `main`; tag from `develop`.
3. **MusicPlayer** (`MxIris-LyricsX-Project/MusicPlayer`) — LyricsX tracks its
   `develop`. Note `master` and `develop` have **deliberately** diverged on the
   LXMusicPlayer state-comparison tolerance (`master` restored 1.5s in
   `ced0ac7`, `develop` chose 0.5s in `e85e8af` and argues the case in its
   commit message). `develop`'s 0.5s is what ships; this is not a fork to
   reconcile before releasing.

For each repo whose new work you want to ship:

1. Decide the next version (minor bump for additive product/API, patch for
   bug fix only, major for breaking changes). These libraries release under
   **plain version numbers — no `-beta.N` suffix**, unlike LyricsX itself.
2. `git tag -a vX.Y.Z <commit> -m "X.Y.Z"` and `git push origin vX.Y.Z`.
3. Update the matching `exact:` string — in `LyricsXPackage/Package.swift` for
   LyricsKit and MusicPlayer, or in MusicPlayer's own `Package.swift` for
   mediaremote-adapter (which then needs a new MusicPlayer tag of its own).

Then in **this** repo:

4. Run `xcodebuild -project LyricsX.xcodeproj -scheme LyricsX
   -resolvePackageDependencies` to refresh
   `LyricsX.xcodeproj/.../Package.resolved`.
5. **Read the `Package.resolved` diff before committing.** A full resolve also
   advances every *other* dependency whose `from:` range allows it — the
   pinning commit itself picked up an unrelated `swift-async-algorithms`
   1.1.4 → 1.1.5 that had to be reverted by hand. Revert anything you did not
   intend to ship; a release should not carry dependency movement nobody asked
   for.
6. Commit the updated `Package.resolved` and `Package.swift`.
7. Bump `CFBundleShortVersionString` (marketing version) in
   `LyricsX/Supporting Files/Info.plist` and
   `LyricsXWidget/Supporting Files/Info.plist` if the new version's base
   (`X.Y.Z` portion, stripping any `-beta.N` / `-rc.N` suffix) differs
   from what's committed. **`CFBundleVersion` does not need to be
   touched** — `Scripts/release/validate.sh` derives it from VERSION using
   the encoded scheme (see `Documentations/BuildNumberScheme.md`) and
   overwrites both plists at CI time, so the value committed in the repo
   is informational only.
8. Add `ReleaseNotes/<version>_en.md` and `ReleaseNotes/<version>_zh.md`,
   following the conventions below.
9. Push the branch, then tag and push `v<version>` to trigger the
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

If the pinned version of a dependency predates a product LyricsX needs — you
updated the `exact:` string but never pushed the tag, or pointed it at an
older release — CI fails fast in `Build` with
`product 'X' required by package 'lyricsxpackage' target 'LyricsXFoundation' not found in package 'Y'`
— treat that as the signal to go tag the dependency and correct the pin, not
as a LyricsX-side bug.

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

### Core Dependencies (via SPM)

- **LyricsKit** (`MxIris-LyricsX-Project/LyricsKit`, branch: main) — lyrics search/parsing engine
- **MusicPlayer** (`MxIris-LyricsX-Project/MusicPlayer`, branch: master) — music player abstraction layer
- **mediaremote-adapter** (`MxIris-LyricsX-Project/mediaremote-adapter`) — transitive dependency of MusicPlayer; provides the `MediaRemoteAdapter` product used by `SystemMedia` to bridge the private MediaRemote APIs
- **LyricsXFoundation** (local package in `LyricsXPackage/`) — re-export wrapper (`@_exported import LyricsKit`) plus small shared extensions (`PlaybackState.lyricsDisplayTime`, `MusicTrack.resolvedArtwork`)
- **AppleMusicLyricsPanel** (local package target in `LyricsXPackage/`) — the Apple Music-style lyrics panel: CALayer karaoke engine, panel view controller, gradient background. Extracted from the app target so it builds and probe-tests standalone (`swift test --filter LineEmphasisProbes`). All app coupling flows through one injection seam, `AppleMusicLyrics.HostEnvironment` (player, translation policy, lyric time delay), installed by the app-side glue

### App Internal Structure (`LyricsX/`)

The app uses a **Combine-driven reactive architecture** with shared singletons:

- **`Component/`** — Core singletons: `AppController` (central lyrics search/management hub), `AppDelegate`, `SelectedPlayer` (player adapter). `AppController` listens for track changes via Combine publishers, runs async lyrics searches (`AsyncSequence`), and distributes results to display layers.
- **`AppleMusicLyrics/`** — App-side glue for the `AppleMusicLyricsPanel` package target: just `AppleMusicLyricsWindowController`, which owns the panel window (frame autosave, pin button, HUD lifecycle), installs `AppleMusicLyrics.HostEnvironment`, and injects `AppController`'s lyrics publishers into the panel. The engine itself lives in `LyricsXPackage/Sources/AppleMusicLyricsPanel/`.
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
