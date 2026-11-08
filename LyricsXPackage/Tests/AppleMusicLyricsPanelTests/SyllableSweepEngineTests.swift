import AppKit
import LyricsXFoundation
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

/// The `appleMusic26` sweep driven through the real content layer, without a
/// window: what `sub_1001689D4` sends each row and when. Red on the old sweep,
/// which placed every row by the share of sung characters on every frame and
/// never animated it.
@MainActor
struct SyllableSweepEngineTests {
    private static let headstart = AppleMusicLyrics.LyricsSpecs.animationHeadstart

    private struct VisualRow {
        let colorContainerLayer: CALayer
        let progressGradientLayer: AppleMusicLyrics.LineProgressGradientLayer
    }

    private static func makeContentLayer(
        text: String,
        words: [LyricsLine.Attachments.SynchronizedTextTiming.Word],
        textWidth: CGFloat = 900,
        variant: AppleMusicLyrics.LineProgressSweepVariant = .appleMusic26
    ) throws -> (AppleMusicLyrics.SyncedLyricsLineContentLayer, AppleMusicLyrics.LineTextLayout) {
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: words,
            duration: words.map(\.timeRange.upperBound).max()
        )
        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold)]
            ),
            content: text,
            wordTimings: [],
            synchronizedTextTiming: timing,
            languageIdentifier: "en",
            lineDuration: timing.duration ?? 0,
            textWidth: textWidth
        ))
        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.sweepVariantProvider = { variant }
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)
        return (contentLayer, layout)
    }

    private static func visualRows(of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer) -> [VisualRow] {
        (contentLayer.sublayers ?? []).compactMap { candidateLayer -> VisualRow? in
            guard let gradient = candidateLayer.sublayers?.compactMap({ $0 as? AppleMusicLyrics.LineProgressGradientLayer }).first else {
                return nil
            }
            return VisualRow(colorContainerLayer: candidateLayer, progressGradientLayer: gradient)
        }
    }

    /// Feed the layer the way the display link does: never more than half a
    /// second apart, or the layer treats it as a jump in the playback time.
    private static func play(
        _ contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer,
        through elapsedTimes: [TimeInterval]
    ) {
        for elapsedTime in elapsedTimes {
            contentLayer.update(elapsedTime: elapsedTime, fillFraction: 0)
        }
    }

    /// The gradient's model `position.x` once its clear end stands at `clearEdge`.
    private static func positionX(
        of gradient: AppleMusicLyrics.LineProgressGradientLayer,
        clearEdge: CGFloat,
        in contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer
    ) -> CGFloat {
        contentLayer.textOutset.width + gradient.originX(forClearEdge: clearEdge)
    }

    private static func travel(of gradient: CALayer) -> CABasicAnimation? {
        AppleMusicLyrics.LayerPropertyAnimator.positionAnimation(on: gradient) as? CABasicAnimation
    }

    private static let slowlyText = "Slowly slowly we fall"
    private static let slowlyWords: [LyricsLine.Attachments.SynchronizedTextTiming.Word] = [
        .init(characterRange: 0 ..< 6, timeRange: 0 ..< 0.746),
        .init(characterRange: 7 ..< 13, timeRange: 1 ..< 1.6),
        .init(characterRange: 14 ..< 16, timeRange: 1.6 ..< 2),
        .init(characterRange: 17 ..< 21, timeRange: 2 ..< 2.5),
    ]

    /// Entering a syllable sends the row's gradient once, in a straight line,
    /// to that syllable's target, timed to what is left of it.
    @Test func enteringASyllableSendsOneLinearTravelToItsTarget() throws {
        let (contentLayer, layout) = try Self.makeContentLayer(text: Self.slowlyText, words: Self.slowlyWords)
        let plan = AppleMusicLyrics.SyllableSweepPlan.make(for: layout)
        let gradient = try #require(Self.visualRows(of: contentLayer).first?.progressGradientLayer)

        Self.play(contentLayer, through: [-0.5, -0.2])
        #expect(gradient.position.x == Self.positionX(of: gradient, clearEdge: 0, in: contentLayer), "before the row the ramp lies wholly before the text")
        #expect(Self.travel(of: gradient) == nil)

        Self.play(contentLayer, through: [0.2])
        let target = plan.rows[0].syllables[0].clearEdge
        #expect(abs(gradient.position.x - Self.positionX(of: gradient, clearEdge: target, in: contentLayer)) < 0.001)
        let travel = try #require(Self.travel(of: gradient), "entering the syllable must send a travel")
        #expect(!(travel is CASpringAnimation), "the sweep moves at constant speed, not on a spring")
        #expect(travel.timingFunction == CAMediaTimingFunction(name: .linear))
        #expect(abs(travel.duration - (0.746 - (0.2 + Self.headstart))) < 0.0001)
        let firstBeginTime = travel.beginTime

        // Later in the same syllable: nothing new is sent.
        Self.play(contentLayer, through: [0.4])
        #expect(Self.travel(of: gradient)?.beginTime == firstBeginTime)
    }

    /// Between words nothing is sent: the gradient waits where the last
    /// syllable left it, and the next travel starts with the next syllable.
    @Test func aGapSendsNothingAndTheNextSyllableTakesOver() throws {
        let (contentLayer, layout) = try Self.makeContentLayer(text: Self.slowlyText, words: Self.slowlyWords)
        let plan = AppleMusicLyrics.SyllableSweepPlan.make(for: layout)
        let gradient = try #require(Self.visualRows(of: contentLayer).first?.progressGradientLayer)

        Self.play(contentLayer, through: [-0.5, -0.2, 0.1])
        let firstBeginTime = try #require(Self.travel(of: gradient)?.beginTime)

        Self.play(contentLayer, through: [0.5, 0.8])
        #expect(Self.travel(of: gradient)?.beginTime == firstBeginTime, "a gap must not send anything")
        #expect(abs(gradient.position.x - Self.positionX(of: gradient, clearEdge: plan.rows[0].syllables[0].clearEdge, in: contentLayer)) < 0.001)

        Self.play(contentLayer, through: [1.1])
        let secondTravel = try #require(Self.travel(of: gradient))
        #expect(secondTravel.beginTime != firstBeginTime)
        #expect(abs(gradient.position.x - Self.positionX(of: gradient, clearEdge: plan.rows[0].syllables[1].clearEdge, in: contentLayer)) < 0.001)
    }

    /// Music hands the sweep the playback time plus `animationHeadstart`, so a
    /// syllable is entered a tenth of a second before it is sung.
    @Test func theSweepRunsATenthOfASecondAhead() throws {
        let (contentLayer, layout) = try Self.makeContentLayer(text: Self.slowlyText, words: Self.slowlyWords)
        let plan = AppleMusicLyrics.SyllableSweepPlan.make(for: layout)
        let gradient = try #require(Self.visualRows(of: contentLayer).first?.progressGradientLayer)

        Self.play(contentLayer, through: [-0.5, -0.1, 0.3, 0.7, 0.85])
        #expect(
            abs(gradient.position.x - Self.positionX(of: gradient, clearEdge: plan.rows[0].syllables[0].clearEdge, in: contentLayer)) < 0.001,
            "0.15 s before \"slowly\" starts the sweep is still waiting in the gap"
        )
        Self.play(contentLayer, through: [0.95])
        #expect(
            abs(gradient.position.x - Self.positionX(of: gradient, clearEdge: plan.rows[0].syllables[1].clearEdge, in: contentLayer)) < 0.001,
            "0.05 s before \"slowly\" starts, the head start must already have sent the sweep towards it"
        )
    }

    @Test func pastTheLastSyllableTheRowIsLitEndToEnd() throws {
        let (contentLayer, layout) = try Self.makeContentLayer(text: Self.slowlyText, words: Self.slowlyWords)
        let plan = AppleMusicLyrics.SyllableSweepPlan.make(for: layout)
        let gradient = try #require(Self.visualRows(of: contentLayer).first?.progressGradientLayer)

        Self.play(contentLayer, through: [-0.5, 0, 0.5, 1, 1.5, 2, 2.3, 2.6])
        #expect(gradient.position.x == Self.positionX(of: gradient, clearEdge: plan.rows[0].filledClearEdge, in: contentLayer))
    }

    /// A wrapped line: the second row stays dark until its own first syllable,
    /// however far the first row has got.
    @Test func theSecondRowWaitsForItsOwnFirstSyllable() throws {
        let text = "We kept walking into the headwind while every streetlight disappeared"
        let wordRanges: [Range<Int>] = [0 ..< 2, 3 ..< 7, 8 ..< 15, 16 ..< 20, 21 ..< 24, 25 ..< 33, 34 ..< 39, 40 ..< 45, 46 ..< 57, 58 ..< 69]
        let words = wordRanges.enumerated().map { index, range in
            LyricsLine.Attachments.SynchronizedTextTiming.Word(
                characterRange: range,
                timeRange: Double(index) * 0.5 ..< Double(index + 1) * 0.5
            )
        }
        let (contentLayer, layout) = try Self.makeContentLayer(text: text, words: words, textWidth: 420)
        try #require(layout.visualLines.count >= 2, "the fixture must wrap")
        let plan = AppleMusicLyrics.SyllableSweepPlan.make(for: layout)
        let rows = Self.visualRows(of: contentLayer)
        try #require(rows.count == layout.visualLines.count)
        let secondRowEmptyPosition = Self.positionX(of: rows[1].progressGradientLayer, clearEdge: 0, in: contentLayer)

        contentLayer.update(elapsedTime: -0.5, fillFraction: 0)
        let insideTheFirstRow = (plan.rows[0].startTime + plan.rows[0].endTime) / 2
        contentLayer.update(elapsedTime: insideTheFirstRow, fillFraction: 0.2)
        #expect(Self.travel(of: rows[0].progressGradientLayer) != nil)
        #expect(rows[1].progressGradientLayer.position.x == secondRowEmptyPosition)
        #expect(Self.travel(of: rows[1].progressGradientLayer) == nil)

        contentLayer.update(elapsedTime: plan.rows[1].startTime + 0.05, fillFraction: 0.6)
        #expect(Self.travel(of: rows[1].progressGradientLayer) != nil)
        #expect(rows[1].progressGradientLayer.position.x > secondRowEmptyPosition)
    }

    /// Selected mid-line, or after a seek, a row is first put where continuous
    /// playback would have it, then the current syllable travels on from there.
    @Test func aJumpLandsWhereContinuousPlaybackWouldBe() throws {
        let (contentLayer, layout) = try Self.makeContentLayer(text: Self.slowlyText, words: Self.slowlyWords)
        let row = AppleMusicLyrics.SyllableSweepPlan.make(for: layout).rows[0]
        let gradient = try #require(Self.visualRows(of: contentLayer).first?.progressGradientLayer)

        let elapsed = 1.2
        contentLayer.update(elapsedTime: elapsed, fillFraction: 0.5)
        let travel = try #require(Self.travel(of: gradient))
        let expectedStart = Self.positionX(of: gradient, clearEdge: row.clearEdge(at: elapsed + Self.headstart), in: contentLayer)
        let travelStart = try #require((travel.fromValue as? NSValue)?.pointValue.x)
        #expect(abs(travelStart - expectedStart) < 0.001, "the travel must start from the continuous-playback position, not from the empty sweep")
        #expect(abs(gradient.position.x - Self.positionX(of: gradient, clearEdge: row.syllables[1].clearEdge, in: contentLayer)) < 0.001)
        #expect(abs(travel.duration - (1.6 - (elapsed + Self.headstart))) < 0.0001)
    }

    /// The hidden switch keeps the old sweep exactly: placed by the character
    /// share every frame, never animated, no head start.
    @Test func theCharacterFractionVariantKeepsTheOldSweep() throws {
        let (contentLayer, layout) = try Self.makeContentLayer(
            text: Self.slowlyText,
            words: Self.slowlyWords,
            variant: .characterFraction
        )
        let gradient = try #require(Self.visualRows(of: contentLayer).first?.progressGradientLayer)
        #expect(gradient.position.x == contentLayer.textOutset.width + gradient.originX(forFillEdge: 0))

        contentLayer.update(elapsedTime: 0.3, fillFraction: 0.25)
        let fillEdge = layout.totalTextWidth * 0.25
        #expect(abs(gradient.position.x - (contentLayer.textOutset.width + gradient.originX(forFillEdge: fillEdge))) < 0.001)
        #expect(Self.travel(of: gradient) == nil)
    }

    /// Deselecting mid-travel stops the sweep where it is, so the sung part
    /// fades out in place rather than carrying on while it fades.
    @Test func deselectingStopsATravelInFlight() throws {
        let (contentLayer, _) = try Self.makeContentLayer(text: Self.slowlyText, words: Self.slowlyWords)
        let gradient = try #require(Self.visualRows(of: contentLayer).first?.progressGradientLayer)
        Self.play(contentLayer, through: [-0.5, -0.2, 0.2])
        try #require(Self.travel(of: gradient) != nil)

        contentLayer.setHighlighted(false, animatedWith: AppleMusicLyrics.LineSelectionPlan.springTiming)
        #expect(Self.travel(of: gradient) == nil)
    }
}

/// The head start reaches the syllable lift too: `sub_1001897C0` is handed the
/// same time as the sweep, so a syllable rises a tenth of a second before it
/// is sung. The port used to lift on the bare playback time.
@MainActor
struct SyllableLiftHeadstartTests {
    @Test func aSyllableRisesATenthOfASecondEarly() throws {
        let text = "Hello world"
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: [
                .init(characterRange: 0 ..< 5, timeRange: 0 ..< 0.5),
                .init(characterRange: 6 ..< 11, timeRange: 1 ..< 1.5),
            ],
            duration: 1.5
        )
        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold)]
            ),
            content: text,
            wordTimings: [],
            synchronizedTextTiming: timing,
            languageIdentifier: "en",
            lineDuration: 1.5,
            textWidth: 900
        ))
        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)
        let rowMasks = (contentLayer.sublayers ?? []).compactMap(\.mask)
        let wordLayers = rowMasks.flatMap { ($0.sublayers ?? []).compactMap(\.mask) }
        try #require(wordLayers.count == layout.words.count)
        let worldIndex = try #require(layout.words.firstIndex { $0.text == "world" })
        let worldGlyphs = wordLayers[worldIndex].sublayers ?? []
        try #require(!worldGlyphs.isEmpty)

        contentLayer.update(elapsedTime: 0.5, fillFraction: 0.4)
        contentLayer.update(elapsedTime: 0.85, fillFraction: 0.6)
        #expect(worldGlyphs.allSatisfy { $0.animation(forKey: "AppleMusicLyrics.position") == nil }, "0.15 s early the word must still be at rest")

        contentLayer.update(elapsedTime: 0.95, fillFraction: 0.63)
        let lifts = worldGlyphs.map { $0.animation(forKey: "AppleMusicLyrics.position") as? CASpringAnimation }
        #expect(lifts.allSatisfy { $0 != nil }, "0.05 s before \"world\" starts, its syllable must already be rising")
        #expect(lifts.allSatisfy { $0?.stiffness == AppleMusicLyrics.SyllableLiftPlan.springStiffness })
    }
}
