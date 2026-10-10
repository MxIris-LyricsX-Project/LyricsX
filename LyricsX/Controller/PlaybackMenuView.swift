import AppKit
import Combine
import MusicPlayer

/// Playback controls hosted by the existing status item's native menu.
final class PlaybackMenuView: NSView {
    private let player: MusicPlayerProtocol
    private let openPlayer: ((MusicPlayerProtocol) -> Void)?
    private let artworkHotspot = PlaybackOpenPlayerButton()
    private let metadataHotspot = PlaybackOpenPlayerButton()
    private let loadArtwork: (MusicTrack, MusicPlayerName?, @escaping (NSImage?) -> Void) -> Void
    private var requestedArtworkKey: String?
    private var requestedArtworkIdentity: ObjectIdentifier?
    private var loadedArtwork: NSImage?
    private let artwork = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "0:00")
    private let previousButton = NSButton()
    private let playPauseButton = NSButton()
    private let nextButton = NSButton()
    private let progress = PlaybackSeekSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var cancellables = Set<AnyCancellable>()
    private var sourceRequestGeneration = 0
    private var requestedSourceKey: String?
    private var requestedSourceIdentity: ObjectIdentifier?
    private var resolvedSourceName: String?
    var sourceIdentity: () -> ObjectIdentifier? = { nil }
    var resolveSourceName: ((MusicPlayerProtocol, @escaping (String?) -> Void) -> Void)?
    var cancelSourceResolution: (() -> Void)?
    private var progressTimer: Timer?
    private(set) var isMenuOpen = false
    private let commands = PlaybackCommandDispatcher()
    private var artworkGeneration = 0
    private var seekGeneration = 0
    private var pendingSeek: (generation: Int, source: ObjectIdentifier, trackID: String, position: TimeInterval)?
    var sourceName: () -> String = { NSLocalizedString("Now Playing", comment: "System music source") }

    init(player: MusicPlayerProtocol,
         openPlayer: ((MusicPlayerProtocol) -> Void)? = nil,
         loadArtwork: @escaping (MusicTrack, MusicPlayerName?, @escaping (NSImage?) -> Void) -> Void = PlaybackArtworkLoader.shared.load) {
        self.player = player
        self.openPlayer = openPlayer
        self.loadArtwork = loadArtwork
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 108))
        setupControls()
        player.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self, self.isMenuOpen else { return }
                self.refresh()
            }
            .store(in: &cancellables)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Use init(player:)") }
    deinit { progressTimer?.invalidate() }

    func beginTracking() {
        isMenuOpen = true
        requestedSourceKey = nil
        commands.refresh(player) { [weak self] in
            guard let self, self.isMenuOpen else { return }
            self.refresh()
        }
        refresh()
    }

    func endTracking() {
        isMenuOpen = false
        pendingSeek = nil
        sourceRequestGeneration += 1
        cancelSourceResolution?()
        artworkGeneration += 1
        if loadedArtwork == nil { requestedArtworkKey = nil }
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func refresh() {
        let track = player.currentTrack
        artworkHotspot.isEnabled = track != nil && openPlayer != nil
        metadataHotspot.isEnabled = artworkHotspot.isEnabled
        titleLabel.stringValue = track?.title ?? NSLocalizedString("No Music Playing", comment: "Empty playback menu")
        subtitleLabel.stringValue = [track?.artist, track?.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        updateSourceName(for: track)
        updateArtwork(for: track)
        let canControl = track != nil
        previousButton.isEnabled = canControl
        playPauseButton.isEnabled = canControl
        nextButton.isEnabled = canControl
        let playing = player.playbackState.isPlaying
        playPauseButton.image = symbol(playing ? "pause.fill" : "play.fill", fallback: playing ? "Ⅱ" : "▶")
        playPauseButton.setAccessibilityLabel(NSLocalizedString(playing ? "Pause" : "Play", comment: "Playback command"))
        updateProgress()
        progressTimer?.invalidate()
        progressTimer = nil
        if isMenuOpen && playing {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateProgress() }
            progressTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
    }

    private func displayName(for name: MusicPlayerName?) -> String? {
        name == .appleMusic ? "Apple Music" : name?.rawValue
    }

    private func updateSourceName(for track: MusicTrack?) {
        let identity = sourceIdentity()
        let key = track.map { PlaybackArtworkLoader.key(for: $0, source: player.name) }
        if key != requestedSourceKey || identity != requestedSourceIdentity {
            sourceRequestGeneration += 1
            requestedSourceKey = key
            requestedSourceIdentity = identity
            resolvedSourceName = nil
            cancelSourceResolution?()
            if isMenuOpen, track != nil, player.name == nil, let resolve = resolveSourceName {
                let request = sourceRequestGeneration
                resolve(player) { [weak self] name in
                    guard let self, self.isMenuOpen, request == self.sourceRequestGeneration,
                          self.sourceIdentity() == identity,
                          self.player.currentTrack.map({ PlaybackArtworkLoader.key(for: $0, source: self.player.name) }) == key else { return }
                    self.resolvedSourceName = name
                    self.sourceLabel.stringValue = self.displayName(for: self.player.name) ?? name ?? self.sourceName()
                }
            }
        }
        sourceLabel.stringValue = displayName(for: player.name) ?? resolvedSourceName ?? sourceName()
    }

    private func updateArtwork(for track: MusicTrack?) {
        guard let track = track else {
            artworkGeneration += 1
            requestedArtworkKey = nil
            loadedArtwork = nil
            artwork.image = symbol("music.note", fallback: "♪")
            return
        }
        let key = PlaybackArtworkLoader.key(for: track, source: player.name)
        let identity = sourceIdentity()
        if requestedArtworkKey != key || requestedArtworkIdentity != identity {
            loadedArtwork = nil
            requestedArtworkKey = nil
        }
        artwork.image = track.artwork ?? loadedArtwork ?? symbol("music.note", fallback: "♪")
        guard isMenuOpen, track.artwork == nil, requestedArtworkKey != key else { return }
        requestedArtworkKey = key
        requestedArtworkIdentity = identity
        artworkGeneration += 1
        let generation = artworkGeneration
        loadArtwork(track, player.name) { [weak self] image in
            guard let self = self, self.isMenuOpen, self.artworkGeneration == generation, self.sourceIdentity() == identity, let current = self.player.currentTrack,
                  PlaybackArtworkLoader.key(for: current, source: self.player.name) == key else { return }
            self.loadedArtwork = image
            if self.isMenuOpen { self.artwork.image = current.artwork ?? image ?? self.symbol("music.note", fallback: "♪") }
        }
    }

    private func updateProgress() {
        let duration = player.currentTrack?.duration ?? 0
        let validDuration = duration.isFinite && duration > 0
        var rawTime = player.playbackTime
        if let seek = pendingSeek {
            if player.currentTrack?.id == seek.trackID,
               PlaybackCommandDispatcher.source(of: player).map(ObjectIdentifier.init) == seek.source {
                rawTime = seek.position
            } else {
                pendingSeek = nil
            }
        }
        let time = rawTime.isFinite ? max(0, rawTime) : 0
        progress.isEnabled = player.currentTrack != nil && validDuration
        if !progress.isTracking {
            progress.maxValue = validDuration ? duration : 1
            progress.doubleValue = validDuration ? min(duration, time) : 0
        }
        elapsedLabel.stringValue = Self.timeString(validDuration ? min(duration, time) : time)
        remainingLabel.stringValue = validDuration ? "−" + Self.timeString(max(0, duration - time)) : "—:—"
    }

    static func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let seconds = Int(min(max(0, time), Double(Int.max / 2)))
        if seconds >= 3600 { return "\(seconds / 3600):" + String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func setupControls() {
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 6
        artwork.layer?.masksToBounds = true
        artwork.setAccessibilityLabel(NSLocalizedString("Album Artwork", comment: "Playback artwork"))
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        for label in [titleLabel, subtitleLabel, sourceLabel] { label.lineBreakMode = .byTruncatingTail }
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        sourceLabel.font = .systemFont(ofSize: 10)
        sourceLabel.textColor = .secondaryLabelColor
        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        remainingLabel.alignment = .right
        configure(previousButton, symbol: "backward.end.fill", fallback: "◀◀", label: "Previous Track", action: #selector(previous))
        configure(playPauseButton, symbol: "play.fill", fallback: "▶", label: "Play", action: #selector(playPause))
        configure(nextButton, symbol: "forward.end.fill", fallback: "▶▶", label: "Next Track", action: #selector(next))
        progress.isContinuous = false
        progress.target = self
        progress.action = #selector(seek)
        progress.setAccessibilityLabel(NSLocalizedString("Playback Position", comment: "Seek slider"))
        for control in [artwork, titleLabel, subtitleLabel, sourceLabel, previousButton, playPauseButton, nextButton, progress, elapsedLabel, remainingLabel] {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
        }
        for hotspot in [artworkHotspot, metadataHotspot] {
            hotspot.isBordered = false
            hotspot.isTransparent = true
            hotspot.focusRingType = .none
            hotspot.target = self
            hotspot.action = #selector(openSourcePlayer)
            hotspot.toolTip = NSLocalizedString("Open Player", comment: "Open the source music app")
            hotspot.setAccessibilityLabel(hotspot.toolTip)
            hotspot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hotspot)
        }
        progress.controlSize = .small
        NSLayoutConstraint.activate([
            artworkHotspot.leadingAnchor.constraint(equalTo: artwork.leadingAnchor),
            artworkHotspot.trailingAnchor.constraint(equalTo: artwork.trailingAnchor),
            artworkHotspot.topAnchor.constraint(equalTo: artwork.topAnchor),
            artworkHotspot.bottomAnchor.constraint(equalTo: artwork.bottomAnchor),
            metadataHotspot.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metadataHotspot.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metadataHotspot.topAnchor.constraint(equalTo: titleLabel.topAnchor),
            metadataHotspot.bottomAnchor.constraint(equalTo: subtitleLabel.bottomAnchor),
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            artwork.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            artwork.widthAnchor.constraint(equalToConstant: 48),
            artwork.heightAnchor.constraint(equalToConstant: 48),
            titleLabel.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: artwork.topAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            sourceLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sourceLabel.trailingAnchor.constraint(lessThanOrEqualTo: previousButton.leadingAnchor, constant: -8),
            sourceLabel.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            playPauseButton.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -74),
            playPauseButton.topAnchor.constraint(equalTo: topAnchor, constant: 45),
            previousButton.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -12),
            nextButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 12),
            previousButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            nextButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            progress.topAnchor.constraint(equalTo: topAnchor, constant: 72),
            progress.heightAnchor.constraint(equalToConstant: 14),
            elapsedLabel.leadingAnchor.constraint(equalTo: progress.leadingAnchor),
            elapsedLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 2),
            remainingLabel.trailingAnchor.constraint(equalTo: progress.trailingAnchor),
            remainingLabel.topAnchor.constraint(equalTo: elapsedLabel.topAnchor),
        ])
        for button in [previousButton, playPauseButton, nextButton] {
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
    }

    private func configure(_ button: NSButton, symbol name: String, fallback: String, label: String, action: Selector) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = symbol(name, fallback: fallback)
        button.target = self
        button.action = action
        button.toolTip = NSLocalizedString(label, comment: "Playback command")
        button.setAccessibilityLabel(button.toolTip)
    }

    private func symbol(_ name: String, fallback: String) -> NSImage {
        if #available(macOS 11, *), let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) { return image }
        let text = NSAttributedString(string: fallback, attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.labelColor])
        return NSImage(size: text.size(), flipped: false) { _ in text.draw(at: .zero); return true }
    }

    @objc private func openSourcePlayer() {
        guard player.currentTrack != nil, let openPlayer = openPlayer else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        openPlayer(player)
    }

    private func perform(_ action: @escaping (MusicPlayerProtocol) -> Void) {
        commands.perform(player, action: action) { [weak self] in
            guard let self, self.isMenuOpen else { return }
            self.refresh()
        }
    }

    @objc private func previous() { perform { $0.skipToPreviousItem() } }
    @objc private func playPause() { perform { $0.playPause() } }
    @objc private func next() { perform { $0.skipToNextItem() } }
    @objc private func seek() {
        guard let track = player.currentTrack, let duration = track.duration,
              duration.isFinite, duration > 0,
              let source = PlaybackCommandDispatcher.source(of: player) else { return }
        let position = min(duration, max(0, progress.doubleValue))
        seekGeneration += 1
        let generation = seekGeneration
        pendingSeek = (generation, ObjectIdentifier(source), track.id, position)
        updateProgress()
        // Keep the dragged position until the background setter has run. Each
        // completion belongs to its own drag; an earlier seek cannot clear a
        // newer preview, nor may a queued seek target a different track.
        commands.perform(player, action: { source in
            guard source.currentTrack?.id == track.id else { return }
            source.playbackTime = position
        }) { [weak self] in
            guard let self else { return }
            if self.pendingSeek?.generation == generation { self.pendingSeek = nil }
            if self.isMenuOpen { self.refresh() }
        }
    }
}

private final class PlaybackSeekSlider: NSSlider {
    private(set) var isTracking = false
    override func mouseDown(with event: NSEvent) {
        isTracking = true
        defer { isTracking = false }
        super.mouseDown(with: event)
    }
}

/// Transparent native button over the artwork or song metadata, with a link cursor.
private final class PlaybackOpenPlayerButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
