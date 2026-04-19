# Menu Bar Playback Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add previous / play-pause / next playback control buttons inside the menu bar lyrics status item, to the right of the existing marquee label, gated by a new preference toggle.

**Architecture:** Three `NSButton` subviews added to the read-only `lyricStatusItem.button` next to `marqueeLabel`. Lyrics width stays at 183pt; total status item width grows to 255pt when controls are visible. Combine subscriptions drive icon state (play/pause) and enabled state (current track presence). A new `MenuBarPlaybackControlsEnabled` preference controls visibility. Hit testing relies on `NSView`'s default recursion — `NSButton` subviews consume their own clicks so `statusItem.menu` still pops from the lyrics region.

**Tech Stack:** AppKit, Combine, SF Symbols (macOS 11+), `GenericID` (`DefaultsKey`), `MusicPlayer` package.

**Design Spec:** `docs/superpowers/specs/2026-04-19-menu-bar-playback-controls-design.md`

**Testing Note:** The project has no automated test target (`LyricsXFoundationTests` is empty). Each task ends with an Xcode build check and, where applicable, manual verification steps.

---

## File Structure

### Files modified

- `LyricsX/Utility/Global.swift` — add `menuBarPlaybackControlsEnabled` `DefaultsKey`
- `LyricsX/Supporting Files/UserDefaults.plist` — register default value `true`
- `LyricsX/Controller/MenuBarLyricsController.swift` — add buttons, subscriptions, layout logic

### Files left for user (not in this plan)

- `LyricsX/Base.lproj/Preferences.storyboard` — the user will manually add a checkbox bound to `values.MenuBarPlaybackControlsEnabled` in the General pane
- `LyricsX/mul.lproj/Preferences.xcstrings` — Xcode will extract the string automatically once the checkbox is added

---

## Task 1: Add UserDefaults Key and Default Value

**Files:**
- Modify: `LyricsX/Utility/Global.swift`
- Modify: `LyricsX/Supporting Files/UserDefaults.plist`

- [ ] **Step 1: Add the DefaultsKey declaration**

In `LyricsX/Utility/Global.swift`, locate the "Menu" section inside `extension UserDefaults.DefaultsKeys` (around line 73–76). Add the new key after `touchBarLyricsEnabled`:

```swift
// Menu
static let desktopLyricsEnabled = Key<Bool>("DesktopLyricsEnabled")
static let menuBarLyricsEnabled = Key<Bool>("MenuBarLyricsEnabled")
static let touchBarLyricsEnabled = Key<Bool>("TouchBarLyricsEnabled")
static let menuBarPlaybackControlsEnabled = Key<Bool>("MenuBarPlaybackControlsEnabled")
```

- [ ] **Step 2: Register the default value in UserDefaults.plist**

In `LyricsX/Supporting Files/UserDefaults.plist`, find the line containing `<key>MenuBarLyricsEnabled</key>` (or any existing menu bar key) and add a new entry. XML form:

```xml
<key>MenuBarPlaybackControlsEnabled</key>
<true/>
```

Place it adjacent to other menu-related keys for readability.

- [ ] **Step 3: Build the project to confirm no compile errors**

Run:
```bash
xcodebuild -workspace ../MxIris-LyricsX-Project.xcworkspace -scheme LyricsX -configuration Debug build 2>&1 | xcsift
```

If the workspace path does not exist, fall back to:
```bash
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add LyricsX/Utility/Global.swift "LyricsX/Supporting Files/UserDefaults.plist"
git commit -m "feat(menu-bar): add MenuBarPlaybackControlsEnabled preference key"
```

---

## Task 2: Add Control Buttons, Actions, and Layout to MenuBarLyricsController

**Files:**
- Modify: `LyricsX/Controller/MenuBarLyricsController.swift`

- [ ] **Step 1: Add button properties and layout constants**

In `LyricsX/Controller/MenuBarLyricsController.swift`, locate the existing private stored properties (around lines 23–47, between `iconStatusItem` and `cancelBag`). Add these properties after `marqueeLabel`:

```swift
private let previousButton = NSButton()
private let playPauseButton = NSButton()
private let nextButton = NSButton()

private static let controlButtonSize: CGFloat = 22
private static let lyricsToControlsGap: CGFloat = 6
private static let lyricsWidth: CGFloat = 183
```

- [ ] **Step 2: Add a `controlsVisible` computed property**

Add this computed property after the static constants (still within `class MenuBarLyricsController`):

```swift
private var controlsVisible: Bool {
    !defaults[.hideMenuBarItems]
        && defaults[.menuBarLyricsEnabled]
        && defaults[.menuBarPlaybackControlsEnabled]
}
```

- [ ] **Step 3: Add `setupControlButtons()` method**

Add this private method inside the class (below `init()` is a good location):

```swift
private func setupControlButtons() {
    configureControlButton(
        previousButton,
        symbolName: "backward.fill",
        action: #selector(previousAction)
    )
    configureControlButton(
        playPauseButton,
        symbolName: "play.fill",
        action: #selector(playPauseAction)
    )
    configureControlButton(
        nextButton,
        symbolName: "forward.fill",
        action: #selector(nextAction)
    )
}

private func configureControlButton(_ button: NSButton, symbolName: String, action: Selector) {
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.bezelStyle = .regularSquare
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    button.target = self
    button.action = action
}
```

- [ ] **Step 4: Add action methods**

Add these three `@objc` methods inside the class:

```swift
@objc private func previousAction() {
    selectedPlayer.skipToPreviousItem()
}

@objc private func playPauseAction() {
    selectedPlayer.playPause()
}

@objc private func nextAction() {
    selectedPlayer.skipToNextItem()
}
```

- [ ] **Step 5: Add `layoutLyricStatusItemContents()` method**

Add this private method:

```swift
private func layoutLyricStatusItemContents() {
    guard let button = lyricStatusItem?.button else { return }

    let lyricsWidth = MenuBarLyricsController.lyricsWidth
    let buttonSize = MenuBarLyricsController.controlButtonSize
    let gap = MenuBarLyricsController.lyricsToControlsGap

    let totalWidth: CGFloat
    if controlsVisible {
        totalWidth = lyricsWidth + gap + buttonSize * 3
    } else {
        totalWidth = lyricsWidth
    }

    button.frame = CGRect(x: 0, y: 0, width: totalWidth, height: buttonSize)
    marqueeLabel.frame = CGRect(x: 0, y: 0, width: lyricsWidth, height: buttonSize)

    if controlsVisible {
        let firstButtonX = lyricsWidth + gap
        previousButton.frame  = CGRect(x: firstButtonX, y: 0, width: buttonSize, height: buttonSize)
        playPauseButton.frame = CGRect(x: firstButtonX + buttonSize, y: 0, width: buttonSize, height: buttonSize)
        nextButton.frame      = CGRect(x: firstButtonX + buttonSize * 2, y: 0, width: buttonSize, height: buttonSize)
        if previousButton.superview !== button { button.addSubview(previousButton) }
        if playPauseButton.superview !== button { button.addSubview(playPauseButton) }
        if nextButton.superview !== button { button.addSubview(nextButton) }
    } else {
        previousButton.removeFromSuperview()
        playPauseButton.removeFromSuperview()
        nextButton.removeFromSuperview()
    }
}
```

- [ ] **Step 6: Add `updatePlayPauseIcon()` and `updateButtonsEnabledState()` stubs**

Add these two methods. They will be wired to subscriptions in Task 3, but are introduced here so the code compiles as a self-contained unit:

```swift
private func updatePlayPauseIcon() {
    let isPlaying = selectedPlayer.playbackState.isPlaying
    let symbolName = isPlaying ? "pause.fill" : "play.fill"
    playPauseButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
}

private func updateButtonsEnabledState() {
    let hasTrack = selectedPlayer.currentTrack != nil
    previousButton.isEnabled = hasTrack
    playPauseButton.isEnabled = hasTrack
    nextButton.isEnabled = hasTrack
}
```

- [ ] **Step 7: Call `setupControlButtons()` once from `init()`**

In the `private init()` method (around lines 49–67), place the setup and initial state calls BEFORE `updateStatusItems()`. The order matters: `setupLyricStatusItem()` (invoked transitively by `updateStatusItems()`) now calls `layoutLyricStatusItemContents()`, which adds the buttons as subviews — they must already have their images and target/action configured by then.

Replace the existing opening of `private init()`:

```swift
private init() {
    if !defaults[.hideMenuBarItems] {
        updateStatusItems()
    }
    AppController.shared.$currentLyrics
        // ... (existing code)
```

with:

```swift
private init() {
    setupControlButtons()
    updatePlayPauseIcon()
    updateButtonsEnabledState()
    if !defaults[.hideMenuBarItems] {
        updateStatusItems()
    }
    AppController.shared.$currentLyrics
        // ... (existing code unchanged)
```

- [ ] **Step 8: Invoke layout from `setupLyricStatusItem()`**

In `setupLyricStatusItem()` (around lines 141–150), replace the current body:

```swift
private func setupLyricStatusItem() {
    marqueeLabel.removeFromSuperview()
    lyricStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    lyricStatusItem?.button?.title = ""
    lyricStatusItem?.button?.image = nil
    lyricStatusItem?.length = NSStatusItem.variableLength
    lyricStatusItem?.button?.frame = marqueeLabel.bounds
    lyricStatusItem?.button?.addSubview(marqueeLabel)
    setupStatusItemMenu()
}
```

with:

```swift
private func setupLyricStatusItem() {
    marqueeLabel.removeFromSuperview()
    previousButton.removeFromSuperview()
    playPauseButton.removeFromSuperview()
    nextButton.removeFromSuperview()
    lyricStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    lyricStatusItem?.button?.title = ""
    lyricStatusItem?.button?.image = nil
    lyricStatusItem?.length = NSStatusItem.variableLength
    lyricStatusItem?.button?.addSubview(marqueeLabel)
    layoutLyricStatusItemContents()
    setupStatusItemMenu()
}
```

The extra `removeFromSuperview()` calls ensure the buttons detach cleanly when `setupLyricStatusItem()` is called again on mode switches.

- [ ] **Step 9: Build to confirm no compile errors**

Run:
```bash
xcodebuild -workspace ../MxIris-LyricsX-Project.xcworkspace -scheme LyricsX -configuration Debug build 2>&1 | xcsift
```

Fall back to `-project LyricsX.xcodeproj` if the workspace is absent.

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 10: Manual smoke test**

Launch the app from Xcode (`⌘R`). With a supported music player running and menu bar lyrics enabled:

1. Confirm three icon buttons (previous / play-pause / next) appear to the right of the menu bar lyrics.
2. Click each button → previous track / toggle play-pause / next track fires on the current player.
3. The play/pause icon currently stays static (will be wired to state changes in Task 3 — expected limitation at this step).

- [ ] **Step 11: Commit**

```bash
git add LyricsX/Controller/MenuBarLyricsController.swift
git commit -m "feat(menu-bar): embed playback control buttons in lyrics status item"
```

---

## Task 3: Subscribe to Player State Changes

**Files:**
- Modify: `LyricsX/Controller/MenuBarLyricsController.swift`

- [ ] **Step 1: Add `playbackStateWillChange` subscription**

In `private init()`, after the existing subscriptions (i.e., after the `defaults.publisher(for: [...])` block around lines 63–66), append:

```swift
selectedPlayer.playbackStateWillChange
    .signal()
    .receive(on: DispatchQueue.lyricsDisplay)
    .invoke(MenuBarLyricsController.updatePlayPauseIcon, weaklyOn: self)
    .store(in: &cancelBag)
```

Note: because `updatePlayPauseIcon` touches AppKit (`NSImage`, `NSButton.image`), the delivery queue matters. Inspect the other handlers in this file — they all use `DispatchQueue.lyricsDisplay` and reach AppKit without explicit main-queue hops. Match that pattern for consistency; if AppKit main-thread warnings surface during manual testing, switch to `DispatchQueue.main`.

- [ ] **Step 2: Add `currentTrackWillChange` subscription**

Immediately after the previous subscription, append:

```swift
selectedPlayer.currentTrackWillChange
    .signal()
    .receive(on: DispatchQueue.lyricsDisplay)
    .invoke(MenuBarLyricsController.updateButtonsEnabledState, weaklyOn: self)
    .store(in: &cancelBag)
```

- [ ] **Step 3: Build to confirm no compile errors**

Run:
```bash
xcodebuild -workspace ../MxIris-LyricsX-Project.xcworkspace -scheme LyricsX -configuration Debug build 2>&1 | xcsift
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manual verification**

Launch the app and, with a supported player running:

1. Play a track → play-pause button shows `pause.fill` (indicating "press to pause").
2. Pause in the player → button flips to `play.fill`.
3. Stop playback / quit the player so there is no current track → all three buttons become greyed out.
4. Resume playback → buttons re-enable.

If any step lags noticeably or causes a threading warning in the console, rerun with `.receive(on: DispatchQueue.main)` on the two subscriptions.

- [ ] **Step 5: Commit**

```bash
git add LyricsX/Controller/MenuBarLyricsController.swift
git commit -m "feat(menu-bar): sync playback button state with player"
```

---

## Task 4: Wire Preference Toggle to Layout

**Files:**
- Modify: `LyricsX/Controller/MenuBarLyricsController.swift`

- [ ] **Step 1: Extend the defaults publisher to watch the new key**

In `private init()`, locate the existing defaults publisher (around lines 63–66):

```swift
defaults.publisher(for: [.menuBarLyricsEnabled, .combinedMenubarLyrics, .hideMenuBarItems])
    .prepend()
    .invoke(MenuBarLyricsController.updateStatusItems, weaklyOn: self)
    .store(in: &cancelBag)
```

Replace with:

```swift
defaults.publisher(for: [
    .menuBarLyricsEnabled,
    .combinedMenubarLyrics,
    .hideMenuBarItems,
    .menuBarPlaybackControlsEnabled,
])
    .prepend()
    .invoke(MenuBarLyricsController.updateStatusItems, weaklyOn: self)
    .store(in: &cancelBag)
```

- [ ] **Step 2: Relayout when the preference changes without recreating the status item**

`updateStatusItems()` only recreates the status item when the display mode changes (separate ↔ combined). Toggling `menuBarPlaybackControlsEnabled` alone does not flip the mode, so the status item isn't rebuilt and the existing `setupLyricStatusItem()` path won't fire.

To pick up the preference change, make `updateSeparateStatusLyrics()` and `updateCombinedStatusLyrics()` call `layoutLyricStatusItemContents()` unconditionally at the end.

Replace `updateSeparateStatusLyrics()` (around lines 123–130) with:

```swift
private func updateSeparateStatusLyrics() {
    if lastDisplayMode == nil || lastDisplayMode == .combine {
        setupIconStatusItem()
        setupLyricStatusItem()
    }
    layoutLyricStatusItemContents()
    marqueeLabel.setStringValue(screenLyrics.lyrics, lineDisplayTime: screenLyrics.duration)
}
```

Replace `updateCombinedStatusLyrics()` (around lines 132–139) with:

```swift
private func updateCombinedStatusLyrics() {
    if lastDisplayMode == nil || lastDisplayMode == .separate {
        iconStatusItem = nil
        setupLyricStatusItem()
    }
    layoutLyricStatusItemContents()
    marqueeLabel.setStringValue(screenLyrics.lyrics, lineDisplayTime: screenLyrics.duration)
}
```

The extra `layoutLyricStatusItemContents()` is idempotent — it either adds or removes the buttons based on `controlsVisible`, and re-sets frames (cheap). When `setupLyricStatusItem()` was just called, the one inside it has already run, so this is a no-op extra layout pass in that path.

- [ ] **Step 3: Build to confirm no compile errors**

Run:
```bash
xcodebuild -workspace ../MxIris-LyricsX-Project.xcworkspace -scheme LyricsX -configuration Debug build 2>&1 | xcsift
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manual verification (requires storyboard checkbox from the user)**

The user adds the preference checkbox in the General pane, bound to `values.MenuBarPlaybackControlsEnabled`. Once present:

1. With the app running and menu bar lyrics visible, open General preferences.
2. Toggle "Show playback controls in menu bar" off → buttons disappear and the status item shrinks back to 183pt.
3. Toggle it on → buttons reappear and the status item widens.
4. No app restart required.

If the checkbox is not yet in the storyboard, temporarily toggle via the command line:

```bash
defaults write com.JH.LyricsX MenuBarPlaybackControlsEnabled -bool false
defaults write com.JH.LyricsX MenuBarPlaybackControlsEnabled -bool true
```

Each write should flip the button visibility live.

- [ ] **Step 5: Commit**

```bash
git add LyricsX/Controller/MenuBarLyricsController.swift
git commit -m "feat(menu-bar): toggle playback controls via preference"
```

---

## Task 5: End-to-End Verification

**Files:**
- None (manual verification only)

- [ ] **Step 1: Run full scenario checklist**

Launch the app. Verify each scenario from the design spec's Testing section:

1. **Initial render** — menu bar lyrics on, supported player running → three buttons render to the right of lyrics.
2. **Button actions** — click previous → skips to previous track; click play/pause → toggles play state; click next → skips to next track.
3. **Preference toggle** — toggle `MenuBarPlaybackControlsEnabled` off and on (via storyboard checkbox or `defaults write`) → buttons appear/disappear live.
4. **Menu bar lyrics off** — disable menu bar lyrics → lyrics item and all buttons disappear; only icon-only status item remains (if enabled), with no controls.
5. **Mode switch (separate ↔ combined)** — toggle "Combine menubar icon with menubar lyrics" → buttons render correctly in both modes.
6. **External play/pause** — pause/play from the player's own UI or Now Playing Center → play/pause button icon updates accordingly.
7. **No current track** — quit the player → all three buttons become disabled (greyed).
8. **Resume playback** — relaunch and play a track → buttons re-enable; play/pause icon matches state.
9. **Lyrics area click (left and right)** — both clicks on the lyrics area pop `statusBarMenu`.
10. **Button click does not pop menu** — clicking any of the three buttons executes its action without `statusBarMenu` popping.

- [ ] **Step 2: If any scenario fails, diagnose and fix**

- Button click also pops the menu → check the fallback in the design spec (`NSStatusBarButton.action` dispatcher). Verify `NSButton.isEnabled == true` and `target`/`action` are set.
- Button icon doesn't update on playback state change → verify the `playbackStateWillChange` subscription in Task 3 and that `updatePlayPauseIcon()` runs on the expected queue.
- Buttons don't enable/disable on track change → verify the `currentTrackWillChange` subscription.
- Layout off after mode switch → confirm `layoutLyricStatusItemContents()` is being called in both `updateSeparateStatusLyrics()` and `updateCombinedStatusLyrics()`.

- [ ] **Step 3: No code change in this task unless a bug was found**

If a fix was needed, commit it with a descriptive message. Otherwise, no commit.

---

## Self-Review Notes (performed by plan author)

- Spec coverage: Goals 1–4 covered by Tasks 1–4; edge cases (mode switch, runtime toggle, no current track, play/pause sync) each have a dedicated manual verification step.
- Placeholder scan: No TBDs, TODOs, or "handle edge cases" hand-waves — every code step shows the actual code.
- Type consistency: `previousButton` / `playPauseButton` / `nextButton`, `controlsVisible`, `layoutLyricStatusItemContents`, `updatePlayPauseIcon`, `updateButtonsEnabledState` are used consistently across tasks.
- Scope: Single subsystem (menu bar lyrics status item); fits a single plan.
