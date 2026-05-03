# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

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

## Architecture

### Build System

Hybrid Xcode project + Swift Package Manager. The Xcode project (`LyricsX.xcodeproj`) is the primary build entry point. It integrates `LyricsXPackage/` as a local Swift package, and all third-party dependencies are managed via Xcode's SPM integration (no CocoaPods/Carthage).

### Targets

| Target | Purpose |
|---|---|
| `LyricsX` | Main macOS app |
| `LyricsXHelper` | LoginItem helper embedded in `Contents/Library/LoginItems/`, watches for music player launch and auto-starts the main app |
| `SwiftLint` | Aggregate target for running SwiftLint |

### Core Dependencies (via SPM)

- **LyricsKit** (`MxIris-LyricsX-Project/LyricsKit`, branch: main) — lyrics search/parsing engine
- **MusicPlayer** (`MxIris-LyricsX-Project/MusicPlayer`, branch: master) — music player abstraction layer
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
