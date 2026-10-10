import AppKit
import AppleMusicLyricsPanel
import Combine
import GenericID
import LyricsXFoundation
import MASShortcut
import MusicKit
import MusicPlayer
import Sparkle
import Semver
import FoundationToolbox

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    static var shared: AppDelegate { NSApplication.shared.delegate as! AppDelegate }

    @IBOutlet var lyricsOffsetView: NSView!
    @IBOutlet var lyricsOffsetTextField: NSTextField!
    @IBOutlet var lyricsOffsetStepper: NSStepper!
    @IBOutlet var statusBarMenu: NSMenu!

    private lazy var updateController = SPUStandardUpdaterController(updaterDelegate: self, userDriverDelegate: self)

    var firstLaunchForShouldHanlderReopen: Bool = true

    var karaokeLyricsWC: KaraokeLyricsWindowController?

    lazy var searchLyricsWC: SearchLyricsWindowController = .init()

    lazy var lyricsHUD: LyricsHUDWindowController = .create()

    private var activeLyricsHUD: NSWindowController?
    private var lyricsHUDCloseObserver: NSObjectProtocol?

    private var lyricsCandidateSwitchCancellable: AnyCancellable?

    private func openLyricsHUD() {
        // Create the Apple Music lyrics window lazily, only when actually
        // opened, and release it again on close (see `releaseActiveLyricsHUD`).
        // Users who never open it keep no SwiftUI hosting view or 30fps refresh
        // timer alive in the background. `lyricsHUD` stays a cached lazy
        // property (lightweight) and is reused across opens.
        let hud: NSWindowController
        if defaults[.useAppleMusicLyricsWindow] {
            hud = AppleMusicLyrics.WindowController()
        } else {
            hud = lyricsHUD
        }
        hud.showWindow(nil)
        activeLyricsHUD = hud
        observeLyricsHUDClose(hud)
    }

    /// Drop the strong reference to the HUD when its window closes (e.g. via the
    /// window's own close button) so the Apple Music window's controller,
    /// SwiftUI hosting view and 30fps timer are deallocated instead of lingering.
    /// `lyricsHUD` has its own lazy owner and merely loses the `activeLyricsHUD`
    /// pointer here.
    private func observeLyricsHUDClose(_ hud: NSWindowController) {
        if let observer = lyricsHUDCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            lyricsHUDCloseObserver = nil
        }
        guard let window = hud.window else { return }
        lyricsHUDCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.releaseActiveLyricsHUD()
        }
    }

    private func releaseActiveLyricsHUD() {
        if let observer = lyricsHUDCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            lyricsHUDCloseObserver = nil
        }
        activeLyricsHUD = nil
    }

    lazy var preferencesWindowController: PreferenceWindowController = .create()

    private let playbackSourceNameResolver = PlaybackPlayerLauncher()
    private let playbackPlayerLauncher = PlaybackPlayerLauncher()

    private lazy var playbackMenuView: PlaybackMenuView = {
        let view = PlaybackMenuView(player: selectedPlayer, openPlayer: { [weak self] in self?.playbackPlayerLauncher.open($0) })
        view.sourceIdentity = {
            var source: MusicPlayerProtocol? = selectedPlayer
            var visited = Set<ObjectIdentifier>()
            while let agent = source as? MusicPlayers.Agent {
                guard visited.insert(ObjectIdentifier(agent)).inserted else { return nil }
                source = agent.designatedPlayer
            }
            return source.map(ObjectIdentifier.init)
        }
        view.resolveSourceName = { [weak self] player, completion in
            self?.playbackSourceNameResolver.resolveName(player, completion: completion)
        }
        view.cancelSourceResolution = { [weak self] in self?.playbackSourceNameResolver.cancel() }
        return view
    }()

    private lazy var playbackMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = playbackMenuView
        return item
    }()
    private let playbackMenuSeparator = NSMenuItem.separator()

    private func updatePlaybackControlsVisibility() {
        let enabled = defaults[.playbackControlsEnabled]
        playbackMenuItem.isHidden = !enabled
        playbackMenuSeparator.isHidden = !enabled
        if !enabled { playbackMenuView.endTracking() }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        UserDefaultsMigrator.shared.migrateFromSandboxIfNeeded()
        // Both migrations read raw persisted values, so they have to run before
        // `register(defaults:)` puts fallbacks in front of them.
        UserDefaultsMigrator.shared.migrateSourceOrderingModeIfNeeded()
        registerUserDefaults()

        let controller = AppController.shared

        karaokeLyricsWC = KaraokeLyricsWindowController()
        karaokeLyricsWC?.showWindow(nil)

        MenuBarLyricsController.shared.statusBarMenu = statusBarMenu
        statusBarMenu.delegate = self
        statusBarMenu.insertItem(playbackMenuItem, at: 0)
        statusBarMenu.insertItem(playbackMenuSeparator, at: 1)
        observeDefaults(key: .playbackControlsEnabled, options: [.new, .initial]) { [weak self] _, _ in
            self?.updatePlaybackControlsVisibility()
        }

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
        observeLyricsCandidateSwitches()

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

        // Flipping the beta toggle should take effect immediately. Sparkle
        // re-evaluates allowedChannels(for:) on every feed parse, so kicking
        // a background check is enough — no feed-URL swap required.
        observeDefaults(key: .receiveBetaUpdates, options: [.new]) { [weak self] _, _ in
            self?.updateController.updater.checkForUpdatesInBackground()
        }

        observeDefaults(key: .touchBarLyricsEnabled, options: [.new, .initial]) { _, change in
            if change.newValue, TouchBarLyricsController.shared == nil {
                TouchBarLyricsController.shared = TouchBarLyricsController()
            } else if !change.newValue, TouchBarLyricsController.shared != nil {
                TouchBarLyricsController.shared = nil
            }
        }

        DispatchQueue.main.async { [self] in
            if defaults[.isShowLyricsHUD] {
                openLyricsHUD()
            }
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
        binder.bindShortcut(.shortcutNextLyricsCandidate, to: #selector(nextLyricsCandidate))
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
        case #selector(nextLyricsCandidate(_:))?:
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
        let isWindowVisible = activeLyricsHUD?.window?.isVisible ?? false
        let presentationAction = LyricsWindowPresentationDecision.action(
            isWindowVisible: isWindowVisible,
            isApplicationActive: NSApp.isActive
        )
        switch presentationAction {
        case .show, .bringToFront:
            if let activeLyricsHUD {
                activeLyricsHUD.showWindow(nil)
            } else {
                openLyricsHUD()
            }
            defaults[.isShowLyricsHUD] = true
            NSApp.activate(ignoringOtherApps: true)
        case .close:
            activeLyricsHUD?.close()
            activeLyricsHUD = nil
            defaults[.isShowLyricsHUD] = false
        }
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

    var canEditCurrentLyrics: Bool {
        let lyrics = AppController.shared.currentLyrics
        let track = selectedPlayer.currentTrack
        let canCreateBlankFile = track.flatMap {
            defaults.lyricsSavingDestination(
                title: $0.title,
                artist: $0.artist
            )
        } != nil
        return LyricsEditingPolicy.canEdit(
            hasLyrics: lyrics != nil,
            hasLocalFile: lyrics?.metadata.localURL != nil,
            canPersist: lyrics?.metadata.needsPersist == true,
            canCreateBlankFile: canCreateBlankFile
        )
    }

    @IBAction func editCurrentLyrics(_ sender: Any?) {
        guard let track = selectedPlayer.currentTrack else {
            return
        }

        let url: URL
        let securityScopedDirectoryURL: URL?
        if let lyrics = AppController.shared.currentLyrics {
            // The mark has to be in the file before the editor gets it: the
            // saving is done by the user in another app from here on, and
            // LyricsX never sees the result to mark it afterwards.
            //
            // Only when the write lands on the file about to be opened, though.
            // Lyrics that came from beside the track are read-only by default,
            // so persisting them produces a library copy — and the user would
            // then be editing a file the lookup never reaches, since the
            // beside-track original still wins. Those files are not the switch's
            // business anyway, so leaving them unmarked costs nothing.
            if let localURL = lyrics.metadata.localURL {
                if defaults.lyricsPersistRewritesFileInPlace(localURL) {
                    lyrics.markAsUserPicked(origin: .edit)
                    lyrics.metadata.needsPersist = true
                    lyrics.persist()
                }
            } else if lyrics.metadata.needsPersist {
                // Never written anywhere yet, so this creates the library file
                // and the mark rides along with it.
                lyrics.markAsUserPicked(origin: .edit)
                lyrics.persist()
            }
            guard let localURL = lyrics.metadata.localURL else {
                return
            }
            url = localURL
            // Opening should work for every local lyrics file, including user-owned
            // beside-track files. Only the custom lyrics library needs a security scope.
            securityScopedDirectoryURL = defaults.lyricsSecurityScopedDirectory(containing: localURL)
        } else {
            guard let destination = defaults.lyricsSavingDestination(
                title: track.title,
                artist: track.artist
            ) else {
                NSSound.beep()
                return
            }
            do {
                // The new file opens with the mark already on its first line,
                // so lyrics typed underneath count as the user's own choice.
                url = try LyricsStoragePolicy.prepareEmptyFile(
                    at: destination,
                    initialContents: Lyrics.userPickMarkLine(origin: .edit)
                )
                securityScopedDirectoryURL = destination.securityScopedDirectoryURL
            } catch {
                log(error.localizedDescription)
                NSSound.beep()
                return
            }
        }

        let workspace = NSWorkspace.shared
        if let securityScopedDirectoryURL,
           !securityScopedDirectoryURL.startAccessingSecurityScopedResource() {
            NSSound.beep()
            return
        }
        if #available(macOS 10.15, *),
           let textEditURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            workspace.open([url], withApplicationAt: textEditURL, configuration: .init()) { _, error in
                securityScopedDirectoryURL?.stopAccessingSecurityScopedResource()
                if error != nil {
                    DispatchQueue.main.async {
                        NSSound.beep()
                    }
                }
            }
            return
        }

        defer {
            securityScopedDirectoryURL?.stopAccessingSecurityScopedResource()
        }
        if !workspace.openFile(url.path, withApplication: "TextEdit") {
            NSSound.beep()
        }
    }

    @IBAction func nextLyricsCandidate(_ sender: Any?) {
        AppController.shared.advanceToNextLyricsCandidate()
    }

    /// The switch itself reports back asynchronously — the replenish path has to
    /// finish a search first — so both paths are answered from one subscription
    /// rather than from the action's return value.
    private func observeLyricsCandidateSwitches() {
        lyricsCandidateSwitchCancellable = AppController.shared.lyricsCandidateSwitchOutcomes
            .receive(on: DispatchQueue.main)
            .sink { outcome in
                Task { @MainActor in
                    guard let message = AppDelegate.message(for: outcome) else {
                        NSSound.beep()
                        return
                    }
                    TransientMessageWindowController.shared.present(message: message)
                }
            }
    }

    private static func message(for outcome: LyricsCandidateSwitchOutcome) -> String? {
        switch outcome {
        case .switched(let position, let total, let service):
            guard let service, !service.isEmpty else {
                let format = NSLocalizedString("Lyrics %1$d of %2$d", comment: "Transient message after switching to another lyrics candidate, when the source is unknown. %1$d is the 1-based position, %2$d the number of candidates.")
                return String(format: format, position, total)
            }
            let format = NSLocalizedString("Lyrics %1$d of %2$d · %3$@", comment: "Transient message after switching to another lyrics candidate. %1$d is the 1-based position, %2$d the number of candidates, %3$@ the lyrics source name.")
            return String(format: format, position, total, service)
        case .searching:
            return NSLocalizedString("Searching for other lyrics…", comment: "Transient message shown when the next-candidate shortcut has to run a search first, because nothing else was in the pool.")
        case .exhausted:
            return NSLocalizedString("No other lyrics found", comment: "Transient message shown when a search for other lyrics candidates turned up nothing but what is already displayed.")
        case .unavailable:
            return nil
        }
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
        updatePlaybackControlsVisibility()
        if defaults[.playbackControlsEnabled] { playbackMenuView.beginTracking() }
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
    func menuDidClose(_ menu: NSMenu) {
        playbackMenuView.endTracking()
    }
}

extension AppDelegate: SPUStandardUserDriverDelegate {
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        return true
    }
}

extension AppDelegate: SPUUpdaterDelegate {
    // Sparkle's channel contract: items WITHOUT <sparkle:channel> are always
    // eligible; items WITH a channel are only eligible if the channel name is
    // in the returned set. So {} = "stable only", {"beta"} = "stable + beta".
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        return defaults[.receiveBetaUpdates] ? ["beta"] : []
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
