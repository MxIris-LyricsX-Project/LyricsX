# Menu Bar Playback Controls — Design

**Date:** 2026-04-19
**Status:** Draft
**Scope:** Add previous / play-pause / next playback controls to the menu bar lyrics status item.

## Summary

Embed three playback control buttons (previous, play/pause, next) inside the existing `lyricStatusItem` to the right of the `MarqueeLabel`. The lyrics text keeps its current width; the status item widens to host the buttons. A new preference toggle (default enabled) governs whether the controls appear.

## Goals

- Provide quick playback control next to the menu bar lyrics without leaving the menu bar.
- Preserve the current interaction where clicking the lyrics region pops up `statusBarMenu` (left or right click).
- Keep the lyrics text width unchanged to avoid visual regression.
- Reflect the player's state (play vs pause icon, enabled vs disabled) in real time.

## Non-Goals

- No controls on the icon-only `iconStatusItem` path (when `menuBarLyricsEnabled == false`).
- No additional playback gestures (scrubbing, volume) — only the three buttons.
- No independent control button when the combined/separate display mode changes (the same buttons are reused in both modes).

## User Decisions (from brainstorming)

| # | Decision |
|---|---|
| Placement | Inside `lyricStatusItem`, right of the lyrics. Lyrics width unchanged; total width grows. |
| Controls visibility tied to lyrics | Controls appear only when menu bar lyrics are enabled. When menu bar lyrics are disabled, the icon-only item shows no controls. |
| "Previous" semantics | Plain `skipToPreviousItem()` — one click always goes to the previous track. |
| Lyrics region click behavior | Both left- and right-click on the lyrics area pop up `statusBarMenu` (current behavior preserved). |
| Icon style | SF Symbols filled: `backward.fill`, `play.fill` ↔ `pause.fill`, `forward.fill`. |
| No current track | Buttons disabled (greyed out). |
| Preference toggle | New `MenuBarPlaybackControlsEnabled` key, default `true`, surfaced as a checkbox in the General preference pane. |

## Architecture

### Overview

```
┌───────────────────────── lyricStatusItem.button (NSStatusBarButton) ─────────────────────────┐
│                                                                                              │
│  ┌────────────── MarqueeLabel (183×22) ──────────────┐  ┌◀◀┐ ┌▶▋┐ ┌▶▶┐                       │
│  │                                                    │  │  │ │  │ │  │                      │
│  │  歌词跑马灯内容                                      │  │prev│ │p/p│ │next│                    │
│  │                                                    │  │  │ │  │ │  │                      │
│  └────────────────────────────────────────────────────┘  └──┘ └──┘ └──┘                      │
│     ↑ click: hitTest returns MarqueeLabel                ↑ click: hitTest returns NSButton   │
│       mouseDown does not consume → event bubbles           NSButton consumes → action fires;  │
│       to NSStatusBarButton → statusItem.menu pops          menu does NOT pop                  │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

  width = 183                                          + 6 (gap) + 3 × 22 (buttons) = 255
```

- `lyricStatusItem.length` remains `NSStatusItem.variableLength`. The total width naturally follows from `button.frame.width`.
- The three control buttons are plain `NSButton` instances added as subviews of `NSStatusBarButton` (the `button` property is read-only, but `addSubview` is fine — the existing code already uses this pattern for `marqueeLabel`).
- Hit testing uses `NSView`'s default recursive behavior — no custom `hitTest(_:)` override is needed.

### Affected Files

| File | Change |
|---|---|
| `LyricsX/Utility/Global.swift` | Add `menuBarPlaybackControlsEnabled` `DefaultsKey` and register default value `true`. |
| `LyricsX/Controller/MenuBarLyricsController.swift` | Add the three buttons, layout logic, state subscriptions, action handlers. |
| `LyricsX/Base.lproj/Preferences.storyboard` | **(User handles manually)** Add checkbox bound to `values.MenuBarPlaybackControlsEnabled` in the General pane. |
| `LyricsX/Base.lproj/*.strings` / `.xcstrings` | New localization entry: "Show playback controls in menu bar" (and zh-Hans translation). |

## Component Design

### Global.swift

```swift
// Menu
static let desktopLyricsEnabled = Key<Bool>("DesktopLyricsEnabled")
static let menuBarLyricsEnabled = Key<Bool>("MenuBarLyricsEnabled")
static let touchBarLyricsEnabled = Key<Bool>("TouchBarLyricsEnabled")
static let menuBarPlaybackControlsEnabled = Key<Bool>("MenuBarPlaybackControlsEnabled") // new
```

In `registerUserDefaults()`:

```swift
defaults.register(defaults: [
    // ...
    .menuBarPlaybackControlsEnabled: true,
])
```

### MenuBarLyricsController

#### New properties

```swift
private let previousButton = NSButton()
private let playPauseButton = NSButton()
private let nextButton = NSButton()

private static let controlButtonSize: CGFloat = 22
private static let lyricsToControlsGap: CGFloat = 6
// Buttons are laid out edge-to-edge (spacing = 0) for a compact look.
```

#### New methods

- `setupControlButtons()` — one-time configuration: SF Symbol images, `isBordered = false`, `imageScaling = .scaleProportionallyDown`, target/action. Stores buttons in an array for iteration.
- `layoutLyricStatusItemContents()` — recomputes `button.frame`, button subview frames, adds/removes control buttons based on `controlsVisible`.
- `updatePlayPauseIcon()` — sets `playPauseButton.image` based on `selectedPlayer.playbackState.isPlaying`.
- `updateButtonsEnabledState()` — sets `isEnabled` on all three buttons based on `selectedPlayer.currentTrack != nil`.

#### Actions

```swift
@objc private func previousAction() { selectedPlayer.skipToPreviousItem() }
@objc private func playPauseAction() { selectedPlayer.playPause() }
@objc private func nextAction() { selectedPlayer.skipToNextItem() }
```

#### Visibility rule

```swift
private var controlsVisible: Bool {
    defaults[.menuBarLyricsEnabled]
        && defaults[.menuBarPlaybackControlsEnabled]
        && !defaults[.hideMenuBarItems]
}
```

#### Layout rule

```swift
let width: CGFloat = controlsVisible ? (183 + 6 + 3 * 22) : 183
button.frame = CGRect(x: 0, y: 0, width: width, height: 22)
marqueeLabel.frame = CGRect(x: 0, y: 0, width: 183, height: 22)

if controlsVisible {
    previousButton.frame  = CGRect(x: 189, y: 0, width: 22, height: 22)
    playPauseButton.frame = CGRect(x: 211, y: 0, width: 22, height: 22)
    nextButton.frame      = CGRect(x: 233, y: 0, width: 22, height: 22)
    // Add to button.subviews if not already present
} else {
    // Remove from superview if present
}
```

### Subscriptions (in `init()`)

Add to the existing `cancelBag`:

```swift
selectedPlayer.playbackStateWillChange
    .signal()
    .receive(on: DispatchQueue.lyricsDisplay)
    .invoke(MenuBarLyricsController.updatePlayPauseIcon, weaklyOn: self)
    .store(in: &cancelBag)

selectedPlayer.currentTrackWillChange
    .signal()
    .receive(on: DispatchQueue.lyricsDisplay)
    .invoke(MenuBarLyricsController.updateButtonsEnabledState, weaklyOn: self)
    .store(in: &cancelBag)

defaults.publisher(for: [.menuBarPlaybackControlsEnabled])
    .prepend()
    .invoke(MenuBarLyricsController.updateStatusItems, weaklyOn: self)
    .store(in: &cancelBag)
```

`updateStatusItems()` calls `layoutLyricStatusItemContents()` in the two paths that invoke `setupLyricStatusItem()` (both `updateSeparateStatusLyrics()` and `updateCombinedStatusLyrics()`).

## Data Flow

```
selectedPlayer.playbackStateWillChange
  → lyricsDisplay queue → updatePlayPauseIcon()

selectedPlayer.currentTrackWillChange
  → lyricsDisplay queue → updateButtonsEnabledState()

defaults.publisher(for: [.menuBarPlaybackControlsEnabled])
  → updateStatusItems() → layoutLyricStatusItemContents()

defaults.publisher(for: [.menuBarLyricsEnabled, .combinedMenubarLyrics, .hideMenuBarItems])
  (existing)
  → updateStatusItems() → layoutLyricStatusItemContents()

User click (previous/play-pause/next button)
  → NSButton consumes event → action handler → selectedPlayer.<method>
  → (statusItem.menu does NOT pop)

User click on lyrics region (left or right)
  → MarqueeLabel default mouseDown (does not consume)
  → NSStatusBarButton → NSStatusItem.menu pops statusBarMenu
```

## Hit Testing

`NSStatusItem.button` is read-only — it cannot be replaced — but it accepts `addSubview`. The recursive default `hitTest(_:)` of `NSView` handles dispatch:

- Click on a button region → `hitTest` returns the `NSButton` subview → `NSButton` handles `mouseDown:` and calls `sendAction` → event stops there.
- Click on the `MarqueeLabel` area → `hitTest` returns `MarqueeLabel` → its default `mouseDown:` does not consume → event bubbles to `NSStatusBarButton` → `NSStatusItem.menu` presents.

No custom `hitTest(_:)` override is required.

**Fallback (if needed in testing):** If `NSStatusBarButton` intercepts the event within the button region (unlikely given the existing subview pattern already works for `marqueeLabel`), we can route `NSStatusBarButton.action` through a dispatcher that uses `NSApp.currentEvent.locationInWindow` to decide whether to forward to a button action or pop the menu.

## Edge Cases

- **Lyrics → icon-only transition.** When `menuBarLyricsEnabled` turns off, `setupLyricStatusItem()` is not called; `lyricStatusItem` becomes `nil` and control buttons are implicitly gone with it. No extra cleanup needed.
- **Separate ↔ combined mode switch.** Both paths call `setupLyricStatusItem()` during transitions. The control buttons are re-added through `layoutLyricStatusItemContents()` on each fresh `lyricStatusItem`.
- **Runtime toggle of the preference.** The `defaults.publisher(for: [.menuBarPlaybackControlsEnabled])` subscription triggers `updateStatusItems()`, which reruns the layout. Buttons fade in/out live.
- **No current track.** `updateButtonsEnabledState()` sets `isEnabled = false` on all three. AppKit dims them automatically.
- **Play ↔ pause icon.** `updatePlayPauseIcon()` fires on every `playbackStateWillChange`. Uses SF Symbols filled (`play.fill` / `pause.fill`).
- **Combined mode.** The controls live inside `lyricStatusItem` regardless of combined/separate mode, so visibility rules remain uniform.

## Error Handling

Playback method calls go through `selectedPlayer` (`MusicPlayers.Selected`). Any failures are swallowed by the underlying provider; there's no UI error surface. This matches how `TouchBarPlaybackControlViewController` already calls the same methods.

## Testing

The project has no automated test target (`LyricsXFoundationTests` is empty). Verification is manual:

1. Launch with menu bar lyrics enabled + a supported player; verify the three buttons render to the right of the lyrics.
2. Click each button → previous/playpause/next fires on the current player.
3. Toggle the new preference → buttons appear/disappear without needing an app restart.
4. Toggle `menuBarLyricsEnabled` → buttons disappear with the lyrics item (icon-only mode shows nothing extra).
5. Switch `combinedMenubarLyrics` → buttons still render correctly in both modes.
6. Pause/play externally (via Now Playing Center or the player's own controls) → `playPauseButton` icon updates to match.
7. Stop playback / quit player (no current track) → buttons become disabled.
8. Left-click and right-click on the lyrics area → `statusBarMenu` pops both times.
9. Left-click on a button → action fires, menu does NOT pop.

## Localization

Add entries:

| Key | en | zh-Hans |
|---|---|---|
| `Show playback controls in menu bar` | Show playback controls in menu bar | 在状态栏显示播放控制 |

Surface via the existing `.xcstrings` and legacy `.strings` files used by the General preference pane.

## User-Handled Follow-Up

The storyboard edit in `LyricsX/Base.lproj/Preferences.storyboard` is left to the user: insert a new checkbox into the General pane's GridView after the "Combine menubar icon with menubar lyrics" row, bound to `values.MenuBarPlaybackControlsEnabled` via the same `userDefaultsController`.
