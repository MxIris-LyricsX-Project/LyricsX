import AppKit
import QuartzCore
import Combine
import LyricsXFoundation
import MSDisplayLink
import OSToolbox

// MARK: - Container View (AppKit + CALayer lyrics engine)

extension AppleMusicLyrics {
    @Loggable(
        isEnabled: AppleMusicLyrics.PanelDiagnostics.isLyricsEnabled,
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics",
        category: "LyricsFrame"
    )
    @Signpostable(
        isEnabled: AppleMusicLyrics.PanelDiagnostics.isLyricsEnabled,
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics",
        category: "LyricsFrame"
    )
    final class SyncedLyricsContainerView: NSView {
        // MARK: Inputs

        var onSeek: ((TimeInterval) -> Void)?
        weak var interactionState: InteractionStateModel?
        var karaokeMode: KaraokeMode = .characterLevel

        // MARK: Subviews

        private let scrollView = NSScrollView()
        private let documentView = FlippedDocumentView()
        private let viewportMaskLayer = CAGradientLayer()

        // MARK: State

        private var lyrics: Lyrics?
        private var hasWordTiming = false
        private var enabledLineViews: [SyncedLyricsLineView] = []
        private var lineViewByOriginalIndex: [Int: SyncedLyricsLineView] = [:]
        private var enabledOriginalIndices: [Int] = []
        private var highlightedOriginalIndex: Int?
        private var wasFollowing = true
        private var mainFontSize: CGFloat = 32
        private var translationFontSize: CGFloat = 18
        private var signature: LayoutSignature?
        private var lastLaidOutSize: CGSize = .zero
        private var displayLink: DisplayLink?
        private var displayLinkFrameTimingAccumulator = FrameTimingAccumulator()
        private var displayLinkWorkTimingAccumulator = FrameWorkTimingAccumulator()
        private var preferenceObservers: Set<AnyCancellable> = []
        private let lineTransitionCoordinator = LineTransitionCoordinator()
        private var pendingInteractiveTargetOriginalIndex: Int?
        private var lastLineTransitionTime: CFTimeInterval?
        private var lineTransitionTimeProvider: () -> CFTimeInterval = CACurrentMediaTime
        /// Where the selected line settles in the viewport. The panel hands over
        /// the cover's centre once its chrome is laid out — Music's
        /// `activeBaseline`, which the Now Playing player pins to
        /// `primaryArtworkCenterY` (`sub_100132638`). Until then, and in the
        /// narrow layout without a cover, the project's 40% baseline applies.
        var selectedLineAnchor: SelectedLineAnchor = .baselineViewportFraction(
            LineTransitionPlan.selectedLineBaselineViewportFraction
        ) {
            didSet {
                guard selectedLineAnchor != oldValue else { return }
                relayout()
                if interactionState?.isFollowing ?? true, let highlighted = highlightedOriginalIndex {
                    centerLine(originalIndex: highlighted, animated: false)
                }
            }
        }

        /// The fade distance the mask currently shows, so a following-state
        /// change only touches the layer when the distance actually flips.
        private var appliedEdgeFadeDistance: CGFloat?
        /// The lyrics display time resolved once per display-link frame; drives the
        /// karaoke fill and the intro/interlude indicators together.
        private var resolvedPlaybackTime: TimeInterval = 0

        /// Which row cascade a normal advance runs; see `LineCascadeVariant`.
        /// Read on every advance so the hidden defaults key can be flipped while
        /// a song plays. Probes inject a fixed variant.
        private var lineCascadeVariantProvider: () -> LineCascadeVariant = {
            LineCascadeVariant.resolve()
        }

        /// A line change that arrived while an Apple Music cascade was still
        /// settling. Music refuses to select a new line while its line-change
        /// animators are in flight and catches up once they finish; this holds the
        /// latest requested line until then.
        private var deferredHighlightedOriginalIndex: Int?
        /// The legacy cascade settles the clip as a unit when several highlights
        /// arrive together, so delayed row springs cannot pile up.
        private var lastHighlightedPosition: Int?
        /// A line advance further than this (e.g. a seek) snaps instantly instead of
        /// springing across the whole song.
        private let scrollJumpThreshold = 5

        // Intro "•••" instrumental indicator. Additive: nil unless the first
        // vocal line starts after `introGapThreshold`, in which case the engine
        // behaves exactly as without it.
        private var instrumentalView: SyncedLyricsInstrumentalView?
        private var introEndTime: Double = 0
        private let introGapThreshold: Double = 4.0

        /// Mid-song instrumental breaks (word-timed lyrics only, where line end
        /// times are known). Persistent inter-verse slots that fill during their
        /// gap. Additive: empty unless a real gap is detected.
        private struct InterludeSegment {
            let view: SyncedLyricsInstrumentalView
            let startTime: Double
            let endTime: Double
            let afterEnabledPosition: Int
        }

        private var interludeSegments: [InterludeSegment] = []
        private let interludeGapThreshold: Double = 5.0

        // MARK: Lifecycle

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            configureViewportMask()
            setupScrollView()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userWillScroll),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            // Re-render translations live when the host's translation
            // preferences change while a track is displayed.
            AppleMusicLyrics.hostEnvironment.translationSettingsDidChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.refreshTranslations() }
                .store(in: &preferenceObservers)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            displayLink = nil
        }

        func setLineTransitionTimeProvider(_ provider: @escaping () -> CFTimeInterval) {
            lineTransitionTimeProvider = provider
        }

        func setLineCascadeVariantProvider(_ provider: @escaping () -> LineCascadeVariant) {
            lineCascadeVariantProvider = provider
        }

        private func setupScrollView() {
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.contentView.drawsBackground = false
            // Every line and instrumental-focus transition attaches its spring to
            // this layer, so create it before the first highlight update.
            scrollView.contentView.wantsLayer = true
            scrollView.documentView = documentView
            scrollView.frame = bounds
            addSubview(scrollView)
        }

        private func configureViewportMask() {
            viewportMaskLayer.colors = [
                CGColor(gray: 1, alpha: 0),
                CGColor(gray: 1, alpha: 1),
                CGColor(gray: 1, alpha: 1),
                CGColor(gray: 1, alpha: 0),
            ]
            viewportMaskLayer.startPoint = CGPoint(x: 0.5, y: 1)
            viewportMaskLayer.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.mask = viewportMaskLayer
            updateViewportMaskGeometry()
        }

        /// Music's outer mask (`sub_1001284F8`) fades both edges over 128 points
        /// while the lyrics follow playback and over 30 while the user scrolls
        /// through them. Music installs it on a flipped container; this one is
        /// not flipped, so the gradient vector runs the other way and the
        /// locations keep their meaning. Size changes set the values outright;
        /// the following-state flip keeps the layer's implicit animation, as
        /// Music does.
        private func updateViewportMaskGeometry(animated: Bool = false) {
            let fadeDistance = NowPlayingLyricsLayoutPolicy.edgeFadeDistance(
                isFollowing: interactionState?.isFollowing ?? true
            )
            let locations = NowPlayingLyricsLayoutPolicy.edgeFadeLocations(
                viewportHeight: bounds.height,
                fadeDistance: fadeDistance
            )
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            viewportMaskLayer.frame = bounds
            viewportMaskLayer.locations = locations.map { NSNumber(value: Double($0)) }
            CATransaction.commit()
            appliedEdgeFadeDistance = fadeDistance
        }

        /// Re-derives the fade after the following state may have changed.
        private func refreshEdgeFadeForFollowingState() {
            let fadeDistance = NowPlayingLyricsLayoutPolicy.edgeFadeDistance(
                isFollowing: interactionState?.isFollowing ?? true
            )
            guard fadeDistance != appliedEdgeFadeDistance else { return }
            updateViewportMaskGeometry(animated: true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                startDisplayLink()
            } else {
                stopDisplayLink()
            }
        }

        // MARK: Update Entry Point

        func update(lyrics: Lyrics, highlightedLineIndex: Int?, mainFontSize: CGFloat, translationFontSize: CGFloat) {
            let newSignature = LayoutSignature(lyrics: lyrics)
            let fontsChanged = mainFontSize != self.mainFontSize || translationFontSize != self.translationFontSize
            self.lyrics = lyrics
            self.mainFontSize = mainFontSize
            self.translationFontSize = translationFontSize

            if newSignature != signature {
                signature = newSignature
                rebuildLineViews()
                relayout()
                highlightedOriginalIndex = nil
                applyHighlight(originalIndex: resolveRenderedIndex(highlightedLineIndex), animated: false)
                if instrumentalView != nil {
                    let currentTime = selectedPlayer.playbackTime + lyrics.adjustedTimeDelay
                    if currentTime < introEndTime {
                        centerOnInstrumentalDots(animated: false)
                    }
                }
                return
            }

            if fontsChanged {
                for view in enabledLineViews {
                    view.updateFonts(mainFontSize: mainFontSize, translationFontSize: translationFontSize)
                }
                relayout()
                if let highlighted = highlightedOriginalIndex {
                    centerLine(originalIndex: highlighted, animated: false)
                }
            }

            let resolvedIndex = resolveRenderedIndex(highlightedLineIndex)
            if resolvedIndex != highlightedOriginalIndex {
                if shouldDeferHighlight(to: resolvedIndex) {
                    deferredHighlightedOriginalIndex = resolvedIndex
                    let deferredIndex = resolvedIndex ?? -1
                    #log(
                        .info,
                        "Line change deferred until the cascade settles originalIndex=\(deferredIndex, privacy: .public)"
                    )
                } else {
                    applyHighlight(originalIndex: resolvedIndex, animated: true)
                }
            } else {
                // The latest known line is the one already shown, so anything
                // held back by an earlier cascade is stale.
                deferredHighlightedOriginalIndex = nil
            }

            // When following resumes together with a data update, snap back to
            // the current line. (Resumes that happen without a data update — the
            // countdown completing — are handled by `resumeFollowingIfNeeded()`,
            // called from the view controller's `interactionState.onChange`.)
            let isFollowing = interactionState?.isFollowing ?? true
            if isFollowing, !wasFollowing, let highlighted = highlightedOriginalIndex {
                centerLine(originalIndex: highlighted, animated: true)
            }
            wasFollowing = isFollowing
            refreshEdgeFadeForFollowingState()
        }

        /// Re-center when the interaction state returns to following outside of a
        /// data update (e.g. the countdown completing). Driven by the view
        /// controller's `interactionState.onChange`, since there is no longer a
        /// SwiftUI `updateNSView` to trigger it.
        func resumeFollowingIfNeeded() {
            let isFollowing = interactionState?.isFollowing ?? true
            if isFollowing, !wasFollowing, let highlighted = highlightedOriginalIndex {
                centerLine(originalIndex: highlighted, animated: true)
            }
            wasFollowing = isFollowing
            refreshEdgeFadeForFollowingState()
        }

        /// Maps an original `lyrics.lines` index (which AppController computes
        /// over `enabled` lines only) to an index that actually has a rendered
        /// view (we additionally drop empty-content lines). During an
        /// enabled-but-empty interlude line, this keeps the previous sung line
        /// highlighted, anchored, and filled instead of dropping the highlight.
        private func resolveRenderedIndex(_ index: Int?) -> Int? {
            guard let index else { return nil }
            if lineViewByOriginalIndex[index] != nil {
                return index
            }
            return enabledOriginalIndices.last(where: { $0 <= index })
        }

        private func refreshTranslations() {
            guard !enabledLineViews.isEmpty else { return }
            for view in enabledLineViews {
                view.refreshTranslation()
            }
            relayout()
            if let highlighted = highlightedOriginalIndex {
                centerLine(originalIndex: highlighted, animated: false)
            }
        }

        // MARK: Build

        private func rebuildLineViews() {
            lastHighlightedPosition = nil
            lastLineTransitionTime = nil
            pendingInteractiveTargetOriginalIndex = nil
            deferredHighlightedOriginalIndex = nil
            lineTransitionCoordinator.cancel(scrollView: scrollView)
            enabledLineViews.forEach { $0.removeFromSuperview() }
            enabledLineViews.removeAll()
            lineViewByOriginalIndex.removeAll()
            enabledOriginalIndices.removeAll()
            hasWordTiming = false

            guard let lyrics else { return }

            hasWordTiming = lyrics.lines.contains { line in
                line.synchronizedTextTiming != nil || line.attachments.timetag?.tags.isEmpty == false
            }
            var enabledPosition = 0
            for (originalIndex, line) in lyrics.lines.enumerated() where line.enabled && !line.content.isEmpty {
                let view = SyncedLyricsLineView()
                view.configure(
                    line: line,
                    originalIndex: originalIndex,
                    enabledPosition: enabledPosition,
                    mainFontSize: mainFontSize,
                    translationFontSize: translationFontSize
                )
                view.alphaValue = 0.55
                view.onTap = { [weak self] tappedLine in
                    guard let self else { return }
                    self.pendingInteractiveTargetOriginalIndex = originalIndex
                    self.onSeek?(tappedLine.position + 0.01)
                    self.interactionState?.returnToFollowing()
                }
                documentView.addSubview(view)
                enabledLineViews.append(view)
                lineViewByOriginalIndex[originalIndex] = view
                enabledOriginalIndices.append(originalIndex)
                enabledPosition += 1
            }

            // Intro "•••" indicator when the first vocal line starts late.
            instrumentalView?.removeFromSuperview()
            instrumentalView = nil
            introEndTime = 0
            if let firstIndex = enabledOriginalIndices.first {
                let firstPosition = lyrics.lines[firstIndex].position
                let currentTime = selectedPlayer.playbackTime + lyrics.adjustedTimeDelay
                // Only while we are actually still inside the intro, so opening
                // the panel mid-song doesn't flash the dots then collapse them.
                if firstPosition > introGapThreshold, currentTime < firstPosition {
                    let view = SyncedLyricsInstrumentalView()
                    documentView.addSubview(view)
                    instrumentalView = view
                    introEndTime = firstPosition
                }
            }

            // Mid-song interlude indicators between word-timed lines whose gap
            // (next line start − this line's sung end) exceeds the threshold.
            interludeSegments.forEach { $0.view.removeFromSuperview() }
            interludeSegments.removeAll()
            for position in enabledOriginalIndices.indices.dropLast() {
                let line = lyrics.lines[enabledOriginalIndices[position]]
                guard let duration = line.timetagDuration, duration > 0 else { continue }
                let lineEnd = line.position + duration
                let nextStart = lyrics.lines[enabledOriginalIndices[position + 1]].position
                if nextStart - lineEnd > interludeGapThreshold {
                    let view = SyncedLyricsInstrumentalView()
                    documentView.addSubview(view)
                    interludeSegments.append(InterludeSegment(view: view, startTime: lineEnd, endTime: nextStart, afterEnabledPosition: position))
                }
            }
        }

        // MARK: Layout

        override func layout() {
            super.layout()
            if layer?.mask !== viewportMaskLayer {
                layer?.mask = viewportMaskLayer
            }
            updateViewportMaskGeometry()
            scrollView.frame = bounds
            if bounds.size != lastLaidOutSize {
                relayout()
                if let highlighted = highlightedOriginalIndex {
                    centerLine(originalIndex: highlighted, animated: false)
                }
            }
        }

        private func relayout() {
            let width = bounds.width
            let clipHeight = bounds.height
            guard width > 0 else { return }

            let topContentInset = enabledLineViews.first.map { lineView in
                selectedLineTopInset(for: lineView, layoutWidth: width)
            } ?? 0
            var cursorY = topContentInset
            if let instrumentalView {
                let dotsHeight = instrumentalView.preferredHeight
                cursorY = max(topContentInset, anchorCenterY(visibleHeight: clipHeight) - dotsHeight / 2)
                instrumentalView.frame = NSRect(x: 0, y: cursorY, width: width, height: dotsHeight)
                cursorY += dotsHeight
            }
            let interludeByPosition = Dictionary(
                interludeSegments.map { ($0.afterEnabledPosition, $0.view) },
                uniquingKeysWith: { first, _ in first }
            )
            for (position, view) in enabledLineViews.enumerated() {
                let height = view.preferredHeight(forWidth: width)
                view.frame = NSRect(x: 0, y: cursorY, width: width, height: height)
                cursorY += height
                if let interludeView = interludeByPosition[position] {
                    let dotsHeight = interludeView.preferredHeight
                    interludeView.frame = NSRect(x: 0, y: cursorY, width: width, height: dotsHeight)
                    cursorY += dotsHeight
                }
            }
            let bottomContentInset = max(0, clipHeight - topContentInset)
            let totalHeight = cursorY + bottomContentInset
            documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(totalHeight, clipHeight))
            lastLaidOutSize = bounds.size
        }

        // MARK: Highlight

        /// Music will not select a new line while a line-change animator is in
        /// flight (`sub_1001D8C08` skips the manager update whenever
        /// `currentAnimators` is non-empty) and catches up when it settles. Only
        /// the Apple Music cascade adopts that; the legacy cascade keeps its own
        /// rapid-change settle. A tapped line and a scroll-away never wait.
        private func shouldDeferHighlight(to originalIndex: Int?) -> Bool {
            guard originalIndex != nil,
                  lineCascadeVariantProvider() == .appleMusic26,
                  window != nil,
                  interactionState?.isFollowing ?? true,
                  pendingInteractiveTargetOriginalIndex != originalIndex
            else {
                return false
            }
            return lineTransitionCoordinator.isCascadeInFlight
        }

        private func applyDeferredHighlightIfNeeded() {
            guard let deferredIndex = deferredHighlightedOriginalIndex else { return }
            deferredHighlightedOriginalIndex = nil
            guard deferredIndex != highlightedOriginalIndex else { return }
            #log(
                .info,
                "Deferred line change applied originalIndex=\(deferredIndex, privacy: .public)"
            )
            applyHighlight(originalIndex: deferredIndex, animated: true)
        }

        private func applyHighlight(originalIndex: Int?, animated: Bool) {
            deferredHighlightedOriginalIndex = nil
            let previousHighlightedOriginalIndex = highlightedOriginalIndex
            if let old = highlightedOriginalIndex, let view = lineViewByOriginalIndex[old] {
                view.setHighlighted(false)
            }
            highlightedOriginalIndex = originalIndex
            if let new = originalIndex, let view = lineViewByOriginalIndex[new] {
                view.setHighlighted(true)
            }
            if !animated {
                lastHighlightedPosition = originalIndex.flatMap { lineViewByOriginalIndex[$0]?.enabledPosition }
                lastLineTransitionTime = nil
            }
            let isFollowing = interactionState?.isFollowing ?? true
            if isFollowing, let new = originalIndex {
                if animated, window != nil {
                    advanceFollowing(toOriginalIndex: new, fromOriginalIndex: previousHighlightedOriginalIndex)
                } else {
                    centerLine(originalIndex: new, animated: false)
                }
            }
            updateDistances(animated: animated)
        }

        /// Move to a newly highlighted line while following. A large noninteractive
        /// jump snaps instantly; otherwise the selected cascade variant runs. The
        /// legacy variant additionally settles the clip as a unit when highlights
        /// arrive in rapid succession.
        private func advanceFollowing(toOriginalIndex originalIndex: Int, fromOriginalIndex previousOriginalIndex: Int?) {
            guard let view = lineViewByOriginalIndex[originalIndex] else { return }
            let newPosition = view.enabledPosition
            let usesInteractiveSpring = pendingInteractiveTargetOriginalIndex == originalIndex
            pendingInteractiveTargetOriginalIndex = nil
            let isJump = lastHighlightedPosition.map { abs(newPosition - $0) > scrollJumpThreshold } ?? true
            let currentLineTransitionTime = lineTransitionTimeProvider()
            let isRapid = lastLineTransitionTime.map { previousLineTransitionTime in
                let elapsedTime = currentLineTransitionTime - previousLineTransitionTime
                return elapsedTime >= 0 && elapsedTime < LineTransitionPlan.rapidTransitionThreshold
            } ?? false
            lastHighlightedPosition = newPosition
            lastLineTransitionTime = currentLineTransitionTime
            let variant = lineCascadeVariantProvider()

            let transitionKind: String
            if usesInteractiveSpring {
                transitionKind = "interactiveSpring"
                centerLine(originalIndex: originalIndex, animated: true, usesInteractiveSpring: true)
            } else if isJump {
                transitionKind = "jump"
                centerLine(originalIndex: originalIndex, animated: false)
            } else {
                switch variant {
                case .appleMusic26:
                    transitionKind = "appleMusicCascade"
                    cascadeVisibleLines(originalIndex: originalIndex, previousOriginalIndex: previousOriginalIndex)
                case .legacySwiftUI where isRapid:
                    transitionKind = "rapidSettle"
                    settleLine(originalIndex: originalIndex)
                case .legacySwiftUI:
                    transitionKind = "cascade"
                    cascadeLine(originalIndex: originalIndex)
                }
            }
            #log(
                .info,
                """
                Line advance kind=\(transitionKind, privacy: .public) \
                variant=\(variant.rawValue, privacy: .public) \
                originalIndex=\(originalIndex, privacy: .public) \
                enabledPosition=\(newPosition, privacy: .public)
                """
            )
            #signpost(
                .event,
                "LineAdvance",
                "kind=\(transitionKind, privacy: .public) enabledPosition=\(newPosition, privacy: .public)"
            )
        }

        private func updateDistances(animated: Bool) {
            let distanceUpdateInterval = #signpost(.begin, "UpdateLineDistances")
            defer { #signpost(.end, distanceUpdateInterval) }
            let highlightedPosition = highlightedOriginalIndex.flatMap { lineViewByOriginalIndex[$0]?.enabledPosition }
            let visibleBounds = scrollView.documentVisibleRect.insetBy(
                dx: 0,
                dy: -scrollView.documentVisibleRect.height * 0.5
            )
            var visibleLinePositions = Set(enabledLineViews.compactMap { lineView in
                lineView.frame.intersects(visibleBounds) ? lineView.enabledPosition : nil
            })
            if let highlightedPosition {
                visibleLinePositions.insert(highlightedPosition)
            }
            let blurPlan = LineBlurPlan.make(
                visibleLinePositions: visibleLinePositions,
                selectedLinePosition: highlightedPosition
            )
            #log(
                .debug,
                """
                Distance update animated=\(animated, privacy: .public) \
                visibleLines=\(visibleLinePositions.count, privacy: .public) \
                blurredLines=\(blurPlan.blurredLinePositions.count, privacy: .public)
                """
            )
            for view in enabledLineViews {
                let isSelected = highlightedPosition.map { view.enabledPosition == $0 } ?? false
                // Every non-selected line sits at one flat opacity no matter how
                // far from the selected one it is — measured off a Music 26.5.2
                // recording, stroke peaks hold at ~0.5 luminance from one line
                // away to four. Depth comes from the blur, not an opacity ramp;
                // the ramp this replaces sank the bottom of the panel into the
                // background.
                let target: CGFloat = isSelected ? 1.0 : 0.55
                if animated {
                    view.animateAlpha(to: target, duration: 0.5)
                } else {
                    view.alphaValue = target
                }
                // `deselectedTransform` is the identity (no whole-line scale) — kept
                // for the active line staying at 1.0.
                view.setLineSelected(isSelected, animated: animated)
                // Music keeps an explicit contextual set rather than treating
                // every non-selected row as blurred. Rows inside the current
                // rendering context use one fixed radius; rows outside it return
                // to zero so they do not retain stale filter state.
                let targetBlurRadius = blurPlan.blurredLinePositions.contains(view.enabledPosition)
                    ? blurPlan.radius
                    : 0
                view.setLineBlurRadius(targetBlurRadius, animated: animated)
            }
        }

        // MARK: Scrolling

        private func cascadeVisibleLines(originalIndex: Int, previousOriginalIndex: Int?) {
            guard let view = lineViewByOriginalIndex[originalIndex] else { return }
            let configuration = UniformLineCascadeConfiguration(
                springTiming: LineTransitionPlan.automaticSpringTiming(
                    sungGap: lineChangeSungGap(from: previousOriginalIndex, to: originalIndex)
                ),
                lineDelay: LineTransitionPlan.appleMusicLineDelay,
                backwardLineDelayScale: LineTransitionPlan.appleMusicBackwardLineDelayScale
            )
            lineTransitionCoordinator.transitionVisibleLines(
                scrollView: scrollView,
                lineViews: enabledLineViews,
                targetClipVerticalOrigin: clampedClipVerticalOrigin(for: view),
                configuration: configuration,
                animated: window != nil
            ) { [weak self] in
                self?.applyDeferredHighlightIfNeeded()
            }
        }

        private func lineChangeSungGap(from previousOriginalIndex: Int?, to originalIndex: Int) -> TimeInterval? {
            guard hasWordTiming,
                  let lyrics,
                  let previousOriginalIndex,
                  lyrics.lines.indices.contains(previousOriginalIndex),
                  lyrics.lines.indices.contains(originalIndex),
                  let previousSungDuration = lyrics.lines[previousOriginalIndex].timetagDuration,
                  previousSungDuration.isFinite,
                  previousSungDuration >= 0
            else {
                return nil
            }
            // Use the line that was actually selected, including deferred catch-up.
            // Inferring an end from the next start would erase every sung gap.
            let previousSungEnd = lyrics.lines[previousOriginalIndex].position + previousSungDuration
            return lyrics.lines[originalIndex].position - previousSungEnd
        }

        private func cascadeLine(originalIndex: Int) {
            guard let view = lineViewByOriginalIndex[originalIndex] else { return }
            let springTiming = SpringTimingParameters(
                dampingRatio: LineTransitionPlan.cascadeSpringDampingRatio,
                period: LineTransitionPlan.cascadeSpringPeriod
            )
            let configuration = LineCascadeConfiguration(
                selectedLinePosition: view.enabledPosition,
                springTiming: springTiming,
                settleDuration: LineTransitionPlan.cascadeSettleDuration,
                stagger: LineTransitionPlan.cascadeStagger,
                aboveLineCount: LineTransitionPlan.cascadeAboveLineCount,
                belowLineCount: LineTransitionPlan.cascadeBelowLineCount
            )
            lineTransitionCoordinator.transitionLines(
                scrollView: scrollView,
                lineViews: enabledLineViews,
                targetClipVerticalOrigin: clampedClipVerticalOrigin(for: view),
                configuration: configuration,
                animated: window != nil
            )
        }

        private func settleLine(originalIndex: Int) {
            guard let view = lineViewByOriginalIndex[originalIndex] else { return }
            let timing = SpringTimingParameters(
                dampingRatio: LineTransitionPlan.rapidSettleDampingRatio,
                period: LineTransitionPlan.rapidSettleSpringPeriod
            )
            lineTransitionCoordinator.transitionClip(
                scrollView: scrollView,
                targetClipVerticalOrigin: clampedClipVerticalOrigin(for: view),
                timing: timing,
                animated: window != nil
            )
        }

        private func centerLine(
            originalIndex: Int,
            animated: Bool,
            usesInteractiveSpring: Bool = false
        ) {
            guard let view = lineViewByOriginalIndex[originalIndex] else { return }
            let targetClipVerticalOrigin = clampedClipVerticalOrigin(for: view)
            let timing = usesInteractiveSpring
                ? SpringTimingParameters(
                    mass: LineTransitionPlan.interactiveSpringMass,
                    stiffness: LineTransitionPlan.interactiveSpringStiffness,
                    damping: LineTransitionPlan.interactiveSpringDamping
                )
                : SpringTimingParameters(
                    mass: LineTransitionPlan.normalSpringMass,
                    stiffness: LineTransitionPlan.normalSpringStiffness,
                    damping: LineTransitionPlan.normalSpringDamping
                )
            lineTransitionCoordinator.transitionClip(
                scrollView: scrollView,
                targetClipVerticalOrigin: targetClipVerticalOrigin,
                timing: timing,
                animated: animated && window != nil
            )
        }

        private func centerOnInstrumentalDots(animated: Bool) {
            guard let instrumentalView else { return }
            anchorClip(toCenterVerticalPosition: instrumentalView.frame.midY, animated: animated)
        }

        /// Scroll so an instrumental indicator's vertical centre sits at the
        /// vertical centre of the viewport.
        private func anchorClip(toCenterVerticalPosition centerVerticalPosition: CGFloat, animated: Bool) {
            let targetVerticalOrigin = clampedClipVerticalOrigin(forCenterVerticalPosition: centerVerticalPosition)
            let timing = SpringTimingParameters(
                mass: LineTransitionPlan.normalSpringMass,
                stiffness: LineTransitionPlan.normalSpringStiffness,
                damping: LineTransitionPlan.normalSpringDamping
            )
            lineTransitionCoordinator.transitionClip(
                scrollView: scrollView,
                targetClipVerticalOrigin: targetVerticalOrigin,
                timing: timing,
                animated: animated && window != nil
            )
        }

        /// The viewport y (down from its top) an instrumental indicator is
        /// centred on: the anchor itself, or the viewport's middle under the
        /// legacy fraction. Music runs its instrumental line through the same
        /// `.center` path as a lyric line.
        private func anchorCenterY(visibleHeight: CGFloat) -> CGFloat {
            switch selectedLineAnchor {
            case .baselineViewportFraction:
                return visibleHeight / 2
            case .contentCenter(let anchorY):
                return anchorY
            }
        }

        private func clampedClipVerticalOrigin(forCenterVerticalPosition centerVerticalPosition: CGFloat) -> CGFloat {
            let visibleHeight = scrollView.contentView.bounds.height
            let maximumVerticalOrigin = max(0, documentView.frame.height - visibleHeight)
            return min(
                max(0, centerVerticalPosition - anchorCenterY(visibleHeight: visibleHeight)),
                maximumVerticalOrigin
            )
        }

        private func clampedClipVerticalOrigin(for lineView: SyncedLyricsLineView) -> CGFloat {
            let visibleHeight = scrollView.contentView.bounds.height
            let maximumVerticalOrigin = max(0, documentView.frame.height - visibleHeight)
            let topInset = selectedLineTopInset(for: lineView, layoutWidth: lineView.bounds.width)
            return min(
                max(0, lineView.frame.minY - topInset),
                maximumVerticalOrigin
            )
        }

        private func selectedLineTopInset(for lineView: SyncedLyricsLineView, layoutWidth: CGFloat) -> CGFloat {
            LineTransitionPlan.selectedLineTopInset(
                anchor: selectedLineAnchor,
                visibleHeight: scrollView.contentView.bounds.height,
                contentCenterOffset: lineView.contentCenterOffset(forWidth: layoutWidth),
                firstBaselineOffset: lineView.mainTextFirstBaselineOffset
            )
        }

        @objc private func userWillScroll() {
            // The user took over — abandon the in-flight auto-scroll spring so it
            // does not keep moving content under the drag.
            lineTransitionCoordinator.cancel(scrollView: scrollView)
            interactionState?.userDidScroll()
            refreshEdgeFadeForFollowingState()
            // The cascade that held a line change back is gone, and following is
            // off, so the held line only updates its highlight without scrolling.
            applyDeferredHighlightIfNeeded()
        }

        // MARK: Display Link (per-frame karaoke driver)

        private func startDisplayLink() {
            guard displayLink == nil else { return }
            // MSDisplayLink wraps CADisplayLink (macOS 14+) and CVDisplayLink (older)
            // behind a single back-deployable Combine-friendly API, so the karaoke
            // driver runs on every supported macOS version.
            let link = DisplayLink()
            link.delegatingObject(self)
            displayLinkFrameTimingAccumulator = FrameTimingAccumulator()
            displayLinkWorkTimingAccumulator = FrameWorkTimingAccumulator()
            displayLink = link
            #log(.info, "Lyrics display link started")
            #signpost(.event, "DisplayLinkStarted")
        }

        private func stopDisplayLink() {
            guard displayLink != nil else { return }
            displayLink = nil
            #log(.info, "Lyrics display link stopped")
            #signpost(.event, "DisplayLinkStopped")
        }

        private func handleDisplayLink() {
            // Resolve the lyrics time once per frame from the player STATE
            // (`lyricsDisplayTime`) — the canonical source every other lyrics view
            // uses, accurate while playing and (now) stable when paused. Everything
            // below uses this single value.
            if FramePerformanceDiagnosticsPolicy.detailedFrameSignpostingIsEnabled {
                resolvedPlaybackTime = #signpostInterval("LyricsPlaybackStateRead") {
                    currentLyricsPlaybackTime()
                }
            } else {
                resolvedPlaybackTime = currentLyricsPlaybackTime()
            }
            // Nothing here advances a transition: Core Animation owns the clip
            // spring, so it keeps moving at the display's own rate even when this
            // callback is late.
            if FramePerformanceDiagnosticsPolicy.detailedFrameSignpostingIsEnabled {
                #signpostInterval("LyricsInstrumentalProgressUpdate") {
                    updateInstrumentalProgress()
                }
            } else {
                updateInstrumentalProgress()
            }

            guard let lyrics,
                  let highlighted = highlightedOriginalIndex,
                  highlighted < lyrics.lines.count,
                  let view = lineViewByOriginalIndex[highlighted] else { return }
            let line = lyrics.lines[highlighted]
            let elapsed = resolvedPlaybackTime + lyrics.adjustedTimeDelay - line.position
            if FramePerformanceDiagnosticsPolicy.detailedFrameSignpostingIsEnabled {
                #signpostInterval("LyricsKaraokeLineUpdate") {
                    updateKaraokeLine(
                        view,
                        elapsedTime: elapsed,
                        originalIndex: highlighted
                    )
                }
            } else {
                updateKaraokeLine(
                    view,
                    elapsedTime: elapsed,
                    originalIndex: highlighted
                )
            }
        }

        private func currentLyricsPlaybackTime() -> TimeInterval {
            selectedPlayer.playbackState.lyricsDisplayTime(
                trackDuration: selectedPlayer.currentTrack?.duration
            )
        }

        private func updateInstrumentalProgress() {
            updateIntroDotsIfNeeded()
            updateInterludesIfNeeded()
        }

        private func updateKaraokeLine(
            _ lineView: SyncedLyricsLineView,
            elapsedTime: TimeInterval,
            originalIndex: Int
        ) {
            lineView.updateKaraoke(
                elapsedTime: elapsedTime,
                lineDuration: lineDuration(forOriginalIndex: originalIndex),
                mode: karaokeMode
            )
        }

        private func updateIntroDotsIfNeeded() {
            guard let instrumentalView, let lyrics else { return }
            let currentTime = resolvedPlaybackTime + lyrics.adjustedTimeDelay
            if currentTime < introEndTime {
                let fraction = introEndTime > 0 ? CGFloat(currentTime / introEndTime) : 0
                instrumentalView.setProgress(fraction)
            } else {
                collapseIntroDots()
            }
        }

        private func updateInterludesIfNeeded() {
            guard !interludeSegments.isEmpty, let lyrics else { return }
            let currentTime = resolvedPlaybackTime + lyrics.adjustedTimeDelay
            var activeSegment: InterludeSegment?
            for segment in interludeSegments {
                if currentTime < segment.startTime {
                    segment.view.setProgress(0)
                } else if currentTime >= segment.endTime {
                    segment.view.setProgress(1)
                } else {
                    let span = segment.endTime - segment.startTime
                    segment.view.setProgress(span > 0 ? CGFloat((currentTime - segment.startTime) / span) : 0)
                    activeSegment = segment
                }
            }
            // During an interlude, keep the dots centered (the previous line
            // stays highlighted but the focus is the upcoming-break indicator).
            if let activeSegment, interactionState?.isFollowing ?? true {
                anchorClip(toCenterVerticalPosition: activeSegment.view.frame.midY, animated: true)
            }
        }

        private func collapseIntroDots() {
            guard let view = instrumentalView else { return }
            instrumentalView = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                view.animator().alphaValue = 0
            } completionHandler: {
                view.removeFromSuperview()
            }
            relayout()
            if interactionState?.isFollowing ?? true {
                if let highlighted = highlightedOriginalIndex {
                    centerLine(originalIndex: highlighted, animated: true)
                } else if let firstIndex = enabledOriginalIndices.first {
                    centerLine(originalIndex: firstIndex, animated: true)
                }
            }
        }

        private func lineDuration(forOriginalIndex index: Int) -> TimeInterval {
            guard let lyrics else { return 5 }
            if let duration = lyrics.lines[index].timetagDuration, duration > 0 {
                return duration
            }
            if let nextIndex = enabledOriginalIndices.first(where: { $0 > index }) {
                return lyrics.lines[nextIndex].position - lyrics.lines[index].position
            }
            return 5
        }

        // MARK: - Layout Signature

        /// Cheap track-change detector: rebuild line views only when the set of
        /// enabled lines actually changes, not on every highlight/resize update.
        private struct LayoutSignature: Equatable {
            var count: Int
            var contentHash: Int

            init(lyrics: Lyrics) {
                var enabledCount = 0
                var hasher = Hasher()
                hasher.combine(lyrics.idTags[.init("lang")] ?? "")
                for line in lyrics.lines where line.enabled && !line.content.isEmpty {
                    enabledCount += 1
                    hasher.combine(line.content)
                    hasher.combine(line.position)
                    // Fold in timing + translation so a same-track source swap
                    // that keeps the same text but changes word timings or the
                    // translation still triggers a rebuild.
                    let timetag = line.attachments.timetag
                    hasher.combine(timetag?.tags.count ?? -1)
                    hasher.combine(timetag?.duration ?? -1)
                    hasher.combine(line.attachments.synchronizedTextTiming?.description ?? "")
                    hasher.combine(line.attachments.translation() ?? "")
                }
                self.count = enabledCount
                self.contentHash = hasher.finalize()
            }
        }

        // MARK: - Flipped Document View

        private final class FlippedDocumentView: NSView {
            override var isFlipped: Bool {
                true
            }
        }
    }
}

extension AppleMusicLyrics.SyncedLyricsContainerView: DisplayLinkDelegate {
    func synchronization(context: DisplayLinkCallbackContext) {
        let arrivalTimestamp = CACurrentMediaTime()
        let cadenceReport = displayLinkFrameTimingAccumulator.record(
            sourceTimestamp: context.timestamp,
            arrivalTimestamp: arrivalTimestamp,
            targetTimestamp: context.targetTimestamp,
            expectedFrameDuration: context.duration
        )

        let workStartTimestamp = CACurrentMediaTime()
        if AppleMusicLyrics.FramePerformanceDiagnosticsPolicy
            .detailedFrameSignpostingIsEnabled {
            #signpostInterval("LyricsDisplayLinkFrame") {
                handleDisplayLink()
            }
        } else {
            handleDisplayLink()
        }
        let workDuration = CACurrentMediaTime() - workStartTimestamp
        displayLinkWorkTimingAccumulator.record(
            duration: workDuration,
            expectedFrameDuration: context.duration
        )

        guard let cadenceReport else { return }

        let workReport = displayLinkWorkTimingAccumulator.takeReport()
        let highlightedLine: LyricsLine?
        if let highlightedOriginalIndex,
           let lyrics,
           lyrics.lines.indices.contains(highlightedOriginalIndex) {
            highlightedLine = lyrics.lines[highlightedOriginalIndex]
        } else {
            highlightedLine = nil
        }
        let highlightedLineCharacterCount = highlightedLine?.content.count ?? 0
        let highlightedLineTimingEntryCount = highlightedLine?.wordTimingEntries?.count ?? 0
        let highlightedLineIndex = highlightedOriginalIndex ?? -1
        #log(
            .info,
            """
            Lyrics cadence nominalFramesPerSecond=\(cadenceReport.nominalFramesPerSecond, privacy: .public) \
            sourceFramesPerSecond=\(cadenceReport.sourceFramesPerSecond, privacy: .public) \
            mainFramesPerSecond=\(cadenceReport.arrivalFramesPerSecond, privacy: .public) \
            sourceMissedFrames=\(cadenceReport.missedSourceFrameCount, privacy: .public) \
            mainMissedFrames=\(cadenceReport.missedArrivalFrameCount, privacy: .public) \
            maximumSourceGapMilliseconds=\(cadenceReport.maximumSourceGapMilliseconds, privacy: .public) \
            maximumMainGapMilliseconds=\(cadenceReport.maximumArrivalGapMilliseconds, privacy: .public) \
            maximumDeliveryLatenessMilliseconds=\(cadenceReport.maximumDeliveryLatenessMilliseconds, privacy: .public) \
            workSamples=\(workReport?.sampledFrameCount ?? 0, privacy: .public) \
            averageWorkMilliseconds=\(workReport?.averageDurationMilliseconds ?? 0, privacy: .public) \
            maximumWorkMilliseconds=\(workReport?.maximumDurationMilliseconds ?? 0, privacy: .public) \
            workBudgetOverruns=\(workReport?.frameBudgetOverrunCount ?? 0, privacy: .public) \
            highlightedLineIndex=\(highlightedLineIndex, privacy: .public) \
            highlightedLineCharacters=\(highlightedLineCharacterCount, privacy: .public) \
            timingEntries=\(highlightedLineTimingEntryCount, privacy: .public)
            """
        )
    }
}
