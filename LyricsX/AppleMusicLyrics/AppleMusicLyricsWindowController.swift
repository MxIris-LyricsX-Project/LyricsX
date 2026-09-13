import AppKit
import Combine
import LyricsXFoundation
import MusicPlayer
import OpenCC
import AppleMusicLyricsPanel

extension AppleMusicLyrics {
    final class WindowController: NSWindowController, NSWindowDelegate {
        private static let windowFrameName = NSWindow.FrameAutosaveName("AppleMusicLyricsWindow")

        private var cancellables: Set<AnyCancellable> = []
        private var delayedArtworkUpgrade: DispatchWorkItem?

        init() {
            AppleMusicLyrics.hostEnvironment = .init(
                player: MusicPlayers.Selected.shared,
                isBilingualPreferred: { defaults[.preferBilingualLyrics] },
                transformTranslation: { ChineseConverter.shared?.convert($0) ?? $0 },
                lyricsTimeDelay: { $0.adjustedTimeDelay },
                translationSettingsDidChange: defaults
                    .publisher(for: [.preferBilingualLyrics, .chineseConversionIndex])
                    .map { _ in }
                    .eraseToAnyPublisher(),
                artworkUpgrades: HighResolutionArtworkService.shared.artworkPublisher
                    .map { AppleMusicLyrics.ArtworkUpgrade(trackIdentifier: $0.trackIdentifier, image: $0.image) }
                    .eraseToAnyPublisher()
            )
            super.init(window: nil)
        }

        deinit {
            delayedArtworkUpgrade?.cancel()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var windowNibName: NSNib.Name? {
            ""
        }

        override func loadWindow() {
            let viewController = LyricsPanelViewController(
                lyricsPublisher: AppController.shared.$currentLyrics.eraseToAnyPublisher(),
                currentLineIndexPublisher: AppController.shared.$currentLineIndex.eraseToAnyPublisher()
            )

            let window = NSWindow(contentViewController: viewController)
            AppleMusicLyricsWindowConfiguration.apply(to: window)

            if !window.setFrameUsingName(Self.windowFrameName, force: true) {
                window.center()
            }
            window.setFrameAutosaveName(Self.windowFrameName)
            window.delegate = self
            self.window = window
        }

        override func windowDidLoad() {
            super.windowDidLoad()

            let isPinned = defaults[.appleMusicLyricsWindowPinned]
            if isPinned {
                window?.level = .floating
            }
            installPinButton(isPinned: isPinned)

            observeArtworkSources()
        }

        // MARK: High-resolution artwork

        /// Drives `HighResolutionArtworkService`. These subscriptions live and
        /// die with the panel window, which is what keeps the app off the
        /// network for anyone who never opens it.
        ///
        /// Both the track and the lyrics matter, and they arrive apart: the
        /// track brings the title, artist and whatever artwork the player has;
        /// the lyrics bring a second cover URL and, often, the artwork the
        /// player only got round to publishing in the meantime.
        private func observeArtworkSources() {
            selectedPlayer.currentTrackWillChange
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] track in
                    self?.requestArtworkUpgrade(for: track, lyrics: AppController.shared.currentLyrics)
                    self?.scheduleDelayedArtworkUpgrade()
                }
                .store(in: &cancellables)

            AppController.shared.$currentLyrics
                .receive(on: DispatchQueue.main)
                .sink { [weak self] lyrics in
                    self?.requestArtworkUpgrade(for: selectedPlayer.currentTrack, lyrics: lyrics)
                }
                .store(in: &cancellables)
        }

        /// A track whose lyrics never arrive gets no second pass from the
        /// publisher above, and the artwork a player publishes routinely lands a
        /// beat after the track change — without this, the only look at that
        /// track would be the one taken before either had a chance to show up.
        private func scheduleDelayedArtworkUpgrade() {
            delayedArtworkUpgrade?.cancel()
            let upgrade = DispatchWorkItem { [weak self] in
                self?.requestArtworkUpgrade(
                    for: selectedPlayer.currentTrack,
                    lyrics: AppController.shared.currentLyrics
                )
            }
            delayedArtworkUpgrade = upgrade
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: upgrade)
        }

        private func requestArtworkUpgrade(for track: MusicTrack?, lyrics: Lyrics?) {
            guard let track else { return }
            let lyricsArtwork = lyrics?.metadata.artworkURL.map { artworkURL in
                ArtworkCandidateSource(
                    url: artworkURL,
                    title: lyrics?.idTags[.title],
                    artist: lyrics?.idTags[.artist],
                    duration: lyrics?.length
                )
            }
            let request = HighResolutionArtworkRequest(
                trackIdentifier: track.id,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                localArtwork: track.resolvedArtwork,
                lyricsArtwork: lyricsArtwork,
                // Lyrics settling is what makes a fruitless search final: before
                // that, the second source has not had its chance yet.
                mayRecordMiss: lyrics != nil
            )
            Task {
                await HighResolutionArtworkService.shared.resolve(request)
            }
        }

        // MARK: Pin control

        /// The pin used to be an `NSTitlebarAccessoryViewController`, which is
        /// precisely what stopped AppKit from auto-hiding the titlebar in full
        /// screen: `_originalWindowShouldAutomaticallyAutohide` answers no as
        /// soon as `titlebarAccessoryViewControllers` is non-empty.
        ///
        /// It is now a plain subview of the titlebar view instead. That keeps it
        /// level with the traffic lights -- the content view is covered by the
        /// titlebar up there, so a button hosted in the content view could never
        /// be clicked -- while staying invisible to the accessory count.
        private lazy var pinButton: NSButton = {
            let button = NSButton(
                image: NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin window")!,
                target: self,
                action: #selector(togglePin(_:))
            )
            button.bezelStyle = .accessoryBarAction
            button.setButtonType(.toggle)
            button.isBordered = false
            button.translatesAutoresizingMaskIntoConstraints = false
            button.alphaValue = 0
            return button
        }()

        private func installPinButton(isPinned: Bool) {
            pinButton.state = isPinned ? .on : .off
            pinButton.contentTintColor = isPinned ? .controlAccentColor : .white
            mountPinButton()

            guard let contentView = window?.contentView else { return }
            contentView.addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self
                )
            )
        }

        /// Re-run after every full screen transition: AppKit hands the titlebar
        /// over to a detached window on the way in and takes it back on the way
        /// out, and the pin has to follow whichever view is current.
        private func mountPinButton() {
            guard let closeButton = window?.standardWindowButton(.closeButton),
                  let titlebarView = closeButton.superview,
                  pinButton.superview !== titlebarView
            else { return }
            titlebarView.addSubview(pinButton)
            NSLayoutConstraint.activate([
                pinButton.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor, constant: -14),
                pinButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
                pinButton.widthAnchor.constraint(equalToConstant: 22),
                pinButton.heightAnchor.constraint(equalToConstant: 22),
            ])
        }

        override func mouseEntered(with event: NSEvent) {
            setPinButtonVisible(true)
        }

        override func mouseExited(with event: NSEvent) {
            setPinButtonVisible(false)
        }

        private func setPinButtonVisible(_ isVisible: Bool) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                pinButton.animator().alphaValue = isVisible ? 1 : 0
            }
        }

        // MARK: Full screen

        func windowWillEnterFullScreen(_ notification: Notification) {
            guard let window else { return }
            AppleMusicLyricsWindowConfiguration.prepareForFullScreen(window)
        }

        func windowDidEnterFullScreen(_ notification: Notification) {
            mountPinButton()
        }

        func windowDidExitFullScreen(_ notification: Notification) {
            guard let window else { return }
            AppleMusicLyricsWindowConfiguration.restoreAfterFullScreen(
                window,
                isPinned: defaults[.appleMusicLyricsWindowPinned]
            )
            mountPinButton()
        }

        func windowWillClose(_ notification: Notification) {
            // The window is released on close, so persist its final frame now to
            // guarantee the next open restores it even if the session-time
            // autosave never registered (e.g. a prior window still owned the name).
            window?.saveFrame(usingName: Self.windowFrameName)
            defaults[.isShowLyricsHUD] = false
        }

        @objc private func togglePin(_ sender: NSButton) {
            guard let window else { return }
            let pinned = sender.state == .on
            // In full screen the level stays put: floating above the Space would
            // cover the titlebar AppKit slides down, and there is nothing to
            // float over anyway. The preference still records the choice, and
            // leaving full screen applies it.
            if !window.styleMask.contains(.fullScreen) {
                window.level = pinned ? .floating : .normal
            }
            sender.contentTintColor = pinned ? .controlAccentColor : .white
            defaults[.appleMusicLyricsWindowPinned] = pinned
        }
    }
}
