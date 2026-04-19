import AppKit
import Combine
import GenericID
import LyricsXFoundation
import MusicPlayer
import OpenCC
import SwiftCF
import AccessibilityExt
import OSLog
import MarqueeLabel

class MenuBarLyricsController {
//    let logger = Logger(subsystem: "com.JH.LyricsX", category: "MenuBarLyricsController")

    static let shared = MenuBarLyricsController()

    var statusBarMenu: NSMenu? {
        didSet {
            setupStatusItemMenu()
        }
    }

    private var iconStatusItem: NSStatusItem?
    private var lyricStatusItem: NSStatusItem?
    private var buttonImage = #imageLiteral(resourceName: "status_bar_icon")
    private var buttonlength: CGFloat = 30

    private let marqueeLabel = MarqueeLabel(frame: .zero)

    private let previousButton = NSButton()
    private let playPauseButton = NSButton()
    private let nextButton = NSButton()

    private static let controlButtonSize: CGFloat = 22
    private static let lyricsToControlsGap: CGFloat = 6
    private static let lyricsWidth: CGFloat = 183

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

    private var screenLyrics: (lyrics: String, duration: TimeInterval) = (MenuBarLyricsController.defaultLyric, 2) {
        didSet {
            DispatchQueue.main.async {
                self.updateStatusItems()
            }
        }
    }

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
        defaults.publisher(for: [.menuBarLyricsEnabled, .combinedMenubarLyrics, .hideMenuBarItems])
            .prepend()
            .invoke(MenuBarLyricsController.updateStatusItems, weaklyOn: self)
            .store(in: &cancelBag)
        selectedPlayer.playbackStateWillChange
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(MenuBarLyricsController.updatePlayPauseIcon, weaklyOn: self)
            .store(in: &cancelBag)
        selectedPlayer.currentTrackWillChange
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(MenuBarLyricsController.updateButtonsEnabledState, weaklyOn: self)
            .store(in: &cancelBag)
    }

    // MARK: - Control Button Setup

    private func setupControlButtons() {
        configureControlButton(
            previousButton,
            symbolName: "backward.fill",
            action: #selector(previousAction)
        )
        configureControlButton(
            playPauseButton,
            symbolName: "play.fill",
            action: #selector(playPauseAction)
        )
        configureControlButton(
            nextButton,
            symbolName: "forward.fill",
            action: #selector(nextAction)
        )
    }

    private func configureControlButton(_ button: NSButton, symbolName: String, action: Selector) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
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

        let lyricsWidth = MenuBarLyricsController.lyricsWidth
        let buttonSize = MenuBarLyricsController.controlButtonSize
        let gap = MenuBarLyricsController.lyricsToControlsGap

        let totalWidth: CGFloat
        if controlsVisible {
            totalWidth = lyricsWidth + gap + buttonSize * 3
        } else {
            totalWidth = lyricsWidth
        }

        button.frame = CGRect(x: 0, y: 0, width: totalWidth, height: buttonSize)
        marqueeLabel.frame = CGRect(x: 0, y: 0, width: lyricsWidth, height: buttonSize)

        if controlsVisible {
            let firstButtonX = lyricsWidth + gap
            previousButton.frame  = CGRect(x: firstButtonX, y: 0, width: buttonSize, height: buttonSize)
            playPauseButton.frame = CGRect(x: firstButtonX + buttonSize, y: 0, width: buttonSize, height: buttonSize)
            nextButton.frame      = CGRect(x: firstButtonX + buttonSize * 2, y: 0, width: buttonSize, height: buttonSize)
            if previousButton.superview !== button { button.addSubview(previousButton) }
            if playPauseButton.superview !== button { button.addSubview(playPauseButton) }
            if nextButton.superview !== button { button.addSubview(nextButton) }
        } else {
            previousButton.removeFromSuperview()
            playPauseButton.removeFromSuperview()
            nextButton.removeFromSuperview()
        }
    }

    // MARK: - State Update Helpers

    private func updatePlayPauseIcon() {
        let isPlaying = selectedPlayer.playbackState.isPlaying
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private func updateButtonsEnabledState() {
        let hasTrack = selectedPlayer.currentTrack != nil
        previousButton.isEnabled = hasTrack
        playPauseButton.isEnabled = hasTrack
        nextButton.isEnabled = hasTrack
    }

    private func handleLyricsDisplay(event: (lyrics: Lyrics?, index: Int?)) {
        guard !defaults[.disableLyricsWhenPaused] || selectedPlayer.playbackState.isPlaying,
              let lyrics = event.lyrics,
              let index = event.index else {
//            screenLyrics = (MenuBarLyricsController.defaultLyric, 2)
            return
        }
        let currentLine = lyrics.lines[index]
        var newScreenLyrics = currentLine.content
        if let converter = ChineseConverter.shared, lyrics.metadata.language?.hasPrefix("zh") == true {
            newScreenLyrics = converter.convert(newScreenLyrics)
        }
        if newScreenLyrics == screenLyrics.lyrics {
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
        screenLyrics = (newScreenLyrics, lineDisplayTime)
    }

    @objc private func updateStatusItems() {
        guard !defaults[.hideMenuBarItems] else {
            marqueeLabel.removeFromSuperview()
            iconStatusItem = nil
            lyricStatusItem = nil
            lastDisplayMode = nil
            return
        }

        guard defaults[.menuBarLyricsEnabled] else {
            marqueeLabel.removeFromSuperview()
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

        marqueeLabel.setStringValue(screenLyrics.lyrics, lineDisplayTime: screenLyrics.duration)
    }

    private func updateCombinedStatusLyrics() {
        if lastDisplayMode == nil || lastDisplayMode == .separate {
            iconStatusItem = nil
            setupLyricStatusItem()
        }

        marqueeLabel.setStringValue(screenLyrics.lyrics, lineDisplayTime: screenLyrics.duration)
    }

    private func setupLyricStatusItem() {
        marqueeLabel.removeFromSuperview()
        previousButton.removeFromSuperview()
        playPauseButton.removeFromSuperview()
        nextButton.removeFromSuperview()
        lyricStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        lyricStatusItem?.button?.title = ""
        lyricStatusItem?.button?.image = nil
        lyricStatusItem?.length = NSStatusItem.variableLength
        lyricStatusItem?.button?.addSubview(marqueeLabel)
        layoutLyricStatusItemContents()
        setupStatusItemMenu()
    }

    private func setupIconStatusItem() {
        iconStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        iconStatusItem?.button?.title = ""
        iconStatusItem?.button?.image = buttonImage
        iconStatusItem?.length = buttonlength
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

// MARK: - Status Item Visibility

extension NSStatusItem {
    fileprivate var isVisibe: Bool {
        guard let buttonFrame = button?.frame,
              let frame = button?.window?.convertToScreen(buttonFrame) else {
            return false
        }

        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            return false
        }
        let carbonPoint = CGPoint(x: point.x, y: screen.frame.height - point.y - 1)

        guard let element = try? AXUIElement.systemWide().element(at: carbonPoint),
              let pid = try? element.pid() else {
            return false
        }

        return getpid() == pid
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
