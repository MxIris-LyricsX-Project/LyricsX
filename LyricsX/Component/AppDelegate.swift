import AppKit
import GenericID
import MASShortcut
import MusicPlayer
import Sparkle
import Semver

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    static var shared: AppDelegate? {
        return NSApplication.shared.delegate as? AppDelegate
    }

    @IBOutlet var lyricsOffsetView: NSView!
    @IBOutlet var lyricsOffsetTextField: NSTextField!
    @IBOutlet var lyricsOffsetStepper: NSStepper!
    @IBOutlet var statusBarMenu: NSMenu!

    private lazy var updateController = SPUStandardUpdaterController(updaterDelegate: nil, userDriverDelegate: self)

    var firstLaunchForShouldHanlderReopen: Bool = true

    var karaokeLyricsWC: KaraokeLyricsWindowController?

    lazy var searchLyricsWC: SearchLyricsWindowController = .init()

    lazy var lyricsHUD: LyricsHUDWindowController = .create()

    lazy var preferencesWindowController: PreferenceWindowController = .create()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        UserDefaultsMigrator.shared.migrateFromSandboxIfNeeded()
        registerUserDefaults()

        let controller = AppController.shared

        karaokeLyricsWC = KaraokeLyricsWindowController()
        karaokeLyricsWC?.showWindow(nil)

        MenuBarLyricsController.shared.statusBarMenu = statusBarMenu
        statusBarMenu.delegate = self

        lyricsOffsetStepper.bind(
            .value,
            to: controller,
            withKeyPath: #keyPath(AppController.lyricsOffset),
            options: [.continuouslyUpdatesValue: true]
        )

        lyricsOffsetTextField.bind(
            .value,
            to: controller,
            withKeyPath: #keyPath(AppController.lyricsOffset),
            options: [.continuouslyUpdatesValue: true]
        )

        setupShortcuts()

        NSRunningApplication.runningApplications(withBundleIdentifier: lyricsXHelperIdentifier).forEach { $0.terminate() }

        // Mirror the keys LyricsXHelper reads from the shared suite. KVO on the
        // standard defaults is reliable; Cocoa Bindings to a bare UserDefaults
        // instance was not — it never actually pushed values into the suite, so
        // the helper read a stale/absent value and exited. `.initial` writes the
        // current value at launch; `.new` keeps the suite in sync as the user
        // toggles the preference.
        observeDefaults(key: .launchAndQuitWithPlayer, options: [.new, .initial]) { _, change in
            sharedDefaults[.launchAndQuitWithPlayer] = change.newValue
        }
        observeDefaults(key: .preferredPlayerIndex, options: [.new, .initial]) { _, change in
            sharedDefaults[.preferredPlayerIndex] = change.newValue
        }

        updateController.updater.checkForUpdatesInBackground()

        observeDefaults(key: .touchBarLyricsEnabled, options: [.new, .initial]) { _, change in
            if change.newValue, TouchBarLyricsController.shared == nil {
                TouchBarLyricsController.shared = TouchBarLyricsController()
            } else if !change.newValue, TouchBarLyricsController.shared != nil {
                TouchBarLyricsController.shared = nil
            }
        }

        if defaults[.isShowLyricsHUD] {
            lyricsHUD.showWindow(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if firstLaunchForShouldHanlderReopen {
            firstLaunchForShouldHanlderReopen = false
            return false
        }
        preferencesWindowController.showWindow(nil)
        return true
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        if AppController.shared.currentLyrics?.metadata.needsPersist == true {
            AppController.shared.currentLyrics?.persist()
        }
        if defaults[.launchAndQuitWithPlayer] {
            let url = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LoginItems/LyricsXHelper.app")
            // Write everything the helper reads at launch right before spawning
            // it, then flush — don't rely on cfprefsd having the latest values
            // batched when this process dies.
            sharedDefaults[.launchAndQuitWithPlayer] = defaults[.launchAndQuitWithPlayer]
            sharedDefaults[.preferredPlayerIndex] = defaults[.preferredPlayerIndex]
            sharedDefaults[.launchHelperTime] = Date()
            sharedDefaults.synchronize()

            // `openApplication` is asynchronous and we're seconds away from
            // process death — block briefly so the LaunchServices request
            // actually leaves this process before NSApp.terminate proceeds.
            let semaphore = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { application, error in
                if let error = error {
                    log("launch LyricsX Helper failed. reason: \(error)")
                } else {
                    log("launch LyricsX Helper succeed.")
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + .milliseconds(500))
        }
    }

    private func setupShortcuts() {
        let binder = MASShortcutBinder.shared()!
        binder.bindBoolShortcut(.shortcutToggleMenuBarLyrics, target: .menuBarLyricsEnabled)
        binder.bindBoolShortcut(.shortcutToggleKaraokeLyrics, target: .desktopLyricsEnabled)
        binder.bindShortcut(.shortcutShowLyricsWindow, to: #selector(showLyricsHUD))
        binder.bindShortcut(.shortcutOffsetIncrease, to: #selector(increaseOffset))
        binder.bindShortcut(.shortcutOffsetDecrease, to: #selector(decreaseOffset))
        binder.bindShortcut(.shortcutWriteToiTunes, to: #selector(writeToiTunes))
        binder.bindShortcut(.shortcutWrongLyrics, to: #selector(wrongLyrics))
        binder.bindShortcut(.shortcutSearchLyrics, to: #selector(searchLyrics))
        binder.bindShortcut(.shortcutTogglePreferences, to: #selector(togglePreferences))
    }

    // MARK: - NSMenuDelegate

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(writeToiTunes(_:))?:
            return selectedPlayer.name == .appleMusic && AppController.shared.currentLyrics != nil
        case #selector(searchLyrics(_:))?:
            return selectedPlayer.currentTrack != nil
        default:
            return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 202)?.isEnabled = AppController.shared.currentLyrics != nil
    }

    // MARK: - Menubar Action

    @IBAction func showLyricsHUD(_ sender: Any?) {
        if defaults[.isShowLyricsHUD] {
            lyricsHUD.close()
            defaults[.isShowLyricsHUD] = false
        } else {
            lyricsHUD.showWindow(nil)
            defaults[.isShowLyricsHUD] = true
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func aboutLyricsXAction(_ sender: Any) {
        if #available(OSX 10.13, *) {
            let channel = "GitHub"
            let versionString = "\(channel) Version \(Bundle.main.semanticVersion ?? "Unknown")"
            NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: versionString])
        } else {
            NSApp.orderFrontStandardAboutPanel(sender)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func showPreferences(_ sender: Any?) {
        preferencesWindowController.showWindow(nil)
    }

    @objc func togglePreferences(_ sender: Any?) {
        if preferencesWindowController.window?.isVisible ?? false {
            preferencesWindowController.close()
        } else {
            preferencesWindowController.showWindow(nil)
        }
    }

    @IBAction func checkUpdateAction(_ sender: Any) {
        updateController.checkForUpdates(sender)
    }

    @IBAction func increaseOffset(_ sender: Any?) {
        AppController.shared.lyricsOffset += 100
    }

    @IBAction func decreaseOffset(_ sender: Any?) {
        AppController.shared.lyricsOffset -= 100
    }

    @IBAction func showCurrentLyricsInFinder(_ sender: Any?) {
        guard let lyrics = AppController.shared.currentLyrics else {
            return
        }
        if lyrics.metadata.needsPersist {
            lyrics.persist()
        }
        if let url = lyrics.metadata.localURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @IBAction func writeToiTunes(_ sender: Any?) {
        AppController.shared.writeToiTunes(overwrite: true)
    }

    @IBAction func searchLyrics(_ sender: Any?) {
        searchLyricsWC.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func wrongLyrics(_ sender: Any?) {
        guard let track = selectedPlayer.currentTrack else {
            return
        }
        defaults[.noSearchingTrackIds].append(track.id)
        if defaults[.writeToiTunesAutomatically] {
            track.setLyrics("")
        }
        if let url = AppController.shared.currentLyrics?.metadata.localURL {
            try? FileManager.default.removeItem(at: url)
        }
        AppController.shared.currentLyrics = nil
        AppController.shared.searchTask?.cancel()
    }

    @IBAction func doNotSearchLyricsForThisAlbum(_ sender: Any?) {
        guard let track = selectedPlayer.currentTrack,
              let album = track.album else {
            return
        }
        defaults[.noSearchingAlbumNames].append(album)
        if defaults[.writeToiTunesAutomatically] {
            track.setLyrics("")
        }
        if let url = AppController.shared.currentLyrics?.metadata.localURL {
            try? FileManager.default.removeItem(at: url)
        }
        AppController.shared.currentLyrics = nil
    }

    func registerUserDefaults() {
        let currentLang = NSLocale.preferredLanguages.first!
        let isZh = currentLang.hasPrefix("zh") || currentLang.hasPrefix("yue")
        let isHant = isZh && (currentLang.contains("-Hant") || currentLang.contains("-HK"))

        let defaultsUrl = Bundle.main.url(forResource: "UserDefaults", withExtension: "plist")!
        if let dict = NSDictionary(contentsOf: defaultsUrl) as? [String: Any] {
            defaults.register(defaults: dict)
        }
        defaults.register(defaults: [
            .desktopLyricsColor: #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1),
            .desktopLyricsProgressColor: #colorLiteral(red: 0.1985405816, green: 1, blue: 0.8664234302, alpha: 1),
            .desktopLyricsShadowColor: #colorLiteral(red: 0, green: 1, blue: 0.8333333333, alpha: 1),
            .desktopLyricsBackgroundColor: #colorLiteral(red: 0, green: 0, blue: 0, alpha: 0.6041579279),
            .lyricsWindowTextColor: #colorLiteral(red: 0.7540688515, green: 0.7540867925, blue: 0.7540771365, alpha: 1),
            .lyricsWindowHighlightColor: #colorLiteral(red: 0.8866666667, green: 1, blue: 0.8, alpha: 1),
            .preferBilingualLyrics: isZh,
            .chineseConversionIndex: isHant ? 2 : 0,
            .desktopLyricsXPositionFactor: 0.5,
            .desktopLyricsYPositionFactor: 0.9,
        ])
    }

    func menuWillOpen(_ menu: NSMenu) {
        if #available(macOS 11, *) {
            let menuHasOnState = statusBarMenu.items.filter { menuItem in
                return menuItem.state == .on
            }.count > 0

            let lyricsOffsetConstraint = lyricsOffsetView.constraints.first(where: { $0.identifier == "lyricsOffsetConstraint" })

            lyricsOffsetConstraint?.constant = 14
            if menuHasOnState {
                lyricsOffsetConstraint?.constant += 10
            }
        }
    }
}

extension AppDelegate: SPUStandardUserDriverDelegate {
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        return true
    }
}

extension MASShortcutBinder {
    func bindShortcut<T>(_ defaultsKay: UserDefaults.DefaultsKey<T>, to action: @escaping () -> Void) {
        bindShortcut(withDefaultsKey: defaultsKay.key, toAction: action)
    }

    func bindBoolShortcut<T>(_ defaultsKay: UserDefaults.DefaultsKey<T>, target: UserDefaults.DefaultsKey<Bool>) {
        bindShortcut(withDefaultsKey: defaultsKay.key) {
            defaults[target] = !defaults[target]
        }
    }

    func bindShortcut<T>(_ defaultsKay: UserDefaults.DefaultsKey<T>, to action: Selector) {
        bindShortcut(defaultsKay) {
            let target = NSApplication.shared.target(forAction: action) as AnyObject?
            _ = target?.perform(action, with: self)
        }
    }
}
