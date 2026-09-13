import AppKit
import LyricsXFoundation
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

@Suite(.serialized)
@MainActor
struct LineTransitionProbes {
    private static let selectedLineBaselineViewportFraction: CGFloat = 0.4

    private static func makeLyrics() -> Lyrics? {
        let body = (0 ..< 12)
            .map { lineIndex in String(format: "[00:%05.2f]probe line number %d", Double(lineIndex) * 4, lineIndex) }
            .joined(separator: "\n")
        return Lyrics(body)
    }

    private static func makeMountedContainer(
        variant: AppleMusicLyrics.LineCascadeVariant
    ) -> (AppleMusicLyrics.SyncedLyricsContainerView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        let container = AppleMusicLyrics.SyncedLyricsContainerView(frame: frame)
        container.setLineCascadeVariantProvider { variant }
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        return (container, window)
    }

    private static func scrollView(of container: AppleMusicLyrics.SyncedLyricsContainerView) throws -> NSScrollView {
        try #require(
            container.subviews.compactMap { $0 as? NSScrollView }.first,
            "the container is expected to hold a scroll view"
        )
    }

    private static func lineViews(in scrollView: NSScrollView) -> [AppleMusicLyrics.SyncedLyricsLineView] {
        scrollView.documentView?.subviews.compactMap { $0 as? AppleMusicLyrics.SyncedLyricsLineView } ?? []
    }

    private static func highlightedOriginalIndex(in scrollView: NSScrollView) -> Int? {
        lineViews(in: scrollView).first { $0.isHighlighted }?.originalIndex
    }

    private static func advanceHighlight(
        _ container: AppleMusicLyrics.SyncedLyricsContainerView,
        lyrics: Lyrics,
        through originalIndices: [Int]
    ) {
        for originalIndex in originalIndices {
            container.update(
                lyrics: lyrics,
                highlightedLineIndex: originalIndex,
                mainFontSize: 30,
                translationFontSize: 16
            )
            container.layoutSubtreeIfNeeded()
        }
    }

    private static func clipBoundsSprings(in scrollView: NSScrollView) -> [CASpringAnimation] {
        guard let clipLayer = scrollView.contentView.layer else { return [] }
        return clipLayer.animationKeys()?.compactMap { animationKey in
            clipLayer.animation(forKey: animationKey) as? CASpringAnimation
        }.filter { animation in
            animation.keyPath == "bounds.origin.y"
        } ?? []
    }

    private static func linePositionSprings(in scrollView: NSScrollView) -> [CASpringAnimation] {
        lineViews(in: scrollView).reduce(into: [CASpringAnimation]()) { animations, lineView in
            guard let lineLayer = lineView.layer else { return }
            let lineAnimations = lineLayer.animationKeys()?.compactMap { animationKey in
                lineLayer.animation(forKey: animationKey) as? CASpringAnimation
            }.filter { animation in
                animation.keyPath == "position.y"
            } ?? []
            animations.append(contentsOf: lineAnimations)
        }
    }

    /// Every row spring keyed by the row it moves, ordered top to bottom.
    private static func linePositionSpringsByRow(
        in scrollView: NSScrollView
    ) -> [(lineView: AppleMusicLyrics.SyncedLyricsLineView, spring: CASpringAnimation)] {
        lineViews(in: scrollView)
            .sorted { $0.frame.minY < $1.frame.minY }
            .compactMap { lineView in
                guard let lineLayer = lineView.layer,
                      let spring = lineLayer.animationKeys()?.lazy.compactMap({ animationKey in
                          lineLayer.animation(forKey: animationKey) as? CASpringAnimation
                      }).first(where: { $0.keyPath == "position.y" })
                else {
                    return nil
                }
                return (lineView, spring)
            }
    }

    private static func linePositionAnimationCount(in scrollView: NSScrollView) -> Int {
        lineViews(in: scrollView).reduce(0) { animationCount, lineView in
            guard let lineLayer = lineView.layer else {
                return animationCount
            }
            let positionAnimationCount = lineLayer.animationKeys()?.reduce(0) { currentCount, animationKey in
                guard let animation = lineLayer.animation(forKey: animationKey) as? CAPropertyAnimation,
                      animation.keyPath == "position.y" else {
                    return currentCount
                }
                return currentCount + 1
            } ?? 0
            return animationCount + positionAnimationCount
        }
    }

    private static func expectAppleMusicLineChangeSpring(_ spring: CASpringAnimation) {
        #expect(abs(Double(spring.mass) - 1) < 0.001)
        #expect(abs(Double(spring.stiffness) - 100) < 0.001)
        #expect(abs(Double(spring.damping) - 18) < 0.001)
        #expect(spring.fillMode == .both)
    }

    // MARK: Apple Music 26.6 cascade

    @Test(arguments: [
        (gap: -0.25, stiffness: 171.3472986300236, damping: 23.56194490192345),
        (gap: 0.2, stiffness: 171.3472986300236, damping: 23.56194490192345),
        (gap: 0.5, stiffness: 100.33372253995483, damping: 16.718736556495248),
        (gap: 0.75, stiffness: 70.18385351885765, damping: 13.069025438933538),
        (gap: 2.0, stiffness: 70.18385351885765, damping: 13.069025438933538),
    ])
    func appleMusicWordTimedCascadeUsesTheGapAfterThePreviousSungLine(
        sample: (gap: TimeInterval, stiffness: Double, damping: Double)
    ) throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        for originalIndex in lyrics.lines.indices {
            lyrics.lines[originalIndex].attachments.timetag = .init(
                tags: [.init(index: 0, time: 0), .init(index: 6, time: 0.5)],
                duration: 4 - sample.gap
            )
        }
        let (container, window) = Self.makeMountedContainer(variant: .appleMusic26)
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3])

        let scrollView = try Self.scrollView(of: container)
        let springs = Self.linePositionSprings(in: scrollView)
        #expect(!springs.isEmpty)
        // Independent coefficients recovered from Music 26.6's timedWords path.
        for spring in springs {
            #expect(abs(Double(spring.mass) - 1) < 0.001)
            #expect(abs(Double(spring.stiffness) - sample.stiffness) < 0.001)
            #expect(abs(Double(spring.damping) - sample.damping) < 0.001)
        }
    }

    @Test func appleMusicCascadePrefersTheStructuredSungEndOverTheInlineFallback() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        lyrics.lines[2].attachments.synchronizedTextTiming = .init(
            words: [.init(characterRange: 0 ..< 5, timeRange: 0 ..< 3.25)],
            duration: 3.25
        )
        lyrics.lines[2].attachments.timetag = .init(
            tags: [.init(index: 0, time: 0)],
            duration: 3.8
        )
        let (container, window) = Self.makeMountedContainer(variant: .appleMusic26)
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3])

        let spring = try #require(Self.linePositionSprings(in: Self.scrollView(of: container)).first)
        #expect(abs(Double(spring.stiffness) - 70.18385351885765) < 0.001)
        #expect(abs(Double(spring.damping) - 13.069025438933538) < 0.001)
    }

    @Test(arguments: [true, false])
    func appleMusicCascadeKeepsTheFallbackWhenWordTimingOrTheSungEndIsMissing(hasWordTiming: Bool) throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        lyrics.lines[2].attachments.timetag = .init(
            tags: hasWordTiming ? [.init(index: 0, time: 0)] : [],
            duration: hasWordTiming ? nil : 3.25
        )
        let (container, window) = Self.makeMountedContainer(variant: .appleMusic26)
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3])

        let spring = try #require(Self.linePositionSprings(in: Self.scrollView(of: container)).first)
        Self.expectAppleMusicLineChangeSpring(spring)
    }

    @Test func appleMusicWordTimedCatchUpUsesTheLastDisplayedLineRatherThanASkippedLine() async throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        for originalIndex in lyrics.lines.indices {
            lyrics.lines[originalIndex].attachments.timetag = .init(
                tags: [.init(index: 0, time: 0)],
                duration: 3.8
            )
        }
        let (container, window) = Self.makeMountedContainer(variant: .appleMusic26)
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3])
        let scrollView = try Self.scrollView(of: container)
        let springs = Self.linePositionSprings(in: scrollView)
        let lastSpringCompletionTime = try #require(springs.map { $0.beginTime + $0.duration }.max())
        Self.advanceHighlight(container, lyrics: lyrics, through: [4, 5])
        #expect(Self.highlightedOriginalIndex(in: scrollView) == 3)

        try await Task.sleep(seconds: max(0, lastSpringCompletionTime - CACurrentMediaTime()) + 0.3)

        #expect(Self.highlightedOriginalIndex(in: scrollView) == 5)
        let spring = try #require(Self.linePositionSprings(in: scrollView).first)
        // Line 3 ended at 15.8 s; line 5 starts at 20 s. Using skipped line 4
        // would incorrectly choose the short-gap spring for only 0.2 s of rest.
        #expect(abs(Double(spring.stiffness) - 70.18385351885765) < 0.001)
        #expect(abs(Double(spring.damping) - 13.069025438933538) < 0.001)
    }

    @Test func appleMusicCascadeStartsTheFirstTwoRowsTogetherAndPreservesTheirPositions() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer(variant: .appleMusic26)
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2])
        let scrollView = try Self.scrollView(of: container)
        let previousViewport = scrollView.contentView.bounds
        let previousRowPositions = Dictionary(uniqueKeysWithValues: Self.lineViews(in: scrollView).compactMap { lineView in
            lineView.layer.map { (lineView.originalIndex, $0.position.y) }
        })
        Self.advanceHighlight(container, lyrics: lyrics, through: [3])
        let travelledViewport = previousViewport.union(scrollView.contentView.bounds)
        let expectedRows = Self.lineViews(in: scrollView).filter { $0.frame.intersects(travelledViewport) }

        #expect(Self.clipBoundsSprings(in: scrollView).isEmpty)
        let springsByRow = Self.linePositionSpringsByRow(in: scrollView)
        #expect(expectedRows.count >= 8, "an 800 point viewport should show most of the twelve fixture lines")
        #expect(Set(springsByRow.map(\.lineView.originalIndex)) == Set(expectedRows.map(\.originalIndex)))
        #expect(Self.linePositionAnimationCount(in: scrollView) == expectedRows.count)
        for (lineView, spring) in springsByRow {
            Self.expectAppleMusicLineChangeSpring(spring)
            let startingPosition = try CGFloat(#require(spring.fromValue as? CGFloat))
            let endingPosition = try CGFloat(#require(spring.toValue as? CGFloat))
            let previousPosition = try #require(previousRowPositions[lineView.originalIndex])
            let currentViewportOrigin = scrollView.contentView.bounds.origin.y
            #expect(abs((startingPosition - currentViewportOrigin) - (previousPosition - previousViewport.origin.y)) < 0.001)
            #expect(endingPosition == previousPosition, "the first row's scroll compensation must not be applied twice")
            #expect(lineView.layer?.position.y == previousPosition, "AppKit keeps ownership of the model position")
            #expect(abs(startingPosition - endingPosition) > 1)
        }
        let beginTimesTopToBottom = springsByRow.map(\.spring.beginTime)
        try #require(beginTimesTopToBottom.count >= 2)
        #expect(
            abs(beginTimesTopToBottom[1] - beginTimesTopToBottom[0]) < 0.005,
            "Music starts the first two participating rows together"
        )
        #expect(zip(beginTimesTopToBottom.dropFirst(2), beginTimesTopToBottom.dropFirst()).allSatisfy { lowerRowTime, upperRowTime in
            abs((lowerRowTime - upperRowTime) - 0.05) < 0.005
        }, "subsequent rows start 50 ms apart")
    }

    @Test func appleMusicCascadeReversesAndHalvesTheDelaysWhenTheLyricsMoveBackwards() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer(variant: .appleMusic26)
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [4])
        let scrollView = try Self.scrollView(of: container)
        let originBeforeMovingBack = scrollView.contentView.bounds.origin.y
        Self.advanceHighlight(container, lyrics: lyrics, through: [3])
        #expect(scrollView.contentView.bounds.origin.y < originBeforeMovingBack)

        let springsByRow = Self.linePositionSpringsByRow(in: scrollView)
        #expect(springsByRow.count >= 8)
        let beginTimesBottomToTop = Array(springsByRow.map(\.spring.beginTime).reversed())
        try #require(beginTimesBottomToTop.count >= 2)
        #expect(
            abs(beginTimesBottomToTop[1] - beginTimesBottomToTop[0]) < 0.005,
            "moving backwards the bottom two rows lead together"
        )
        #expect(zip(beginTimesBottomToTop.dropFirst(2), beginTimesBottomToTop.dropFirst()).allSatisfy { upperRowTime, lowerRowTime in
            abs((upperRowTime - lowerRowTime) - 0.025) < 0.005
        }, "subsequent rows wait 25 ms longer going upwards")
    }

    @Test func appleMusicCascadeHoldsANewLineUntilItSettlesThenCatchesUp() async throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer(variant: .appleMusic26)
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3])
        let scrollView = try Self.scrollView(of: container)
        let springsWhileInFlight = Self.linePositionSpringsByRow(in: scrollView)
        let clipOriginForLineThree = scrollView.contentView.bounds.origin.y

        Self.advanceHighlight(container, lyrics: lyrics, through: [4])
        #expect(Self.highlightedOriginalIndex(in: scrollView) == 3, "the cascade to line 3 is still settling")
        #expect(scrollView.contentView.bounds.origin.y == clipOriginForLineThree)
        #expect(Self.clipBoundsSprings(in: scrollView).isEmpty)
        #expect(zip(Self.linePositionSpringsByRow(in: scrollView), springsWhileInFlight).allSatisfy { current, previous in
            current.spring.beginTime == previous.spring.beginTime
        }, "the held line change must not restart the running cascade")

        let lastSpringCompletionTime = try #require(springsWhileInFlight.map { $0.spring.beginTime + $0.spring.duration }.max())
        try await Task.sleep(seconds: max(0, lastSpringCompletionTime - CACurrentMediaTime()) + 0.3)

        #expect(Self.highlightedOriginalIndex(in: scrollView) == 4, "the held line is applied once the cascade settles")
        #expect(scrollView.contentView.bounds.origin.y > clipOriginForLineThree)
        #expect(Self.clipBoundsSprings(in: scrollView).isEmpty)
        #expect(!Self.linePositionSpringsByRow(in: scrollView).isEmpty, "catching up runs its own cascade")
    }

    // MARK: Legacy SwiftUI cascade

    @Test func legacyLineChangeUsesTheSwiftUICascadeAndAnchorsTheSelectedBaseline() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer(variant: .legacySwiftUI)
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3])

        let scrollView = try Self.scrollView(of: container)
        let clipBoundsSprings = Self.clipBoundsSprings(in: scrollView)
        #expect(clipBoundsSprings.isEmpty)

        let linePositionSprings = Self.linePositionSprings(in: scrollView)
        #expect(Self.linePositionAnimationCount(in: scrollView) == 9)
        #expect(linePositionSprings.count == 6)
        let expectedStiffness = pow(2 * Double.pi / 0.6, 2)
        let expectedDamping = 0.725 * 2 * sqrt(expectedStiffness)
        for spring in linePositionSprings {
            #expect(abs(Double(spring.mass) - 1) < 0.001)
            #expect(abs(Double(spring.stiffness) - expectedStiffness) < 1)
            #expect(abs(Double(spring.damping) - expectedDamping) < 0.5)
            #expect(spring.fillMode == .both)
            let startingPosition = try CGFloat(#require(spring.fromValue as? CGFloat))
            let endingPosition = try CGFloat(#require(spring.toValue as? CGFloat))
            #expect(abs(startingPosition - endingPosition) > 1)
        }
        let orderedBeginTimes = linePositionSprings.map(\.beginTime).sorted()
        #expect(zip(orderedBeginTimes.dropFirst(), orderedBeginTimes).allSatisfy { laterTime, earlierTime in
            abs((laterTime - earlierTime) - 0.08) < 0.005
        })

        let selectedLine = try #require(Self.lineViews(in: scrollView).first { $0.originalIndex == 3 })
        let selectedBaselineInViewport = selectedLine.frame.minY
            - scrollView.contentView.bounds.origin.y
            + selectedLine.mainTextFirstBaselineOffset
        let expectedBaselineInViewport = scrollView.contentView.bounds.height
            * Self.selectedLineBaselineViewportFraction
        #expect(abs(selectedBaselineInViewport - expectedBaselineInViewport) < 1)
    }

    @Test func legacyRepeatingTheSameTargetDoesNotRestartTheClipSpring() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer(variant: .legacySwiftUI)
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3, 4])
        let scrollView = try Self.scrollView(of: container)
        let firstSpring = try #require(Self.clipBoundsSprings(in: scrollView).first)

        Self.advanceHighlight(container, lyrics: lyrics, through: [4, 4, 4])

        let currentSpring = try #require(Self.clipBoundsSprings(in: scrollView).first)
        #expect(currentSpring.beginTime == firstSpring.beginTime)
        #expect(currentSpring.fromValue as? CGFloat == firstSpring.fromValue as? CGFloat)
        #expect(currentSpring.toValue as? CGFloat == firstSpring.toValue as? CGFloat)
    }

    @Test func legacyRapidLineChangeCancelsTheCascadeAndSettlesFromTheVisibleClipOrigin() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer(variant: .legacySwiftUI)
        defer {
            window.contentView = nil
            window.close()
        }

        var currentLineTransitionTime: CFTimeInterval = 100
        container.setLineTransitionTimeProvider { currentLineTransitionTime }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3])
        let scrollView = try Self.scrollView(of: container)
        #expect(Self.linePositionSprings(in: scrollView).count == 6)
        let clipLayer = try #require(scrollView.contentView.layer)
        let visibleOriginBeforeInterruption = (clipLayer.presentation() ?? clipLayer).bounds.origin.y

        currentLineTransitionTime += 0.1
        Self.advanceHighlight(container, lyrics: lyrics, through: [4])

        let replacementSpring = try #require(Self.clipBoundsSprings(in: scrollView).first)
        #expect(Self.linePositionAnimationCount(in: scrollView) == 0)
        let expectedStiffness = pow(2 * Double.pi / 0.5, 2)
        let expectedDamping = 2 * sqrt(expectedStiffness)
        #expect(abs(Double(replacementSpring.mass) - 1) < 0.001)
        #expect(abs(Double(replacementSpring.stiffness) - expectedStiffness) < 1)
        #expect(abs(Double(replacementSpring.damping) - expectedDamping) < 0.5)
        let replacementStartingOrigin = try CGFloat(#require(replacementSpring.fromValue as? CGFloat))
        #expect(abs(replacementStartingOrigin - visibleOriginBeforeInterruption) < 0.5)
    }

    // MARK: Shared behaviour

    @Test(arguments: AppleMusicLyrics.LineCascadeVariant.allCases)
    func automaticFollowingMapsAppleMusicFadeOntoTheUnflippedContainer(
        variant: AppleMusicLyrics.LineCascadeVariant
    ) throws {
        let (container, window) = Self.makeMountedContainer(variant: variant)
        defer {
            window.contentView = nil
            window.close()
        }

        container.layoutSubtreeIfNeeded()

        let gradientMask = try #require(
            container.layer?.mask as? CAGradientLayer,
            "the lyrics viewport should use Apple Music's outer gradient mask"
        )
        let maskColors = try #require(gradientMask.colors as? [CGColor])
        let maskLocations = try #require(gradientMask.locations)
        // Music's pretty mode fades 128 points at both edges while following.
        let expectedTopFadeEndLocation = NSNumber(value: 128 / Double(container.bounds.height))
        let expectedBottomFadeStartLocation = NSNumber(value: 1 - 128 / Double(container.bounds.height))

        #expect(maskColors.count == 4)
        #expect(maskColors[0].alpha == 0)
        #expect(maskColors[1].alpha == 1)
        #expect(maskColors[2].alpha == 1)
        #expect(maskColors[3].alpha == 0)
        #expect(maskLocations.count == 4)
        #expect(maskLocations[0] == 0)
        #expect(abs(maskLocations[1].doubleValue - expectedTopFadeEndLocation.doubleValue) < 0.000_001)
        #expect(abs(maskLocations[2].doubleValue - expectedBottomFadeStartLocation.doubleValue) < 0.000_001)
        #expect(maskLocations[3] == 1)
        #expect(gradientMask.startPoint == CGPoint(x: 0.5, y: 1))
        #expect(gradientMask.endPoint == CGPoint(x: 0.5, y: 0))
        #expect(gradientMask.frame == container.bounds)
    }

    /// `sub_1001284F8` narrows both fades to 30 points once the user scrolls
    /// the lyrics themselves, and widens them again when following resumes.
    @Test func scrollingAwayNarrowsBothFadesAndFollowingRestoresThem() throws {
        let (container, window) = Self.makeMountedContainer(variant: .appleMusic26)
        defer {
            window.contentView = nil
            window.close()
        }
        let interactionState = AppleMusicLyrics.InteractionStateModel()
        container.interactionState = interactionState
        container.layoutSubtreeIfNeeded()
        let scrollView = try Self.scrollView(of: container)
        let gradientMask = try #require(container.layer?.mask as? CAGradientLayer)
        let containerHeight = Double(container.bounds.height)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)

        #expect(!interactionState.isFollowing)
        let scrollingLocations = try #require(gradientMask.locations)
        #expect(abs(scrollingLocations[1].doubleValue - 30 / containerHeight) < 0.000_001)
        #expect(abs(scrollingLocations[2].doubleValue - (1 - 30 / containerHeight)) < 0.000_001)

        interactionState.returnToFollowing()
        container.resumeFollowingIfNeeded()

        let followingLocations = try #require(gradientMask.locations)
        #expect(abs(followingLocations[1].doubleValue - 128 / containerHeight) < 0.000_001)
        #expect(abs(followingLocations[2].doubleValue - (1 - 128 / containerHeight)) < 0.000_001)
    }

    /// Music's `.center(rect:)` anchor: the selected line's whole content block
    /// sits centred on the anchor's y, the way the Now Playing player centres
    /// it on the artwork.
    @Test func contentCentreAnchorPutsTheSelectedLinesContentCentreOnTheAnchor() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer(variant: .legacySwiftUI)
        defer {
            window.contentView = nil
            window.close()
        }
        let anchorY: CGFloat = 250
        container.selectedLineAnchor = .contentCenter(y: anchorY)

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3])

        let scrollView = try Self.scrollView(of: container)
        let selectedLine = try #require(Self.lineViews(in: scrollView).first { $0.originalIndex == 3 })
        let contentCentreInViewport = selectedLine.frame.minY
            - scrollView.contentView.bounds.origin.y
            + selectedLine.contentCenterOffset(forWidth: selectedLine.bounds.width)
        #expect(abs(contentCentreInViewport - anchorY) < 1)
    }

    @Test func lyricsViewportUsesTheCompleteContainerHeight() throws {
        let (container, window) = Self.makeMountedContainer(variant: .appleMusic26)
        defer {
            window.contentView = nil
            window.close()
        }

        container.layoutSubtreeIfNeeded()

        let scrollView = try Self.scrollView(of: container)
        #expect(scrollView.frame == container.bounds)
    }

    @Test(arguments: AppleMusicLyrics.LineCascadeVariant.allCases)
    func tappedLineUsesTheInteractiveClipSpringEvenForALargeJump(
        variant: AppleMusicLyrics.LineCascadeVariant
    ) throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer(variant: variant)
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3])
        let scrollView = try Self.scrollView(of: container)
        let targetLine = try #require(Self.lineViews(in: scrollView).first { $0.originalIndex == 8 })
        targetLine.onTap?(lyrics.lines[8])
        Self.advanceHighlight(container, lyrics: lyrics, through: [8])

        #expect(Self.highlightedOriginalIndex(in: scrollView) == 8, "a tap never waits for a running cascade")
        let interactiveSpring = try #require(Self.clipBoundsSprings(in: scrollView).first)
        #expect(abs(Double(interactiveSpring.mass) - 2) < 0.001)
        #expect(abs(Double(interactiveSpring.stiffness) - 260) < 1)
        #expect(abs(Double(interactiveSpring.damping) - 50) < 0.5)
    }
}
