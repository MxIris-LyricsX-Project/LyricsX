import AppKit
import QuartzCore
import OSToolbox

extension AppleMusicLyrics {
    /// The cascade restored from the panel's earlier SwiftUI renderer
    /// (`LineCascadeVariant.legacySwiftUI`).
    struct LineCascadeConfiguration {
        let selectedLinePosition: Int
        let springTiming: SpringTimingParameters
        let settleDuration: TimeInterval
        let stagger: TimeInterval
        let aboveLineCount: Int
        let belowLineCount: Int
    }

    /// Apple Music 26.6's own line change (`LineCascadeVariant.appleMusic26`):
    /// one spring per row that crosses the viewport, with the curve selected for
    /// this transition. The leading two rows start together, followed by the
    /// remaining rows at `lineDelay` intervals.
    struct UniformLineCascadeConfiguration {
        let springTiming: SpringTimingParameters
        let lineDelay: TimeInterval
        /// Multiplies `lineDelay` when the lyrics move backwards, where the delays
        /// are also handed out from the bottom row up.
        let backwardLineDelayScale: Double
    }

    /// Coordinates both kinds of lyric movement without asking the display link
    /// to step either one.
    ///
    /// Direct manipulation and rapid changes move the clip on one render-server
    /// spring. A normal line advance runs a row cascade: the clip model snaps to
    /// its new anchor, the participating row layers receive the opposite
    /// presentation displacement, and those rows settle back with per-row delays.
    /// Their AppKit-owned model positions never change. Apple Music animates the
    /// row frames first and moves its clip in the completion instead; the two
    /// orders are visually identical, and this one keeps AppKit layout as the
    /// single owner of every model frame.
    @MainActor
    @Loggable(
        isEnabled: AppleMusicLyrics.PanelDiagnostics.isLyricsEnabled,
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics",
        category: "LineTransition"
    )
    @Signpostable(
        isEnabled: AppleMusicLyrics.PanelDiagnostics.isLyricsEnabled,
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics",
        category: "LineTransition"
    )
    final class LineTransitionCoordinator {
        static let clipBoundsAnimationKey = "AppleMusicLyrics.clipBounds"
        static let linePositionAnimationKey = "AppleMusicLyrics.lineCascadePosition"

        private var targetClipVerticalOrigin: CGFloat?
        private var animatedLineLayers: [CALayer] = []
        /// Fires once the last row spring of an Apple Music cascade has settled.
        /// Music keeps a matching `currentAnimators` set and refuses to select a
        /// new line while it is non-empty; `isCascadeInFlight` is that set.
        private var pendingCascadeSettlement: DispatchWorkItem?

        /// True from scheduling an Apple Music cascade until its slowest row has
        /// settled. The legacy cascade never sets it: it keeps its own rapid-change
        /// rule instead.
        var isCascadeInFlight: Bool {
            pendingCascadeSettlement != nil
        }

        func transitionClip(
            scrollView: NSScrollView,
            targetClipVerticalOrigin: CGFloat,
            timing: SpringTimingParameters,
            animated: Bool
        ) {
            let schedulingInterval = #signpost(
                .begin,
                "ClipTransitionSchedule",
                "animated=\(animated, privacy: .public) targetVerticalOrigin=\(targetClipVerticalOrigin, privacy: .public)"
            )
            defer { #signpost(.end, schedulingInterval) }
            let clipView = scrollView.contentView
            guard animated, let clipLayer = clipView.layer else {
                #log(
                    .info,
                    """
                    Clip transition snapped animated=\(animated, privacy: .public) \
                    targetVerticalOrigin=\(targetClipVerticalOrigin, privacy: .public)
                    """
                )
                cancel(scrollView: scrollView)
                setClipOrigin(targetClipVerticalOrigin, scrollView: scrollView)
                return
            }

            if self.targetClipVerticalOrigin.map({ abs($0 - targetClipVerticalOrigin) <= 0.5 }) == true,
               clipLayer.animation(forKey: Self.clipBoundsAnimationKey) != nil {
                return
            }
            // Already resting on the target: nothing to move. The interlude dots
            // re-anchor the clip on every display-link frame, and once the spring
            // had settled each of those calls used to cancel the row animations
            // and run `setBoundsOrigin` + `reflectScrolledClipView` again.
            if clipLayer.animation(forKey: Self.clipBoundsAnimationKey) == nil,
               abs(clipView.bounds.origin.y - targetClipVerticalOrigin) <= 0.5 {
                return
            }

            let visibleClipVerticalOrigin = (clipLayer.presentation() ?? clipLayer).bounds.origin.y
            let displacement = targetClipVerticalOrigin - visibleClipVerticalOrigin
            removeLineAnimations()
            self.targetClipVerticalOrigin = targetClipVerticalOrigin

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setClipOrigin(targetClipVerticalOrigin, scrollView: scrollView)
            CATransaction.commit()

            guard abs(visibleClipVerticalOrigin - targetClipVerticalOrigin) > 0.5 else {
                #log(
                    .debug,
                    "Clip transition skipped displacement=\(displacement, privacy: .public)"
                )
                clipLayer.removeAnimation(forKey: Self.clipBoundsAnimationKey)
                return
            }

            let animation = timing.makeAnimation(keyPath: "bounds.origin.y")
            animation.fromValue = visibleClipVerticalOrigin
            animation.toValue = targetClipVerticalOrigin
            animation.isRemovedOnCompletion = true
            animation.preferredFrameRateRange = LyricsSpecs.preferredFrameRateRange
            clipLayer.add(animation, forKey: Self.clipBoundsAnimationKey)
            #log(
                .info,
                """
                Clip transition scheduled displacement=\(displacement, privacy: .public) \
                settlingDuration=\(animation.settlingDuration, privacy: .public)
                """
            )
        }

        func transitionLines(
            scrollView: NSScrollView,
            lineViews: [SyncedLyricsLineView],
            targetClipVerticalOrigin: CGFloat,
            configuration: LineCascadeConfiguration,
            animated: Bool
        ) {
            let schedulingInterval = #signpost(
                .begin,
                "LineCascadeSchedule",
                "animated=\(animated, privacy: .public) selectedLinePosition=\(configuration.selectedLinePosition, privacy: .public)"
            )
            defer { #signpost(.end, schedulingInterval) }
            let clipView = scrollView.contentView
            guard animated, let clipLayer = clipView.layer else {
                #log(
                    .info,
                    """
                    Line cascade snapped animated=\(animated, privacy: .public) \
                    selectedLinePosition=\(configuration.selectedLinePosition, privacy: .public)
                    """
                )
                cancel(scrollView: scrollView)
                setClipOrigin(targetClipVerticalOrigin, scrollView: scrollView)
                return
            }

            let (aboveLineViews, springingLineViews) = lineGroups(
                from: lineViews,
                configuration: configuration
            )
            let transitioningLineViews = aboveLineViews + springingLineViews
            let visibleLineVerticalPositions = visibleVerticalPositions(for: transitioningLineViews)
            let visibleClipVerticalOrigin = (clipLayer.presentation() ?? clipLayer).bounds.origin.y
            let compensatingDisplacement = targetClipVerticalOrigin - visibleClipVerticalOrigin

            self.targetClipVerticalOrigin = nil
            clipLayer.removeAnimation(forKey: Self.clipBoundsAnimationKey)
            removeLineAnimations()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setClipOrigin(targetClipVerticalOrigin, scrollView: scrollView)

            guard abs(compensatingDisplacement) > 0.5 else {
                CATransaction.commit()
                #log(
                    .debug,
                    "Line cascade skipped displacement=\(compensatingDisplacement, privacy: .public)"
                )
                return
            }

            addSettlingAnimations(
                to: aboveLineViews,
                visibleVerticalPositions: visibleLineVerticalPositions,
                compensatingDisplacement: compensatingDisplacement,
                duration: configuration.settleDuration
            )
            addSpringAnimations(
                to: springingLineViews,
                visibleVerticalPositions: visibleLineVerticalPositions,
                compensatingDisplacement: compensatingDisplacement,
                configuration: configuration
            )
            CATransaction.commit()

            animatedLineLayers = transitioningLineViews.compactMap(\.layer)
            #log(
                .info,
                """
                Line cascade scheduled variant=legacySwiftUI \
                displacement=\(compensatingDisplacement, privacy: .public) \
                aboveLineCount=\(aboveLineViews.count, privacy: .public) \
                springingLineCount=\(springingLineViews.count, privacy: .public) \
                settleDuration=\(configuration.settleDuration, privacy: .public) \
                stagger=\(configuration.stagger, privacy: .public)
                """
            )
        }

        /// Apple Music 26.6's line change. `sub_1001DCBD4` builds one
        /// `AnimationDescriptor` per visible row, all on the selected line-change
        /// spring, delayed by `lineDelay × max(rowIndex - 1, 0)` from the top
        /// (from the bottom, at half the delay, when moving backwards), and only
        /// commits the new clip offset once the last row has settled. The rows
        /// considered are every row that crosses either the old or the new
        /// viewport, so a row sliding in from the bottom edge arrives on the same
        /// wave instead of appearing at rest.
        ///
        /// `onSettled` runs once the slowest row has come to rest, which is when
        /// Music would let the manager select the next line again.
        func transitionVisibleLines(
            scrollView: NSScrollView,
            lineViews: [SyncedLyricsLineView],
            targetClipVerticalOrigin: CGFloat,
            configuration: UniformLineCascadeConfiguration,
            animated: Bool,
            onSettled: @escaping () -> Void
        ) {
            let schedulingInterval = #signpost(
                .begin,
                "UniformLineCascadeSchedule",
                "animated=\(animated, privacy: .public) targetVerticalOrigin=\(targetClipVerticalOrigin, privacy: .public)"
            )
            defer { #signpost(.end, schedulingInterval) }
            let clipView = scrollView.contentView
            guard animated, let clipLayer = clipView.layer else {
                #log(
                    .info,
                    """
                    Uniform line cascade snapped animated=\(animated, privacy: .public) \
                    targetVerticalOrigin=\(targetClipVerticalOrigin, privacy: .public)
                    """
                )
                cancel(scrollView: scrollView)
                setClipOrigin(targetClipVerticalOrigin, scrollView: scrollView)
                return
            }

            let visibleClipVerticalOrigin = (clipLayer.presentation() ?? clipLayer).bounds.origin.y
            let compensatingDisplacement = targetClipVerticalOrigin - visibleClipVerticalOrigin
            let viewportSize = clipView.bounds.size
            let previousViewport = CGRect(
                origin: CGPoint(x: clipView.bounds.origin.x, y: visibleClipVerticalOrigin),
                size: viewportSize
            )
            let targetViewport = CGRect(
                origin: CGPoint(x: clipView.bounds.origin.x, y: targetClipVerticalOrigin),
                size: viewportSize
            )
            let travelledViewport = previousViewport.union(targetViewport)
            let participatingLineViews = lineViews
                .filter { $0.frame.intersects(travelledViewport) }
                .sorted { $0.frame.minY < $1.frame.minY }
            let visibleLineVerticalPositions = visibleVerticalPositions(for: participatingLineViews)

            self.targetClipVerticalOrigin = nil
            clipLayer.removeAnimation(forKey: Self.clipBoundsAnimationKey)
            removeLineAnimations()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setClipOrigin(targetClipVerticalOrigin, scrollView: scrollView)

            guard abs(compensatingDisplacement) > 0.5 else {
                CATransaction.commit()
                #log(
                    .debug,
                    "Uniform line cascade skipped displacement=\(compensatingDisplacement, privacy: .public)"
                )
                return
            }

            let movesForward = compensatingDisplacement > 0
            let lineDelay = movesForward
                ? configuration.lineDelay
                : configuration.lineDelay * configuration.backwardLineDelayScale
            let lastLineOffset = participatingLineViews.count - 1
            let currentMediaTime = CACurrentMediaTime()
            var settlingDelay: TimeInterval = 0
            for (lineOffset, lineView) in participatingLineViews.enumerated() {
                guard let lineLayer = lineView.layer,
                      let visibleLineVerticalPosition = visibleLineVerticalPositions[ObjectIdentifier(lineLayer)]
                else {
                    continue
                }
                let delayIndex = movesForward ? lineOffset : lastLineOffset - lineOffset
                let animationDelay = lineDelay * TimeInterval(max(0, delayIndex - 1))
                let animation = configuration.springTiming.makeAnimation(keyPath: "position.y")
                // Music offsets the first target frame, then lays subsequent
                // frames out below it. Compensating each start is equivalent
                // with our clip already at its destination; do not offset the
                // first row a second time.
                animation.fromValue = visibleLineVerticalPosition + compensatingDisplacement
                animation.toValue = lineLayer.position.y
                animation.beginTime = lineLayer.convertTime(currentMediaTime, from: nil)
                    + animationDelay
                configureLineAnimation(animation)
                lineLayer.add(animation, forKey: Self.linePositionAnimationKey)
                settlingDelay = max(settlingDelay, animationDelay + animation.duration)
            }
            CATransaction.commit()

            animatedLineLayers = participatingLineViews.compactMap(\.layer)
            let settlement = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingCascadeSettlement = nil
                self.animatedLineLayers.removeAll(keepingCapacity: true)
                #log(.info, "Uniform line cascade settled")
                #signpost(.event, "UniformLineCascadeSettled")
                onSettled()
            }
            pendingCascadeSettlement = settlement
            DispatchQueue.main.asyncAfter(deadline: .now() + settlingDelay, execute: settlement)
            #log(
                .info,
                """
                Line cascade scheduled variant=appleMusic26 \
                displacement=\(compensatingDisplacement, privacy: .public) \
                lineCount=\(participatingLineViews.count, privacy: .public) \
                lineDelay=\(lineDelay, privacy: .public) \
                settlingDelay=\(settlingDelay, privacy: .public)
                """
            )
        }

        private func lineGroups(
            from lineViews: [SyncedLyricsLineView],
            configuration: LineCascadeConfiguration
        ) -> (above: [SyncedLyricsLineView], springing: [SyncedLyricsLineView]) {
            let aboveLineViews = Array(lineViews
                .filter { $0.enabledPosition < configuration.selectedLinePosition }
                .suffix(max(0, configuration.aboveLineCount)))
            let springingLineViews = Array(lineViews
                .filter { $0.enabledPosition >= configuration.selectedLinePosition }
                .prefix(max(0, configuration.belowLineCount)))
            return (aboveLineViews, springingLineViews)
        }

        private func visibleVerticalPositions(
            for lineViews: [SyncedLyricsLineView]
        ) -> [ObjectIdentifier: CGFloat] {
            lineViews.reduce(into: [ObjectIdentifier: CGFloat]()) { positions, lineView in
                guard let lineLayer = lineView.layer else { return }
                positions[ObjectIdentifier(lineLayer)] = (lineLayer.presentation() ?? lineLayer).position.y
            }
        }

        private func addSettlingAnimations(
            to lineViews: [SyncedLyricsLineView],
            visibleVerticalPositions: [ObjectIdentifier: CGFloat],
            compensatingDisplacement: CGFloat,
            duration: TimeInterval
        ) {
            for lineView in lineViews {
                guard let lineLayer = lineView.layer,
                      let visibleLineVerticalPosition = visibleVerticalPositions[ObjectIdentifier(lineLayer)]
                else {
                    continue
                }
                let animation = CABasicAnimation(keyPath: "position.y")
                animation.fromValue = visibleLineVerticalPosition + compensatingDisplacement
                animation.toValue = lineLayer.position.y
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                configureLineAnimation(animation)
                lineLayer.add(animation, forKey: Self.linePositionAnimationKey)
            }
        }

        private func addSpringAnimations(
            to lineViews: [SyncedLyricsLineView],
            visibleVerticalPositions: [ObjectIdentifier: CGFloat],
            compensatingDisplacement: CGFloat,
            configuration: LineCascadeConfiguration
        ) {
            let currentMediaTime = CACurrentMediaTime()
            for (lineOffset, lineView) in lineViews.enumerated() {
                guard let lineLayer = lineView.layer,
                      let visibleLineVerticalPosition = visibleVerticalPositions[ObjectIdentifier(lineLayer)]
                else {
                    continue
                }
                let animation = configuration.springTiming.makeAnimation(keyPath: "position.y")
                animation.fromValue = visibleLineVerticalPosition + compensatingDisplacement
                animation.toValue = lineLayer.position.y
                animation.beginTime = lineLayer.convertTime(currentMediaTime, from: nil)
                    + configuration.stagger * TimeInterval(lineOffset + 2)
                configureLineAnimation(animation)
                lineLayer.add(animation, forKey: Self.linePositionAnimationKey)
            }
        }

        private func configureLineAnimation(_ animation: CAPropertyAnimation) {
            animation.fillMode = .both
            animation.isRemovedOnCompletion = true
            animation.preferredFrameRateRange = LyricsSpecs.preferredFrameRateRange
        }

        /// Stops presentation-only motion and commits the currently visible clip
        /// origin so direct manipulation starts without a jump.
        func cancel(scrollView: NSScrollView) {
            let cancelledLineAnimationCount = animatedLineLayers.count
            removeLineAnimations()
            targetClipVerticalOrigin = nil
            let clipView = scrollView.contentView
            guard let clipLayer = clipView.layer,
                  clipLayer.animation(forKey: Self.clipBoundsAnimationKey) != nil else {
                return
            }
            let visibleClipVerticalOrigin = (clipLayer.presentation() ?? clipLayer).bounds.origin.y
            clipLayer.removeAnimation(forKey: Self.clipBoundsAnimationKey)
            setClipOrigin(visibleClipVerticalOrigin, scrollView: scrollView)
            #log(
                .info,
                """
                Line transition cancelled lineAnimationCount=\(cancelledLineAnimationCount, privacy: .public) \
                visibleClipVerticalOrigin=\(visibleClipVerticalOrigin, privacy: .public)
                """
            )
            #signpost(
                .event,
                "LineTransitionCancelled",
                "lineAnimationCount=\(cancelledLineAnimationCount, privacy: .public)"
            )
        }

        private func removeLineAnimations() {
            pendingCascadeSettlement?.cancel()
            pendingCascadeSettlement = nil
            for lineLayer in animatedLineLayers {
                lineLayer.removeAnimation(forKey: Self.linePositionAnimationKey)
            }
            animatedLineLayers.removeAll(keepingCapacity: true)
        }

        private func setClipOrigin(_ verticalOrigin: CGFloat, scrollView: NSScrollView) {
            let clipView = scrollView.contentView
            clipView.setBoundsOrigin(CGPoint(x: clipView.bounds.origin.x, y: verticalOrigin))
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}
