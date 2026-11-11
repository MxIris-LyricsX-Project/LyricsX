import AppKit
import LyricsXFoundation
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

/// A selected line laid out again while it plays — the window is being resized,
/// so every row is rebuilt for its new width, or the font size changed — has to
/// come back as the last frame left it, before anything is drawn: the sweep
/// where the playing time has it, the sung syllables still up, nothing set
/// moving again.
///
/// A rebuild used to start the line over from an empty sweep with every glyph
/// at rest, and only the next display link frame put it back. While the window
/// was resized the selected line flickered between its unsung and its sung
/// look, and its sung syllables dropped and sprang up again.
@MainActor
struct SelectedLineRebuildTests {
    private static let font = NSFont.systemFont(ofSize: 36, weight: .bold)

    private static func makeLayout(
        text: String,
        words: [LyricsLine.Attachments.SynchronizedTextTiming.Word]?,
        lineDuration: TimeInterval,
        textWidth: CGFloat
    ) throws -> AppleMusicLyrics.LineTextLayout {
        let timing = words.map { words in
            LyricsLine.Attachments.SynchronizedTextTiming(words: words, duration: lineDuration)
        }
        return try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: NSAttributedString(string: text, attributes: [.font: font]),
            content: text,
            wordTimings: [],
            synchronizedTextTiming: timing,
            languageIdentifier: "en",
            lineDuration: lineDuration,
            textWidth: textWidth
        ))
    }

    private static func makeSelectedContentLayer(
        layout: AppleMusicLyrics.LineTextLayout,
        variant: AppleMusicLyrics.LineProgressSweepVariant
    ) -> AppleMusicLyrics.SyncedLyricsLineContentLayer {
        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.sweepVariantProvider = { variant }
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)
        return contentLayer
    }

    private static func gradients(
        of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer
    ) -> [AppleMusicLyrics.LineProgressGradientLayer] {
        (contentLayer.sublayers ?? []).compactMap { rowLayer in
            rowLayer.sublayers?.compactMap { $0 as? AppleMusicLyrics.LineProgressGradientLayer }.first
        }
    }

    /// Each word's glyph layers, in the layout's word order.
    private static func glyphLayersByWord(
        of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer
    ) -> [[CALayer]] {
        let rowMasks = (contentLayer.sublayers ?? []).compactMap(\.mask)
        return rowMasks.flatMap { ($0.sublayers ?? []).compactMap(\.mask) }.map { $0.sublayers ?? [] }
    }

    /// The gradient's model `position.x` once its clear end stands at `clearEdge`.
    private static func positionX(
        of gradient: AppleMusicLyrics.LineProgressGradientLayer,
        clearEdge: CGFloat,
        in contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer
    ) -> CGFloat {
        contentLayer.textOutset.width + gradient.originX(forClearEdge: clearEdge)
    }

    private static let positionAnimationKey = "AppleMusicLyrics.position"

    // MARK: - Sweep

    /// The case the resize recording showed: a line with no word timing is lit
    /// whole from its first frame, and has to stay lit when it is laid out again.
    @Test func aLineWithoutWordTimingStaysLitThroughARebuild() throws {
        let text = "Hu 66 - Hao Bu Xi Huan"
        let wideLayout = try Self.makeLayout(text: text, words: nil, lineDuration: 5, textWidth: 900)
        let contentLayer = Self.makeSelectedContentLayer(layout: wideLayout, variant: .appleMusic26)
        contentLayer.update(elapsedTime: 1.0, fillFraction: 1)

        let narrowLayout = try Self.makeLayout(text: text, words: nil, lineDuration: 5, textWidth: 700)
        contentLayer.rebuild(with: narrowLayout, contentsScale: 2)

        let plan = AppleMusicLyrics.SyllableSweepPlan.make(for: narrowLayout)
        let gradient = try #require(Self.gradients(of: contentLayer).first)
        let litPosition = Self.positionX(of: gradient, clearEdge: plan.rows[0].filledClearEdge, in: contentLayer)
        #expect(abs(gradient.position.x - litPosition) < 0.001, "rebuilt dark at \(gradient.position.x); lit is \(litPosition)")
    }

    private static let slowlyText = "Slowly slowly we fall"
    private static let slowlyWords: [LyricsLine.Attachments.SynchronizedTextTiming.Word] = [
        .init(characterRange: 0 ..< 6, timeRange: 0 ..< 0.746),
        .init(characterRange: 7 ..< 13, timeRange: 1 ..< 1.6),
        .init(characterRange: 14 ..< 16, timeRange: 1.6 ..< 2),
        .init(characterRange: 17 ..< 21, timeRange: 2 ..< 2.5),
    ]

    /// Mid-syllable, Music's sweep comes back heading for the sung syllable's
    /// target, as continuous playback would have it.
    @Test func theSyllableSweepKeepsItsPlaceThroughARebuild() throws {
        let wideLayout = try Self.makeLayout(text: Self.slowlyText, words: Self.slowlyWords, lineDuration: 2.5, textWidth: 900)
        let contentLayer = Self.makeSelectedContentLayer(layout: wideLayout, variant: .appleMusic26)
        for elapsedTime in [-0.2, 0.1, 0.5, 0.8, 1.1] {
            contentLayer.update(elapsedTime: elapsedTime, fillFraction: 0)
        }

        let narrowLayout = try Self.makeLayout(text: Self.slowlyText, words: Self.slowlyWords, lineDuration: 2.5, textWidth: 700)
        contentLayer.rebuild(with: narrowLayout, contentsScale: 2)

        let plan = AppleMusicLyrics.SyllableSweepPlan.make(for: narrowLayout)
        let gradient = try #require(Self.gradients(of: contentLayer).first)
        let target = Self.positionX(of: gradient, clearEdge: plan.rows[0].syllables[1].clearEdge, in: contentLayer)
        #expect(abs(gradient.position.x - target) < 0.001, "rebuilt at \(gradient.position.x); the sung syllable's target is \(target)")
        #expect(AppleMusicLyrics.LayerPropertyAnimator.positionAnimation(on: gradient) != nil, "the rest of the syllable still travels")
    }

    /// The old sweep, still selectable, places the gradient by the sung share
    /// of the text; that share holds through a rebuild too.
    @Test func theCharacterShareSweepKeepsItsPlaceThroughARebuild() throws {
        let wideLayout = try Self.makeLayout(text: Self.slowlyText, words: Self.slowlyWords, lineDuration: 2.5, textWidth: 900)
        let contentLayer = Self.makeSelectedContentLayer(layout: wideLayout, variant: .characterFraction)
        contentLayer.update(elapsedTime: 1.1, fillFraction: 0.5)

        let narrowLayout = try Self.makeLayout(text: Self.slowlyText, words: Self.slowlyWords, lineDuration: 2.5, textWidth: 700)
        contentLayer.rebuild(with: narrowLayout, contentsScale: 2)

        let gradient = try #require(Self.gradients(of: contentLayer).first)
        let halfway = contentLayer.textOutset.width + gradient.originX(forFillEdge: narrowLayout.totalTextWidth * 0.5)
        #expect(abs(gradient.position.x - halfway) < 0.001, "rebuilt at \(gradient.position.x); half sung is \(halfway)")
    }

    /// Nothing to restore: a line that has not had a frame since it was
    /// selected is laid out empty, as before.
    @Test func aLineSelectedAgainRebuildsEmptyUntilItsFirstFrame() throws {
        let wideLayout = try Self.makeLayout(text: Self.slowlyText, words: Self.slowlyWords, lineDuration: 2.5, textWidth: 900)
        let contentLayer = Self.makeSelectedContentLayer(layout: wideLayout, variant: .appleMusic26)
        contentLayer.update(elapsedTime: 1.1, fillFraction: 0)
        contentLayer.isHighlighted = false
        contentLayer.isHighlighted = true

        let narrowLayout = try Self.makeLayout(text: Self.slowlyText, words: Self.slowlyWords, lineDuration: 2.5, textWidth: 700)
        contentLayer.rebuild(with: narrowLayout, contentsScale: 2)

        let plan = AppleMusicLyrics.SyllableSweepPlan.make(for: narrowLayout)
        let gradient = try #require(Self.gradients(of: contentLayer).first)
        let emptyPosition = Self.positionX(of: gradient, clearEdge: plan.rows[0].emptyClearEdge, in: contentLayer)
        #expect(abs(gradient.position.x - emptyPosition) < 0.001)
    }

    // MARK: - Lift

    /// Sung syllables come back up at once; only a spring the next frame
    /// started would make them bounce.
    @Test func sungSyllablesStayUpThroughARebuildWithoutSpringingAgain() throws {
        let text = "Hello world"
        let words: [LyricsLine.Attachments.SynchronizedTextTiming.Word] = [
            .init(characterRange: 0 ..< 5, timeRange: 0 ..< 0.5),
            .init(characterRange: 6 ..< 11, timeRange: 1 ..< 1.5),
        ]
        let wideLayout = try Self.makeLayout(text: text, words: words, lineDuration: 1.5, textWidth: 900)
        let contentLayer = Self.makeSelectedContentLayer(layout: wideLayout, variant: .appleMusic26)
        for elapsedTime in [-0.2, 0.1, 0.4, 0.6] {
            contentLayer.update(elapsedTime: elapsedTime, fillFraction: 0)
        }
        let helloIndex = try #require(wideLayout.words.firstIndex { $0.text == "Hello" })
        let worldIndex = try #require(wideLayout.words.firstIndex { $0.text == "world" })
        let liftedHelloPositions = Self.glyphLayersByWord(of: contentLayer)[helloIndex].map(\.position)
        let restingWorldPositions = Self.glyphLayersByWord(of: contentLayer)[worldIndex].map(\.position)
        try #require(!liftedHelloPositions.isEmpty)

        // Narrower, but still one row: the glyphs keep their places in their words.
        let narrowLayout = try Self.makeLayout(text: text, words: words, lineDuration: 1.5, textWidth: 700)
        try #require(narrowLayout.visualLines.count == 1)
        contentLayer.rebuild(with: narrowLayout, contentsScale: 2)

        let rebuiltGlyphs = Self.glyphLayersByWord(of: contentLayer)
        let helloGlyphs = rebuiltGlyphs[helloIndex]
        #expect(helloGlyphs.map(\.position) == liftedHelloPositions, "\"Hello\" was sung and must still be up")
        #expect(helloGlyphs.allSatisfy { $0.animation(forKey: Self.positionAnimationKey) == nil }, "\"Hello\" must not spring up again")
        #expect(rebuiltGlyphs[worldIndex].map(\.position) == restingWorldPositions, "\"world\" has not been sung yet")
    }
}
