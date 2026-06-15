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

        // Spring-driven auto-scroll (replaces ease-in-out), stepped by the
        // display link. Values mirror the previous SwiftUI cascade animation.
        private var scrollTargetY: CGFloat?
        private var scrollVelocity: CGFloat = 0
        private var lastScrollTickTimestamp: CFTimeInterval = 0
        // Apple Music's line-change spring (mass 1, damping ratio 0.9), applied to
        // the whole scroll so all lines move together.
        private let scrollSpringStiffness: CGFloat = 100
        private let scrollSpringDamping: CGFloat = 18

        // Per-line "cascade" on a normal line advance — the Apple Music signature:
        // the scroll jumps instantly to center the new line while every nearby
        // line is displaced so it appears stationary, then each line springs back
        // to its laid-out position. Lines below the new line settle with a
        // staggered bouncy spring (the visible cascade wave); lines above settle
        // smoothly. A single rigid scroll spring (what the rewrite shipped) only
        // overshoots ~4% and reads as a plain ease — the bounce lives in the
        // staggered per-line springs. Ports the previous SwiftUI cascade.
        private struct LineCascade {
            let view: SyncedLyricsLineView
            var displacement: CGFloat
            var velocity: CGFloat
            var delayRemaining: CFTimeInterval
            let stiffness: CGFloat
            let damping: CGFloat
        }
        private var lineCascades: [LineCascade] = []
        private var lastCascadeTickTimestamp: CFTimeInterval = 0
        private var lastHighlightedPosition: Int?
        private var lastHighlightChangeTime: CFTimeInterval = 0
        // Reverse-engineered from Apple Music 26.5.1 (`LyricsSpecs` in Music.i64):
        // the line-change move is ONE spring (mass 1, stiffness 100, damping 18 →
        // damping ratio 0.9, smooth, almost no overshoot), staggered per line by
        // `lineDelay` × its distance from the active line. Critically the active
        // line and its nearest neighbour start with ZERO delay; only lines further
        // out wait. The previous values (a bouncier, slower hand-tuned spring with
        // an inflated `delay = stagger × (order + 2)`) froze the active line ~0.16s
        // before it moved and over-ran into the next line — that was the "reaches a
        // point then snaps back" artifact.
        private let cascadeSpringStiffness: CGFloat = 100   // lineChangeSpringTimingParametersValues.stiffness
        private let cascadeSpringDamping: CGFloat = 18      // …damping (mass = 1)
        private let lineDelay: CFTimeInterval = 0.05        // LyricsSpecs.lineDelay
        private let cascadeWindow = 8                       // displace lines within this distance of the active line
        private let cascadeJumpThreshold = 5
        private let cascadeRapidThreshold: CFTimeInterval = 0.4
        // Apple Music anchors the active line in the upper third (its `.top`-style
        // selectedLinePosition) — NOT centered, so more upcoming lines show below
        // it. Measured by tracking the active line's brightness centroid across
        // three line changes in a 26.5.1 capture: it settles at ~0.343–0.359 of
        // the viewport from the top (average ≈0.35), springing up monotonically
        // from below over ~0.6s with no overshoot (the ζ≈0.9 line-move spring).
        private let activeLineAnchorFraction: CGFloat = 0.35

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
            lineCascades.removeAll()
            lastCascadeTickTimestamp = 0
            lastHighlightedPosition = nil
            lastHighlightChangeTime = 0
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

            // Frames are being reset to their laid-out positions; abandon any
            // in-flight cascade (its displacements would fight these frames).
            lineCascades.removeAll()
            lastCascadeTickTimestamp = 0

            // Top/bottom padding match the active-line anchor, so the first line
            // can rest at the anchor (clip pinned to 0) and the last line can too.
            let topInset = clipHeight * activeLineAnchorFraction
            var cursorY = topInset
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
                view.cascadeBaselineY = cursorY
                cursorY += height
                if let interludeView = interludeByPosition[position] {
                    let dotsHeight = interludeView.preferredHeight
                    interludeView.frame = NSRect(x: 0, y: cursorY, width: width, height: dotsHeight)
                    cursorY += dotsHeight
                }
            }
            let totalHeight = cursorY + clipHeight * (1 - activeLineAnchorFraction)
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
                    clearLineCascades()
                    centerLine(originalIndex: new, animated: false)
                }
            }
        }

        /// Decide how to move to a newly highlighted line while following: a large
        /// gap jumps instantly, a rapid succession does a plain smooth scroll, and
        /// a normal single step runs the per-line cascade. Mirrors the previous
        /// SwiftUI `scrollToHighlighted` jump / rapid / cascade branching.
        private func advanceFollowing(toOriginalIndex originalIndex: Int) {
            guard let view = lineViewByOriginalIndex[originalIndex] else { return }
            let now = CACurrentMediaTime()
            let newPosition = view.enabledPosition
            let timeSinceLast = lastHighlightChangeTime == 0 ? .greatestFiniteMagnitude : now - lastHighlightChangeTime
            let isJump = lastHighlightedPosition.map { abs(newPosition - $0) > cascadeJumpThreshold } ?? true
            let isRapid = !isJump && timeSinceLast < cascadeRapidThreshold
            lastHighlightChangeTime = now
            lastHighlightedPosition = newPosition

            if isJump {
                clearLineCascades()
                centerLine(originalIndex: originalIndex, animated: false)
            } else if isRapid {
                clearLineCascades()
                centerLine(originalIndex: originalIndex, animated: true)
            } else {
                cascadeToLine(originalIndex: originalIndex)
            }
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
            centerOn(midY: view.frame.midY, animated: animated)
        }

        private func centerOnInstrumentalDots(animated: Bool) {
            guard let instrumentalView else { return }
            centerOn(midY: instrumentalView.frame.midY, animated: animated)
        }

        private func centerOn(midY: CGFloat, animated: Bool) {
            let targetY = clampedClipY(forMidY: midY)

            // A spring needs the display link to step it; if we're off-window it
            // is not running, so jump directly.
            if animated, window != nil {
                scrollTargetY = targetY // keep current velocity for continuity across rapid line changes
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

        private func clampedClipY(forMidY midY: CGFloat) -> CGFloat {
            let visibleHeight = scrollView.contentView.bounds.height
            let maxOriginY = max(0, documentView.frame.height - visibleHeight)
            return min(max(0, midY - visibleHeight * activeLineAnchorFraction), maxOriginY)
        }

        // MARK: Line-switch cascade

        /// Jump the scroll instantly to center the new line, displace every nearby
        /// line so it appears stationary, then hand each line to the cascade
        /// stepper to spring back to its baseline (below = staggered bounce,
        /// above = smooth settle).
        private func cascadeToLine(originalIndex: Int) {
            guard let target = lineViewByOriginalIndex[originalIndex] else { return }
            scrollTargetY = nil
            scrollVelocity = 0

            // Center on the target's LAID-OUT position (ignore any displacement it
            // may still carry from an in-flight cascade) so the clip math is stable.
            let oldClipY = scrollView.contentView.bounds.origin.y
            let targetBaselineMidY = target.cascadeBaselineY + target.frame.height / 2
            let newClipY = clampedClipY(forMidY: targetBaselineMidY)
            setClipOrigin(newClipY)
            let clipDelta = newClipY - oldClipY

            // Carry over in-flight spring velocity so an interrupted cascade keeps
            // its momentum and stays visually continuous through the clip jump,
            // instead of being snapped back to baseline. The previous code cleared
            // (snapped) the prior cascade here — that was the "reaches a point then
            // retracts" jump the user saw whenever lines changed faster than a
            // cascade settles (the common case during playback).
            var velocityByView: [ObjectIdentifier: CGFloat] = [:]
            for cascade in lineCascades {
                velocityByView[ObjectIdentifier(cascade.view)] = cascade.velocity
            }

            let highlightedPosition = target.enabledPosition
            var rebuilt: [LineCascade] = []
            for view in enabledLineViews {
                let order = abs(view.enabledPosition - highlightedPosition)
                let identifier = ObjectIdentifier(view)
                let isInFlight = velocityByView[identifier] != nil
                let velocity = velocityByView[identifier] ?? 0
                // Continuity: add the clip jump to the line's CURRENT displacement
                // so it holds still through the jump, then springs to baseline.
                let currentDisplacement = view.frame.origin.y - view.cascadeBaselineY
                let displacement = currentDisplacement + clipDelta

                guard order <= cascadeWindow else {
                    // Outside the cascade window: settle any leftover displacement
                    // with no extra stagger; otherwise leave it at baseline.
                    if abs(displacement) > 0.5 {
                        view.applyCascadeDisplacement(displacement)
                        rebuilt.append(LineCascade(view: view, displacement: displacement, velocity: velocity, delayRemaining: 0, stiffness: cascadeSpringStiffness, damping: cascadeSpringDamping))
                    } else {
                        view.applyCascadeDisplacement(0)
                    }
                    continue
                }

                if abs(displacement) <= 0.5, !isInFlight {
                    view.applyCascadeDisplacement(0)
                    continue
                }

                // delay = lineDelay × (max(order, 1) − 1): the active line and its
                // nearest neighbour start immediately, each further ring waits one
                // more `lineDelay` (Apple Music's exact per-line formula). Lines
                // already in flight keep moving — they aren't re-delayed.
                let delay = isInFlight ? 0 : lineDelay * CFTimeInterval(max(order, 1) - 1)
                view.applyCascadeDisplacement(displacement)
                rebuilt.append(LineCascade(view: view, displacement: displacement, velocity: velocity, delayRemaining: delay, stiffness: cascadeSpringStiffness, damping: cascadeSpringDamping))
            }
            lineCascades = rebuilt
            lastCascadeTickTimestamp = 0
        }

        private func clearLineCascades() {
            guard !lineCascades.isEmpty else { return }
            for cascade in lineCascades {
                cascade.view.applyCascadeDisplacement(0)
            }
            lineCascades.removeAll()
            lastCascadeTickTimestamp = 0
        }

        /// Step every active per-line cascade spring one frame toward its baseline.
        private func stepLineCascades() {
            guard !lineCascades.isEmpty else { return }

            let timestamp = displayLink?.timestamp ?? lastCascadeTickTimestamp
            var deltaTime = lastCascadeTickTimestamp == 0 ? (1.0 / 60.0) : (timestamp - lastCascadeTickTimestamp)
            lastCascadeTickTimestamp = timestamp
            deltaTime = min(max(deltaTime, 1.0 / 240.0), 1.0 / 30.0)
            let step = CGFloat(deltaTime)

            var stillActive: [LineCascade] = []
            stillActive.reserveCapacity(lineCascades.count)
            for var cascade in lineCascades {
                if cascade.delayRemaining > 0 {
                    cascade.delayRemaining -= deltaTime
                    stillActive.append(cascade)
                    continue
                }
                let acceleration = -cascade.stiffness * cascade.displacement - cascade.damping * cascade.velocity
                cascade.velocity += acceleration * step
                cascade.displacement += cascade.velocity * step
                if abs(cascade.displacement) < 0.5, abs(cascade.velocity) < 1.0 {
                    cascade.view.applyCascadeDisplacement(0)
                } else {
                    cascade.view.applyCascadeDisplacement(cascade.displacement)
                    stillActive.append(cascade)
                }
            }
            lineCascades = stillActive
            if lineCascades.isEmpty {
                lastCascadeTickTimestamp = 0
            }
        }

        /// Spring step of the whole scroll toward `scrollTargetY`, driven by the
        /// display link — this moves every line together (Apple Music's unified
        /// line-change motion). Uses Apple Music's exact line-change spring
        /// (`lineChangeSpringTimingParametersValues`): mass 1, stiffness 100,
        /// damping 18 (damping ratio 0.9, settling ~0.6s).
        private func stepScrollSpring() {
            guard let targetY = scrollTargetY else { return }

            let timestamp = displayLink?.timestamp ?? lastScrollTickTimestamp
            var deltaTime = lastScrollTickTimestamp == 0 ? (1.0 / 60.0) : (timestamp - lastScrollTickTimestamp)
            lastScrollTickTimestamp = timestamp
            deltaTime = min(max(deltaTime, 1.0 / 240.0), 1.0 / 30.0)

            let stiffness = scrollSpringStiffness
            let damping = scrollSpringDamping

            let currentY = scrollView.contentView.bounds.origin.y
            let displacement = currentY - targetY
            let acceleration = -stiffness * displacement - damping * scrollVelocity
            scrollVelocity += acceleration * deltaTime
            let nextY = currentY + scrollVelocity * deltaTime

            if abs(nextY - targetY) < 0.5, abs(scrollVelocity) < 1.0 {
                scrollTargetY = nil
                scrollVelocity = 0
                lastScrollTickTimestamp = 0
                setClipOrigin(targetY)
            } else {
                setClipOrigin(nextY)
            }
        }

        @objc private func userWillScroll() {
            // The user took over — abandon any in-flight auto-scroll spring and
            // line cascade so neither keeps moving content under the drag.
            scrollTargetY = nil
            scrollVelocity = 0
            lastScrollTickTimestamp = 0
            clearLineCascades()
            interactionState?.userDidScroll()
        }

        // MARK: Display Link (per-frame karaoke driver)

        private func startDisplayLink() {
            guard displayLink == nil else { return }
            let link = displayLink(target: self, selector: #selector(handleDisplayLink))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func handleDisplayLink() {
            stepScrollSpring()
            stepLineCascades()
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
                centerOn(midY: activeSegment.view.frame.midY, animated: true)
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
