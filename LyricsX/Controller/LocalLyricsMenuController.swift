import AppKit
import Combine
import LyricsXFoundation
import MusicPlayer

/// Owns the Local Lyrics submenu, its subscriptions and its refresh lifetime.
/// Menu state is updated on the main queue; LocalLyricsCatalog performs file and metadata reads.
final class LocalLyricsMenuController: NSObject {
    private let statusBarMenu: NSMenu
    private let submenu = NSMenu(title: NSLocalizedString("Local Lyrics", comment: "Local lyrics submenu title"))
    private lazy var submenuItem = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
    private var choices: [LocalLyricsChoice] = []
    private var choicesTrackKey: String?
    private var refreshState = LocalLyricsRefreshState()
    private var activationCancellable: AnyCancellable?
    private var trackCancellable: AnyCancellable?
    private var candidatesCancellable: AnyCancellable?
    private var sourceCancellable: AnyCancellable?
    private var publishedSource: LocalLyricsSource?
    private var observedTrackKey: String?
    private var observedTrackSignature: String?

    init(menu: NSMenu) {
        statusBarMenu = menu
        super.init()
    }

    func updateMenu() {
        let menu = statusBarMenu
        guard let searchItem = menu.item(withTag: 201) else { return }
        let currentTrackKey = selectedPlayer.currentTrack?.id
        if currentTrackKey != choicesTrackKey {
            resetChoices(for: currentTrackKey)
            if currentTrackKey != nil {
                // NSMenu may ask for items before menuWillOpen. Start the
                // refresh here so the first render can show its loading state.
                refresh()
            }
        }
        if submenuItem.menu == nil {
            submenuItem.submenu = submenu
            let index = menu.index(of: searchItem) + 1
            menu.insertItem(.separator(), at: index)
            menu.insertItem(submenuItem, at: index + 1)
            menu.insertItem(.separator(), at: index + 2)
        }
        var desiredItems: [NSMenuItem] = []
        for choice in choices {
            // Keep both the submenu and existing rows alive while AppKit tracks the pointer.
            let item = submenu.items.first {
                ($0.representedObject as? LocalLyricsChoice)?.source == choice.source
            } ?? NSMenuItem(title: choice.title, action: #selector(selectLocalLyrics(_:)), keyEquivalent: "")
            item.title = choice.title
            item.target = self
            item.representedObject = choice
            item.state = publishedSource == choice.source ? .on : .off
            if case .file(let url) = choice.source {
                item.toolTip = url.path
            } else {
                item.toolTip = choice.lyricsXFileURL?.path
            }
            desiredItems.append(item)
        }
        if desiredItems.isEmpty {
            let item = submenu.items.first { $0.representedObject == nil }
                ?? NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.title = NSLocalizedString(
                refreshState.inFlight ? "Loading Local Lyrics…" : "No Local Lyrics Available",
                comment: "Local lyrics menu status"
            )
            item.isEnabled = false
            desiredItems.append(item)
        }
        for item in submenu.items where !desiredItems.contains(where: { $0 === item }) {
            submenu.removeItem(item)
        }
        for (index, item) in desiredItems.enumerated() where submenu.index(of: item) != index {
            if item.menu === submenu { submenu.removeItem(item) }
            submenu.insertItem(item, at: index)
        }
    }

    @objc private func selectLocalLyrics(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? LocalLyricsChoice else { return }
        AppController.shared.applyLocalLyrics(choice) { applied, error in
            guard !applied,
                  let error,
                  selectedPlayer.currentTrack?.id == choice.track.id else {
                return
            }
            NSApp.presentError(error)
        }
    }

    func startObserving() {
        activationCancellable = AppController.shared.localLyricsActivations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                guard let self else { return }
                guard let session else {
                    if selectedPlayer.currentTrack == nil {
                        self.resetChoices(for: nil)
                        self.refreshState.receiveActivation(nil)
                        self.statusBarMenu.update()
                    }
                    return
                }
                guard selectedPlayer.currentTrack?.id == session.trackID,
                      AppController.shared.isCurrentLocalLyricsSession(session),
                      self.refreshState.receiveActivation(session.token) else { return }
                self.choices = []
                self.choicesTrackKey = session.trackID
                self.refresh()
                self.statusBarMenu.update()
            }
        trackCancellable = selectedPlayer.currentTrackWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Read after the player's will-change publication has completed.
                self?.preloadCurrentTrack()
            }
        candidatesCancellable = AppController.shared.localLyricsChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self, let track = selectedPlayer.currentTrack, track.id == change.trackID else { return }
                let trackChanged = self.choicesTrackKey != track.id
                let needsRefresh = change.kind == .embeddedRefreshRequired
                if trackChanged {
                    self.resetChoices(for: track.id)
                } else if needsRefresh {
                    self.refreshState.invalidate()
                }
                if let session = AppController.shared.localLyricsSession(for: track.id) {
                    self.choices = AppController.shared.reconcileLocalLyricsChoices(self.choices, for: track, session: session)
                }
                if trackChanged || needsRefresh { self.refresh() }
                self.statusBarMenu.update()
            }

        // The source is published after a local load commits, so this also
        // covers fallback from an invalid managed file to another one without
        // relying on the candidate-list notification.
        publishedSource = AppController.shared.currentLocalLyricsSource
        sourceCancellable = AppController.shared.$currentLocalLyricsSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] source in
                guard let self else { return }
                // Use the value emitted by @Published. The property wrapper
                // publishes during willSet, so re-reading the controller here
                // could still observe the previous value on another queue.
                self.publishedSource = source
                self.statusBarMenu.update()
            }

        // Explicitly handle launch with a song already playing, without relying
        // on the selected adapter replaying its current value on subscription.
        // Register all observers first so a source update from the initial
        // lookup cannot be missed.
        preloadCurrentTrack()
    }

    private func preloadCurrentTrack() {
        let track = selectedPlayer.currentTrack
        // MusicTrack equality compares only IDs. A file URL or scripting object
        // arriving later for the same song must also trigger a lookup.
        let signature = track.map {
            "\($0.id)|\($0.fileURL?.absoluteString ?? "")|\($0.originalTrack != nil)"
        }
        guard signature != observedTrackSignature else { return }
        let metadataChanged = observedTrackSignature != nil && observedTrackKey == track?.id
        observedTrackSignature = signature
        observedTrackKey = track?.id
        if choicesTrackKey != track?.id {
            resetChoices(for: track?.id)
        } else if metadataChanged {
            refreshState.invalidate()
        }
        refresh()
        statusBarMenu.update()
    }

    /// Drop options and invalidate pending callbacks when the track or its metadata changes.
    private func resetChoices(for trackKey: String?) {
        refreshState.invalidate()
        if choicesTrackKey != trackKey {
            choices = []
        }
        choicesTrackKey = trackKey
    }

    func refresh() {
        guard let track = selectedPlayer.currentTrack else {
            choices = []
            choicesTrackKey = nil
            refreshState.invalidate()
            return
        }
        let requestedTrackKey = track.id
        if choicesTrackKey != requestedTrackKey { resetChoices(for: requestedTrackKey) }
        guard let session = AppController.shared.localLyricsSession(for: track.id) else {
            // Activation will resume this lookup. Do not cache an empty result.
            refreshState.waitForActivation()
            return
        }
        if refreshState.receiveActivation(session.token) { choices = [] }
        if refreshState.inFlight { return }
        if let lastRefresh = refreshState.lastCompleted, Date().timeIntervalSince(lastRefresh) < 10 { return }
        let generation = refreshState.begin()
        AppController.shared.refreshLocalLyricsChoices(session: session) { [weak self] choices, stage in
            guard let self else { return }
            guard selectedPlayer.currentTrack?.id == requestedTrackKey else {
                return
            }
            guard self.refreshState.accept(stage, generation: generation) else { return }
            if stage == .cancelled {
                self.statusBarMenu.update()
                return
            }
            // Location and final batches replace cached file choices; absence
            // must not merge the old directory's files back into the menu.
            self.choices = AppController.shared.reconcileLocalLyricsChoices(choices, for: track, session: session)
            self.statusBarMenu.update()
        }
    }
}
