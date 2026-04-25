# Apple Music HUD Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Lab-pane preference (`UseAppleMusicLyricsWindow`, default off) that lets the user opt into the new Apple Music-style HUD lyrics window on macOS 15+. When off — or on macOS < 15 — the legacy `LyricsHUDWindowController` is used.

**Architecture:** A single `Bool` `UserDefaults` key gates the choice between the two existing window controllers in `AppDelegate`. To avoid orphaning a visible window when the toggle changes mid-session, the actually-opened controller is recorded in a new `activeLyricsHUD: NSWindowController?` instance var; the close path closes that controller rather than re-reading the toggle. The Lab-pane checkbox is disabled with a programmatic tooltip on macOS < 15 so the requirement is discoverable.

**Tech Stack:** AppKit (`NSWindowController`, `NSButton` checkbox via storyboard), `GenericID` (`DefaultsKey`), `LyricsXFoundation` (`defaults` / `bind(_:withDefaultName:)`), Xcode String Catalogs (`.xcstrings`).

**Design Spec:** `docs/superpowers/specs/2026-04-25-apple-music-hud-toggle-design.md`

**Testing Note:** The project has no automated test target (`LyricsXFoundationTests` is empty). Each task ends with an Xcode build check and, where applicable, manual verification steps.

---

## File Structure

### Files modified

- `LyricsX/Utility/Global.swift` — add `useAppleMusicLyricsWindow` `DefaultsKey`
- `LyricsX/Supporting Files/UserDefaults.plist` — register default value `false`
- `LyricsX/Component/AppDelegate.swift` — add `activeLyricsHUD` + `openLyricsHUD()`; route launch and `showLyricsHUD(_:)` through them
- `LyricsX/Preferences/PreferenceLabViewController.swift` — add `useAppleMusicLyricsWindowButton` outlet, bind, and macOS-< 15 disable + tooltip
- `LyricsX/Base.lproj/Preferences.storyboard` — add new gridRow + checkbox + outlet wiring inside the active Lab scene (`JPs-hn-m7d`)
- `LyricsX/mul.lproj/Preferences.xcstrings` — add `AML-Cl-001.title` entry with en/zh-Hans/zh-Hant translations
- `LyricsX/Supporting Files/Localizable.xcstrings` — add programmatic tooltip string `"Requires macOS 15 or later"` with en/zh-Hans/zh-Hant translations

### Files NOT modified

- `LyricsX/AppleMusicLyrics/AppleMusicLyricsWindowController.swift` — no change
- `LyricsX/LyricsHUD/LyricsHUDWindowController.swift` and `LyricsHUDViewController.swift` — no change
- `LyricsX/<lang>.lproj/Preferences.strings` — legacy per-locale strings are not touched (consistent with how `MBP-Cl-001` was added in commit `f86b9a5`)

---

## Task 1: Add UserDefaults Key and Default Value

**Files:**
- Modify: `LyricsX/Utility/Global.swift`
- Modify: `LyricsX/Supporting Files/UserDefaults.plist`

- [ ] **Step 1: Add the `DefaultsKey` declaration**

In `LyricsX/Utility/Global.swift`, locate the existing `isShowLyricsHUD` and `appleMusicLyricsBackgroundMode` lines (around 163–166 in the `extension UserDefaults.DefaultsKeys` block). Insert the new key between them:

```swift
static let isShowLyricsHUD = Key<Bool>("isShowLyricsHUD")

static let useAppleMusicLyricsWindow = Key<Bool>("UseAppleMusicLyricsWindow")
static let appleMusicLyricsBackgroundMode = Key<Int>("AppleMusicLyricsBackgroundMode")
static let appleMusicLyricsWindowPinned = Key<Bool>("AppleMusicLyricsWindowPinned")
```

- [ ] **Step 2: Register the default value in `UserDefaults.plist`**

In `LyricsX/Supporting Files/UserDefaults.plist`, add a new entry inside the top-level `<dict>`. Place it next to other Apple-Music-related defaults (or just before `<key>NSApplicationCrashOnExceptions</key>` if no obvious neighbor):

```xml
<key>UseAppleMusicLyricsWindow</key>
<false/>
```

This guarantees fresh installs and upgraders default to `false` (legacy HUD).

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
git commit -m "feat(apple-music-lyrics): add UseAppleMusicLyricsWindow preference key"
```

---

## Task 2: Refactor AppDelegate to Honor the Toggle

**Files:**
- Modify: `LyricsX/Component/AppDelegate.swift`

The goal is to (a) sample `defaults[.useAppleMusicLyricsWindow]` at HUD-open time only, and (b) close the controller that was actually opened — not whichever one the current toggle would pick. A new `activeLyricsHUD` instance var and a private `openLyricsHUD()` helper are introduced for this.

- [ ] **Step 1: Add `activeLyricsHUD` instance property**

In `LyricsX/Component/AppDelegate.swift`, locate the existing properties `lyricsHUD` and `appleMusicLyricsWindowControllerStorage` (around lines 27–29). Add a new property after `appleMusicLyricsWindowControllerStorage`:

```swift
lazy var lyricsHUD: LyricsHUDWindowController = .create()

private var appleMusicLyricsWindowControllerStorage: Any?

private var activeLyricsHUD: NSWindowController?
```

- [ ] **Step 2: Add the `openLyricsHUD()` private helper**

Add this helper method to the `AppDelegate` class. A natural location is right after the `appleMusicLyricsWindowController` accessor (around line 39, before `preferencesWindowController`):

```swift
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

- [ ] **Step 3: Replace the launch-time HUD branch**

In `applicationDidFinishLaunching(_:)`, locate the existing block (currently lines 90–96):

```swift
if defaults[.isShowLyricsHUD] {
    if #available(macOS 15, *) {
        appleMusicLyricsWindowController.showWindow(nil)
    } else {
        lyricsHUD.showWindow(nil)
    }
}
```

Replace it with:

```swift
if defaults[.isShowLyricsHUD] {
    openLyricsHUD()
}
```

- [ ] **Step 4: Replace `showLyricsHUD(_:)` body**

Locate the existing `@IBAction func showLyricsHUD(_ sender: Any?)` (currently lines 159–177):

```swift
@IBAction func showLyricsHUD(_ sender: Any?) {
    if defaults[.isShowLyricsHUD] {
        if #available(macOS 15, *) {
            appleMusicLyricsWindowController.close()
        } else {
            lyricsHUD.close()
        }
        defaults[.isShowLyricsHUD] = false
    } else {
        if #available(macOS 15, *) {
            appleMusicLyricsWindowController.showWindow(nil)
        } else {
            lyricsHUD.showWindow(nil)
        }
        defaults[.isShowLyricsHUD] = true
    }

    NSApp.activate(ignoringOtherApps: true)
}
```

Replace it with:

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
```

- [ ] **Step 5: Build to confirm no compile errors**

Run:
```bash
xcodebuild -workspace ../MxIris-LyricsX-Project.xcworkspace -scheme LyricsX -configuration Debug build 2>&1 | xcsift
```

Fall back to `-project LyricsX.xcodeproj` if the workspace is absent.

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Manual smoke test (without the Lab UI yet)**

1. With the app freshly installed (or after `defaults delete com.JH.LyricsX UseAppleMusicLyricsWindow`), launch.
2. Open the lyrics HUD via the menu (or shortcut) → legacy `LyricsHUDWindowController` should appear (default off).
3. Close it via the menu (or X button).
4. Force the toggle on via shell: `defaults write com.JH.LyricsX UseAppleMusicLyricsWindow -bool true`
5. Open the HUD again → on macOS 15+, the new Apple Music-style window appears; on older macOS, the legacy window still appears.
6. Toggle off via shell: `defaults write com.JH.LyricsX UseAppleMusicLyricsWindow -bool false`
7. Open the HUD with the visible-orphan scenario:
   - Open HUD (legacy shows)
   - Run `defaults write com.JH.LyricsX UseAppleMusicLyricsWindow -bool true` while the HUD is visible
   - Click the menu item again to close → the legacy window (which was actually open) closes correctly. The `activeLyricsHUD` reference made this work.

- [ ] **Step 7: Commit**

```bash
git add LyricsX/Component/AppDelegate.swift
git commit -m "feat(apple-music-lyrics): gate HUD style on UseAppleMusicLyricsWindow"
```

---

## Task 3: Add Lab Pane Checkbox + Outlet

**Files:**
- Modify: `LyricsX/Base.lproj/Preferences.storyboard`
- Modify: `LyricsX/Preferences/PreferenceLabViewController.swift`

The active Lab scene id is `JPs-hn-m7d` (starts at line 1458). The grid is defined at lines 1463–1483 with rows declared in `<rows>` and corresponding cells in `<gridCells>`. New IDs use the prefix `AML-` (Apple Music Lyrics) — distinct from the existing `MBP-` row added for the playback controls checkbox.

- [ ] **Step 1: Insert a new `gridRow` declaration**

In `LyricsX/Base.lproj/Preferences.storyboard`, locate the existing `<rows>` block in the Lab scene. After the `MBP-Ro-W01` row (currently around line 1477) and before `lp0-JX-wTa`, add the new row using the Edit tool with the exact `old_string`:

```
                                    <gridRow yPlacement="center" height="30" id="MBP-Ro-W01"/>
                                    <gridRow height="30" id="lp0-JX-wTa"/>
```

Replace with:

```
                                    <gridRow yPlacement="center" height="30" id="MBP-Ro-W01"/>
                                    <gridRow yPlacement="center" height="30" id="AML-Ro-W01"/>
                                    <gridRow height="30" id="lp0-JX-wTa"/>
```

- [ ] **Step 2: Insert the new `gridCell` pair for the row**

Find the `MBP-Ce-R01` cell (which closes around line 1654 with `</gridCell>`, just before `<gridCell row="lp0-JX-wTa" column="8ba-lF-U7s" yPlacement="center" id="YZh-w9-vzD">`). Use the Edit tool with this exact `old_string`:

```
                                    <gridCell row="MBP-Ro-W01" column="4uA-B7-Dvh" id="MBP-Ce-R01">
                                        <button key="contentView" verticalHuggingPriority="750" translatesAutoresizingMaskIntoConstraints="NO" id="MBP-Bt-N01">
                                            <rect key="frame" x="170" y="12" width="284" height="16"/>
                                            <buttonCell key="cell" type="check" title="Show playback controls in menu bar" bezelStyle="regularSquare" imagePosition="left" state="on" inset="2" id="MBP-Cl-001">
                                                <behavior key="behavior" changeContents="YES" doesNotDimImage="YES" lightByContents="YES"/>
                                                <font key="font" metaFont="system"/>
                                            </buttonCell>
                                            <connections>
                                                <binding destination="DdU-cn-wN1" name="value" keyPath="values.MenuBarPlaybackControlsEnabled" id="MBP-Bn-D01"/>
                                            </connections>
                                        </button>
                                    </gridCell>
                                    <gridCell row="lp0-JX-wTa" column="8ba-lF-U7s" yPlacement="center" id="YZh-w9-vzD">
```

Replace with:

```
                                    <gridCell row="MBP-Ro-W01" column="4uA-B7-Dvh" id="MBP-Ce-R01">
                                        <button key="contentView" verticalHuggingPriority="750" translatesAutoresizingMaskIntoConstraints="NO" id="MBP-Bt-N01">
                                            <rect key="frame" x="170" y="12" width="284" height="16"/>
                                            <buttonCell key="cell" type="check" title="Show playback controls in menu bar" bezelStyle="regularSquare" imagePosition="left" state="on" inset="2" id="MBP-Cl-001">
                                                <behavior key="behavior" changeContents="YES" doesNotDimImage="YES" lightByContents="YES"/>
                                                <font key="font" metaFont="system"/>
                                            </buttonCell>
                                            <connections>
                                                <binding destination="DdU-cn-wN1" name="value" keyPath="values.MenuBarPlaybackControlsEnabled" id="MBP-Bn-D01"/>
                                            </connections>
                                        </button>
                                    </gridCell>
                                    <gridCell row="AML-Ro-W01" column="8ba-lF-U7s" id="AML-Ce-L01"/>
                                    <gridCell row="AML-Ro-W01" column="4uA-B7-Dvh" id="AML-Ce-R01">
                                        <button key="contentView" verticalHuggingPriority="750" translatesAutoresizingMaskIntoConstraints="NO" id="AML-Bt-N01">
                                            <rect key="frame" x="170" y="12" width="320" height="16"/>
                                            <buttonCell key="cell" type="check" title="Use Apple Music-style lyrics window" bezelStyle="regularSquare" imagePosition="left" inset="2" id="AML-Cl-001">
                                                <behavior key="behavior" changeContents="YES" doesNotDimImage="YES" lightByContents="YES"/>
                                                <font key="font" metaFont="system"/>
                                            </buttonCell>
                                            <connections>
                                                <binding destination="DdU-cn-wN1" name="value" keyPath="values.UseAppleMusicLyricsWindow" id="AML-Bn-D01"/>
                                            </connections>
                                        </button>
                                    </gridCell>
                                    <gridCell row="lp0-JX-wTa" column="8ba-lF-U7s" yPlacement="center" id="YZh-w9-vzD">
```

Notes on choices made:
- The button cell omits `state="on"` (the legacy MBP cell had it, but our default is `false` — the binding to the userDefaultsController will set the initial state from defaults at runtime regardless, so this is cosmetic).
- No `tooltip` attribute on the button — the tooltip is set programmatically only when disabled (see `PreferenceLabViewController.swift` step below).
- Frame width `320` is wide enough for the longer English label `Use Apple Music-style lyrics window`. The grid column is 350pt wide; this fits.
- The outlet wiring is added separately in Step 3 below — outlets live in the view controller's `<connections>` block, not on the button.

- [ ] **Step 3: Add the outlet in the view controller's connections block**

Locate the `<connections>` block of the Lab view controller (around lines 1688–1691 in the current storyboard). Use the Edit tool with this exact `old_string`:

```
                    <connections>
                        <outlet property="enableTouchBarLyricsButton" destination="D7U-qs-Keb" id="k7p-hg-kzy"/>
                        <outlet property="musixmatchTokenField" destination="PeC-aV-j5M" id="SSi-r8-o1g"/>
                    </connections>
```

Replace with:

```
                    <connections>
                        <outlet property="enableTouchBarLyricsButton" destination="D7U-qs-Keb" id="k7p-hg-kzy"/>
                        <outlet property="musixmatchTokenField" destination="PeC-aV-j5M" id="SSi-r8-o1g"/>
                        <outlet property="useAppleMusicLyricsWindowButton" destination="AML-Bt-N01" id="AML-Ot-U01"/>
                    </connections>
```

The `destination` is the button id `AML-Bt-N01` introduced in Step 2. The `id` `AML-Ot-U01` is a fresh outlet connection id.

- [ ] **Step 4: Verify the storyboard XML still parses**

Quick lint by opening the project in Xcode IB **briefly** is the safest check, but a build will also fail loudly if the XML is malformed.

Run:
```bash
xcodebuild -workspace ../MxIris-LyricsX-Project.xcworkspace -scheme LyricsX -configuration Debug build 2>&1 | xcsift
```

Expected: `BUILD SUCCEEDED`. Storyboard compilation runs as part of the build; an XML problem would surface as a `ibtool` error.

- [ ] **Step 5: Add the outlet and viewDidLoad logic in `PreferenceLabViewController`**

In `LyricsX/Preferences/PreferenceLabViewController.swift`, locate the existing class body. Replace the entire current contents:

```swift
import AppKit
import LyricsXFoundation

class PreferenceLabViewController: PreferenceViewController {
    @IBOutlet var enableTouchBarLyricsButton: NSButton!

    @IBOutlet var musixmatchTokenField: NSTextField!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        enableTouchBarLyricsButton.bind(.value, withDefaultName: .touchBarLyricsEnabled)

        if let token = defaults[.musixmatchToken] {
            musixmatchTokenField.stringValue = token
        } else {
            musixmatchTokenField.stringValue = ""
        }

    }

    @IBAction func musixmatchTokenChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            defaults.remove(.musixmatchToken)
        } else {
            defaults[.musixmatchToken] = value
        }
        
        // Update lyrics manager when token changes
        Task { @MainActor in
            try await AppController.shared.updateLyricsManager()
        }
    }

    @IBAction func customizeAllowsNowPlayingApplicationsAction(_ sender: NSButton) {
        let viewController = NowPlayingApplicationListViewController()
        viewController.preferredContentSize = .init(width: 600, height: 500)
        presentAsSheet(viewController)
    }

    @IBAction func customizeTouchBarAction(_ sender: NSButton) {
        NSApplication.shared.toggleTouchBarCustomizationPalette(sender)
    }
}
```

with:

```swift
import AppKit
import LyricsXFoundation

class PreferenceLabViewController: PreferenceViewController {
    @IBOutlet var enableTouchBarLyricsButton: NSButton!

    @IBOutlet var musixmatchTokenField: NSTextField!

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

        if let token = defaults[.musixmatchToken] {
            musixmatchTokenField.stringValue = token
        } else {
            musixmatchTokenField.stringValue = ""
        }
    }

    @IBAction func musixmatchTokenChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            defaults.remove(.musixmatchToken)
        } else {
            defaults[.musixmatchToken] = value
        }

        // Update lyrics manager when token changes
        Task { @MainActor in
            try await AppController.shared.updateLyricsManager()
        }
    }

    @IBAction func customizeAllowsNowPlayingApplicationsAction(_ sender: NSButton) {
        let viewController = NowPlayingApplicationListViewController()
        viewController.preferredContentSize = .init(width: 600, height: 500)
        presentAsSheet(viewController)
    }

    @IBAction func customizeTouchBarAction(_ sender: NSButton) {
        NSApplication.shared.toggleTouchBarCustomizationPalette(sender)
    }
}
```

- [ ] **Step 6: Build to confirm no compile errors**

Run:
```bash
xcodebuild -workspace ../MxIris-LyricsX-Project.xcworkspace -scheme LyricsX -configuration Debug build 2>&1 | xcsift
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Manual UI verification**

Launch the app, open Preferences → Lab. The new checkbox `Use Apple Music-style lyrics window` should appear under the existing `Show playback controls in menu bar` row. On macOS 15+ it is interactive and unchecked by default. On macOS 11–14 it is disabled and shows the tooltip on hover (the tooltip will still be in English here — Task 4 adds translations).

Toggle it on with the HUD closed, then open the HUD via the menu — the new Apple Music-style window appears. Toggle off, close, reopen — legacy HUD returns.

- [ ] **Step 8: Commit**

```bash
git add LyricsX/Base.lproj/Preferences.storyboard LyricsX/Preferences/PreferenceLabViewController.swift
git commit -m "feat(apple-music-lyrics): add Lab pane toggle for new HUD"
```

---

## Task 4: Add Localization Entries

**Files:**
- Modify: `LyricsX/mul.lproj/Preferences.xcstrings`
- Modify: `LyricsX/Supporting Files/Localizable.xcstrings`

- [ ] **Step 1: Add `AML-Cl-001.title` to `Preferences.xcstrings`**

In `LyricsX/mul.lproj/Preferences.xcstrings`, locate the existing `MBP-Cl-001.title` block (around line 9058). Use the Edit tool with this exact `old_string`:

```
    "MBP-Cl-001.title" : {
      "comment" : "Class = \"NSButtonCell\"; title = \"Show playback controls in menu bar\"; ObjectID = \"MBP-Cl-001\";",
      "extractionState" : "extracted_with_value",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "new",
            "value" : "Show playback controls in menu bar"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "在菜单栏显示播放控制"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "在選單列顯示播放控制"
          }
        }
      }
    },
```

Replace with:

```
    "AML-Cl-001.title" : {
      "comment" : "Class = \"NSButtonCell\"; title = \"Use Apple Music-style lyrics window\"; ObjectID = \"AML-Cl-001\";",
      "extractionState" : "extracted_with_value",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "new",
            "value" : "Use Apple Music-style lyrics window"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "使用 Apple Music 风格的歌词窗口"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "使用 Apple Music 風格的歌詞視窗"
          }
        }
      }
    },
    "MBP-Cl-001.title" : {
      "comment" : "Class = \"NSButtonCell\"; title = \"Show playback controls in menu bar\"; ObjectID = \"MBP-Cl-001\";",
      "extractionState" : "extracted_with_value",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "new",
            "value" : "Show playback controls in menu bar"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "在菜单栏显示播放控制"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "在選單列顯示播放控制"
          }
        }
      }
    },
```

The new entry is inserted alphabetically before `MBP-Cl-001.title`.

- [ ] **Step 2: Add the tooltip string to `Localizable.xcstrings`**

In `LyricsX/Supporting Files/Localizable.xcstrings`, find the closing of the `strings` object — the last entry's closing `}` followed by the file-level `},` and `"version" : "1.0"`. The structure looks like:

```
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "無法啟用 Touch Bar 歌詞"
          }
        }
      }
    }
  },
  "version" : "1.0"
}
```

Use the Edit tool with this exact `old_string` (matches the very last entry's closing braces):

```
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "無法啟用 Touch Bar 歌詞"
          }
        }
      }
    }
  },
  "version" : "1.0"
}
```

Replace with:

```
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "無法啟用 Touch Bar 歌詞"
          }
        }
      }
    },
    "Requires macOS 15 or later" : {
      "comment" : "Tooltip on the Apple Music-style lyrics window toggle when the OS is too old.",
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Requires macOS 15 or later"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "需要 macOS 15 或更高版本"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "需要 macOS 15 或更新版本"
          }
        }
      }
    }
  },
  "version" : "1.0"
}
```

- [ ] **Step 3: Verify both string catalogs still parse as JSON**

Quick syntax check (does not require Xcode):

```bash
python3 -c "import json; json.load(open('LyricsX/mul.lproj/Preferences.xcstrings'))" && echo "Preferences.xcstrings OK"
python3 -c "import json; json.load(open('LyricsX/Supporting Files/Localizable.xcstrings'))" && echo "Localizable.xcstrings OK"
```

Expected: both echo `OK`. A `json.JSONDecodeError` indicates a syntax issue — re-check the Edit diff.

- [ ] **Step 4: Build to confirm no compile errors**

Run:
```bash
xcodebuild -workspace ../MxIris-LyricsX-Project.xcworkspace -scheme LyricsX -configuration Debug build 2>&1 | xcsift
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Manual localization verification**

1. Set system language to Simplified Chinese, relaunch the app, open Preferences → Lab → checkbox label reads `使用 Apple Music 风格的歌词窗口`.
2. Set system language to Traditional Chinese, relaunch, label reads `使用 Apple Music 風格的歌詞視窗`.
3. On macOS 11–14 (or by temporarily flipping the `#available` to `if false`), hover the disabled checkbox — tooltip reads the localized "Requires macOS 15 or later" string in the active language.
4. Restore system language and `#available` to defaults if changed.

- [ ] **Step 6: Commit**

```bash
git add LyricsX/mul.lproj/Preferences.xcstrings "LyricsX/Supporting Files/Localizable.xcstrings"
git commit -m "i18n(apple-music-lyrics): localize Use Apple Music-style toggle"
```

---

## Task 5: End-to-End Verification

**Files:**
- None (manual verification only)

- [ ] **Step 1: Run full scenario checklist**

Launch the app on macOS 15+. Verify each scenario from the design spec's Testing section:

1. **Default behavior.** Fresh launch (after `defaults delete com.JH.LyricsX UseAppleMusicLyricsWindow`) → Preferences → Lab → checkbox is unchecked. Open the HUD → legacy `LyricsHUDWindowController` appears.
2. **Opt in.** Check the Lab checkbox, close the HUD via menu, re-open → new Apple Music-style window appears.
3. **Opt out.** Uncheck the checkbox, close the HUD, re-open → legacy HUD returns.
4. **Live toggle does not swap.** With the HUD visible, flip the checkbox → visible window does not change. After closing and reopening, the new style takes effect.
5. **Persistence across restart.** Set the toggle to `true`, leave the HUD open, quit, relaunch → new HUD opens at launch (legacy if toggle was `false`).
6. **Orphan-window safeguard (the activeLyricsHUD path).**
   - Open HUD with toggle off → legacy shows.
   - In Preferences, flip the toggle on. Window does not change (correct — next-show wins).
   - Click the menu's "Lyrics Window" item → the **legacy** window closes (not the new one — because `activeLyricsHUD` remembers what was opened). `defaults[.isShowLyricsHUD]` is now `false`. No orphan.
   - Click the menu item again → opens the new HUD (toggle is now on).
7. **macOS < 15.** On macOS 11–14, the Lab checkbox is disabled with the localized tooltip. Toggling it (via `defaults write`) is ignored — the legacy HUD opens regardless.
8. **Shortcut path.** The "Show Lyrics Window" global shortcut goes through `showLyricsHUD(_:)`, so it respects the toggle the same way.
9. **X-button close still works.** Open the HUD, close it via the window's X button → `windowWillClose` of the controller resets `defaults[.isShowLyricsHUD] = false`. Click the menu item to reopen → fresh open path runs and matches current toggle state.
10. **Localization.** Switch app language to zh-Hans / zh-Hant → checkbox label and disabled-state tooltip are translated.

- [ ] **Step 2: If any scenario fails, diagnose and fix**

Common diagnostics:
- HUD opens but wrong style → confirm Task 2 step 4 replacement of `showLyricsHUD(_:)` is in place; confirm `openLyricsHUD()` reads `defaults[.useAppleMusicLyricsWindow]` inside the `#available` block.
- Orphan window after mid-session toggle → confirm the close path uses `activeLyricsHUD?.close()` and not the original `#available` branching.
- Checkbox label not translated → confirm Task 4 step 1 added `AML-Cl-001.title` and the storyboard button id matches `AML-Cl-001`.
- Tooltip not translated → confirm Task 4 step 2 entry exists in `Localizable.xcstrings`. The `NSLocalizedString(_:comment:)` call must use the exact source string `"Requires macOS 15 or later"`.

- [ ] **Step 3: No code change in this task unless a bug was found**

If a fix was needed, commit it with a descriptive message. Otherwise, no commit.

---

## Self-Review Notes (performed by plan author)

- **Spec coverage:** All sections of the spec are covered:
  - `useAppleMusicLyricsWindow` key + plist default → Task 1.
  - `AppDelegate` `activeLyricsHUD` + `openLyricsHUD()` + close-path safety → Task 2.
  - Lab pane checkbox + `useAppleMusicLyricsWindowButton` outlet + macOS-< 15 disable + tooltip → Task 3.
  - Storyboard `AML-*` ids and binding → Task 3.
  - `Preferences.xcstrings` `AML-Cl-001.title` + `Localizable.xcstrings` programmatic tooltip → Task 4.
  - All edge cases (mid-session toggle, X-button close, shortcut path, macOS < 15, localization) → Task 5.
- **Placeholder scan:** No TBDs, TODOs, or "handle edge cases" hand-waves. Every code step shows the exact text to insert.
- **Type consistency:** `useAppleMusicLyricsWindow` (DefaultsKey symbol), `UseAppleMusicLyricsWindow` (defaults string key), `useAppleMusicLyricsWindowButton` (outlet), `AML-Cl-001` (storyboard buttonCell id), `activeLyricsHUD` (instance var), `openLyricsHUD()` (helper) — all names used identically across all tasks.
- **Scope:** Single subsystem (HUD selection + one new preference); fits a single plan.
