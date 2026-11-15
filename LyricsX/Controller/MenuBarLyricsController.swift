import AppKit
import SnapKit
import Combine
import GenericID
import LyricsXFoundation
import MusicPlayer
import OpenCC
import SwiftCF
import AccessibilityExt
import OSLog
import MarqueeLabel
import UIFoundation

final class MenuBarLyricsController {
    static let shared = MenuBarLyricsController()

    var statusBarMenu: NSMenu? {
        didSet {
            setupStatusItemMenu()
        }
    }

    private var iconStatusItem: NSStatusItem?
    private var lyricStatusItem: NSStatusItem?
    private var buttonImage = #imageLiteral(resourceName: "status_bar_icon")

    /// `MenuBarMarqueeLabel` from macOS 26 on, where the menu bar shows the
    /// item through snapshots and an `NSTextField` in it keeps them coming
    /// forever; MarqueeLabel's text field before that, where it is fine.
    private let marqueeLabel: MenuBarLyricsMarquee = {
        if #available(macOS 26, *) {
            return MenuBarMarqueeLabel(frame: .zero)
        }
        return MarqueeLabel(frame: .zero)
    }()

    private let previousButton = MenuBarControlButton()
    private let playPauseButton = MenuBarControlButton()
    private let nextButton = MenuBarControlButton()

    private static let controlButtonSize: CGFloat = 24
    private static let lyricsToControlsGap: CGFloat = 6
    private static let lyricsWidth: CGFloat = 183
    private static let lyricsHeight: CGFloat = 24

    private lazy var contentStackView = HStackView(
        distribution: .fill,
        alignment: .center,
        spacing: 4
    ) {
        // `.box` is generic over the view's own type, so it needs the view,
        // not the protocol it is reached through.
        (marqueeLabel as NSView)
            .box
            .size(width: MenuBarLyricsController.lyricsWidth, height: MenuBarLyricsController.lyricsHeight)
            .stackView
            .customSpacing(MenuBarLyricsController.lyricsToControlsGap)
        previousButton
            .box
            .size(MenuBarLyricsController.controlButtonSize)
        playPauseButton
            .box
            .size(MenuBarLyricsController.controlButtonSize)
        nextButton
            .box
            .size(MenuBarLyricsController.controlButtonSize)
    }

    private static let previousImage = NSImage(
        systemSymbolName: "backward.end.fill",
        accessibilityDescription: NSLocalizedString("Previous Track", comment: "Menu bar playback previous button")
    )
    private static let nextImage = NSImage(
        systemSymbolName: "forward.end.fill",
        accessibilityDescription: NSLocalizedString("Next Track", comment: "Menu bar playback next button")
    )
    private static let playImage = NSImage(
        systemSymbolName: "play.fill",
        accessibilityDescription: NSLocalizedString("Play", comment: "Menu bar playback play button")
    )
    private static let pauseImage = NSImage(
        systemSymbolName: "pause.fill",
        accessibilityDescription: NSLocalizedString("Pause", comment: "Menu bar playback pause button")
    )

    private var controlsVisible: Bool {
        !defaults[.hideMenuBarItems]
            && defaults[.menuBarLyricsEnabled]
            && defaults[.menuBarPlaybackControlsEnabled]
    }

    private var lastDisplayMode: DisplayMode?

    private enum DisplayMode {
        case separate
        case combine
    }

    private static let defaultLyric = "LyricsX"

    /// A line's karaoke timing, and the offset of the lyrics it came from
    /// when it was shown.
    private struct KaraokeProgress: Equatable {
        let timing: KaraokeLineTiming
        /// `Lyrics.adjustedTimeDelay`: playback position plus this is the
        /// lyrics time the timing is in.
        let timeDelay: TimeInterval
    }

    private typealias ScreenLyrics = (lyrics: String, duration: TimeInterval, karaokeProgress: KaraokeProgress?)

    private static let placeholderScreenLyrics: ScreenLyrics = (MenuBarLyricsController.defaultLyric, 2, nil)

    /// The line to show. Read and written on `DispatchQueue.lyricsDisplay`.
    private var screenLyrics: ScreenLyrics = MenuBarLyricsController.placeholderScreenLyrics {
        didSet {
            let screenLyricsToDisplay = screenLyrics
            DispatchQueue.main.async {
                self.displayedScreenLyrics = screenLyricsToDisplay
                self.updateStatusItems()
            }
        }
    }

    /// `screenLyrics` as last handed to the main queue, which shows it. The
    /// main queue reads only this: reading `screenLyrics` there raced the
    /// lyrics display queue's writes, and could pair one line's text with
    /// the next line's karaoke timing.
    private var displayedScreenLyrics: ScreenLyrics = MenuBarLyricsController.placeholderScreenLyrics

    /// The lyrics on screen and the line playback is at, as last published.
    /// Kept to show the line again when playback resumes. Read and written on
    /// `DispatchQueue.lyricsDisplay`.
    private var latestLyricsEvent: (lyrics: Lyrics?, index: Int?) = (nil, nil)

    private var cancelBag = Set<AnyCancellable>()

    private init() {
        setupControlButtons()
        updatePlayPauseIcon()
        updateButtonsEnabledState()
        if !defaults[.hideMenuBarItems] {
            updateStatusItems()
        }
        AppController.shared.$currentLyrics
            .combineLatest(AppController.shared.$currentLineIndex)
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(MenuBarLyricsController.handleLyricsDisplay, weaklyOn: self)
            .store(in: &cancelBag)
        workspaceNC
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .signal()
            .invoke(MenuBarLyricsController.updateStatusItems, weaklyOn: self)
            .store(in: &cancelBag)
        defaults.publisher(for: [
            .menuBarLyricsEnabled,
            .combinedMenubarLyrics,
            .hideMenuBarItems,
            .menuBarPlaybackControlsEnabled,
        ])
            .prepend()
            .invoke(MenuBarLyricsController.updateStatusItems, weaklyOn: self)
            .store(in: &cancelBag)
        selectedPlayer.playbackStateWillChange
            .signal()
            .receive(on: DispatchQueue.main)
            .invoke(MenuBarLyricsController.updatePlayPauseIcon, weaklyOn: self)
            .store(in: &cancelBag)
        defaults.publisher(for: [.menuBarLyricsScrollFramesPerSecond])
            .prepend()
            .receive(on: DispatchQueue.main)
            .invoke(MenuBarLyricsController.updateScrollFrameRate, weaklyOn: self)
            .store(in: &cancelBag)
        marqueeLabel.setPlaybackPaused(!selectedPlayer.playbackState.isPlaying)
        selectedPlayer.playbackStateWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playbackState in
                self?.marqueeLabel.setPlaybackPaused(!playbackState.isPlaying)
                // A pause, a resume or a jump: the progress goes on from
                // where playback is now.
                self?.updateKaraokeProgress(playbackState: playbackState)
            }
            .store(in: &cancelBag)
        // "Hide menu bar lyrics when paused" has to act on the pause itself,
        // which moves neither the lyrics nor the line.
        selectedPlayer.playbackStateWillChange
            .receive(on: DispatchQueue.lyricsDisplay)
            .sink { [weak self] playbackState in
                self?.showLyricsLine(isPlaying: playbackState.isPlaying)
            }
            .store(in: &cancelBag)
        defaults.publisher(for: [.menuBarHidesLyricsWhenPaused, .menuBarKaraokeProgressEnabled, .globalLyricsOffset])
            .receive(on: DispatchQueue.lyricsDisplay)
            .sink { [weak self] _ in
                self?.showLyricsLine(isPlaying: selectedPlayer.playbackState.isPlaying)
            }
            .store(in: &cancelBag)
        // A new offset moves where the karaoke progress is, not which line
        // is on screen.
        AppController.shared.publisher(for: \.lyricsOffset)
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .sink { [weak self] in
                self?.showLyricsLine(isPlaying: selectedPlayer.playbackState.isPlaying)
            }
            .store(in: &cancelBag)
        selectedPlayer.currentTrackWillChange
            .signal()
            .receive(on: DispatchQueue.main)
            .invoke(MenuBarLyricsController.updateButtonsEnabledState, weaklyOn: self)
            .store(in: &cancelBag)
    }

    // MARK: - Control Button Setup

    private func setupControlButtons() {
        configureControlButton(
            previousButton,
            image: MenuBarLyricsController.previousImage,
            action: #selector(previousAction)
        )
        configureControlButton(
            playPauseButton,
            image: MenuBarLyricsController.playImage,
            action: #selector(playPauseAction)
        )
        configureControlButton(
            nextButton,
            image: MenuBarLyricsController.nextImage,
            action: #selector(nextAction)
        )
    }

    private func configureControlButton(_ button: MenuBarControlButton, image: NSImage?, action: Selector) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .regularSquare
        button.image = image
        button.target = self
        button.action = action
    }

    // MARK: - Control Button Actions

    @objc private func previousAction() {
        selectedPlayer.skipToPreviousItem()
    }

    @objc private func playPauseAction() {
        selectedPlayer.playPause()
    }

    @objc private func nextAction() {
        selectedPlayer.skipToNextItem()
    }

    // MARK: - Layout

    private func layoutLyricStatusItemContents() {
        guard let button = lyricStatusItem?.button else { return }

        if contentStackView.superview !== button {
            button.addSubview(contentStackView)
            contentStackView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
        }

        let hidden = !controlsVisible
        previousButton.isHidden = hidden
        playPauseButton.isHidden = hidden
        nextButton.isHidden = hidden

        contentStackView.layoutSubtreeIfNeeded()
        button.frame = CGRect(
            x: 0,
            y: 0,
            width: contentStackView.fittingSize.width,
            height: NSStatusBar.system.thickness
        )
    }

    // MARK: - State Update Helpers

    private func updatePlayPauseIcon() {
        playPauseButton.image = selectedPlayer.playbackState.isPlaying
            ? MenuBarLyricsController.pauseImage
            : MenuBarLyricsController.playImage
    }

    private func updateButtonsEnabledState() {
        let hasTrack = selectedPlayer.currentTrack != nil
        previousButton.isEnabled = hasTrack
        playPauseButton.isEnabled = hasTrack
        nextButton.isEnabled = hasTrack
    }

    private func handleLyricsDisplay(event: (lyrics: Lyrics?, index: Int?)) {
        latestLyricsEvent = event
        showLyricsLine(isPlaying: selectedPlayer.playbackState.isPlaying)
    }

    /// Runs on `DispatchQueue.lyricsDisplay`.
    private func showLyricsLine(isPlaying: Bool) {
        let (lyrics, index) = latestLyricsEvent
        let display = MenuBarLyricsLinePolicy.display(
            lineCount: lyrics?.lines.count,
            currentLineIndex: index,
            isPlaying: isPlaying,
            hidesLyricsWhenPaused: defaults[.menuBarHidesLyricsWhenPaused]
        )
        switch display {
        case .unchanged:
            return
        case .placeholder:
            if screenLyrics.lyrics != MenuBarLyricsController.defaultLyric {
                screenLyrics = MenuBarLyricsController.placeholderScreenLyrics
            }
        case let .line(lineIndex):
            if let lyrics {
                showLine(at: lineIndex, of: lyrics)
            }
        }
    }

    private func showLine(at index: Int, of lyrics: Lyrics) {
        let currentLine = lyrics.lines[index]
        var newScreenLyrics = currentLine.content
        if let converter = ChineseConverter.shared, lyrics.metadata.language?.hasPrefix("zh") == true {
            newScreenLyrics = converter.convert(newScreenLyrics)
        }
        let karaokeProgress = defaults[.menuBarKaraokeProgressEnabled]
            ? KaraokeLineTiming(line: currentLine).map { KaraokeProgress(timing: $0, timeDelay: lyrics.adjustedTimeDelay) }
            : nil
        // The same text again is the same line on screen, unless it is sung
        // again: then its progress starts over.
        if newScreenLyrics == screenLyrics.lyrics, karaokeProgress == screenLyrics.karaokeProgress {
            return
        }
        let lineDisplayTime: TimeInterval
        if let duration = currentLine.attachments.timetag?.duration {
            lineDisplayTime = duration
        } else if let nextLine = lyrics.lines[safe: index + 1] {
            lineDisplayTime = nextLine.position - currentLine.position
        } else {
            lineDisplayTime = 2
        }
        screenLyrics = (newScreenLyrics, lineDisplayTime, karaokeProgress)
    }

    @objc private func updateStatusItems() {
        guard !defaults[.hideMenuBarItems] else {
            contentStackView.removeFromSuperview()
            iconStatusItem = nil
            lyricStatusItem = nil
            lastDisplayMode = nil
            return
        }

        guard defaults[.menuBarLyricsEnabled] else {
            contentStackView.removeFromSuperview()
            if iconStatusItem == nil {
                setupIconStatusItem()
            }
            lyricStatusItem = nil
            lastDisplayMode = nil
            return
        }

        if defaults[.combinedMenubarLyrics] {
            updateCombinedStatusLyrics()
            lastDisplayMode = .combine
        } else {
            updateSeparateStatusLyrics()
            lastDisplayMode = .separate
        }
    }

    private func updateSeparateStatusLyrics() {
        if lastDisplayMode == nil || lastDisplayMode == .combine {
            setupIconStatusItem()
            setupLyricStatusItem()
        }
        layoutLyricStatusItemContents()
        updateMarqueeText()
    }

    private func updateCombinedStatusLyrics() {
        if lastDisplayMode == nil || lastDisplayMode == .separate {
            iconStatusItem = nil
            setupLyricStatusItem()
        }
        layoutLyricStatusItemContents()
        updateMarqueeText()
    }

    private func updateScrollFrameRate() {
        marqueeLabel.maximumScrollFramesPerSecond = Double(defaults[.menuBarLyricsScrollFramesPerSecond])
    }

    private func updateMarqueeText() {
        marqueeLabel.setStringValue(displayedScreenLyrics.lyrics, lineDisplayTime: displayedScreenLyrics.duration)
        updateKaraokeProgress(playbackState: selectedPlayer.playbackState)
    }

    /// Anchors the line's karaoke progress at where `playbackState` has
    /// playback now. Runs on the main queue.
    private func updateKaraokeProgress(playbackState: PlaybackState) {
        let karaokeProgress = displayedScreenLyrics.karaokeProgress
        let playbackPosition = playbackState.lyricsDisplayTime(trackDuration: selectedPlayer.currentTrack?.duration)
        marqueeLabel.setKaraokeTiming(karaokeProgress?.timing, lyricsTime: playbackPosition + (karaokeProgress?.timeDelay ?? 0))
    }

    private func setupLyricStatusItem() {
        contentStackView.removeFromSuperview()
        lyricStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        lyricStatusItem?.button?.title = ""
        lyricStatusItem?.button?.image = nil
        lyricStatusItem?.length = NSStatusItem.variableLength
        layoutLyricStatusItemContents()
        setupStatusItemMenu()
    }

    private func setupIconStatusItem() {
        // Square, like every other icon-only item: the menu bar sizes it and
        // its highlight. A fixed 30 pt around the 16 pt icon left the
        // highlight about a third wider than its neighbours' (#214).
        iconStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        iconStatusItem?.button?.title = ""
        iconStatusItem?.button?.image = buttonImage
        setupStatusItemMenu()
    }

    private func setupStatusItemMenu() {
        if defaults[.combinedMenubarLyrics] {
            if defaults[.menuBarLyricsEnabled] {
                lyricStatusItem?.menu = statusBarMenu
            } else {
                iconStatusItem?.menu = statusBarMenu
            }
        } else {
            iconStatusItem?.menu = statusBarMenu
        }
    }
}

// MARK: - Lyric Line

/// What the lyrics status item needs from its scrolling line, whichever of
/// the two hosts it.
private protocol MenuBarLyricsMarquee: NSView {
    func setStringValue(_ value: String, lineDisplayTime: TimeInterval)
    func setKaraokeTiming(_ timing: KaraokeLineTiming?, lyricsTime: TimeInterval)
    func setPlaybackPaused(_ isPaused: Bool)
    /// Zero or less means the line's own default.
    var maximumScrollFramesPerSecond: Double { get set }
}

@available(macOS 26, *)
extension MenuBarMarqueeLabel: MenuBarLyricsMarquee {}

extension MarqueeLabel: MenuBarLyricsMarquee {
    /// MarqueeLabel shows no karaoke progress: the menu bar's progress needs
    /// macOS 26, where `MenuBarMarqueeLabel` draws the line.
    fileprivate func setKaraokeTiming(_ timing: KaraokeLineTiming?, lyricsTime: TimeInterval) {}

    /// MarqueeLabel keeps scrolling through a pause, as it always has.
    fileprivate func setPlaybackPaused(_ isPaused: Bool) {}

    /// MarqueeLabel's animation runs at the display's rate and takes no cap.
    fileprivate var maximumScrollFramesPerSecond: Double {
        get { 0 }
        set {}
    }
}

// MARK: - Menu Bar Control Button

private final class MenuBarControlButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            let highlightRect = bounds.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: highlightRect, xRadius: 4, yRadius: 4)
            NSColor.controlAccentColor.setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }
}

extension String {
    fileprivate func components(options: String.EnumerationOptions) -> [String] {
        var components: [String] = []
        let range = Range(uncheckedBounds: (startIndex, endIndex))
        enumerateSubstrings(in: range, options: options) { _, _, range, _ in
            components.append(String(self[range]))
        }
        return components
    }
}

extension Array {
    subscript(safe safeIndex: Int) -> Element? {
        if safeIndex >= 0, safeIndex < count {
            return self[safeIndex]
        } else {
            return nil
        }
    }
}
