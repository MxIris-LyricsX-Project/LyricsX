import AppKit
import Combine
import GenericID
import LyricsXFoundation
import MusicPlayer
import OpenCC
import SnapKit
import SwiftCF
import CoreGraphicsExt

class KaraokeLyricsWindowController: NSWindowController {
    private static let windowFrame = NSWindow.FrameAutosaveName("KaraokeWindow")

    private var lyricsView = KaraokeLyricsView(frame: .zero)

    private var cancelBag = Set<AnyCancellable>()

    init() {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.setFrameUsingName(KaraokeLyricsWindowController.windowFrame, force: true)
        super.init(window: window)

        window.contentView?.addSubview(lyricsView)

        addObserver()
        makeConstraints()

        updateWindowFrame(animate: false)

        lyricsView.displayLrc("LyricsX")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.lyricsView.displayLrc("")
            AppController.shared.$currentLyrics
                .signal()
                .receive(on: DispatchQueue.lyricsDisplay)
                .invoke(KaraokeLyricsWindowController.handleLyricsDisplay, weaklyOn: self)
                .store(in: &self.cancelBag)
            AppController.shared.$currentLineIndex
                .signal()
                .receive(on: DispatchQueue.lyricsDisplay)
                .invoke(KaraokeLyricsWindowController.handleLyricsDisplay, weaklyOn: self)
                .store(in: &self.cancelBag)
            AppController.shared.publisher(for: \.lyricsOffset)
                .signal()
                .receive(on: DispatchQueue.lyricsDisplay)
                .invoke(KaraokeLyricsWindowController.lyricsOffsetChanged, weaklyOn: self)
                .store(in: &self.cancelBag)
            selectedPlayer.playbackStateWillChange
                .receive(on: DispatchQueue.lyricsDisplay)
                .invoke(KaraokeLyricsWindowController.playbackStateChanged, weaklyOn: self)
                .store(in: &self.cancelBag)
            defaults.publisher(for: Self.displayRefreshPreferenceKeys)
                .prepend()
                .receive(on: DispatchQueue.lyricsDisplay)
                .invoke(KaraokeLyricsWindowController.displayPreferencesChanged, weaklyOn: self)
                .store(in: &self.cancelBag)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func addObserver() {
        lyricsView.bind(\.textColor, withDefaultName: .desktopLyricsColor)
        lyricsView.bind(\.progressColor, withDefaultName: .desktopLyricsProgressColor)
        lyricsView.bind(\.shadowColor, withDefaultName: .desktopLyricsShadowColor)
        lyricsView.bind(\.backgroundColor, withDefaultName: .desktopLyricsBackgroundColor)
        lyricsView.bind(\.isVertical, withDefaultName: .desktopLyricsVerticalMode, options: [.nullPlaceholder: false])
        lyricsView.bind(\.drawFurigana, withDefaultName: .desktopLyricsEnableFurigana, options: [.nullPlaceholder: false])
        lyricsView.bind(\.drawRomajin, withDefaultName: .desktopLyricsEnableRomajin, options: [.nullPlaceholder: false])

        let negateOption = [NSBindingOption.valueTransformerName: NSValueTransformerName.negateBooleanTransformerName]
        window?.contentView?.bind(.hidden, withDefaultName: .desktopLyricsEnabled, options: negateOption)

        observeDefaults(key: .disableLyricsWhenSreenShot, options: [.new, .initial]) { [unowned self] _, change in
            self.window?.sharingType = change.newValue ? .none : .readOnly
        }
        observeDefaults(keys: [
            .hideLyricsWhenMousePassingBy,
            .desktopLyricsDraggable,
        ], options: [.initial]) {
            self.lyricsView.shouldHideWithMouse = defaults[.hideLyricsWhenMousePassingBy] && !defaults[.desktopLyricsDraggable]
        }
        observeDefaults(keys: [
            .desktopLyricsFontName,
            .desktopLyricsFontSize,
            .desktopLyricsFontNameFallback,
        ], options: [.initial]) { [unowned self] in
            self.lyricsView.font = defaults.desktopLyricsFont
        }

        observeNotification(name: NSApplication.didChangeScreenParametersNotification, queue: .main) { [unowned self] _ in
            self.updateWindowFrame(animate: true)
        }
        observeNotification(center: workspaceNC, name: NSWorkspace.activeSpaceDidChangeNotification, queue: .main) { [unowned self] _ in
            self.updateWindowFrame(animate: true)
        }
    }

    private func updateWindowFrame(toScreen: NSScreen? = nil, animate: Bool) {
        let screen = toScreen ?? window?.screen ?? NSScreen.screens[0]
        let fullScreen = screen.isFullScreen || defaults.bool(forKey: "DesktopLyricsIgnoreSafeArea")
        let frame = fullScreen ? screen.frame : screen.visibleFrame
        window?.setFrame(frame, display: false, animate: animate)
        window?.saveFrame(usingName: KaraokeLyricsWindowController.windowFrame)
    }

    // Mirrors the Cocoa bindings / observeDefaults set above. Those
    // main-thread invalidations can tear down `inlineProgress`, so these
    // preference publishes re-install it after the bindings settle.
    private static let displayRefreshPreferenceKeys: [UserDefaults.DefaultsKeys] = [
        .desktopLyricsEnabled,
        .disableLyricsWhenPaused,
        .preferBilingualLyrics,
        .desktopLyricsOneLineMode,
        .chineseConversionIndex,
        .globalLyricsOffset,
        .desktopLyricsVerticalMode,
        .desktopLyricsEnableFurigana,
        .desktopLyricsEnableRomajin,
        .desktopLyricsFontName,
        .desktopLyricsFontSize,
        .desktopLyricsFontNameFallback,
        .desktopLyricsColor,
        .desktopLyricsProgressColor,
        .desktopLyricsShadowColor,
        .desktopLyricsBackgroundColor,
    ]

    // Captures playback/content state for the current render. Repeated
    // `playbackStateWillChange` publishes for the same line otherwise tear
    // down and re-add the karaoke `inlineProgress` animation each call,
    // which restarts it from `values[0]` (the current playback offset).
    // When the publisher fires faster than the animation can advance, the
    // progress stays pinned near zero — visible as the "stuck at 0s"
    // first-line flicker reported in single-song repeat.
    private struct DisplayKey: Equatable {
        let lyricsId: ObjectIdentifier
        let lineIndex: Int
        let isPlaying: Bool
        let preferBilingual: Bool
        let oneLineMode: Bool
        let chineseConversionIndex: Int
        // Quantized to ms so floating-point equality is stable. The
        // progress animation below interpolates each timetag against
        // `adjustedTimeDelay`, so a change here (user adjusts global
        // or per-track lyric offset) must invalidate the cached
        // render even when staying on the same line.
        let timeDelayMs: Int
    }

    private var lastShowingKey: DisplayKey?
    private var lastRenderedPlaybackState: PlaybackState?
    private var lastRenderedWallclock: Date?
    private var hasDisplayedLyrics = false
    private var pendingDisplayPreferenceRefresh = false

    private func playbackStateChanged(_ playbackState: PlaybackState) {
        handleLyricsDisplay(playbackState: playbackState)
    }

    private func lyricsOffsetChanged() {
        invalidateDisplayedLine()
        handleLyricsDisplay()
    }

    private func displayPreferencesChanged() {
        invalidateDisplayedLine()

        guard !pendingDisplayPreferenceRefresh else { return }
        pendingDisplayPreferenceRefresh = true

        // KVO for UserDefaults and Cocoa bindings can be delivered in the same
        // turn. Refresh after the main-thread bindings have invalidated
        // KaraokeLabel caches so the newly installed progress animation is not
        // immediately removed by font/color/layout updates.
        DispatchQueue.main.async {
            DispatchQueue.lyricsDisplay.async { [weak self] in
                guard let self = self else { return }
                self.pendingDisplayPreferenceRefresh = false
                self.invalidateDisplayedLine()
                self.handleLyricsDisplay()
            }
        }
    }

    private func invalidateDisplayedLine() {
        lastShowingKey = nil
        lastRenderedPlaybackState = nil
        lastRenderedWallclock = nil
    }

    private func clearDisplayedLyricsIfNeeded() {
        lastShowingKey = nil
        guard hasDisplayedLyrics else { return }
        hasDisplayedLyrics = false
        DispatchQueue.main.async {
            self.lyricsView.displayLrc("", secondLine: "")
        }
    }

    @objc private func handleLyricsDisplay() {
        handleLyricsDisplay(playbackState: selectedPlayer.playbackState)
    }

    private func handleLyricsDisplay(playbackState: PlaybackState) {
        let isPlaying = playbackState.isPlaying
        guard defaults[.desktopLyricsEnabled],
              !defaults[.disableLyricsWhenPaused] || isPlaying,
              let lyrics = AppController.shared.currentLyrics,
              let index = AppController.shared.currentLineIndex else {
            lastRenderedPlaybackState = nil
            lastRenderedWallclock = nil
            clearDisplayedLyricsIfNeeded()
            return
        }

        // Re-anchor the progress animation only when playback actually
        // jumps. We extrapolate the previous state forward by wallclock
        // (linear when playing, frozen when paused) and treat any drift
        // beyond ~80ms as a real seek/buffer/wrap-around — which is when
        // the animation needs to be re-installed against a fresh anchor.
        // Linear playback inside a single line stays anchored, so the
        // running keyframe animation continues uninterrupted, and the
        // highlight tracks playback to within the jump threshold (vs.
        // up to 0.5s of drift previously).
        let didJump: Bool
        if let lastState = lastRenderedPlaybackState, let lastWall = lastRenderedWallclock {
            let elapsed = Date().timeIntervalSince(lastWall)
            let predicted: TimeInterval
            switch lastState {
            case .playing:
                predicted = lastState.time
            case .fastForwarding(let time):
                predicted = time + elapsed
            case .rewinding(let time):
                predicted = time - elapsed
            case .paused(let time):
                predicted = time
            case .stopped:
                predicted = 0
            }
            didJump = abs(playbackState.time - predicted) > 0.08
        } else {
            didJump = true
        }
        let trackDuration = selectedPlayer.currentTrack?.duration
        let key = DisplayKey(
            lyricsId: ObjectIdentifier(lyrics),
            lineIndex: index,
            isPlaying: isPlaying,
            preferBilingual: defaults[.preferBilingualLyrics],
            oneLineMode: defaults[.desktopLyricsOneLineMode],
            chineseConversionIndex: defaults[.chineseConversionIndex],
            timeDelayMs: Int((lyrics.adjustedTimeDelay * 1000).rounded())
        )
        if lastShowingKey == key && !didJump {
            return
        }
        lastShowingKey = key
        lastRenderedPlaybackState = playbackState
        lastRenderedWallclock = Date()
        hasDisplayedLyrics = true

        let lrc = lyrics.lines[index]
        let next = lyrics.lines[(index + 1)...].first { $0.enabled }

        let languageCode = lyrics.metadata.translationLanguages.first

        var firstLine = lrc.content
        var secondLine: String
        var secondLineIsTranslation = false
        if defaults[.desktopLyricsOneLineMode] {
            secondLine = ""
        } else if defaults[.preferBilingualLyrics],
                  let translation = lrc.attachments[.translation(languageCode: languageCode)] {
            secondLine = translation
            secondLineIsTranslation = true
        } else {
            secondLine = next?.content ?? ""
        }

        if let converter = ChineseConverter.shared {
            if lyrics.metadata.language?.hasPrefix("zh") == true {
                firstLine = converter.convert(firstLine)
                if !secondLineIsTranslation {
                    secondLine = converter.convert(secondLine)
                }
            }
            if languageCode?.hasPrefix("zh") == true {
                secondLine = converter.convert(secondLine)
            }
        }

        // Capture the offset on `lyricsDisplay` so the progress animation
        // below is computed against the same lyrics that produced `lrc`
        // and `index`. Re-reading `AppController.shared.currentLyrics`
        // inside the `main.async` block would race with track switching
        // and could mix the old line with the new song's offset.
        let timeDelay = lyrics.adjustedTimeDelay
        DispatchQueue.main.async {
            self.lyricsView.displayLrc(firstLine, secondLine: secondLine)
            if let upperTextField = self.lyricsView.displayLine1,
               let timetag = lrc.attachments.timetag {
                // Anchor on the PlaybackState that triggered this render so the
                // animation is not seeded from a stale `selectedPlayer.playbackTime`
                // around repeat-one wrap or track-change boundaries.
                let position = playbackState.lyricsDisplayTime(trackDuration: trackDuration)
                let progress = timetag.tags.map { ($0.time + lrc.position - timeDelay - position, $0.index) }
                upperTextField.setProgressAnimation(color: self.lyricsView.progressColor, progress: progress)
                if !isPlaying {
                    upperTextField.pauseProgressAnimation()
                }
            }
        }
    }

    private func makeConstraints() {
        lyricsView.snp.remakeConstraints { make in
            make.centerX.equalToSuperview().safeMultipliedBy(defaults[.desktopLyricsXPositionFactor] * 2).priority(.low)
            make.centerY.equalToSuperview().safeMultipliedBy(defaults[.desktopLyricsYPositionFactor] * 2).priority(.low)

            make.leading.greaterThanOrEqualToSuperview().priority(.keepWindowSize)
            make.trailing.lessThanOrEqualToSuperview().priority(.keepWindowSize)
            make.top.greaterThanOrEqualToSuperview().priority(.keepWindowSize)
            make.bottom.lessThanOrEqualToSuperview().priority(.keepWindowSize)
        }
    }

    // MARK: Dragging

    private var vecToCenter: CGVector?

    override func mouseDown(with event: NSEvent) {
        let location = lyricsView.convert(event.locationInWindow, from: nil)
        vecToCenter = CGVector(from: location, to: lyricsView.bounds.center)
    }

    override func mouseDragged(with event: NSEvent) {
        guard defaults[.desktopLyricsDraggable],
              let vecToCenter = vecToCenter,
              let window = window else {
            return
        }
        let bounds = window.frame
        var center = event.locationInWindow + vecToCenter
        let centerInScreen = window.convertToScreen(CGRect(origin: center, size: .zero)).origin
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(centerInScreen) }),
           screen != window.screen {
            updateWindowFrame(toScreen: screen, animate: false)
            center = window.convertFromScreen(CGRect(origin: centerInScreen, size: .zero)).origin
            return
        }

        var xFactor = (center.x / bounds.width).clamped(to: 0 ... 1)
        var yFactor = (1 - center.y / bounds.height).clamped(to: 0 ... 1)
        if abs(center.x - bounds.width / 2) < 8 {
            xFactor = 0.5
        }
        if abs(center.y - bounds.height / 2) < 8 {
            yFactor = 0.5
        }
        defaults[.desktopLyricsXPositionFactor] = xFactor
        defaults[.desktopLyricsYPositionFactor] = yFactor
        makeConstraints()
        window.layoutIfNeeded()
    }
}

extension NSScreen {
    fileprivate var isFullScreen: Bool {
        guard let windowInfoList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return !windowInfoList.contains { info in
            guard info[kCGWindowOwnerName as String] as? String == "Window Server",
                  info[kCGWindowName as String] as? String == "Menubar",
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary as CFDictionary?,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                return false
            }
            return frame.contains(bounds)
        }
    }
}

extension ConstraintMakerEditable {
    @discardableResult
    fileprivate func safeMultipliedBy(_ amount: ConstraintMultiplierTarget) -> ConstraintMakerEditable {
        var factor = amount.constraintMultiplierTargetValue
        if factor.isZero {
            factor = .leastNonzeroMagnitude
        }
        return multipliedBy(factor)
    }
}

extension ConstraintPriority {
    static let windowSizeStayPut = ConstraintPriority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue)
    static let keepWindowSize = ConstraintPriority.windowSizeStayPut.advanced(by: -1)
}
