import AppKit
import QuartzCore
import Combine
import LyricsXFoundation

// MARK: - Container View (AppKit + CALayer lyrics engine)

@available(macOS 15, *)
extension AppleMusicLyrics {
    final class SyncedLyricsContainerView: NSView {
        // MARK: Inputs

        var onSeek: ((TimeInterval) -> Void)?
        weak var interactionState: InteractionStateModel?
        var karaokeMode: KaraokeMode = .characterLevel

        // MARK: Subviews

        private let scrollView = NSScrollView()
        private let documentView = FlippedDocumentView()

        // MARK: State

        private var lyrics: Lyrics?
        private var enabledLineViews: [SyncedLyricsLineView] = []
        private var lineViewByOriginalIndex: [Int: SyncedLyricsLineView] = [:]
        private var enabledOriginalIndices: [Int] = []
        private var highlightedOriginalIndex: Int?
        private var wasFollowing = true
        private var mainFontSize: CGFloat = 32
        private var translationFontSize: CGFloat = 18
        private var signature: LayoutSignature?
        private var lastLaidOutSize: CGSize = .zero
        private var displayLink: CADisplayLink?
        private var preferenceObservers: Set<AnyCancellable> = []

        // Auto-follow scroll. Apple Music animates a single spring on
        // `scrollView.contentView.bounds` (the clip origin) so the whole line
        // stack moves together — the lines are STATIC in the document; only the
        // clip moves. Re-confirmed 2026-06-16 in Music.arm64e: `LayerPropertyAnimator`
        // (`sub_100162B3C`) builds a real `CASpringAnimation` whose action
        // (`sub_10015AF20`) sets `contentView.bounds`. There is NO per-line position
        // cascade — that earlier reading was wrong, and the jump-clip-then-displace
        // implementation it produced leaked the literal clip jump as the
        // "直接运动" (teleport) the user reported. We reproduce the real mechanism
        // by stepping the clip origin toward its target every display-link frame
        // with the EXACT line-change spring, restarting from the current position
        // with zero velocity on each new target (matching AM's
        // `fromValue = presentationLayer`, default `initialVelocity = 0`).
        private var scrollTargetY: CGFloat?
        private var scrollVelocity: CGFloat = 0
        private var lastScrollTickTimestamp: CFTimeInterval = 0
        // `lineChangeSpringTimingParametersValues` (struct 0x2F8/0x300/0x308):
        // mass 1, stiffness 100, damping 18 → damping ratio ζ = 18/(2·√100) = 0.9.
        private let scrollSpringNaturalFrequency: CGFloat = 10      // √(stiffness / mass)
        private let scrollSpringDampingRatio: CGFloat = 0.9         // damping / (2·√(stiffness·mass))
        private var lastHighlightedPosition: Int?
        // A line advance further than this (e.g. a seek) snaps instantly instead of
        // springing across the whole song.
        private let scrollJumpThreshold = 5
        // Apple Music pins the active line near the very TOP of the lyrics area —
        // `LyricsSpecs.selectedLinePosition = .top(12.0)` — so there is (almost)
        // nothing above the active line and a full screen of upcoming lines below.
        // Frame-by-frame comparison against a 26.5.1 capture (2026-06-16) confirms
        // the active line is consistently the topmost line with only a small fixed
        // top margin. The earlier 0.35 anchor (active line a third of the way down,
        // with two already-sung lines above it) was a brightness-centroid
        // mis-measurement — the karaoke fill and faded just-sung lines skewed the
        // centroid downward.
        private let selectedLineTopInset: CGFloat = 12

        // Intro "•••" instrumental indicator. Additive: nil unless the first
        // vocal line starts after `introGapThreshold`, in which case the engine
        // behaves exactly as without it.
        private var instrumentalView: SyncedLyricsInstrumentalView?
        private var introEndTime: Double = 0
        private let introGapThreshold: Double = 4.0

        // Mid-song instrumental breaks (word-timed lyrics only, where line end
        // times are known). Persistent inter-verse slots that fill during their
        // gap. Additive: empty unless a real gap is detected.
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
            setupScrollView()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userWillScroll),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            // Re-render translations live when the bilingual / Chinese-conversion
            // preferences change while a track is displayed.
            defaults.publisher(for: [.preferBilingualLyrics, .chineseConversionIndex])
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshTranslations() }
                .store(in: &preferenceObservers)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            displayLink?.invalidate()
        }

        private func setupScrollView() {
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.contentView.drawsBackground = false
            scrollView.documentView = documentView
            addSubview(scrollView)
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
                applyHighlight(originalIndex: resolvedIndex, animated: true)
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
        }

        /// Maps an original `lyrics.lines` index (which AppController computes
        /// over `enabled` lines only) to an index that actually has a rendered
        /// view (we additionally drop empty-content lines). During an
        /// enabled-but-empty interlude line, this keeps the previous sung line
        /// highlighted, centered, and filled instead of dropping the highlight.
        private func resolveRenderedIndex(_ index: Int?) -> Int? {
            guard let index else { return nil }
            if lineViewByOriginalIndex[index] != nil { return index }
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
            enabledLineViews.forEach { $0.removeFromSuperview() }
            enabledLineViews.removeAll()
            lineViewByOriginalIndex.removeAll()
            enabledOriginalIndices.removeAll()

            guard let lyrics else { return }

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

            // The first line rests at the top inset (clip pinned to 0); a full
            // screen of bottom padding (added below) lets the LAST line scroll up
            // to the same top anchor — matching Apple Music's `.top(12)` position.
            var cursorY = selectedLineTopInset
            if let instrumentalView {
                let dotsHeight = instrumentalView.preferredHeight
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
            let totalHeight = cursorY + clipHeight
            documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(totalHeight, clipHeight))
            lastLaidOutSize = bounds.size
        }

        // MARK: Highlight

        private func applyHighlight(originalIndex: Int?, animated: Bool) {
            if let old = highlightedOriginalIndex, let view = lineViewByOriginalIndex[old] {
                view.setHighlighted(false)
            }
            highlightedOriginalIndex = originalIndex
            if let new = originalIndex, let view = lineViewByOriginalIndex[new] {
                view.setHighlighted(true)
            }
            updateDistances(animated: animated)

            let isFollowing = interactionState?.isFollowing ?? true
            if isFollowing, let new = originalIndex {
                if animated, window != nil {
                    advanceFollowing(toOriginalIndex: new)
                } else {
                    centerLine(originalIndex: new, animated: false)
                }
            }
        }

        /// Move to a newly highlighted line while following. A large jump (a seek)
        /// snaps instantly; every normal advance springs the clip toward the new
        /// anchor. Apple Music drives both through the same clip-bounds spring —
        /// rapid successive line changes stay continuous because the spring
        /// restarts from the current (presentation) position each time, so there
        /// is no separate "rapid" branch.
        private func advanceFollowing(toOriginalIndex originalIndex: Int) {
            guard let view = lineViewByOriginalIndex[originalIndex] else { return }
            let newPosition = view.enabledPosition
            let isJump = lastHighlightedPosition.map { abs(newPosition - $0) > scrollJumpThreshold } ?? true
            lastHighlightedPosition = newPosition
            centerLine(originalIndex: originalIndex, animated: !isJump)
        }

        private func updateDistances(animated: Bool) {
            let highlightedPosition = highlightedOriginalIndex.flatMap { lineViewByOriginalIndex[$0]?.enabledPosition }
            for view in enabledLineViews {
                let target: CGFloat
                let isSelected: Bool
                if let highlightedPosition {
                    let distance = abs(view.enabledPosition - highlightedPosition)
                    target = distance == 0 ? 1.0 : max(0.125, min(0.55 - CGFloat(distance) * 0.05, 0.55))
                    isSelected = distance == 0
                } else {
                    target = 0.55
                    isSelected = false
                }
                if animated {
                    view.animateAlpha(to: target, duration: 0.5)
                } else {
                    view.alphaValue = target
                }
                // Apple Music's per-line 0.98 deselected scale (selected line 1.0).
                view.setLineSelected(isSelected, animated: animated)
            }
        }

        // MARK: Scrolling

        private func centerLine(originalIndex: Int, animated: Bool) {
            guard let view = lineViewByOriginalIndex[originalIndex] else { return }
            anchorClip(toTopY: view.frame.minY, animated: animated)
        }

        private func centerOnInstrumentalDots(animated: Bool) {
            guard let instrumentalView else { return }
            anchorClip(toTopY: instrumentalView.frame.minY, animated: animated)
        }

        /// Scroll so `topY` (a line or indicator's TOP edge) sits `selectedLineTopInset`
        /// below the top of the viewport — Apple Music's `.top(12)` active-line anchor.
        private func anchorClip(toTopY topY: CGFloat, animated: Bool) {
            let targetY = clampedClipY(forTopY: topY)

            // A spring needs the display link to step it; if we're off-window it
            // is not running, so jump directly.
            if animated, window != nil {
                // New target → restart the spring from the current position with
                // zero velocity, exactly as Apple Music's CASpringAnimation does
                // (fromValue = presentation, default initialVelocity 0). Re-centering
                // to the same target (e.g. during an interlude hold, called every
                // frame) is a no-op so the spring is not perpetually reset.
                if scrollTargetY == nil || abs(scrollTargetY! - targetY) > 0.5 {
                    scrollTargetY = targetY
                    scrollVelocity = 0
                }
            } else {
                scrollTargetY = nil
                scrollVelocity = 0
                // Reset so a later spring's first frame uses the canonical dt
                // instead of the gap since this interrupted scroll.
                lastScrollTickTimestamp = 0
                setClipOrigin(targetY)
            }
        }

        private func setClipOrigin(_ originY: CGFloat) {
            let clipView = scrollView.contentView
            clipView.setBoundsOrigin(CGPoint(x: clipView.bounds.origin.x, y: originY))
            scrollView.reflectScrolledClipView(clipView)
        }

        private func clampedClipY(forTopY topY: CGFloat) -> CGFloat {
            let visibleHeight = scrollView.contentView.bounds.height
            let maxOriginY = max(0, documentView.frame.height - visibleHeight)
            return min(max(0, topY - selectedLineTopInset), maxOriginY)
        }

        // MARK: Auto-follow scroll spring

        /// Step the clip origin toward `scrollTargetY` one display-link frame with
        /// Apple Music's exact line-change spring (mass 1, stiffness 100, damping 18
        /// → damping ratio ζ = 0.9, settling ~0.6s). This springs the
        /// `scrollView.contentView` bounds, so the whole line stack moves together —
        /// precisely how Apple Music animates a line change: its `LayerPropertyAnimator`
        /// (`sub_100162B3C`) attaches a `CASpringAnimation` with these parameters to a
        /// layer whose model value (`sub_10015AF20`) is `contentView.bounds`. The
        /// integration is the closed-form underdamped solution, so the curve matches a
        /// real CASpringAnimation exactly and is unconditionally stable for any Δt.
        private func stepScrollSpring() {
            guard let targetY = scrollTargetY else { return }

            let timestamp = displayLink?.timestamp ?? lastScrollTickTimestamp
            var deltaTime = lastScrollTickTimestamp == 0 ? (1.0 / 60.0) : (timestamp - lastScrollTickTimestamp)
            lastScrollTickTimestamp = timestamp
            deltaTime = min(max(deltaTime, 1.0 / 240.0), 1.0 / 30.0)
            let step = CGFloat(deltaTime)

            let naturalFrequency = scrollSpringNaturalFrequency
            let dampingRatio = scrollSpringDampingRatio
            let dampedFrequency = naturalFrequency * sqrt(1 - dampingRatio * dampingRatio) // ω_d
            let decayRate = dampingRatio * naturalFrequency                                // σ = ζ·ωₙ

            let currentY = scrollView.contentView.bounds.origin.y
            let displacement = currentY - targetY    // y₀ (distance still to travel)
            let velocity = scrollVelocity             // v₀
            let decay = CGFloat(exp(Double(-decayRate * step)))
            let cosine = CGFloat(cos(Double(dampedFrequency * step)))
            let sine = CGFloat(sin(Double(dampedFrequency * step)))

            // Exact underdamped step:
            //   y(t) = e^{-σt}·[ y₀·cos(ω_d t) + ((v₀ + σ·y₀)/ω_d)·sin(ω_d t) ]
            //   v(t) = e^{-σt}·[ v₀·cos(ω_d t) − ((σ·v₀ + ωₙ²·y₀)/ω_d)·sin(ω_d t) ]
            let nextDisplacement = decay * (displacement * cosine
                + (velocity + decayRate * displacement) / dampedFrequency * sine)
            let nextVelocity = decay * (velocity * cosine
                - (decayRate * velocity + naturalFrequency * naturalFrequency * displacement) / dampedFrequency * sine)

            if abs(nextDisplacement) < 0.5, abs(nextVelocity) < 1.0 {
                scrollTargetY = nil
                scrollVelocity = 0
                lastScrollTickTimestamp = 0
                setClipOrigin(targetY)
            } else {
                scrollVelocity = nextVelocity
                setClipOrigin(targetY + nextDisplacement)
            }
        }

        @objc private func userWillScroll() {
            // The user took over — abandon the in-flight auto-scroll spring so it
            // does not keep moving content under the drag.
            scrollTargetY = nil
            scrollVelocity = 0
            lastScrollTickTimestamp = 0
            interactionState?.userDidScroll()
        }

        // MARK: Display Link (per-frame karaoke driver)

        private func startDisplayLink() {
            guard displayLink == nil else { return }
            let link = displayLink(target: self, selector: #selector(handleDisplayLink))
            // Apple Music drives its lyric animations at ProMotion rates
            // (`setPreferredFrameRateRange:` = CAFrameRateRange(80, 120, preferred 120)).
            // Match it so the spring scroll and per-syllable breathing are as smooth.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func handleDisplayLink() {
            stepScrollSpring()
            updateIntroDotsIfNeeded()
            updateInterludesIfNeeded()

            guard let lyrics,
                  let highlighted = highlightedOriginalIndex,
                  highlighted < lyrics.lines.count,
                  let view = lineViewByOriginalIndex[highlighted] else { return }
            let line = lyrics.lines[highlighted]
            let elapsed = selectedPlayer.playbackTime + lyrics.adjustedTimeDelay - line.position
            view.updateKaraoke(elapsedTime: elapsed, lineDuration: lineDuration(forOriginalIndex: highlighted), mode: karaokeMode)
        }

        private func updateIntroDotsIfNeeded() {
            guard let instrumentalView, let lyrics else { return }
            let currentTime = selectedPlayer.playbackTime + lyrics.adjustedTimeDelay
            if currentTime < introEndTime {
                let fraction = introEndTime > 0 ? CGFloat(currentTime / introEndTime) : 0
                instrumentalView.setProgress(fraction)
            } else {
                collapseIntroDots()
            }
        }

        private func updateInterludesIfNeeded() {
            guard !interludeSegments.isEmpty, let lyrics else { return }
            let currentTime = selectedPlayer.playbackTime + lyrics.adjustedTimeDelay
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
                anchorClip(toTopY: activeSegment.view.frame.minY, animated: true)
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
                    hasher.combine(line.attachments.translation() ?? "")
                }
                count = enabledCount
                contentHash = hasher.finalize()
            }
        }

        // MARK: - Flipped Document View

        private final class FlippedDocumentView: NSView {
            override var isFlipped: Bool { true }
        }
    }
}
