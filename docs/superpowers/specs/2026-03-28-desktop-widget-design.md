# LyricsX Desktop Widget Design Spec

**Date**: 2026-03-28
**Status**: Draft
**Minimum Deployment**: macOS 15 (widget extension only; main app remains macOS 11)

## Overview

Add WidgetKit-based desktop widgets to LyricsX that display current song information and synchronized lyrics in an Apple Music full-screen lyrics visual style. Widgets support all four macOS sizes (Small, Medium, Large, Extra Large) with content scaled per size.

## Requirements

- Time-driven lyric line synchronization via `TimelineEntry` scheduling
- Apple Music-inspired visual style: current line highlighted and enlarged, surrounding lines faded, album-color gradient background with dark fallback
- Playback controls (play/pause, next, previous) on Large and Extra Large sizes
- User-configurable translation display (on/off, language selection)
- All four widget sizes supported

## Architecture

### Data Bridge: Main App → Widget

Hybrid storage via App Group (`D5Q73692VW.group.com.JH.LyricsX`):

- **Structured data** → App Group `UserDefaults` (key: `widgetLyricsData`)
- **Album artwork** → App Group shared container file (`cover.jpg`, ~200x200 JPEG)

### Shared Data Model

```swift
struct LyricsWidgetData: Codable {
    let trackTitle: String
    let artist: String
    let albumName: String?
    let backgroundColor: CodableColor?  // Extracted from album art
    let lyricsLines: [LyricsLineEntry]  // Context window around current line
    let currentLineIndex: Int           // Index in lyricsLines
    let isPlaying: Bool
    let timestamp: Date                 // Snapshot time
    let playbackPosition: TimeInterval  // Playback position at snapshot (seconds)
    let availableTranslationLanguages: [String]  // e.g. ["zh-Hans", "ja"] — what's available
}

struct LyricsLineEntry: Codable {
    let text: String
    let translation: String?
    let startTime: TimeInterval  // Lyric line start time (seconds)
    let endTime: TimeInterval?
}

struct CodableColor: Codable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
}
```

### Write Triggers (in AppController)

New Combine subscriptions in `AppController` that write to shared storage and call `WidgetCenter.shared.reloadTimelines()`:

| Event | Data Updated |
|---|---|
| Track change | Full `LyricsWidgetData` + cover image + `reloadTimelines()` |
| Lyric line change | `currentLineIndex` update + `reloadTimelines()` |
| Play/pause | `isPlaying` update + `reloadTimelines()` |

Lyrics context window: current line +/- 50 lines maximum per write.

### Timeline Construction

```
Main app writes data → reloadTimelines()
         ↓
TimelineProvider.timeline(in:) called
         ↓
Read LyricsWidgetData from groupDefaults
         ↓
For each lyric line, compute absolute display date:
  entryDate = timestamp + (line.startTime - playbackPosition)
         ↓
Generate TimelineEntry per line with highlighted index
         ↓
Return Timeline(entries:, policy: .never)
```

**Edge cases:**
- **Paused**: Single static entry, `policy: .never`
- **No lyrics**: Single entry with song info only
- **Not playing**: Empty state entry ("Not Playing")

## Widget Sizes & Layouts

### Small (Square)

Album cover as blurred background, song title and artist overlaid at bottom. No lyrics, no controls.

```
┌──────────────┐
│  Album cover  │
│  (blurred bg) │
│              │
│  Song Title   │
│  Artist       │
└──────────────┘
```

### Medium (Horizontal Rectangle)

Left: album cover thumbnail. Right: song info + 1-2 lyric lines (current highlighted, next faded).

```
┌─────────────────────────────┐
│ ┌──────┐                    │
│ │Cover │  Song - Artist     │
│ │      │  ♪ Current lyric   │
│ │      │    Next lyric      │
│ └──────┘                    │
└─────────────────────────────┘
```

### Large

Full gradient background. Multi-line lyrics list with current line centered and highlighted. Playback controls at bottom.

```
┌─────────────────────────────┐
│  Song Title - Artist        │
│                             │
│    Previous line (faded)    │
│    Current line (bright)    │
│    Next line (faded)        │
│    Next+1 (more faded)      │
│                             │
│       ◁   ▶︎/⏸   ▷          │
└─────────────────────────────┘
```

### Extra Large

Top: album cover + full song info. Center: expanded lyrics context with translation (if enabled). Bottom: playback controls.

```
┌──────────────────────────────────────────┐
│  ┌──────┐                                │
│  │Cover │  Song Title                    │
│  │      │  Artist — Album                │
│  └──────┘                                │
│                                          │
│        Previous lines (faded)            │
│        Current line (bright, large)      │
│        (Translation, if enabled)         │
│        Next lines (faded)                │
│                                          │
│          ◁    ▶︎/⏸    ▷                   │
└──────────────────────────────────────────┘
```

### Apple Music Visual Style

- **Background**: Album-extracted primary color gradient (with dark fallback)
- **Current line**: White, larger font, full opacity
- **Surrounding lines**: White, smaller font, opacity 0.3-0.5
- **Transitions**: Implicit SwiftUI animation (`.easeInOut`) on timeline entry switch

## Widget Configuration (AppIntent)

```swift
struct LyricsWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Lyrics Widget"

    @Parameter(title: "Show Translation")
    var showTranslation: Bool  // Default: false

    @Parameter(title: "Translation Language")
    var translationLanguage: TranslationLanguage?
}

// Dynamic lookup enum backed by AppEntity
struct TranslationLanguage: AppEntity {
    var id: String          // e.g. "zh-Hans", "ja"
    var displayName: String // e.g. "Chinese (Simplified)", "Japanese"
    // EntityQuery reads availableTranslationLanguages from LyricsWidgetData
}
```

**Responsibility split**: `LyricsWidgetData.availableTranslationLanguages` tells the widget which translations exist for the current track. `LyricsWidgetConfigurationIntent.showTranslation` and `.translationLanguage` are the user's display preference. The `TimelineProvider` combines both: if the user enabled translation AND the chosen language is available, include translation text in entries.

### WidgetDataStore

Encapsulates all shared storage access for both the main app (write) and widget extension (read):

```swift
struct WidgetDataStore {
    static let groupIdentifier = "D5Q73692VW.group.com.JH.LyricsX"
    static let dataKey = "widgetLyricsData"
    static let coverFileName = "cover.jpg"

    // Read/write LyricsWidgetData via groupDefaults (JSON encoded)
    func write(_ data: LyricsWidgetData) throws
    func read() -> LyricsWidgetData?

    // Read/write album cover to shared container directory
    func writeCover(_ image: NSImage) throws  // main app only
    func readCoverURL() -> URL?               // widget reads file URL for SwiftUI Image
}
```

## Playback Control Intents

Widget extension cannot use Apple Events. Controls execute in main app process via `openAppWhenRun = true`. Since LyricsX is an `LSUIElement` app, this is invisible to the user.

| Intent | Action |
|---|---|
| `PlayPauseIntent` | Toggle play/pause via `MusicPlayers.Selected.shared` |
| `NextTrackIntent` | Next track |
| `PreviousTrackIntent` | Previous track |

```swift
struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play/Pause"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        MusicPlayers.Selected.shared.playPause()
        return .result()
    }
}
```

## Project Structure

### New Target

| Target | Type | Bundle ID | Deployment |
|---|---|---|---|
| `LyricsXWidget` | Widget Extension | `com.JH.LyricsX.LyricsWidget` | macOS 15 |

Embedded in main app's `Contents/PlugIns/`.

### New Module: LyricsXWidgetShared

Added to `LyricsXPackage/` as a new target. Contains shared data model and storage logic. No dependency on LyricsKit or MusicPlayer.

### File Structure

```
LyricsXWidget/
├── LyricsXWidget.swift                    // @main Widget entry
├── LyricsTimelineProvider.swift           // TimelineProvider
├── LyricsTimelineEntry.swift              // TimelineEntry
├── Configuration/
│   └── LyricsWidgetConfigurationIntent.swift
├── Views/
│   ├── SmallWidgetView.swift
│   ├── MediumWidgetView.swift
│   ├── LargeWidgetView.swift
│   ├── ExtraLargeWidgetView.swift
│   ├── LyricsLineView.swift              // Reusable lyric line component
│   └── PlaybackControlView.swift
├── Intents/
│   ├── PlayPauseIntent.swift
│   ├── NextTrackIntent.swift
│   └── PreviousTrackIntent.swift
├── Utilities/
│   └── ColorExtraction.swift
├── Info.plist
└── LyricsXWidget.entitlements
```

### Dependency Graph

```
LyricsX (main app)
├── LyricsXFoundation (LyricsKit + MusicPlayer)
└── LyricsXWidgetShared

LyricsXWidget (widget extension)
└── LyricsXWidgetShared
```

### Main App Modifications

- `AppController.swift`: Add Combine subscriptions to write widget data on track/lyric/playback changes
- `LyricsXPackage/Package.swift`: Add `LyricsXWidgetShared` target
- Main app target: Add dependency on `LyricsXWidgetShared`
- Album color extraction: Compute dominant color from `NSImage`, store as `CodableColor`

### Entitlements (LyricsXWidget)

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.application-groups</key>
<array>
    <string>$(TeamIdentifierPrefix)group.$(LX_BUNDLE_ID_PREFIX).LyricsX</string>
</array>
```
