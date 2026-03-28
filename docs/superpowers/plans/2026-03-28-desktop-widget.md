# Desktop Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add WidgetKit-based desktop widgets to LyricsX that display current song info and time-synchronized lyrics in Apple Music style.

**Architecture:** Hybrid data bridge (App Group UserDefaults + shared container file) from main app to widget extension. Main app writes `LyricsWidgetData` on track/lyric/playback changes and calls `reloadTimelines()`. Widget extension reads data, builds time-driven `TimelineEntry` per lyric line.

**Tech Stack:** WidgetKit, SwiftUI, AppIntents, Combine. macOS 15+ for widget extension. Swift 6.2 toolchain.

**Design Spec:** `docs/superpowers/specs/2026-03-28-desktop-widget-design.md`

---

## File Structure

### New files to create

**LyricsXPackage (shared module):**
- `LyricsXPackage/Sources/LyricsXWidgetShared/LyricsWidgetData.swift` — shared data models (`LyricsWidgetData`, `LyricsLineEntry`, `CodableColor`)
- `LyricsXPackage/Sources/LyricsXWidgetShared/WidgetDataStore.swift` — read/write logic for groupDefaults + shared container
- `LyricsXPackage/Tests/LyricsXWidgetSharedTests/LyricsWidgetDataTests.swift` — unit tests for data model serialization
- `LyricsXPackage/Tests/LyricsXWidgetSharedTests/WidgetDataStoreTests.swift` — unit tests for data store

**Widget extension:**
- `LyricsXWidget/LyricsXWidget.swift` — `@main` widget entry point
- `LyricsXWidget/LyricsTimelineProvider.swift` — `AppIntentTimelineProvider` implementation
- `LyricsXWidget/LyricsTimelineEntry.swift` — `TimelineEntry` definition
- `LyricsXWidget/Configuration/LyricsWidgetConfigurationIntent.swift` — widget configuration intent
- `LyricsXWidget/Configuration/TranslationLanguage.swift` — `AppEntity` for dynamic language enum
- `LyricsXWidget/Views/SmallWidgetView.swift` — small size layout
- `LyricsXWidget/Views/MediumWidgetView.swift` — medium size layout
- `LyricsXWidget/Views/LargeWidgetView.swift` — large size layout
- `LyricsXWidget/Views/ExtraLargeWidgetView.swift` — extra large size layout
- `LyricsXWidget/Views/LyricsLineView.swift` — reusable lyric line component
- `LyricsXWidget/Views/PlaybackControlView.swift` — playback control buttons
- `LyricsXWidget/Views/EmptyStateView.swift` — "not playing" placeholder
- `LyricsXWidget/Utilities/ColorExtensions.swift` — `CodableColor` ↔ SwiftUI `Color` conversion
- `LyricsXWidget/Info.plist` — widget extension Info.plist
- `LyricsXWidget/LyricsXWidget.entitlements` — App Group entitlement

**Shared between both targets:**
- `LyricsX/Intents/WidgetPlaybackIntents.swift` — playback control AppIntents (compiled into both LyricsX and LyricsXWidget with `#if !WIDGET_EXTENSION` conditional compilation)

**Main app modifications:**
- `LyricsX/Component/AppController.swift` — add widget data bridge (Combine subscriptions)
- `LyricsX/Utility/AlbumColorExtractor.swift` — new file, dominant color extraction from NSImage
- `LyricsXPackage/Package.swift` — add `LyricsXWidgetShared` product and target

### Xcode project modifications (via xcodeproj MCP)
- Add `LyricsXWidget` extension target (macOS 15, Widget Extension)
- Add `LyricsXWidget.entitlements` with App Group
- Add embed widget extension build phase to main app
- Add `LyricsXWidgetShared` package dependency to both main app and widget targets

---

## Task 1: Create LyricsXWidgetShared Module

**Files:**
- Modify: `LyricsXPackage/Package.swift`
- Create: `LyricsXPackage/Sources/LyricsXWidgetShared/LyricsWidgetData.swift`
- Create: `LyricsXPackage/Sources/LyricsXWidgetShared/WidgetDataStore.swift`

- [ ] **Step 1: Update Package.swift to add LyricsXWidgetShared**

Add a new product and target to `LyricsXPackage/Package.swift`. The module has NO dependencies on LyricsKit or MusicPlayer — it is pure data models + Foundation.

In `Package.swift`, add to the `products` array:

```swift
.library(
    name: "LyricsXWidgetShared",
    targets: ["LyricsXWidgetShared"]
),
```

Add to the `targets` array:

```swift
.target(
    name: "LyricsXWidgetShared",
    dependencies: []
),
```

- [ ] **Step 2: Create LyricsWidgetData.swift**

Create `LyricsXPackage/Sources/LyricsXWidgetShared/LyricsWidgetData.swift`:

```swift
import Foundation

/// Data snapshot written by the main app for the widget extension to consume.
public struct LyricsWidgetData: Codable, Sendable {
    public let trackTitle: String
    public let artist: String
    public let albumName: String?
    public let backgroundColor: CodableColor?
    public let lyricsLines: [LyricsLineEntry]
    public let currentLineIndex: Int
    public let isPlaying: Bool
    public let timestamp: Date
    public let playbackPosition: TimeInterval
    public let availableTranslationLanguages: [String]

    public init(
        trackTitle: String,
        artist: String,
        albumName: String?,
        backgroundColor: CodableColor?,
        lyricsLines: [LyricsLineEntry],
        currentLineIndex: Int,
        isPlaying: Bool,
        timestamp: Date,
        playbackPosition: TimeInterval,
        availableTranslationLanguages: [String]
    ) {
        self.trackTitle = trackTitle
        self.artist = artist
        self.albumName = albumName
        self.backgroundColor = backgroundColor
        self.lyricsLines = lyricsLines
        self.currentLineIndex = currentLineIndex
        self.isPlaying = isPlaying
        self.timestamp = timestamp
        self.playbackPosition = playbackPosition
        self.availableTranslationLanguages = availableTranslationLanguages
    }
}

public struct LyricsLineEntry: Codable, Sendable {
    public let text: String
    public let translation: String?
    public let startTime: TimeInterval
    public let endTime: TimeInterval?

    public init(text: String, translation: String?, startTime: TimeInterval, endTime: TimeInterval?) {
        self.text = text
        self.translation = translation
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct CodableColor: Codable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}
```

- [ ] **Step 3: Create WidgetDataStore.swift**

Create `LyricsXPackage/Sources/LyricsXWidgetShared/WidgetDataStore.swift`:

```swift
import Foundation

public struct WidgetDataStore: Sendable {
    public static let dataKey = "widgetLyricsData"
    public static let coverFileName = "cover.jpg"

    private let groupIdentifier: String

    public init(groupIdentifier: String) {
        self.groupIdentifier = groupIdentifier
    }

    private var groupDefaults: UserDefaults? {
        UserDefaults(suiteName: groupIdentifier)
    }

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    // MARK: - LyricsWidgetData

    public func write(_ data: LyricsWidgetData) throws {
        let encoded = try JSONEncoder().encode(data)
        groupDefaults?.set(encoded, forKey: Self.dataKey)
    }

    public func read() -> LyricsWidgetData? {
        guard let data = groupDefaults?.data(forKey: Self.dataKey) else { return nil }
        return try? JSONDecoder().decode(LyricsWidgetData.self, from: data)
    }

    public func clear() {
        groupDefaults?.removeObject(forKey: Self.dataKey)
        clearCover()
    }

    // MARK: - Album Cover

    public var coverURL: URL? {
        sharedContainerURL?.appendingPathComponent(Self.coverFileName)
    }

    public func writeCover(_ jpegData: Data) throws {
        guard let coverURL else { return }
        try jpegData.write(to: coverURL, options: .atomic)
    }

    public func clearCover() {
        guard let coverURL else { return }
        try? FileManager.default.removeItem(at: coverURL)
    }
}
```

- [ ] **Step 4: Build the package to verify**

Run:
```bash
cd LyricsXPackage && swift build
```

Expected: Build succeeds with no errors.

- [ ] **Step 5: Commit**

```bash
git add LyricsXPackage/Package.swift \
       LyricsXPackage/Sources/LyricsXWidgetShared/
git commit -m "feat: add LyricsXWidgetShared module with data models and store"
```

---

## Task 2: Unit Tests for LyricsXWidgetShared

**Files:**
- Modify: `LyricsXPackage/Package.swift`
- Create: `LyricsXPackage/Tests/LyricsXWidgetSharedTests/LyricsWidgetDataTests.swift`
- Create: `LyricsXPackage/Tests/LyricsXWidgetSharedTests/WidgetDataStoreTests.swift`

- [ ] **Step 1: Add test target to Package.swift**

Add to the `targets` array in `Package.swift`:

```swift
.testTarget(
    name: "LyricsXWidgetSharedTests",
    dependencies: ["LyricsXWidgetShared"]
),
```

- [ ] **Step 2: Create LyricsWidgetDataTests.swift**

Create `LyricsXPackage/Tests/LyricsXWidgetSharedTests/LyricsWidgetDataTests.swift`:

```swift
import Testing
import Foundation
@testable import LyricsXWidgetShared

@Suite("LyricsWidgetData Serialization")
struct LyricsWidgetDataTests {
    @Test("Round-trip encode/decode preserves all fields")
    func roundTripEncoding() throws {
        let original = LyricsWidgetData(
            trackTitle: "Test Song",
            artist: "Test Artist",
            albumName: "Test Album",
            backgroundColor: CodableColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1.0),
            lyricsLines: [
                LyricsLineEntry(text: "First line", translation: "第一行", startTime: 10.5, endTime: 15.0),
                LyricsLineEntry(text: "Second line", translation: nil, startTime: 15.0, endTime: 20.0),
            ],
            currentLineIndex: 0,
            isPlaying: true,
            timestamp: Date(timeIntervalSince1970: 1000),
            playbackPosition: 10.5,
            availableTranslationLanguages: ["zh-Hans", "ja"]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LyricsWidgetData.self, from: encoded)

        #expect(decoded.trackTitle == "Test Song")
        #expect(decoded.artist == "Test Artist")
        #expect(decoded.albumName == "Test Album")
        #expect(decoded.backgroundColor?.red == 0.2)
        #expect(decoded.backgroundColor?.green == 0.4)
        #expect(decoded.backgroundColor?.blue == 0.6)
        #expect(decoded.lyricsLines.count == 2)
        #expect(decoded.lyricsLines[0].text == "First line")
        #expect(decoded.lyricsLines[0].translation == "第一行")
        #expect(decoded.lyricsLines[0].startTime == 10.5)
        #expect(decoded.lyricsLines[1].translation == nil)
        #expect(decoded.currentLineIndex == 0)
        #expect(decoded.isPlaying == true)
        #expect(decoded.playbackPosition == 10.5)
        #expect(decoded.availableTranslationLanguages == ["zh-Hans", "ja"])
    }

    @Test("Encode/decode with nil optional fields")
    func nilOptionalFields() throws {
        let original = LyricsWidgetData(
            trackTitle: "Song",
            artist: "Artist",
            albumName: nil,
            backgroundColor: nil,
            lyricsLines: [],
            currentLineIndex: 0,
            isPlaying: false,
            timestamp: Date(),
            playbackPosition: 0,
            availableTranslationLanguages: []
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LyricsWidgetData.self, from: encoded)

        #expect(decoded.albumName == nil)
        #expect(decoded.backgroundColor == nil)
        #expect(decoded.lyricsLines.isEmpty)
    }
}
```

- [ ] **Step 3: Create WidgetDataStoreTests.swift**

Create `LyricsXPackage/Tests/LyricsXWidgetSharedTests/WidgetDataStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import LyricsXWidgetShared

@Suite("WidgetDataStore")
struct WidgetDataStoreTests {
    // Use a unique suite name to avoid conflicts with other tests
    private static let testSuiteName = "com.test.LyricsXWidgetSharedTests.\(UUID().uuidString)"

    @Test("Write and read round-trip")
    func writeAndRead() throws {
        let store = WidgetDataStore(groupIdentifier: WidgetDataStoreTests.testSuiteName)
        let data = LyricsWidgetData(
            trackTitle: "Hello",
            artist: "World",
            albumName: nil,
            backgroundColor: nil,
            lyricsLines: [
                LyricsLineEntry(text: "Line 1", translation: nil, startTime: 0, endTime: 5),
            ],
            currentLineIndex: 0,
            isPlaying: true,
            timestamp: Date(timeIntervalSince1970: 500),
            playbackPosition: 2.0,
            availableTranslationLanguages: []
        )

        try store.write(data)
        let readBack = store.read()

        #expect(readBack != nil)
        #expect(readBack?.trackTitle == "Hello")
        #expect(readBack?.artist == "World")
        #expect(readBack?.lyricsLines.count == 1)
    }

    @Test("Read returns nil when no data written")
    func readEmpty() {
        let store = WidgetDataStore(groupIdentifier: "com.test.nonexistent.\(UUID().uuidString)")
        #expect(store.read() == nil)
    }

    @Test("Clear removes data")
    func clearData() throws {
        let store = WidgetDataStore(groupIdentifier: WidgetDataStoreTests.testSuiteName)
        let data = LyricsWidgetData(
            trackTitle: "Song",
            artist: "Artist",
            albumName: nil,
            backgroundColor: nil,
            lyricsLines: [],
            currentLineIndex: 0,
            isPlaying: false,
            timestamp: Date(),
            playbackPosition: 0,
            availableTranslationLanguages: []
        )

        try store.write(data)
        #expect(store.read() != nil)

        store.clear()
        #expect(store.read() == nil)
    }
}
```

- [ ] **Step 4: Run tests**

Run:
```bash
cd LyricsXPackage && swift test --filter LyricsXWidgetSharedTests
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add LyricsXPackage/Package.swift \
       LyricsXPackage/Tests/LyricsXWidgetSharedTests/
git commit -m "test: add unit tests for LyricsXWidgetShared module"
```

---

## Task 3: Album Color Extraction

**Files:**
- Create: `LyricsX/Utility/AlbumColorExtractor.swift`

- [ ] **Step 1: Create AlbumColorExtractor.swift**

Create `LyricsX/Utility/AlbumColorExtractor.swift`:

```swift
import AppKit
import LyricsXWidgetShared

enum AlbumColorExtractor {
    /// Extract the dominant color from an image by scaling it down to 1x1 pixel.
    static func dominantColor(from image: NSImage) -> CodableColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = 1
        let height = 1
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixelData,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let red = Double(pixelData[0]) / 255.0
        let green = Double(pixelData[1]) / 255.0
        let blue = Double(pixelData[2]) / 255.0
        let alpha = Double(pixelData[3]) / 255.0

        // Darken the color slightly for a better background effect
        let darkenFactor = 0.6
        return CodableColor(
            red: red * darkenFactor,
            green: green * darkenFactor,
            blue: blue * darkenFactor,
            alpha: alpha
        )
    }

    /// Compress an NSImage to JPEG data suitable for the widget cover file.
    static func compressedCoverData(from image: NSImage, maxDimension: CGFloat = 200) -> Data? {
        let originalSize = image.size
        let scaleFactor: CGFloat
        if originalSize.width > originalSize.height {
            scaleFactor = maxDimension / originalSize.width
        } else {
            scaleFactor = maxDimension / originalSize.height
        }

        let targetSize = NSSize(
            width: originalSize.width * scaleFactor,
            height: originalSize.height * scaleFactor
        )

        let resizedImage = NSImage(size: targetSize)
        resizedImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1.0
        )
        resizedImage.unlockFocus()

        guard let tiffData = resizedImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.7]
              ) else {
            return nil
        }

        return jpegData
    }
}
```

- [ ] **Step 2: Build the main app to verify**

Run:
```bash
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift
```

Expected: Build succeeds. (The file won't be referenced by Xcode yet until we add it via xcodeproj MCP in Task 7.)

Note: If the file is not yet added to the Xcode project, add it via xcodeproj MCP first, then build.

- [ ] **Step 3: Commit**

```bash
git add LyricsX/Utility/AlbumColorExtractor.swift
git commit -m "feat: add album dominant color extraction utility"
```

---

## Task 4: Widget Data Bridge in AppController

**Files:**
- Modify: `LyricsX/Component/AppController.swift`

This task adds Combine subscriptions to `AppController` that write widget data whenever the track, lyrics, lyric line, or playback state changes.

- [ ] **Step 1: Add WidgetKit and LyricsXWidgetShared imports**

At the top of `LyricsX/Component/AppController.swift`, add:

```swift
import WidgetKit
import LyricsXWidgetShared
```

Since the main app's deployment target is macOS 11 but `WidgetKit` is macOS 14+, wrap the widget-related code with `if #available(macOS 14, *)`.

- [ ] **Step 2: Add widgetDataStore property and widget update method**

Add after the `cancelBag` property:

```swift
private let widgetDataStore = WidgetDataStore(groupIdentifier: lyricsXGroupIdentifier)
```

Add a new method at the end of the `AppController` class:

```swift
func updateWidgetData() {
    guard #available(macOS 14, *) else { return }

    guard let track = selectedPlayer.currentTrack else {
        widgetDataStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
        return
    }

    let playbackState = selectedPlayer.playbackState
    let playbackTime = playbackState.time

    // Build lyrics lines with context window
    var lyricsLines: [LyricsLineEntry] = []
    var widgetCurrentLineIndex = 0
    var availableTranslationLanguages: [String] = []

    if let lyrics = currentLyrics {
        availableTranslationLanguages = lyrics.metadata.translationLanguages
        let enabledLines = lyrics.lines.enumerated().filter { $0.element.enabled }
        let contextRadius = 50
        let (currentIndex, _) = lyrics[playbackTime + lyrics.adjustedTimeDelay]

        // Find the position of currentIndex in enabledLines
        let enabledCurrentPosition = enabledLines.firstIndex { $0.offset == currentIndex } ?? 0

        let startPosition = max(0, enabledCurrentPosition - contextRadius)
        let endPosition = min(enabledLines.count - 1, enabledCurrentPosition + contextRadius)

        if startPosition <= endPosition {
            let windowSlice = enabledLines[startPosition...endPosition]
            lyricsLines = windowSlice.enumerated().map { windowIndex, indexedLine in
                let line = indexedLine.element
                let nextPosition = line.position  // startTime
                // Calculate endTime from the next enabled line
                let sliceArray = Array(windowSlice)
                let endTime: TimeInterval? = (windowIndex + 1 < sliceArray.count)
                    ? sliceArray[windowIndex + 1].element.position
                    : nil

                // Collect translations for all available languages
                let firstTranslationLanguage = availableTranslationLanguages.first
                let translation = firstTranslationLanguage.flatMap {
                    line.attachments[.translation(languageCode: $0)]
                }

                return LyricsLineEntry(
                    text: line.content,
                    translation: translation,
                    startTime: nextPosition,
                    endTime: endTime
                )
            }
            widgetCurrentLineIndex = enabledCurrentPosition - startPosition
        }
    }

    // Extract artwork color and cover data
    var backgroundColor: CodableColor?
    if let artwork = track.artwork {
        backgroundColor = AlbumColorExtractor.dominantColor(from: artwork)
        if let coverData = AlbumColorExtractor.compressedCoverData(from: artwork) {
            try? widgetDataStore.writeCover(coverData)
        }
    } else {
        widgetDataStore.clearCover()
    }

    let widgetData = LyricsWidgetData(
        trackTitle: track.title ?? "Unknown",
        artist: track.artist ?? "Unknown",
        albumName: track.album,
        backgroundColor: backgroundColor,
        lyricsLines: lyricsLines,
        currentLineIndex: widgetCurrentLineIndex,
        isPlaying: playbackState.isPlaying,
        timestamp: Date(),
        playbackPosition: playbackTime,
        availableTranslationLanguages: availableTranslationLanguages
    )

    try? widgetDataStore.write(widgetData)
    WidgetCenter.shared.reloadAllTimelines()
}
```

- [ ] **Step 3: Add Combine subscriptions in init()**

In `AppController.init()`, after the existing `workspaceNC` subscription (before `currentTrackChanged()`), add:

```swift
// Widget data bridge: update widget on lyrics or line changes
$currentLyrics
    .combineLatest($currentLineIndex)
    .debounce(for: .milliseconds(100), scheduler: DispatchQueue.lyricsDisplay)
    .sink { [weak self] _, _ in
        self?.updateWidgetData()
    }
    .store(in: &cancelBag)

selectedPlayer.playbackStateWillChange
    .signal()
    .receive(on: DispatchQueue.lyricsDisplay)
    .sink { [weak self] _ in
        self?.updateWidgetData()
    }
    .store(in: &cancelBag)
```

- [ ] **Step 4: Build to verify**

Run:
```bash
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift
```

Expected: Build succeeds. WidgetKit import may warn about availability but code is guarded.

- [ ] **Step 5: Commit**

```bash
git add LyricsX/Component/AppController.swift
git commit -m "feat: add widget data bridge in AppController"
```

---

## Task 5: Create Widget Extension Target in Xcode

**Files:**
- Create: `LyricsXWidget/Info.plist`
- Create: `LyricsXWidget/LyricsXWidget.entitlements`
- Modify: `LyricsX.xcodeproj/project.pbxproj` (via xcodeproj MCP)

This task sets up the Xcode project structure for the widget extension. Use **xcodeproj MCP** for all project file modifications.

- [ ] **Step 1: Create the LyricsXWidget directory**

```bash
mkdir -p LyricsXWidget
```

- [ ] **Step 2: Create Info.plist**

Create `LyricsXWidget/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleDisplayName</key>
    <string>LyricsX Widget</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
```

- [ ] **Step 3: Create entitlements file**

Create `LyricsXWidget/LyricsXWidget.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>$(TeamIdentifierPrefix)group.$(LX_BUNDLE_ID_PREFIX).LyricsX</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 4: Add widget extension target to Xcode project**

Use xcodeproj MCP to:

1. Create a new native target `LyricsXWidget` with product type `com.apple.product-type.app-extension`
2. Set build settings:
   - `PRODUCT_BUNDLE_IDENTIFIER`: Debug = `dev.JH.LyricsX.LyricsWidget`, Release = `com.JH.LyricsX.LyricsWidget`
   - `MACOSX_DEPLOYMENT_TARGET`: `15.0`
   - `INFOPLIST_FILE`: `LyricsXWidget/Info.plist`
   - `CODE_SIGN_ENTITLEMENTS`: `LyricsXWidget/LyricsXWidget.entitlements`
   - `CODE_SIGN_STYLE`: `Automatic`
   - `DEVELOPMENT_TEAM`: `D5Q73692VW`
   - `SWIFT_VERSION`: `5.0`
   - `GENERATE_INFOPLIST_FILE`: `NO`
   - `SKIP_INSTALL`: `YES`
   - `LD_RUNPATH_SEARCH_PATHS`: `$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks`
   - `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` matching the main app
3. Add `LyricsXWidgetShared` framework dependency to the widget target
4. Add a "Copy Widget Extension" build phase (Embed App Extensions) to the main `LyricsX` target:
   - Destination: `Contents/PlugIns/`
   - Product: `LyricsXWidget.appex`
5. Add all `LyricsXWidget/*.swift` source files to the target (will be created in subsequent tasks)

- [ ] **Step 5: Add LyricsXWidgetShared dependency to main app target**

Use xcodeproj MCP to add `LyricsXWidgetShared` package product as a framework dependency of the `LyricsX` main app target.

- [ ] **Step 6: Commit**

```bash
git add LyricsXWidget/Info.plist LyricsXWidget/LyricsXWidget.entitlements LyricsX.xcodeproj/
git commit -m "chore: add LyricsXWidget extension target to Xcode project"
```

---

## Task 6: Timeline Entry and Provider

**Files:**
- Create: `LyricsXWidget/LyricsTimelineEntry.swift`
- Create: `LyricsXWidget/LyricsTimelineProvider.swift`

- [ ] **Step 1: Create LyricsTimelineEntry.swift**

Create `LyricsXWidget/LyricsTimelineEntry.swift`:

```swift
import WidgetKit
import LyricsXWidgetShared

struct LyricsTimelineEntry: TimelineEntry {
    let date: Date
    let trackTitle: String
    let artist: String
    let albumName: String?
    let backgroundColor: CodableColor?
    let coverImageURL: URL?
    let lyricsLines: [LyricsLineEntry]
    let highlightedLineIndex: Int
    let isPlaying: Bool
    let showTranslation: Bool
    let translationLanguage: String?
    let isEmpty: Bool

    static var empty: LyricsTimelineEntry {
        LyricsTimelineEntry(
            date: Date(),
            trackTitle: "",
            artist: "",
            albumName: nil,
            backgroundColor: nil,
            coverImageURL: nil,
            lyricsLines: [],
            highlightedLineIndex: 0,
            isPlaying: false,
            showTranslation: false,
            translationLanguage: nil,
            isEmpty: true
        )
    }
}
```

- [ ] **Step 2: Create LyricsTimelineProvider.swift**

Create `LyricsXWidget/LyricsTimelineProvider.swift`:

```swift
import WidgetKit
import LyricsXWidgetShared

struct LyricsTimelineProvider: AppIntentTimelineProvider {
    private let dataStore: WidgetDataStore

    init() {
        #if DEBUG
        let groupIdentifier = "D5Q73692VW.group.dev.JH.LyricsX"
        #else
        let groupIdentifier = "D5Q73692VW.group.com.JH.LyricsX"
        #endif
        self.dataStore = WidgetDataStore(groupIdentifier: groupIdentifier)
    }

    func placeholder(in context: Context) -> LyricsTimelineEntry {
        LyricsTimelineEntry(
            date: Date(),
            trackTitle: "Song Title",
            artist: "Artist",
            albumName: "Album",
            backgroundColor: CodableColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0),
            coverImageURL: nil,
            lyricsLines: [
                LyricsLineEntry(text: "Lyrics will appear here", translation: nil, startTime: 0, endTime: nil),
            ],
            highlightedLineIndex: 0,
            isPlaying: true,
            showTranslation: false,
            translationLanguage: nil,
            isEmpty: false
        )
    }

    func snapshot(for configuration: LyricsWidgetConfigurationIntent, in context: Context) async -> LyricsTimelineEntry {
        buildCurrentEntry(for: configuration, at: Date())
    }

    func timeline(for configuration: LyricsWidgetConfigurationIntent, in context: Context) async -> Timeline<LyricsTimelineEntry> {
        guard let widgetData = dataStore.read(), widgetData.isPlaying else {
            // Not playing or no data: single static entry
            let entry = buildCurrentEntry(for: configuration, at: Date())
            return Timeline(entries: [entry], policy: .never)
        }

        // Build time-driven entries from lyrics lines
        let coverURL = dataStore.coverURL
        let showTranslation = configuration.showTranslation
        let translationLanguage = configuration.translationLanguage?.id

        var entries: [LyricsTimelineEntry] = []
        let now = Date()

        for (lineIndex, line) in widgetData.lyricsLines.enumerated() {
            // Calculate when this line should be displayed
            let lineOffset = line.startTime - widgetData.playbackPosition
            let entryDate = widgetData.timestamp.addingTimeInterval(lineOffset)

            // Skip entries in the past (except the most recent one)
            if entryDate < now && lineIndex < widgetData.lyricsLines.count - 1 {
                let nextLineOffset = widgetData.lyricsLines[lineIndex + 1].startTime - widgetData.playbackPosition
                let nextEntryDate = widgetData.timestamp.addingTimeInterval(nextLineOffset)
                if nextEntryDate < now {
                    continue
                }
            }

            let entry = LyricsTimelineEntry(
                date: max(entryDate, now),
                trackTitle: widgetData.trackTitle,
                artist: widgetData.artist,
                albumName: widgetData.albumName,
                backgroundColor: widgetData.backgroundColor,
                coverImageURL: coverURL,
                lyricsLines: widgetData.lyricsLines,
                highlightedLineIndex: lineIndex,
                isPlaying: widgetData.isPlaying,
                showTranslation: showTranslation,
                translationLanguage: translationLanguage,
                isEmpty: false
            )
            entries.append(entry)
        }

        if entries.isEmpty {
            let entry = buildCurrentEntry(for: configuration, at: now)
            return Timeline(entries: [entry], policy: .never)
        }

        return Timeline(entries: entries, policy: .never)
    }

    private func buildCurrentEntry(for configuration: LyricsWidgetConfigurationIntent, at date: Date) -> LyricsTimelineEntry {
        guard let widgetData = dataStore.read() else {
            return .empty
        }

        return LyricsTimelineEntry(
            date: date,
            trackTitle: widgetData.trackTitle,
            artist: widgetData.artist,
            albumName: widgetData.albumName,
            backgroundColor: widgetData.backgroundColor,
            coverImageURL: dataStore.coverURL,
            lyricsLines: widgetData.lyricsLines,
            highlightedLineIndex: widgetData.currentLineIndex,
            isPlaying: widgetData.isPlaying,
            showTranslation: configuration.showTranslation,
            translationLanguage: configuration.translationLanguage?.id,
            isEmpty: false
        )
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add LyricsXWidget/LyricsTimelineEntry.swift LyricsXWidget/LyricsTimelineProvider.swift
git commit -m "feat: implement widget TimelineEntry and TimelineProvider"
```

---

## Task 7: Widget Configuration and Translation Entity

**Files:**
- Create: `LyricsXWidget/Configuration/LyricsWidgetConfigurationIntent.swift`
- Create: `LyricsXWidget/Configuration/TranslationLanguage.swift`

- [ ] **Step 1: Create TranslationLanguage.swift**

Create `LyricsXWidget/Configuration/TranslationLanguage.swift`:

```swift
import AppIntents
import LyricsXWidgetShared

struct TranslationLanguage: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Translation Language"
    static var defaultQuery = TranslationLanguageQuery()

    var id: String
    var displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

struct TranslationLanguageQuery: EntityQuery {
    private var dataStore: WidgetDataStore {
        #if DEBUG
        let groupIdentifier = "D5Q73692VW.group.dev.JH.LyricsX"
        #else
        let groupIdentifier = "D5Q73692VW.group.com.JH.LyricsX"
        #endif
        return WidgetDataStore(groupIdentifier: groupIdentifier)
    }

    func entities(for identifiers: [String]) async throws -> [TranslationLanguage] {
        let available = availableLanguages()
        return available.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TranslationLanguage] {
        availableLanguages()
    }

    private func availableLanguages() -> [TranslationLanguage] {
        guard let widgetData = dataStore.read() else { return [] }
        return widgetData.availableTranslationLanguages.map { languageCode in
            let displayName = Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode
            return TranslationLanguage(id: languageCode, displayName: displayName)
        }
    }
}
```

- [ ] **Step 2: Create LyricsWidgetConfigurationIntent.swift**

Create `LyricsXWidget/Configuration/LyricsWidgetConfigurationIntent.swift`:

```swift
import AppIntents
import WidgetKit

struct LyricsWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "LyricsX Widget"
    static var description: IntentDescription = "Display current song lyrics"

    @Parameter(title: "Show Translation", default: false)
    var showTranslation: Bool

    @Parameter(title: "Translation Language")
    var translationLanguage: TranslationLanguage?
}
```

- [ ] **Step 3: Commit**

```bash
git add LyricsXWidget/Configuration/
git commit -m "feat: add widget configuration intent and translation entity"
```

---

## Task 8: Playback Control Intents

**Files:**
- Create: `LyricsX/Intents/WidgetPlaybackIntents.swift` (shared between both targets)

Intent structs must be compiled into both the main app and widget extension so the AppIntents framework can route them. Use a single shared file with conditional compilation: the main app compiles the full `perform()` with `MusicPlayer`, while the widget extension compiles a no-op stub.

- [ ] **Step 1: Add WIDGET_EXTENSION compilation condition to widget target**

Via xcodeproj MCP, set `SWIFT_ACTIVE_COMPILATION_CONDITIONS = WIDGET_EXTENSION` on the `LyricsXWidget` target (both Debug and Release).

- [ ] **Step 2: Create WidgetPlaybackIntents.swift**

Create `LyricsX/Intents/WidgetPlaybackIntents.swift`. Add this file to **both** the `LyricsX` and `LyricsXWidget` targets in Xcode.

```swift
import AppIntents
#if !WIDGET_EXTENSION
import MusicPlayer
#endif

struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play/Pause"
    static var description: IntentDescription = "Toggle music playback"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run {
            MusicPlayers.Selected.shared.playPause()
        }
        #endif
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description: IntentDescription = "Skip to next track"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run {
            MusicPlayers.Selected.shared.skipToNextItem()
        }
        #endif
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description: IntentDescription = "Skip to previous track"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run {
            MusicPlayers.Selected.shared.skipToPreviousItem()
        }
        #endif
        return .result()
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add LyricsX/Intents/WidgetPlaybackIntents.swift
git commit -m "feat: add playback control AppIntents for widget"
```

---

## Task 9: Widget Views — Shared Components

**Files:**
- Create: `LyricsXWidget/Utilities/ColorExtensions.swift`
- Create: `LyricsXWidget/Views/LyricsLineView.swift`
- Create: `LyricsXWidget/Views/PlaybackControlView.swift`
- Create: `LyricsXWidget/Views/EmptyStateView.swift`

- [ ] **Step 1: Create ColorExtensions.swift**

Create `LyricsXWidget/Utilities/ColorExtensions.swift`:

```swift
import SwiftUI
import LyricsXWidgetShared

extension CodableColor {
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var gradientColors: [Color] {
        let baseColor = swiftUIColor
        let darkerColor = Color(red: red * 0.5, green: green * 0.5, blue: blue * 0.5, opacity: alpha)
        return [baseColor, darkerColor]
    }
}

extension Color {
    static let widgetDefaultBackground = Color(red: 0.1, green: 0.1, blue: 0.12)
    static let widgetDefaultBackgroundDarker = Color(red: 0.05, green: 0.05, blue: 0.07)

    static var defaultGradientColors: [Color] {
        [.widgetDefaultBackground, .widgetDefaultBackgroundDarker]
    }
}
```

- [ ] **Step 2: Create LyricsLineView.swift**

Create `LyricsXWidget/Views/LyricsLineView.swift`:

```swift
import SwiftUI
import LyricsXWidgetShared

struct LyricsLineView: View {
    let line: LyricsLineEntry
    let isHighlighted: Bool
    let showTranslation: Bool
    let translationLanguage: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(line.text)
                .font(.system(size: isHighlighted ? 18 : 14, weight: isHighlighted ? .bold : .medium))
                .foregroundStyle(.white.opacity(isHighlighted ? 1.0 : 0.4))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if showTranslation, let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: isHighlighted ? 14 : 11, weight: .regular))
                    .foregroundStyle(.white.opacity(isHighlighted ? 0.8 : 0.3))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
```

- [ ] **Step 3: Create PlaybackControlView.swift**

Create `LyricsXWidget/Views/PlaybackControlView.swift`:

```swift
import SwiftUI
import AppIntents

struct PlaybackControlView: View {
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 32) {
            Button(intent: PreviousTrackIntent()) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Button(intent: PlayPauseIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)

            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }
}
```

- [ ] **Step 4: Create EmptyStateView.swift**

Create `LyricsXWidget/Views/EmptyStateView.swift`:

```swift
import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.4))
            Text("Not Playing")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add LyricsXWidget/Utilities/ LyricsXWidget/Views/LyricsLineView.swift \
       LyricsXWidget/Views/PlaybackControlView.swift LyricsXWidget/Views/EmptyStateView.swift
git commit -m "feat: add shared widget view components"
```

---

## Task 10: Widget Views — Size-Specific Layouts

**Files:**
- Create: `LyricsXWidget/Views/SmallWidgetView.swift`
- Create: `LyricsXWidget/Views/MediumWidgetView.swift`
- Create: `LyricsXWidget/Views/LargeWidgetView.swift`
- Create: `LyricsXWidget/Views/ExtraLargeWidgetView.swift`

- [ ] **Step 1: Create SmallWidgetView.swift**

Create `LyricsXWidget/Views/SmallWidgetView.swift`:

```swift
import SwiftUI
import WidgetKit
import LyricsXWidgetShared

struct SmallWidgetView: View {
    let entry: LyricsTimelineEntry

    var body: some View {
        if entry.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(gradientBackground)
        } else {
            ZStack(alignment: .bottomLeading) {
                // Album cover as blurred background
                if let coverURL = entry.coverImageURL,
                   let nsImage = NSImage(contentsOf: coverURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 20)
                        .overlay(Color.black.opacity(0.4))
                } else {
                    gradientBackground
                }

                // Song info overlay at bottom
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.trackTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(entry.artist)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .padding(12)
            }
        }
    }

    private var gradientBackground: some View {
        LinearGradient(
            colors: entry.backgroundColor?.gradientColors ?? Color.defaultGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
```

- [ ] **Step 2: Create MediumWidgetView.swift**

Create `LyricsXWidget/Views/MediumWidgetView.swift`:

```swift
import SwiftUI
import WidgetKit
import LyricsXWidgetShared

struct MediumWidgetView: View {
    let entry: LyricsTimelineEntry

    var body: some View {
        if entry.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(gradientBackground)
        } else {
            HStack(spacing: 12) {
                // Album cover
                if let coverURL = entry.coverImageURL,
                   let nsImage = NSImage(contentsOf: coverURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 80, height: 80)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                }

                // Song info and current lyric
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.trackTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(entry.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }

                    if !entry.lyricsLines.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            // Current line
                            if entry.highlightedLineIndex < entry.lyricsLines.count {
                                let currentLine = entry.lyricsLines[entry.highlightedLineIndex]
                                Text(currentLine.text)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(1)

                                if entry.showTranslation,
                                   let translation = currentLine.translation,
                                   !translation.isEmpty {
                                    Text(translation)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.6))
                                        .lineLimit(1)
                                }
                            }

                            // Next line
                            let nextIndex = entry.highlightedLineIndex + 1
                            if nextIndex < entry.lyricsLines.count {
                                Text(entry.lyricsLines[nextIndex].text)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.35))
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(gradientBackground)
        }
    }

    private var gradientBackground: some View {
        LinearGradient(
            colors: entry.backgroundColor?.gradientColors ?? Color.defaultGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
```

- [ ] **Step 3: Create LargeWidgetView.swift**

Create `LyricsXWidget/Views/LargeWidgetView.swift`:

```swift
import SwiftUI
import WidgetKit
import LyricsXWidgetShared

struct LargeWidgetView: View {
    let entry: LyricsTimelineEntry

    private let visibleLineCount = 7

    var body: some View {
        if entry.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(gradientBackground)
        } else {
            VStack(spacing: 0) {
                // Song info header
                HStack {
                    Text("\(entry.trackTitle) — \(entry.artist)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                Spacer(minLength: 8)

                // Lyrics lines
                if !entry.lyricsLines.isEmpty {
                    lyricsSection
                } else {
                    Text("No Lyrics")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer(minLength: 8)

                // Playback controls
                PlaybackControlView(isPlaying: entry.isPlaying)
                    .padding(.bottom, 14)
            }
            .background(gradientBackground)
        }
    }

    private var lyricsSection: some View {
        let halfWindow = visibleLineCount / 2
        let startIndex = max(0, entry.highlightedLineIndex - halfWindow)
        let endIndex = min(entry.lyricsLines.count - 1, startIndex + visibleLineCount - 1)
        let adjustedStartIndex = max(0, endIndex - visibleLineCount + 1)

        return VStack(spacing: 6) {
            ForEach(adjustedStartIndex...endIndex, id: \.self) { lineIndex in
                let line = entry.lyricsLines[lineIndex]
                let isHighlighted = (lineIndex == entry.highlightedLineIndex)
                LyricsLineView(
                    line: line,
                    isHighlighted: isHighlighted,
                    showTranslation: entry.showTranslation && isHighlighted,
                    translationLanguage: entry.translationLanguage
                )
            }
        }
        .padding(.horizontal, 16)
    }

    private var gradientBackground: some View {
        LinearGradient(
            colors: entry.backgroundColor?.gradientColors ?? Color.defaultGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
```

- [ ] **Step 4: Create ExtraLargeWidgetView.swift**

Create `LyricsXWidget/Views/ExtraLargeWidgetView.swift`:

```swift
import SwiftUI
import WidgetKit
import LyricsXWidgetShared

struct ExtraLargeWidgetView: View {
    let entry: LyricsTimelineEntry

    private let visibleLineCount = 9

    var body: some View {
        if entry.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(gradientBackground)
        } else {
            VStack(spacing: 0) {
                // Header with album art and song info
                HStack(spacing: 12) {
                    if let coverURL = entry.coverImageURL,
                       let nsImage = NSImage(contentsOf: coverURL) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.trackTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 0) {
                            Text(entry.artist)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                            if let albumName = entry.albumName {
                                Text(" — \(albumName)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer(minLength: 12)

                // Lyrics lines with translation
                if !entry.lyricsLines.isEmpty {
                    lyricsSection
                } else {
                    Text("No Lyrics")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer(minLength: 12)

                // Playback controls
                PlaybackControlView(isPlaying: entry.isPlaying)
                    .padding(.bottom, 16)
            }
            .background(gradientBackground)
        }
    }

    private var lyricsSection: some View {
        let halfWindow = visibleLineCount / 2
        let startIndex = max(0, entry.highlightedLineIndex - halfWindow)
        let endIndex = min(entry.lyricsLines.count - 1, startIndex + visibleLineCount - 1)
        let adjustedStartIndex = max(0, endIndex - visibleLineCount + 1)

        return VStack(spacing: 8) {
            ForEach(adjustedStartIndex...endIndex, id: \.self) { lineIndex in
                let line = entry.lyricsLines[lineIndex]
                let isHighlighted = (lineIndex == entry.highlightedLineIndex)
                LyricsLineView(
                    line: line,
                    isHighlighted: isHighlighted,
                    showTranslation: entry.showTranslation,
                    translationLanguage: entry.translationLanguage
                )
            }
        }
        .padding(.horizontal, 20)
    }

    private var gradientBackground: some View {
        LinearGradient(
            colors: entry.backgroundColor?.gradientColors ?? Color.defaultGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add LyricsXWidget/Views/SmallWidgetView.swift \
       LyricsXWidget/Views/MediumWidgetView.swift \
       LyricsXWidget/Views/LargeWidgetView.swift \
       LyricsXWidget/Views/ExtraLargeWidgetView.swift
git commit -m "feat: implement all four widget size layouts"
```

---

## Task 11: Widget Entry Point

**Files:**
- Create: `LyricsXWidget/LyricsXWidget.swift`

- [ ] **Step 1: Create LyricsXWidget.swift**

Create `LyricsXWidget/LyricsXWidget.swift`:

```swift
import WidgetKit
import SwiftUI

@main
struct LyricsXWidgetBundle: WidgetBundle {
    var body: some Widget {
        LyricsWidget()
    }
}

struct LyricsWidget: Widget {
    let kind = "com.JH.LyricsX.LyricsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: LyricsWidgetConfigurationIntent.self,
            provider: LyricsTimelineProvider()
        ) { entry in
            LyricsWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    // Container background handled inside each view
                    Color.clear
                }
        }
        .configurationDisplayName("LyricsX")
        .description("Display current song lyrics")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct LyricsWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    let entry: LyricsTimelineEntry

    var body: some View {
        switch widgetFamily {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        case .systemExtraLarge:
            ExtraLargeWidgetView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    LyricsWidget()
} timeline: {
    LyricsTimelineEntry(
        date: Date(),
        trackTitle: "Bohemian Rhapsody",
        artist: "Queen",
        albumName: "A Night at the Opera",
        backgroundColor: CodableColor(red: 0.15, green: 0.1, blue: 0.25, alpha: 1.0),
        coverImageURL: nil,
        lyricsLines: [],
        highlightedLineIndex: 0,
        isPlaying: true,
        showTranslation: false,
        translationLanguage: nil,
        isEmpty: false
    )
}

#Preview("Large", as: .systemLarge) {
    LyricsWidget()
} timeline: {
    LyricsTimelineEntry(
        date: Date(),
        trackTitle: "Bohemian Rhapsody",
        artist: "Queen",
        albumName: "A Night at the Opera",
        backgroundColor: CodableColor(red: 0.15, green: 0.1, blue: 0.25, alpha: 1.0),
        coverImageURL: nil,
        lyricsLines: [
            LyricsLineEntry(text: "Is this the real life?", translation: nil, startTime: 0, endTime: 5),
            LyricsLineEntry(text: "Is this just fantasy?", translation: nil, startTime: 5, endTime: 10),
            LyricsLineEntry(text: "Caught in a landslide", translation: nil, startTime: 10, endTime: 15),
            LyricsLineEntry(text: "No escape from reality", translation: nil, startTime: 15, endTime: 20),
            LyricsLineEntry(text: "Open your eyes", translation: nil, startTime: 20, endTime: 25),
            LyricsLineEntry(text: "Look up to the skies and see", translation: nil, startTime: 25, endTime: 30),
            LyricsLineEntry(text: "I'm just a poor boy", translation: nil, startTime: 30, endTime: 35),
        ],
        highlightedLineIndex: 3,
        isPlaying: true,
        showTranslation: false,
        translationLanguage: nil,
        isEmpty: false
    )
}
```

- [ ] **Step 2: Commit**

```bash
git add LyricsXWidget/LyricsXWidget.swift
git commit -m "feat: add widget entry point with size routing and previews"
```

---

## Task 12: Integration Build and Verification

**Files:** No new files. This task verifies everything builds together.

- [ ] **Step 1: Ensure all widget source files are added to the Xcode project**

Use xcodeproj MCP to verify all `.swift` files under `LyricsXWidget/` are added to the `LyricsXWidget` target. Also verify `LyricsX/Utility/AlbumColorExtractor.swift` and `LyricsX/Intents/WidgetPlaybackIntents.swift` are in the `LyricsX` main app target, and that `WidgetPlaybackIntents.swift` is also in the `LyricsXWidget` target.

- [ ] **Step 2: Build the SPM package**

Run:
```bash
cd LyricsXPackage && swift build
```

Expected: Build succeeds.

- [ ] **Step 3: Run SPM tests**

Run:
```bash
cd LyricsXPackage && swift test --filter LyricsXWidgetSharedTests
```

Expected: All tests pass.

- [ ] **Step 4: Build the main app with widget**

Run:
```bash
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift
```

Expected: Build succeeds with both the main app and widget extension compiled.

- [ ] **Step 5: Verify widget extension is embedded**

Run:
```bash
ls -la "$(xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $3}')/LyricsX.app/Contents/PlugIns/"
```

Expected: `LyricsXWidget.appex` is present.

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "feat: complete desktop widget integration"
```
