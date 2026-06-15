import AppKit
import Combine
import QuartzCore
import LyricsXFoundation
import MusicPlayer
import UIFoundation

@available(macOS 15, *)
extension AppleMusicLyrics {
    /// The full Apple Music-style lyrics panel, in pure AppKit. Hosts the
    /// ColorfulX Metal gradient background, the album/track/transport chrome,
    /// and the CALayer lyrics engine — replacing the previous SwiftUI `RootView`
    /// + `NSHostingController`.
    final class LyricsPanelViewController: NSViewController {
        // MARK: Data

        private var currentLyrics: Lyrics?
        private var currentLineIndex: Int?
        private var currentTrackID: String?
        private var trackDuration: TimeInterval?
        private var lastArtworkFetchAttempt: Date = .distantPast

        private let interactionState = InteractionStateModel()
        private var karaokeMode: KaraokeMode = .characterLevel
        private var cancellables: Set<AnyCancellable> = []
        private var chromeTimer: Timer?

        // MARK: Views

        private let backgroundView = GradientBackgroundView()
        private let lyricsContainer = SyncedLyricsContainerView()
        private let coverImageView = RoundedImageView()
        private let titleLabel = NSTextField(labelWithString: "")
        private let artistLabel = NSTextField(labelWithString: "")
        private let progressView = PlaybackProgressView()
        private lazy var previousButton = PanelControlButton(symbolName: "backward.fill", pointSize: 20) { [weak self] in self?.previousTrack() }
        private lazy var playPauseButton = PanelControlButton(symbolName: "play.fill", pointSize: 28) { [weak self] in selectedPlayer.playPause() }
        private lazy var nextButton = PanelControlButton(symbolName: "forward.fill", pointSize: 20) { [weak self] in selectedPlayer.skipToNextItem() }
        private let interactionButton = InteractionToggleButton()
        private let messageLabel = NSTextField(labelWithString: "")
        private let leftColumn = NSStackView()
        private let contentStack = NSStackView()

        private var leftColumnWidthConstraint: NSLayoutConstraint!
        private var coverSizeConstraint: NSLayoutConstraint!
        private var contentLeadingConstraint: NSLayoutConstraint!

        // MARK: Lifecycle

        override func loadView() {
            // `DraggablePanelView` is a `LayerBackedView`; its black background is
            // applied via the renderer in `updateLayer`, not poked onto the layer.
            view = DraggablePanelView()
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            buildHierarchy()
            wireInteraction()
            subscribe()
            startChromeTimer()
            // Seed the track id before the first artwork apply, so the gradient
            // palette extracts on initial load (the currentTrackWillChange sink
            // delivers a turn later and would otherwise leave a nil-vs-nil guard
            // suppressing the first palette).
            currentTrackID = selectedPlayer.currentTrack?.id
            refreshTrackInfo()
            refreshArtwork()
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            startChromeTimer()
        }

        override func viewDidDisappear() {
            super.viewDidDisappear()
            chromeTimer?.invalidate()
            chromeTimer = nil
        }

        // MARK: Build

        private func buildHierarchy() {
            backgroundView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(backgroundView)

            // Left column: cover + track info + scrubber + transport.
            coverImageView.translatesAutoresizingMaskIntoConstraints = false
            coverImageView.imageScaling = .scaleProportionallyUpOrDown
            // `RoundedImageView` owns its corner radius (applied in its own
            // `layout()`), so the controller never pokes the cover's layer.
            coverImageView.cornerRadius = 12

            titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            titleLabel.textColor = .white
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.maximumNumberOfLines = 1
            configurePlainLabel(titleLabel)

            artistLabel.font = .systemFont(ofSize: 12, weight: .regular)
            artistLabel.textColor = NSColor.white.withAlphaComponent(0.6)
            artistLabel.lineBreakMode = .byTruncatingTail
            artistLabel.maximumNumberOfLines = 1
            configurePlainLabel(artistLabel)

            let infoColumn = NSStackView(views: [titleLabel, artistLabel])
            infoColumn.orientation = .vertical
            infoColumn.alignment = .leading
            infoColumn.spacing = 2

            progressView.translatesAutoresizingMaskIntoConstraints = false
            progressView.onSeek = { time in selectedPlayer.playbackTime = time }

            let transport = NSStackView(views: [previousButton, playPauseButton, nextButton])
            transport.orientation = .horizontal
            transport.spacing = 28
            transport.alignment = .centerY

            leftColumn.orientation = .vertical
            leftColumn.alignment = .centerX
            leftColumn.spacing = 16
            leftColumn.translatesAutoresizingMaskIntoConstraints = false
            leftColumn.setViews([coverImageView, infoColumn, progressView, transport], in: .center)

            // Right: lyrics engine.
            lyricsContainer.translatesAutoresizingMaskIntoConstraints = false
            lyricsContainer.onSeek = { [weak self] time in
                guard let lyrics = self?.currentLyrics else { return }
                selectedPlayer.playbackTime = time - lyrics.adjustedTimeDelay
            }
            lyricsContainer.interactionState = interactionState
            lyricsContainer.karaokeMode = karaokeMode

            contentStack.orientation = .horizontal
            contentStack.alignment = .centerY
            contentStack.distribution = .fill
            contentStack.spacing = 40
            contentStack.translatesAutoresizingMaskIntoConstraints = false
            contentStack.setViews([leftColumn, lyricsContainer], in: .leading)
            view.addSubview(contentStack)

            // "No Lyrics" message.
            messageLabel.stringValue = NSLocalizedString("No Lyrics", comment: "")
            messageLabel.font = .systemFont(ofSize: 24, weight: .medium)
            messageLabel.textColor = NSColor.white.withAlphaComponent(0.4)
            configurePlainLabel(messageLabel)
            messageLabel.translatesAutoresizingMaskIntoConstraints = false
            messageLabel.isHidden = true
            view.addSubview(messageLabel)

            // Interaction toggle, bottom-right.
            interactionButton.translatesAutoresizingMaskIntoConstraints = false
            interactionButton.alphaValue = 0
            view.addSubview(interactionButton)

            leftColumnWidthConstraint = leftColumn.widthAnchor.constraint(equalToConstant: 280)
            coverSizeConstraint = coverImageView.widthAnchor.constraint(equalToConstant: 240)
            contentLeadingConstraint = contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 48)

            NSLayoutConstraint.activate([
                backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
                backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

                contentStack.topAnchor.constraint(equalTo: view.topAnchor),
                contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                contentLeadingConstraint,
                contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),

                leftColumnWidthConstraint,
                coverSizeConstraint,
                coverImageView.heightAnchor.constraint(equalTo: coverImageView.widthAnchor),
                infoColumn.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),
                progressView.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),
                progressView.heightAnchor.constraint(equalToConstant: 24),

                messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

                interactionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                interactionButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
                interactionButton.widthAnchor.constraint(equalToConstant: 36),
                interactionButton.heightAnchor.constraint(equalToConstant: 36),
            ])
        }

        private func configurePlainLabel(_ label: NSTextField) {
            label.isBezeled = false
            label.drawsBackground = false
            label.isEditable = false
            label.isSelectable = false
        }

        private func wireInteraction() {
            interactionButton.onClick = { [weak self] in self?.interactionState.toggleIsolation() }
            interactionState.onChange = { [weak self] in
                guard let self else { return }
                self.updateInteractionButton()
                self.lyricsContainer.resumeFollowingIfNeeded()
            }
            updateInteractionButton()
        }

        // MARK: Adaptive layout

        override func viewDidLayout() {
            super.viewDidLayout()
            let size = view.bounds.size
            let isWide = size.width > 640

            leftColumn.isHidden = !isWide

            let coverSize = max(150, min(size.width * 0.285, size.height - 260))
            coverSizeConstraint.constant = coverSize
            leftColumnWidthConstraint.constant = coverSize
            // Adaptive insets/gap matching the previous layout: a proportional
            // leading inset and column gap so the cover↔lyrics spacing scales
            // with the window instead of staying a cramped fixed value.
            contentLeadingConstraint.constant = isWide ? max(40, size.width * 0.065) : 24
            contentStack.spacing = isWide ? max(40, size.width * 0.1) : 0

            let mainFontSize = max(26, min(42, size.width * 0.03))
            let translationFontSize = max(14, mainFontSize * 0.55)
            if let lyrics = currentLyrics {
                lyricsContainer.update(
                    lyrics: lyrics,
                    highlightedLineIndex: currentLineIndex,
                    mainFontSize: mainFontSize,
                    translationFontSize: translationFontSize
                )
            }
        }

        private var adaptiveMainFontSize: CGFloat {
            max(26, min(42, view.bounds.width * 0.03))
        }

        private var adaptiveTranslationFontSize: CGFloat {
            max(14, adaptiveMainFontSize * 0.55)
        }

        // MARK: Subscriptions

        private func subscribe() {
            AppController.shared.$currentLyrics
                .receive(on: DispatchQueue.main)
                .sink { [weak self] lyrics in self?.applyLyrics(lyrics) }
                .store(in: &cancellables)

            AppController.shared.$currentLineIndex
                .receive(on: DispatchQueue.main)
                .sink { [weak self] index in self?.applyLineIndex(index) }
                .store(in: &cancellables)

            selectedPlayer.currentTrackWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.handleTrackChange() }
                .store(in: &cancellables)
        }

        private func startChromeTimer() {
            guard chromeTimer == nil else { return }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.chromeTick()
            }
            // .common so the scrubber keeps updating during window resize too.
            RunLoop.main.add(timer, forMode: .common)
            chromeTimer = timer
        }

        // MARK: Data handlers

        private func applyLyrics(_ lyrics: Lyrics?) {
            currentLyrics = lyrics
            let hasLyrics = lyrics != nil
            // Fade, do NOT toggle `isHidden`: `lyricsContainer` is an arranged
            // subview of `contentStack` (an NSStackView), so hiding it changes the
            // stack's fitting size, which the window — created via
            // `NSWindow(contentViewController:)` — adopts, snapping the user's
            // resized window back to its initial (content-fitting) size on every
            // track change. Alpha keeps the layout slot, so the window holds size.
            lyricsContainer.alphaValue = hasLyrics ? 1 : 0
            messageLabel.isHidden = hasLyrics
            if let lyrics {
                lyricsContainer.update(
                    lyrics: lyrics,
                    highlightedLineIndex: currentLineIndex,
                    mainFontSize: adaptiveMainFontSize,
                    translationFontSize: adaptiveTranslationFontSize
                )
            }
            refreshArtwork()
        }

        private func applyLineIndex(_ index: Int?) {
            currentLineIndex = index
            guard let lyrics = currentLyrics else { return }
            lyricsContainer.update(
                lyrics: lyrics,
                highlightedLineIndex: index,
                mainFontSize: adaptiveMainFontSize,
                translationFontSize: adaptiveTranslationFontSize
            )
        }

        private func handleTrackChange() {
            let newTrackID = selectedPlayer.currentTrack?.id
            if newTrackID != currentTrackID {
                currentTrackID = newTrackID
                coverImageView.image = nil
                lastArtworkFetchAttempt = .distantPast
            }
            refreshArtwork()
            refreshTrackInfo()
        }

        private func chromeTick() {
            let isPlaying = selectedPlayer.playbackState.isPlaying
            playPauseButton.setSymbol(isPlaying ? "pause.fill" : "play.fill")
            progressView.update(currentTime: selectedPlayer.playbackTime, duration: trackDuration ?? 0)
            if coverImageView.image == nil {
                refreshArtwork()
            }
            if titleLabel.stringValue.isEmpty {
                refreshTrackInfo()
            }
        }

        private func refreshArtwork() {
            if let artwork = selectedPlayer.currentTrack?.artwork {
                applyArtwork(artwork)
                return
            }
            // Throttled SBObject fallback (matches the previous implementation).
            let now = Date()
            guard now.timeIntervalSince(lastArtworkFetchAttempt) >= 1.0 else { return }
            lastArtworkFetchAttempt = now
            if let artwork = selectedPlayer.currentTrack?.resolvedArtwork {
                applyArtwork(artwork)
            }
        }

        private func applyArtwork(_ artwork: NSImage) {
            coverImageView.image = artwork
            backgroundView.update(artwork: artwork, trackID: currentTrackID)
        }

        private func refreshTrackInfo() {
            titleLabel.stringValue = selectedPlayer.currentTrack?.title ?? "—"
            artistLabel.stringValue = selectedPlayer.currentTrack?.artist ?? "—"
            trackDuration = selectedPlayer.currentTrack?.duration
        }

        // MARK: Transport

        private func previousTrack() {
            if selectedPlayer.playbackTime > 5 {
                selectedPlayer.playbackTime = 0
            } else {
                selectedPlayer.skipToPreviousItem()
            }
        }

        // MARK: Interaction button

        private var lastDelegated = false

        private func updateInteractionButton() {
            interactionButton.update(state: interactionState.state, progress: interactionState.delegationProgress)
            // Only (re)animate the fade when delegation actually toggles — not on
            // every countdown-progress tick.
            let isDelegated = interactionState.isDelegated
            guard isDelegated != lastDelegated else { return }
            lastDelegated = isDelegated
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                interactionButton.animator().alphaValue = isDelegated ? 1 : 0
            }
        }
    }

    // MARK: - Draggable Root View (window-move without entering tracking mode)

    /// Moving the window via `mouseDragged` keeps the main run loop in its
    /// default mode (unlike `isMovableByWindowBackground`, which spins a nested
    /// `NSEventTrackingRunLoopMode` loop). That lets ColorfulX's
    /// `DispatchQueue.main.async`-hopped frames keep draining, so the gradient
    /// animates during the drag instead of freezing.
    final class DraggablePanelView: LayerBackedView {
        private var initialMouseScreen: NSPoint?
        private var initialWindowOrigin: NSPoint?

        override func setup() {
            backgroundColor = .black
        }

        /// Route clicks on interactive controls (transport buttons, scrubber,
        /// interaction toggle, the lyrics scroll) to those views; everything else
        /// — cover, labels, stack gaps, background — falls through to `self` so a
        /// click-drag there moves the window.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point), hit !== self else { return self }
            var node: NSView? = hit
            while let current = node, current !== self {
                if current is NSButton
                    || current is PanelControlButton
                    || current is PlaybackProgressView
                    || current is InteractionToggleButton
                    || current is SyncedLyricsContainerView {
                    return hit
                }
                node = current.superview
            }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            initialMouseScreen = NSEvent.mouseLocation
            initialWindowOrigin = window.frame.origin
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window,
                  let initialMouseScreen,
                  let initialWindowOrigin else { return }
            let current = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(
                x: initialWindowOrigin.x + (current.x - initialMouseScreen.x),
                y: initialWindowOrigin.y + (current.y - initialMouseScreen.y)
            ))
        }

        override func mouseUp(with event: NSEvent) {
            initialMouseScreen = nil
            initialWindowOrigin = nil
        }
    }

    // MARK: - Interaction Toggle Button (lock / return-to-following + countdown ring)

    /// The background circle is renderer-driven (`backgroundColor` + a
    /// half-height `cornerRadius` applied in `updateLayer`); only the animated
    /// countdown ring remains a hosted `CAShapeLayer`, since a partial
    /// `strokeEnd` progress arc isn't something the background renderer models.
    final class InteractionToggleButton: NSView, LayerBackgroundProviding {
        var onClick: (() -> Void)?

        private let iconView = NSImageView()
        private let ringLayer = CAShapeLayer()
        private var lastIsolated: Bool?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            attachToSelfIfNeeded()
            setup()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            super.updateLayer()
            updateLayerBackgroundIfNeeded()
        }

        private func setup() {
            backgroundColor = NSColor.white.withAlphaComponent(0.15)

            ringLayer.fillColor = NSColor.clear.cgColor
            ringLayer.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
            ringLayer.lineWidth = 2
            ringLayer.strokeEnd = 0
            ringLayer.isHidden = true
            layer?.addSublayer(ringLayer)

            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.contentTintColor = NSColor.white.withAlphaComponent(0.8)
            iconView.imageScaling = .scaleProportionallyDown
            addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
            ])
        }

        func update(state: InteractionStateModel.State, progress: Double) {
            // Rebuild the icon only when the symbol actually changes (not on every
            // countdown-progress tick).
            let isolated = state == .isolated
            if isolated != lastIsolated {
                lastIsolated = isolated
                let symbol = isolated ? "lock.fill" : "arrow.down.to.line"
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)
            }

            ringLayer.isHidden = state != .countingDown
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ringLayer.strokeEnd = CGFloat(progress)
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            layoutLayerBackgroundIfNeeded()
            // Half-height radius makes the renderer's background fill a circle.
            cornerRadius = bounds.height / 2
            // Ring inset slightly and drawn from the top, clockwise.
            let inset = bounds.insetBy(dx: 1, dy: 1)
            ringLayer.path = CGPath(ellipseIn: inset, transform: nil)
            ringLayer.frame = bounds
        }

        override func mouseDown(with event: NSEvent) {
            // accept; act on mouseUp inside bounds
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) {
                onClick?()
            }
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}
