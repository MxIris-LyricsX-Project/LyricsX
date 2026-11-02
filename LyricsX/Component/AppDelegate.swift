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

    /// The status menu's lyrics offset row, which lines its label up with the
    /// menu's titles by itself.
    @IBOutlet var lyricsOffsetView: TitleAlignedMenuItemView!
    @IBOutlet var lyricsOffsetTextField: NSTextField!
    @IBOutlet var lyricsOffsetStepper: NSStepper!
    @IBOutlet var statusBarMenu: NSMenu!

    private var localLyricsMenuItems: [NSMenuItem] = []
    private var localLyricsChoices: [AppController.LocalLyricsChoice] = []
    private var localLyricsChoicesTrackKey: String?
    private var localLyricsRefreshGeneration = 0
    private var localLyricsRefreshInFlight = false
    private var localLyricsLastRefresh: Date?
    private var localLyricsTrackCancellable: AnyCancellable?
    private var localLyricsCandidatesCancellable: AnyCancellable?
    private var localLyricsSourceCancellable: AnyCancellable?
    private var localLyricsPublishedSource: AppController.LocalLyricsSource?
    private var localLyricsObservedTrackSignature: String?

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
        observeLocalLyricsTrackChanges()

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

        // After an update the desktop widgets are still answered by the old
        // version's widget extension until something ends it.
        DispatchQueue.global(qos: .utility).async {
            StaleWidgetExtensionTerminator().terminateStaleProcesses()
        }

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
        performOnLyricsDisplayQueue {
            if AppController.shared.currentLyrics?.metadata.needsPersist == true {
                AppController.shared.currentLyrics?.persist()
            }
            AppController.shared.retireWidgetSnapshot()
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
        guard menu === statusBarMenu, let searchItem = menu.item(withTag: 201) else { return }
        let currentTrackKey = localLyricsTrackKey(selectedPlayer.currentTrack)
        if currentTrackKey != localLyricsChoicesTrackKey {
            localLyricsChoicesTrackKey = currentTrackKey
            localLyricsChoices = []
            localLyricsLastRefresh = nil
            localLyricsRefreshGeneration += 1
            localLyricsRefreshInFlight = false
            if currentTrackKey != nil {
                // NSMenu may ask for items before menuWillOpen. Start the
                // refresh here so the first render can show its loading state.
                refreshLocalLyricsChoices()
            }
        }
        for item in localLyricsMenuItems {
            menu.removeItem(item)
        }
        let localLyricsMenuItem = NSMenuItem(
            title: NSLocalizedString("Local Lyrics", comment: "Local lyrics submenu title"), action: nil, keyEquivalent: ""
        )
        let localLyricsSubmenu = NSMenu(title: localLyricsMenuItem.title)
        localLyricsMenuItem.submenu = localLyricsSubmenu
        let choices = localLyricsChoices
        let currentSource = localLyricsPublishedSource
        for choice in choices {
            let item = NSMenuItem(title: choice.title, action: #selector(selectLocalLyrics(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice
            item.state = currentSource == choice.source ? .on : .off
            if case .file(let url) = choice.source {
                item.toolTip = url.path
            } else if choice.source == .lyricsX, let url = choice.lyricsXFileURL {
                item.toolTip = url.path
            }
            localLyricsSubmenu.addItem(item)
        }
        if choices.isEmpty {
            let item = NSMenuItem(
                title: NSLocalizedString(
                    localLyricsRefreshInFlight ? "Loading Local Lyrics…" : "No Local Lyrics Available",
                    comment: "Local lyrics menu status"
                ),
                action: nil, keyEquivalent: ""
            )
            item.isEnabled = false
            localLyricsSubmenu.addItem(item)
        }
        localLyricsMenuItems = [.separator(), localLyricsMenuItem, .separator()]
        let insertionIndex = menu.index(of: searchItem) + 1
        for (offset, item) in localLyricsMenuItems.enumerated() {
            menu.insertItem(item, at: insertionIndex + offset)
        }
    }

    // MARK: - Menubar Action

    @objc private func selectLocalLyrics(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? AppController.LocalLyricsChoice else { return }
        AppController.shared.applyLocalLyrics(choice) { applied, error in
            guard !applied,
                  let error,
                  selectedPlayer.currentTrack?.id == choice.track.id else {
                return
            }
            NSApp.presentError(error)
        }
    }

    private func localLyricsTrackKey(_ track: MusicTrack?) -> String? {
        track.map { String(describing: $0.id) }
    }

    private func observeLocalLyricsTrackChanges() {
        localLyricsTrackCancellable = selectedPlayer.currentTrackWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Read after the player's will-change publication has completed.
                self?.preloadLocalLyricsForCurrentTrack()
            }
        localLyricsCandidatesCancellable = NotificationCenter.default.publisher(
            for: .lyricsCandidatesDidChange,
            object: AppController.shared
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            guard let self,
                  let trackID = notification.userInfo?["trackID"] as? String,
                  selectedPlayer.currentTrack?.id == trackID else {
                return
            }
            // Selected online results and writes into Music can change the
            // available lyrics without changing the track. Discard snapshots.
            self.localLyricsLastRefresh = nil
            if self.localLyricsRefreshInFlight {
                self.localLyricsRefreshGeneration += 1
                self.localLyricsRefreshInFlight = false
            }
            self.refreshLocalLyricsChoices()
            self.statusBarMenu.update()
        }

        // The source is published after a local load commits, so this also
        // covers fallback from an invalid managed file to another one without
        // relying on the candidate-list notification.
        localLyricsPublishedSource = AppController.shared.currentLocalLyricsSource
        localLyricsSourceCancellable = AppController.shared.$currentLocalLyricsSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] source in
                guard let self else { return }
                // Use the value emitted by @Published. The property wrapper
                // publishes during willSet, so re-reading the controller here
                // could still observe the previous value on another queue.
                self.localLyricsPublishedSource = source
                self.statusBarMenu.update()
            }

        // Explicitly handle launch with a song already playing, without relying
        // on the selected adapter replaying its current value on subscription.
        // Register all observers first so a source update from the initial
        // lookup cannot be missed.
        preloadLocalLyricsForCurrentTrack()
    }

    private func preloadLocalLyricsForCurrentTrack() {
        let track = selectedPlayer.currentTrack
        // MusicTrack equality compares only IDs. A file URL or scripting object
        // arriving later for the same song must also trigger a lookup.
        let signature = track.map {
            "\($0.id)|\($0.fileURL?.absoluteString ?? "")|\($0.originalTrack != nil)"
        }
        guard signature != localLyricsObservedTrackSignature else { return }
        localLyricsObservedTrackSignature = signature
        localLyricsRefreshGeneration += 1
        localLyricsRefreshInFlight = false
        localLyricsLastRefresh = nil
        localLyricsChoices = []
        localLyricsChoicesTrackKey = localLyricsTrackKey(track)
        refreshLocalLyricsChoices()
        statusBarMenu.update()
    }

    private func refreshLocalLyricsChoices() {
        guard let track = selectedPlayer.currentTrack else {
            localLyricsChoices = []
            localLyricsChoicesTrackKey = nil
            localLyricsRefreshInFlight = false
            return
        }
        let trackKey = localLyricsTrackKey(track)
        if localLyricsRefreshInFlight, localLyricsChoicesTrackKey == trackKey {
            return
        }
        // Reuse the embedded snapshot briefly, but still discover external edits
        // on subsequent refreshes. Track changes always bypass this cache.
        if localLyricsChoicesTrackKey == trackKey,
           let lastRefresh = localLyricsLastRefresh,
           Date().timeIntervalSince(lastRefresh) < 10 { return }
        localLyricsChoicesTrackKey = trackKey
        localLyricsRefreshGeneration += 1
        let generation = localLyricsRefreshGeneration
        localLyricsRefreshInFlight = true
        AppController.shared.refreshLocalLyricsChoices { [weak self] resultTrack, choices, isFinal in
            guard let self, self.localLyricsRefreshGeneration == generation else { return }
            guard self.localLyricsTrackKey(resultTrack) == trackKey,
                  self.localLyricsTrackKey(selectedPlayer.currentTrack) == trackKey else {
                return
            }
            self.localLyricsRefreshInFlight = !isFinal
            if isFinal { self.localLyricsLastRefresh = Date() }
            if isFinal || self.localLyricsLastRefresh == nil {
                self.localLyricsChoices = choices
            } else {
                // Partial results may not yet contain the fallback location or
                // embedded entry. Remove stale choices only on the final result.
                let retained = self.localLyricsChoices.filter { previous in
                    !choices.contains { $0.source == previous.source }
                }
                self.localLyricsChoices = retained + choices
            }
            self.statusBarMenu.update()
        }
    }

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
        let localURL = performOnLyricsDisplayQueue { () -> URL? in
            guard let lyrics = AppController.shared.currentLyrics else {
                return nil
            }
            if lyrics.metadata.needsPersist {
                lyrics.persist()
            }
            return lyrics.metadata.localURL
        }
        guard let localURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([localURL])
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

        enum ExistingLyricsEditTarget {
            case noLyrics
            case file(URL, URL?)
            case unavailable
        }

        let existingLyricsTarget = performOnLyricsDisplayQueue { () -> ExistingLyricsEditTarget in
            guard let lyrics = AppController.shared.currentLyrics else {
                return .noLyrics
            }
            guard selectedPlayer.currentTrack?.id == track.id else {
                return .unavailable
            }

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
                return .unavailable
            }
            // Opening should work for every local lyrics file, including user-owned
            // beside-track files. Only the custom lyrics library needs a security scope.
            return .file(
                localURL,
                defaults.lyricsSecurityScopedDirectory(containing: localURL)
            )
        }

        let url: URL
        let securityScopedDirectoryURL: URL?
        switch existingLyricsTarget {
        case .file(let localURL, let scopedDirectoryURL):
            url = localURL
            securityScopedDirectoryURL = scopedDirectoryURL
        case .unavailable:
            return
        case .noLyrics:
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
        guard let textEditURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            securityScopedDirectoryURL?.stopAccessingSecurityScopedResource()
            NSSound.beep()
            return
        }
        workspace.open([url], withApplicationAt: textEditURL, configuration: .init()) { _, error in
            securityScopedDirectoryURL?.stopAccessingSecurityScopedResource()
            if error != nil {
                DispatchQueue.main.async {
                    NSSound.beep()
                }
            }
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
            AppController.shared.removeRejectedLyricsFromMusic(of: track)
        }
        removeRejectedLyricsFile()
        AppController.shared.currentLyrics = nil
        AppController.shared.cancelLyricsSearches()
    }

    @IBAction func doNotSearchLyricsForThisAlbum(_ sender: Any?) {
        guard let track = selectedPlayer.currentTrack,
              let album = track.album else {
            return
        }
        defaults[.noSearchingAlbumNames].append(album)
        if defaults[.writeToiTunesAutomatically] {
            AppController.shared.removeRejectedLyricsFromMusic(of: track)
        }
        removeRejectedLyricsFile()
        AppController.shared.currentLyrics = nil
        AppController.shared.cancelLyricsSearches()
    }

    /// Deletes LyricsX's own copy of the lyrics the user just rejected, so the
    /// next lookup cannot bring them back. A file beside the track is left
    /// alone: it is the user's, not LyricsX's to delete.
    private func removeRejectedLyricsFile() {
        guard let fileURL = LyricsStoragePolicy.fileToRemoveWhenRejected(
            localURL: AppController.shared.currentLyrics?.metadata.localURL,
            defaultDirectoryURL: defaults.lyricsDefaultSavingDirectory,
            customDirectoryURL: defaults.lyricsCustomSavingPath
        ) else {
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
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
        if menu === statusBarMenu {
            refreshLocalLyricsChoices()
            statusBarMenu.update()
        }
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
