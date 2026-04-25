# Apple Music HUD Toggle — Design

**Date:** 2026-04-25
**Status:** Draft
**Scope:** Add a user-facing preference that decides whether the HUD lyrics window opens with the new Apple Music-style design or the legacy `LyricsHUDWindowController`. Default off (legacy).

## Summary

On macOS 15+, `AppDelegate` currently picks `AppleMusicLyrics.WindowController` unconditionally for the HUD lyrics window via `#available(macOS 15, *)`. This design introduces a new preference key `UseAppleMusicLyricsWindow` (default `false`) that lets the user opt into the new design. When the toggle is off — or when the OS is below macOS 15 — the legacy `LyricsHUDWindowController` is used. The toggle lives in the Lab preference pane and takes effect on the next time the HUD is shown (no live swap).

## Goals

- Give users an explicit choice between the legacy HUD and the new Apple Music-style HUD on macOS 15+.
- Default to the legacy HUD so upgraders see no behavior change.
- Keep the toggle discoverable but clearly marked as an experimental opt-in.
- Keep the existing `isShowLyricsHUD` "is HUD visible" flag and the new "which HUD style" key fully orthogonal.

## Non-Goals

- No live swap between styles when the HUD is already visible.
- No changes to `LyricsHUDWindowController` or `AppleMusicLyrics.WindowController` themselves.
- No migration of existing per-style state (window pin, background mode, frame autosave, etc.).
- No per-track or per-player automatic style selection.

## User Decisions (from brainstorming)

| # | Decision |
|---|---|
| Placement | Lab preference pane, alongside the other experimental toggles. |
| Behavior on toggle | Next-show wins. Already-visible HUD is not closed/re-opened automatically. |
| macOS < 15 | Checkbox is shown but disabled; tooltip explains the macOS 15 requirement. |
| Label | `Use Apple Music-style lyrics window` |
| Default value | `false` (legacy HUD) |

## Architecture

### Overview

```
┌─────────────────── Preferences › Lab ───────────────────┐
│                                                          │
│   [✓] Use Apple Music-style lyrics window                │
│       tooltip: "Requires macOS 15 or later"              │
│       (disabled on macOS < 15)                           │
│                                                          │
└──────────────────────────────────────────────────────────┘
              │  bound to values.UseAppleMusicLyricsWindow
              ▼
        UserDefaults
              │
              │  read at HUD-show time only
              ▼
   #available(macOS 15, *) && defaults[.useAppleMusicLyricsWindow]
              │
   ┌──────────┴──────────┐
   │                     │
   ▼                     ▼
new HUD               legacy HUD
(macOS 15+)           (any macOS)
```

### Affected Files

| File | Change |
|---|---|
| `LyricsX/Utility/Global.swift` | Add `useAppleMusicLyricsWindow` `DefaultsKey<Bool>`. |
| `LyricsX/Supporting Files/UserDefaults.plist` | Register default value `false` for `UseAppleMusicLyricsWindow`. |
| `LyricsX/Component/AppDelegate.swift` | Add `activeLyricsHUD: NSWindowController?` instance var and an `openLyricsHUD()` helper; route both the launch branch and `showLyricsHUD(_:)` through them so the toggle is sampled at open time and the actually-opened controller is closed. |
| `LyricsX/Preferences/PreferenceLabViewController.swift` | Add `@IBOutlet useAppleMusicLyricsWindowButton`; bind to defaults; disable on macOS < 15. |
| `LyricsX/Base.lproj/Preferences.storyboard` | Add new gridRow + gridCells + checkbox in the Lab scene (`JPs-hn-m7d`); wire outlet and binding. |
| `LyricsX/mul.lproj/Preferences.xcstrings` | Add `AML-Cl-001.title` entry for the new checkbox with en/zh-Hans/zh-Hant translations. |
| `LyricsX/Supporting Files/Localizable.xcstrings` | Add programmatic tooltip string `"Requires macOS 15 or later"` with en/zh-Hans/zh-Hant translations. |

## Component Design

### Global.swift

Add a new key in `UserDefaults.DefaultsKeys`, grouped near the other Apple Music HUD keys:

```swift
static let isShowLyricsHUD = Key<Bool>("isShowLyricsHUD")

static let useAppleMusicLyricsWindow = Key<Bool>("UseAppleMusicLyricsWindow") // new
static let appleMusicLyricsBackgroundMode = Key<Int>("AppleMusicLyricsBackgroundMode")
static let appleMusicLyricsWindowPinned = Key<Bool>("AppleMusicLyricsWindowPinned")
```

### UserDefaults.plist

Add (anywhere inside the top-level `<dict>`):

```xml
<key>UseAppleMusicLyricsWindow</key>
<false/>
```

This guarantees a deterministic default on fresh installs and on upgraders who never touched the new key.

### AppDelegate.swift

Two design constraints shape the change:

1. **Compiler gating.** `appleMusicLyricsWindowController` is annotated `@available(macOS 15, *)`, so its accessor must be reached inside an `#available` block — a custom `Bool` helper that erases availability would not type-check. Keep the existing `#available` shape and add the defaults check inside it.
2. **Close-path staleness.** The open path samples `defaults[.useAppleMusicLyricsWindow]`. If the user opens the HUD, flips the toggle in Preferences, then re-clicks the menu item, a close path that re-reads the toggle would target the wrong controller and orphan the visible window. We must close the controller that was actually opened.

The cleanest fix is a small instance variable that remembers which controller was last opened. The menu/shortcut close path uses it; the X-button close path keeps the existing `defaults[.isShowLyricsHUD] = false` from each window controller's `windowWillClose` and lets the next open call overwrite the (now stale) reference.

Add a private property to `AppDelegate`:

```swift
private var activeLyricsHUD: NSWindowController?
```

Replace the launch-time branch (currently lines 90-96):

```swift
if defaults[.isShowLyricsHUD] {
    openLyricsHUD()
}
```

Replace the toggle action `showLyricsHUD(_:)` (currently lines 159-177):

```swift
@IBAction func showLyricsHUD(_ sender: Any?) {
    if defaults[.isShowLyricsHUD] {
        activeLyricsHUD?.close()
        activeLyricsHUD = nil
        defaults[.isShowLyricsHUD] = false
    } else {
        openLyricsHUD()
        defaults[.isShowLyricsHUD] = true
    }

    NSApp.activate(ignoringOtherApps: true)
}

private func openLyricsHUD() {
    let hud: NSWindowController
    if #available(macOS 15, *), defaults[.useAppleMusicLyricsWindow] {
        hud = appleMusicLyricsWindowController
    } else {
        hud = lyricsHUD
    }
    hud.showWindow(nil)
    activeLyricsHUD = hud
}
```

Why this works:

- The choice between new and legacy is sampled exactly once per open, inside a single `if #available` block. The compiler is happy.
- `activeLyricsHUD` records the actually-opened controller, so the close path closes that one regardless of any subsequent toggle change.
- The close path never touches the *other* controller, so neither `lyricsHUD` (a lazy `StoryboardWindowController.create()` — non-trivial) nor `appleMusicLyricsWindowController` (a SwiftUI hosting controller) is needlessly instantiated.
- The window's own `windowWillClose` handler already sets `defaults[.isShowLyricsHUD] = false`. After an X-button close, `activeLyricsHUD` still references the closed controller, but the next `showLyricsHUD(_:)` call goes through the open path (because `isShowLyricsHUD` is `false`) and overwrites it. No leak; controllers are app-lifetime singletons.

Because the open path samples `defaults[.useAppleMusicLyricsWindow]` at open time only, toggling the preference while the HUD is visible has no effect on the visible window — the user must close and re-open. This matches the user's "next-show wins" decision.

The `appleMusicLyricsWindowController` lazy storage stays as-is. It's only created on first read inside the gated `#available(macOS 15, *)` block, so pre-15 systems never instantiate it.

### PreferenceLabViewController.swift

Add an outlet and configure it in `viewDidLoad`:

```swift
@IBOutlet var useAppleMusicLyricsWindowButton: NSButton!

override func viewDidLoad() {
    super.viewDidLoad()
    enableTouchBarLyricsButton.bind(.value, withDefaultName: .touchBarLyricsEnabled)

    useAppleMusicLyricsWindowButton.bind(.value, withDefaultName: .useAppleMusicLyricsWindow)
    if #available(macOS 15, *) {
        // Available — leave the checkbox interactive.
    } else {
        useAppleMusicLyricsWindowButton.isEnabled = false
        useAppleMusicLyricsWindowButton.toolTip = NSLocalizedString(
            "Requires macOS 15 or later",
            comment: "Tooltip on the Apple Music-style lyrics window toggle when the OS is too old."
        )
    }

    // ...existing musixmatch token setup...
}
```

The bind is fine even on older macOS — the underlying defaults key still exists; it just becomes a no-op because the open path's `if #available` short-circuits to the legacy branch.

### Preferences.storyboard

Add to the Lab scene (`JPs-hn-m7d`, starts at line 1458):

1. **New gridRow** inserted between `MBP-Ro-W01` (the playback controls row) and `lp0-JX-wTa` (the Musixmatch row), with a stable id like `AML-Ro-W01`, `height="30"`, `yPlacement="center"`.
2. **Two gridCells** for the new row: `AML-Ce-L01` (empty, left column) and `AML-Ce-R01` (right column, contains the button).
3. **NSButton**: id `AML-Bt-N01`, with a checkbox `buttonCell` id `AML-Cl-001`, title `"Use Apple Music-style lyrics window"`, frame matching the sibling rows (`x="170" y="..." width="..." height="16"`). Do **not** set a tooltip in the storyboard — the tooltip is set programmatically only when the checkbox is disabled (see `PreferenceLabViewController.swift` above). Setting it in the storyboard would also surface "Requires macOS 15 or later" to users on macOS 15+ where the feature works.
4. **Binding**: `<binding destination="DdU-cn-wN1" name="value" keyPath="values.UseAppleMusicLyricsWindow" id="AML-Bn-D01"/>`.
5. **Outlet**: connect from the controller (`JPs-hn-m7d`) to `useAppleMusicLyricsWindowButton`.

### Preferences.xcstrings

Add one `AML-Cl-001.title` entry following the template used by `MBP-Cl-001.title`:

| String table key | en | zh-Hans | zh-Hant |
|---|---|---|---|
| `AML-Cl-001.title` | `Use Apple Music-style lyrics window` | `使用 Apple Music 风格的歌词窗口` | `使用 Apple Music 風格的歌詞視窗` |

The legacy per-locale `Preferences.strings` files under `LyricsX/<lang>.lproj/` are NOT updated — `MBP-Cl-001` followed the same pattern (only `mul.lproj/Preferences.xcstrings` was touched).

The tooltip text "Requires macOS 15 or later" is set programmatically via `NSLocalizedString` and lives in `LyricsX/Supporting Files/Localizable.xcstrings` (already in the project). Add the English source string and the two Chinese translations there.

## Data Flow

```
User checks "Use Apple Music-style lyrics window"
  → userDefaultsController write → UserDefaults["UseAppleMusicLyricsWindow"] = true

User toggles HUD visibility (menu / shortcut)
  → AppDelegate.showLyricsHUD(_:)
  → open path: openLyricsHUD()
            → reads #available + defaults[.useAppleMusicLyricsWindow] now
            → opens matching controller; records it in activeLyricsHUD
  → close path: activeLyricsHUD?.close(); activeLyricsHUD = nil
            (does NOT re-read the toggle, to avoid orphaning the visible window)

App launch
  → applicationDidFinishLaunching reads defaults[.isShowLyricsHUD]
  → if true, calls openLyricsHUD() (same path as menu toggle)
```

No publishers, no observers — the new key is sampled only at the two HUD show/close sites.

## Edge Cases

- **macOS < 15.** The open path's `if #available(macOS 15, *)` fails, so the legacy HUD is always chosen regardless of the stored toggle. The lazy `appleMusicLyricsWindowController` is never instantiated (its accessor is `@available(macOS 15, *)`). The Lab checkbox is still visible but disabled with a tooltip.
- **Toggle while HUD is visible.** No live swap. The visible HUD stays as-is; the next time the HUD is closed and re-opened, the new style applies.
- **Frame autosave / window state.** The two HUD window controllers have independent autosave names, so switching styles preserves each one's own remembered geometry.
- **`appleMusicLyricsWindowController` lazy storage.** Stored in `appleMusicLyricsWindowControllerStorage: Any?` and only typed inside `@available(macOS 15, *)` accessors — switching off the new style does not deallocate it, but that is harmless (it's just an `NSWindowController` instance with no window if `loadWindow()` was never invoked).
- **Shortcut path.** `bindShortcut(.shortcutShowLyricsWindow, to: #selector(showLyricsHUD))` already routes through `showLyricsHUD(_:)`, so the keyboard shortcut automatically respects the new toggle.
- **Sandboxing / defaults sync.** The new key is plain `UserDefaults.standard`, not `groupDefaults`, so no helper coordination is needed.

## Error Handling

There is no failure mode introduced. `defaults[.useAppleMusicLyricsWindow]` returns `Bool` with a registered default of `false`; reads cannot fail. Window show/close calls on `NSWindowController` are safe to call repeatedly.

## Testing

Manual verification (no automated test target exists):

1. **Default behavior.** Fresh launch on macOS 15+ with no prior `UseAppleMusicLyricsWindow` value → toggling the HUD via menu opens the legacy `LyricsHUDWindowController`.
2. **Opt in.** Check the Lab checkbox, close the HUD, re-open → new Apple Music-style window appears.
3. **Opt out.** Uncheck the checkbox, close the HUD, re-open → legacy HUD returns.
4. **Live toggle does not swap.** With the HUD visible, flip the checkbox → visible window does not change.
5. **Persistence across restart.** Set the toggle to `true`, quit, relaunch with `isShowLyricsHUD == true` → new HUD opens at launch (and vice versa).
6. **macOS < 15.** On macOS 11–14, the Lab checkbox is disabled and shows the "Requires macOS 15 or later" tooltip; toggling it has no effect. (If macOS 15 hardware/VM is unavailable, this path can be exercised by temporarily flipping the `#available` check.)
7. **Shortcut path.** The "Show Lyrics Window" global shortcut respects the toggle the same way.
8. **Localization.** Switch the app language to zh-Hans / zh-Hant → checkbox label is translated correctly.

## Localization

| String table key | en | zh-Hans | zh-Hant |
|---|---|---|---|
| `AML-Cl-001.title` | Use Apple Music-style lyrics window | 使用 Apple Music 风格的歌词窗口 | 使用 Apple Music 風格的歌詞視窗 |
| (programmatic, in `Localizable.xcstrings`) `Requires macOS 15 or later` | Requires macOS 15 or later | 需要 macOS 15 或更高版本 | 需要 macOS 15 或更新版本 |

## Open Questions

None — all four user decisions are recorded above.
