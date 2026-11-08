import AppKit
import LyricsXFoundation
import Testing
@testable import AppleMusicLyricsPanel

/// Music 26.6's sweep targets (`sub_1001689D4`), worked out from the layout:
/// where the ramp's clear end comes to rest after each syllable, how far past
/// the sung glyphs it reaches, and how a row lights up over time.
struct SyllableSweepPlanTests {
    private static let feather = AppleMusicLyrics.LyricsSpecs.lineProgressionGradientFeather

    private static func structuredLayout(
        text: String,
        words: [LyricsLine.Attachments.SynchronizedTextTiming.Word],
        textWidth: CGFloat = 900
    ) throws -> AppleMusicLyrics.LineTextLayout {
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: words,
            duration: words.map(\.timeRange.upperBound).max()
        )
        return try #require(AppleMusicLyrics.LineTextLayout.build(
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
    }

    /// The trailing edge of a word's last glyph, measured from its row's start.
    private static func trailingEdge(
        of word: AppleMusicLyrics.LineTextLayout.Word,
        in layout: AppleMusicLyrics.LineTextLayout
    ) -> CGFloat {
        let rowStart = layout.visualLines[word.visualLineIndex].typographicFrame.minX
        return word.frame.minX + (word.glyphs.map(\.frame.maxX).max() ?? 0) - rowStart
    }

    private static func leadingEdge(
        of word: AppleMusicLyrics.LineTextLayout.Word,
        in layout: AppleMusicLyrics.LineTextLayout
    ) -> CGFloat {
        word.frame.minX - layout.visualLines[word.visualLineIndex].typographicFrame.minX
    }

    // MARK: Feather lead

    @Test func featherLeadFollowsMusicsFourCasesInOrder() {
        typealias Plan = AppleMusicLyrics.SyllableSweepPlan
        // The row's last syllable pushes the whole ramp past the text, whatever
        // else is true of it.
        #expect(Plan.featherLeadFraction(isLastSyllableOfRow: true, wordLength: 1, syllableLength: 1, isFollowedBySyllable: false) == 1)
        // A word of one or two characters centres the ramp on its end.
        #expect(Plan.featherLeadFraction(isLastSyllableOfRow: false, wordLength: 1, syllableLength: 1, isFollowedBySyllable: true) == 0.5)
        #expect(Plan.featherLeadFraction(isLastSyllableOfRow: false, wordLength: 2, syllableLength: 2, isFollowedBySyllable: true) == 0.5)
        // A short syllable of a longer word, with more to come.
        #expect(Plan.featherLeadFraction(isLastSyllableOfRow: false, wordLength: 6, syllableLength: 2, isFollowedBySyllable: true) == 0.25)
        // Everything else barely leads.
        #expect(Plan.featherLeadFraction(isLastSyllableOfRow: false, wordLength: 6, syllableLength: 3, isFollowedBySyllable: true) == 0.12)
        #expect(Plan.featherLeadFraction(isLastSyllableOfRow: false, wordLength: 0, syllableLength: 2, isFollowedBySyllable: false) == 0.12)
    }

    // MARK: Targets

    /// 《Slowly》: a whole word's target is where the *next* word starts, so the
    /// space is swept while the word is sung; "we" leads by half a feather; the
    /// row's last word pushes the ramp a whole feather past its last glyph.
    @Test func wordTargetsReachTheNextWordAndLeadByMusicsFractions() throws {
        let layout = try Self.structuredLayout(
            text: "Slowly slowly we fall in love",
            words: [
                .init(characterRange: 0 ..< 6, timeRange: 0 ..< 0.746),
                .init(characterRange: 7 ..< 13, timeRange: 0.746 ..< 1.322),
                .init(characterRange: 14 ..< 16, timeRange: 1.322 ..< 1.630),
                .init(characterRange: 17 ..< 21, timeRange: 1.630 ..< 1.844),
                .init(characterRange: 22 ..< 24, timeRange: 1.844 ..< 2.064),
                .init(characterRange: 25 ..< 29, timeRange: 2.064 ..< 2.790),
            ]
        )
        try #require(layout.visualLines.count == 1)
        let timedWords = layout.words.filter { $0.timeRange != nil }
        try #require(timedWords.count == 6)
        let plan = AppleMusicLyrics.SyllableSweepPlan.make(for: layout)
        let row = try #require(plan.rows.first)
        try #require(row.syllables.count == 6)

        #expect(abs(row.syllables[0].clearEdge - (Self.leadingEdge(of: timedWords[1], in: layout) + 0.12 * Self.feather)) < 0.001)
        #expect(abs(row.syllables[2].clearEdge - (Self.leadingEdge(of: timedWords[3], in: layout) + 0.5 * Self.feather)) < 0.001)
        #expect(abs(row.syllables[4].clearEdge - (Self.leadingEdge(of: timedWords[5], in: layout) + 0.5 * Self.feather)) < 0.001)
        #expect(abs(row.syllables[5].clearEdge - (Self.trailingEdge(of: timedWords[5], in: layout) + Self.feather)) < 0.001)
        #expect(row.startTime == 0)
        #expect(row.endTime == 2.790)
        #expect(row.syllables.map(\.timeRange) == timedWords.compactMap(\.timeRange))
    }

    /// Inside a word, a syllable's target is its own last glyph; a short one
    /// with more to come leads by a quarter of the feather.
    @Test func syllableTargetsStopAtTheirOwnGlyphs() throws {
        let layout = try Self.structuredLayout(
            text: "inside out",
            words: [
                .init(characterRange: 0 ..< 6, timeRange: 0 ..< 1, syllables: [
                    .init(characterRange: 0 ..< 2, timeRange: 0 ..< 0.4),
                    .init(characterRange: 2 ..< 6, timeRange: 0.4 ..< 1),
                ]),
                .init(characterRange: 7 ..< 10, timeRange: 1 ..< 1.5),
            ]
        )
        let timedWords = layout.words.filter { $0.timeRange != nil }
        try #require(timedWords.count == 2)
        let inside = timedWords[0]
        let firstSyllable = try #require(inside.syllables.first)
        let rowStart = layout.visualLines[0].typographicFrame.minX
        let firstSyllableTrailingEdge = inside.frame.minX
            + (firstSyllable.glyphIndices.map { inside.glyphs[$0].frame.maxX }.max() ?? 0)
            - rowStart

        let row = try #require(AppleMusicLyrics.SyllableSweepPlan.make(for: layout).rows.first)
        try #require(row.syllables.count == 3)
        #expect(abs(row.syllables[0].clearEdge - (firstSyllableTrailingEdge + 0.25 * Self.feather)) < 0.001)
        #expect(abs(row.syllables[1].clearEdge - (Self.leadingEdge(of: timedWords[1], in: layout) + 0.12 * Self.feather)) < 0.001)
        #expect(abs(row.syllables[2].clearEdge - (Self.trailingEdge(of: timedWords[1], in: layout) + Self.feather)) < 0.001)
    }

    /// The reason for the rewrite: the old sweep put the boundary at the share
    /// of sung *characters* times the line's width. Three wide letters after
    /// three narrow ones sit nowhere near the character midpoint.
    @Test func targetsFollowTheGlyphsRatherThanTheCharacterShare() throws {
        let layout = try Self.structuredLayout(
            text: "iii WWW",
            words: [
                .init(characterRange: 0 ..< 3, timeRange: 0 ..< 1),
                .init(characterRange: 4 ..< 7, timeRange: 1 ..< 2),
            ]
        )
        let timedWords = layout.words.filter { $0.timeRange != nil }
        let row = try #require(AppleMusicLyrics.SyllableSweepPlan.make(for: layout).rows.first)
        let sungEdge = row.syllables[0].clearEdge - 0.12 * Self.feather
        #expect(abs(sungEdge - Self.leadingEdge(of: timedWords[1], in: layout)) < 0.001)
        let characterShareEdge = layout.totalTextWidth * 4 / 7
        #expect(
            characterShareEdge - sungEdge > 30,
            "the glyph edge (\(sungEdge)) should sit well short of the character share (\(characterShareEdge)) for narrow letters"
        )
    }

    /// Inline-tag segments carry their trailing space, and stand in for one
    /// syllable each; their length is counted without it.
    @Test func inlineTagSegmentsAreOneSyllableEach() throws {
        let text = "Stay with me"
        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold)]
            ),
            content: text,
            wordTimings: [
                .init(characterIndex: 0, timeOffset: 0),
                .init(characterIndex: 5, timeOffset: 0.4),
                .init(characterIndex: 10, timeOffset: 0.8),
            ],
            lineDuration: 1.2,
            textWidth: 900
        ))
        try #require(layout.words.count == 3)
        let row = try #require(AppleMusicLyrics.SyllableSweepPlan.make(for: layout).rows.first)
        try #require(row.syllables.count == 3)
        #expect(abs(row.syllables[0].clearEdge - (Self.leadingEdge(of: layout.words[1], in: layout) + 0.12 * Self.feather)) < 0.001)
        // "me" is two letters, but it is the row's last syllable.
        #expect(abs(row.syllables[2].clearEdge - (Self.trailingEdge(of: layout.words[2], in: layout) + Self.feather)) < 0.001)
        // "with " counts four letters, not five, and is not short.
        #expect(abs(row.syllables[1].clearEdge - (Self.leadingEdge(of: layout.words[2], in: layout) + 0.12 * Self.feather)) < 0.001)
    }

    // MARK: Rows and time

    @Test func eachWrappedRowLightsOnItsOwnSyllables() throws {
        let text = "We kept walking into the headwind while every streetlight disappeared"
        let wordRanges: [Range<Int>] = [0 ..< 2, 3 ..< 7, 8 ..< 15, 16 ..< 20, 21 ..< 24, 25 ..< 33, 34 ..< 39, 40 ..< 45, 46 ..< 57, 58 ..< 69]
        let words = wordRanges.enumerated().map { index, range in
            LyricsLine.Attachments.SynchronizedTextTiming.Word(
                characterRange: range,
                timeRange: Double(index) * 0.5 ..< Double(index + 1) * 0.5
            )
        }
        let layout = try Self.structuredLayout(text: text, words: words, textWidth: 420)
        try #require(layout.visualLines.count >= 2, "the fixture must wrap")
        let plan = AppleMusicLyrics.SyllableSweepPlan.make(for: layout)
        try #require(plan.rows.count == layout.visualLines.count)

        for (rowIndex, row) in plan.rows.enumerated() {
            let rowWords = layout.words.filter { $0.visualLineIndex == rowIndex && $0.timeRange != nil }
            #expect(row.startTime == rowWords.first?.timeRange?.lowerBound)
            #expect(row.endTime == rowWords.last?.timeRange?.upperBound)
            #expect(row.width == layout.visualLines[rowIndex].typographicFrame.width)
        }
        #expect(plan.rows[1].startTime >= plan.rows[0].endTime, "the second row waits for the first")
    }

    @Test func continuousPlaybackStepsThroughTheTargetsAndHoldsInGaps() {
        let row = AppleMusicLyrics.SyllableSweepPlan.Row(
            syllables: [
                .init(timeRange: 1 ..< 2, clearEdge: 50),
                .init(timeRange: 3 ..< 4, clearEdge: 130),
            ],
            width: 140,
            featherWidth: 30,
            startTime: 1,
            endTime: 4
        )
        #expect(row.clearEdge(at: 0.5) == 0)
        #expect(row.clearEdge(at: 1) == 0)
        #expect(row.clearEdge(at: 1.5) == 25)
        #expect(row.clearEdge(at: 2.5) == 50, "a gap holds the last target")
        #expect(row.clearEdge(at: 3.5) == 90)
        #expect(row.clearEdge(at: 4) == 170, "past the last syllable the row is lit end to end")
        #expect(row.indexOfSyllable(sungAt: 1.5) == 0)
        #expect(row.indexOfSyllable(sungAt: 2.5) == nil)
        #expect(row.indexOfSyllable(sungAt: 3) == 1)
        #expect(row.indexOfSyllable(sungAt: 4) == nil)
    }

    /// Overlapping syllables: Music keeps the earlier one current until it
    /// ends, so the later one's travel starts there.
    @Test func overlappingSyllablesTravelOneAfterTheOther() {
        let row = AppleMusicLyrics.SyllableSweepPlan.Row(
            syllables: [
                .init(timeRange: 0 ..< 2, clearEdge: 40),
                .init(timeRange: 1 ..< 3, clearEdge: 80),
            ],
            width: 100,
            featherWidth: 30,
            startTime: 0,
            endTime: 3
        )
        #expect(row.indexOfSyllable(sungAt: 1.5) == 0)
        #expect(row.clearEdge(at: 1.5) == 30)
        #expect(row.clearEdge(at: 2) == 40)
        #expect(row.clearEdge(at: 2.5) == 60)
    }

    @Test func untimedLinesAreLitFromTheStart() throws {
        let text = "A line with no word timing"
        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold)]
            ),
            content: text,
            wordTimings: [],
            lineDuration: 4,
            textWidth: 900
        ))
        let row = try #require(AppleMusicLyrics.SyllableSweepPlan.make(for: layout).rows.first)
        #expect(row.syllables.isEmpty)
        #expect(row.clearEdge(at: -10) == row.filledClearEdge)
        #expect(row.clearEdge(at: 0) == row.filledClearEdge)
    }

    /// A row that ends in untimed text — punctuation outside the spans — is
    /// swept to its end by its last syllable, so the row is already fully lit
    /// when its last syllable ends instead of snapping the rest on afterwards.
    @Test func theLastSyllableSweepsToTheEndOfTheRow() throws {
        let layout = try Self.structuredLayout(
            text: "Hello world!!!",
            words: [
                .init(characterRange: 0 ..< 5, timeRange: 0 ..< 0.5),
                .init(characterRange: 6 ..< 11, timeRange: 0.5 ..< 1),
            ]
        )
        let row = try #require(AppleMusicLyrics.SyllableSweepPlan.make(for: layout).rows.first)
        let world = try #require(layout.words.first { $0.text == "world" })
        #expect(Self.trailingEdge(of: world, in: layout) + Self.feather < row.filledClearEdge - 1, "the fixture must end in untimed glyphs")
        #expect(abs((row.syllables.last?.clearEdge ?? 0) - row.filledClearEdge) < 0.001)
    }

    /// The full-feather lead goes to the last syllable the row can actually
    /// reach, not to a zero-length one after it that is never entered.
    @Test func theLastReachableSyllableLeadsByAWholeFeather() throws {
        let layout = try Self.structuredLayout(
            text: "one two",
            words: [
                .init(characterRange: 0 ..< 3, timeRange: 0 ..< 1),
                .init(characterRange: 4 ..< 7, timeRange: 1 ..< 1),
            ]
        )
        let row = try #require(AppleMusicLyrics.SyllableSweepPlan.make(for: layout).rows.first)
        #expect(row.syllables.count == 1)
        #expect(abs((row.syllables.last?.clearEdge ?? 0) - row.filledClearEdge) < 0.001)
    }

    @Test func syllablesThatLastNoTimeAreLeftOut() throws {
        let layout = try Self.structuredLayout(
            text: "one two",
            words: [
                .init(characterRange: 0 ..< 3, timeRange: 0 ..< 0),
                .init(characterRange: 4 ..< 7, timeRange: 0 ..< 1),
            ]
        )
        let row = try #require(AppleMusicLyrics.SyllableSweepPlan.make(for: layout).rows.first)
        #expect(row.syllables.map(\.timeRange) == [0 ..< 1])
    }
}
