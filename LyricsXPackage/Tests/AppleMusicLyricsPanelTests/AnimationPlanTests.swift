import AppKit
import LyricsXFoundation
import Testing
@testable import AppleMusicLyricsPanel

struct AnimationPlanTests {
    /// `sub_1001C28A4` withholds the `emphasis` capability from these
    /// languages, so `sub_1001C2DD4` leaves every word `.none`: no per-glyph
    /// schedule at all — the syllables lift on their own.
    @Test(arguments: ["ar", "ar-SA", "he_IL", "zh-Hant", "ja-JP"])
    func excludedLanguagesGetNoPerGlyphSchedule(languageIdentifier: String) {
        let plan = AppleMusicLyrics.WordEmphasisPlan.make(
            wordDuration: 1.5,
            wordLength: 4,
            renderedGlyphCount: 4,
            timingGlyphCount: 4,
            languageIdentifier: languageIdentifier
        )

        #expect(plan == nil)
    }

    @Test func synchronizedFactorUsesStrictDurationAndLengthBoundaries() {
        func factor(duration: TimeInterval, length: Int) -> CGFloat? {
            AppleMusicLyrics.WordEmphasisPlan.make(
                wordDuration: duration,
                wordLength: length,
                renderedGlyphCount: length,
                timingGlyphCount: length,
                languageIdentifier: "en-US"
            )?.factor
        }

        #expect(factor(duration: 1, length: 7) == nil, "a word of exactly one second is `.none`")
        #expect(abs((factor(duration: 1.25, length: 7) ?? 0) - 0.25) < 0.000_001)
        #expect(factor(duration: 2, length: 7) == 1)
        #expect(factor(duration: 8, length: 7) == 1)
        #expect(factor(duration: 2, length: 8) == nil, "eight characters is `.none`")
    }

    @Test func syllableLiftUsesMusicsSoftSpring() {
        #expect(AppleMusicLyrics.SyllableLiftPlan.springMass == 1)
        #expect(AppleMusicLyrics.SyllableLiftPlan.springStiffness == 14)
        #expect(AppleMusicLyrics.SyllableLiftPlan.springDamping == 7)
        let timing = AppleMusicLyrics.SyllableLiftPlan.springTiming
        #expect(timing.stiffness == 14)
        #expect(timing.settlingDuration > 1, "this spring takes about a second to settle, which is the whole point")
    }

    @Test func synchronizedScheduleUsesTheRecoveredWordFormulas() throws {
        let plan = try #require(AppleMusicLyrics.WordEmphasisPlan.make(
            wordDuration: 2,
            wordLength: 4,
            renderedGlyphCount: 4,
            timingGlyphCount: 4,
            languageIdentifier: nil
        ))

        #expect(plan.factor == 1)
        #expect(abs(plan.scale - 1.14) < 0.000_001)
        #expect(abs(plan.glowOpacity - 0.4) < 0.000_001)
        #expect(plan.springPeriod == 2)
        #expect(abs(plan.glyphStagger - 0.2) < 0.000_001)
        #expect(zip(plan.riseDelays, [0.2, 0.4, 0.6, 0.8]).allSatisfy { actualValue, expectedValue in
            abs(actualValue - expectedValue) < 0.000_001
        })
        #expect(zip(plan.returnDelays, [1.2, 1.4, 1.6, 1.8]).allSatisfy { actualValue, expectedValue in
            abs(actualValue - expectedValue) < 0.000_001
        })
        #expect(plan.deglowDelay == 2)
        #expect(AppleMusicLyrics.WordEmphasisPlan.deglowSpringMass == 1)
        #expect(AppleMusicLyrics.WordEmphasisPlan.deglowSpringStiffness == 14)
        #expect(AppleMusicLyrics.WordEmphasisPlan.deglowSpringDamping == 7)
    }

    @Test func synchronizedScheduleClampsTheSpringPeriodAndGlyphStagger() throws {
        let plan = try #require(AppleMusicLyrics.WordEmphasisPlan.make(
            wordDuration: 10,
            wordLength: 1,
            renderedGlyphCount: 1,
            timingGlyphCount: 1,
            languageIdentifier: "en"
        ))

        #expect(plan.springPeriod == 3)
        #expect(plan.glyphStagger == 0.4)
        #expect(plan.riseDelays == [0.4])
        #expect(abs((plan.returnDelays.first ?? 0) - 20.4) < 0.000_001)
    }

    /// The full-emphasis policy is where the legacy inline-tag look lives now:
    /// every phrase at factor 1, no leading stagger, whatever the language.
    @Test func inferredTimingKeepsTheEstablishedPhraseFallbackUnderTheFullEmphasisPolicy() throws {
        let plan = try #require(AppleMusicLyrics.WordEmphasisPlan.make(
            wordDuration: 2,
            wordLength: 1,
            renderedGlyphCount: 1,
            timingGlyphCount: 4,
            languageIdentifier: "zh-Hant",
            structuredEmphasisPolicy: .fullEmphasis
        ))

        #expect(plan.factor == 1)
        #expect(plan.riseDelays == [0])
        #expect(plan.returnDelays == [1])
    }

    /// By default an inline-tag segment is judged exactly like a structured
    /// word: Kugou's held "stay" (1.461 s, four letters, English) swells by
    /// `min(1.461, 2) - 1`, a `zh` segment never does, a short one never does.
    @Test func inferredTimingFollowsMusicsGateByDefault() throws {
        let heldEnglish = try #require(AppleMusicLyrics.WordEmphasisPlan.make(
            wordDuration: 1.461,
            wordLength: 4,
            renderedGlyphCount: 4,
            timingGlyphCount: 4,
            languageIdentifier: "en"
        ))
        #expect(abs(heldEnglish.factor - 0.461) < 0.000_001)
        #expect(heldEnglish.riseDelays.first == heldEnglish.glyphStagger, "the first glyph waits one stagger, as Music schedules it")

        #expect(AppleMusicLyrics.WordEmphasisPlan.make(
            wordDuration: 2,
            wordLength: 1,
            renderedGlyphCount: 1,
            timingGlyphCount: 1,
            languageIdentifier: "zh-Hant"
        ) == nil, "zh has no emphasis capability, so its segments only lift")

        #expect(AppleMusicLyrics.WordEmphasisPlan.make(
            wordDuration: 0.574,
            wordLength: 4,
            renderedGlyphCount: 5,
            timingGlyphCount: 5,
            languageIdentifier: "en"
        ) == nil, "a segment under a second only lifts")
    }

    @Test(arguments: ["zh-Hans", "ja-JP", "en-US"])
    func fullEmphasisPolicyGivesStructuredWordsTheInlineFallbackLook(languageIdentifier: String) throws {
        let plan = try #require(AppleMusicLyrics.WordEmphasisPlan.make(
            wordDuration: 0.4,
            wordLength: 2,
            renderedGlyphCount: 2,
            timingGlyphCount: 2,
            languageIdentifier: languageIdentifier,
            structuredEmphasisPolicy: .fullEmphasis
        ))

        #expect(plan.factor == 1)
        #expect(abs(plan.scale - 1.14) < 0.000_001)
        #expect(abs(plan.glowOpacity - 0.4) < 0.000_001)
        #expect(plan.riseDelays.first == 0, "the full-emphasis look drops Apple Music's leading stagger")
        #expect(abs((plan.riseDelays.last ?? 0) - plan.glyphStagger) < 0.000_001)
    }

    @Test func structuredEmphasisPolicyDefaultsToAppleMusicAndFollowsTheHiddenKey() throws {
        let suiteName = "AnimationPlanTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        #expect(AppleMusicLyrics.StructuredEmphasisPolicy.resolve(from: userDefaults) == .appleMusic26)

        userDefaults.set("fullEmphasis", forKey: AppleMusicLyrics.StructuredEmphasisPolicy.userDefaultsKey)
        #expect(AppleMusicLyrics.StructuredEmphasisPolicy.resolve(from: userDefaults) == .fullEmphasis)

        userDefaults.set("somethingElse", forKey: AppleMusicLyrics.StructuredEmphasisPolicy.userDefaultsKey)
        #expect(AppleMusicLyrics.StructuredEmphasisPolicy.resolve(from: userDefaults) == .appleMusic26)
    }

    @Test func cascadeVariantDefaultsToAppleMusicAndFollowsTheHiddenKey() throws {
        let suiteName = "AnimationPlanTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        #expect(AppleMusicLyrics.LineCascadeVariant.resolve(from: userDefaults) == .appleMusic26)

        userDefaults.set("legacySwiftUI", forKey: AppleMusicLyrics.LineCascadeVariant.userDefaultsKey)
        #expect(AppleMusicLyrics.LineCascadeVariant.resolve(from: userDefaults) == .legacySwiftUI)

        userDefaults.set("somethingElse", forKey: AppleMusicLyrics.LineCascadeVariant.userDefaultsKey)
        #expect(AppleMusicLyrics.LineCascadeVariant.resolve(from: userDefaults) == .appleMusic26)
    }

    @Test func relativeLineAnchorPlacesTheFirstBaselineAtFortyPercent() {
        let visibleHeight: CGFloat = 800
        let firstBaselineOffset: CGFloat = 60
        let topInset = AppleMusicLyrics.LineTransitionPlan.selectedLineTopInset(
            visibleHeight: visibleHeight,
            firstBaselineOffset: firstBaselineOffset
        )

        #expect(abs(topInset + firstBaselineOffset - visibleHeight * 0.4) < 0.000_001)
    }

    @Test func blurPlanOnlyIncludesContextuallyVisibleNonselectedLines() {
        let plan = AppleMusicLyrics.LineBlurPlan.make(
            visibleLinePositions: [2, 3, 4],
            selectedLinePosition: 3
        )
        #expect(plan.blurredLinePositions == [2, 4])
        #expect(plan.radius == AppleMusicLyrics.LyricsSpecs.deselectedLineBlurRadius)

        let noSelectionPlan = AppleMusicLyrics.LineBlurPlan.make(
            visibleLinePositions: [2, 3, 4],
            selectedLinePosition: nil
        )
        #expect(noSelectionPlan.blurredLinePositions.isEmpty)
        #expect(noSelectionPlan.radius == 0)
    }

    @Test func structuredKaraokeUsesExplicitSyllableEnds() {
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: [
                .init(
                    characterRange: 0 ..< 3,
                    timeRange: 0 ..< 1,
                    syllables: [.init(characterRange: 0 ..< 3, timeRange: 0 ..< 1)]
                ),
                .init(
                    characterRange: 3 ..< 6,
                    timeRange: 1.5 ..< 3,
                    syllables: [.init(characterRange: 3 ..< 6, timeRange: 1.5 ..< 3)]
                ),
            ],
            duration: 3
        )

        let halfwayThroughFirstWord = AppleMusicLyrics.KaraokeFill.fraction(
            elapsedTime: 0.5,
            lineDuration: 3,
            wordTimings: [],
            synchronizedTextTiming: timing,
            totalCharacterCount: 6,
            mode: .characterLevel
        )
        let betweenWords = AppleMusicLyrics.KaraokeFill.fraction(
            elapsedTime: 1.25,
            lineDuration: 3,
            wordTimings: [],
            synchronizedTextTiming: timing,
            totalCharacterCount: 6,
            mode: .characterLevel
        )
        let halfwayThroughSecondWord = AppleMusicLyrics.KaraokeFill.fraction(
            elapsedTime: 2.25,
            lineDuration: 3,
            wordTimings: [],
            synchronizedTextTiming: timing,
            totalCharacterCount: 6,
            mode: .characterLevel
        )

        #expect(abs(halfwayThroughFirstWord - 0.25) < 0.000_001)
        #expect(abs(betweenWords - 0.5) < 0.000_001)
        #expect(abs(halfwayThroughSecondWord - 0.75) < 0.000_001)
    }

    /// A line-synced (plain LRC) line has no word timing, so Music lights the
    /// whole line the moment it becomes current. Sweeping it left to right
    /// across the gap to the next line read as word-by-word progress and
    /// trailed the singing (issue #205).
    @Test(arguments: [
        (-0.05, AppleMusicLyrics.KaraokeMode.characterLevel),
        (0, .characterLevel),
        (0.4, .characterLevel),
        (2, .characterLevel),
        (3.99, .characterLevel),
        (0.4, .wordLevel),
    ])
    func lineSyncedLyricsLightTheWholeLineAtOnce(
        elapsedTime: TimeInterval,
        mode: AppleMusicLyrics.KaraokeMode
    ) {
        let fraction = AppleMusicLyrics.KaraokeFill.fraction(
            elapsedTime: elapsedTime,
            lineDuration: 4,
            wordTimings: [],
            synchronizedTextTiming: nil,
            totalCharacterCount: 12,
            mode: mode
        )
        #expect(fraction == 1)
    }

    /// Two lines sharing a timestamp leave the earlier one a zero duration; a
    /// line-synced line is still lit while it is current.
    @Test func lineSyncedLyricsLightTheLineEvenWithoutADuration() {
        let fraction = AppleMusicLyrics.KaraokeFill.fraction(
            elapsedTime: 0,
            lineDuration: 0,
            wordTimings: [],
            synchronizedTextTiming: nil,
            totalCharacterCount: 12,
            mode: .characterLevel
        )
        #expect(fraction == 1)
    }

    /// Structured timing that does not fit the line is ignored, which leaves a
    /// line with no usable word timing: it lights like a line-synced line.
    @Test func structuredTimingThatDoesNotFitTheLineLightsTheWholeLine() {
        let mismatchedTiming = LyricsLine.Attachments.SynchronizedTextTiming(
            words: [
                .init(
                    characterRange: 0 ..< 40,
                    timeRange: 0 ..< 3,
                    syllables: [.init(characterRange: 0 ..< 40, timeRange: 0 ..< 3)]
                ),
            ],
            duration: 3
        )
        #expect(!mismatchedTiming.isValid(forCharacterCount: 6))

        let fraction = AppleMusicLyrics.KaraokeFill.fraction(
            elapsedTime: 0.5,
            lineDuration: 3,
            wordTimings: [],
            synchronizedTextTiming: mismatchedTiming,
            totalCharacterCount: 6,
            mode: .characterLevel
        )
        #expect(fraction == 1)
    }

    /// Inline `[tt]` timing keeps its per-word sweep: a quarter of the way
    /// through the text at the first word's midpoint.
    @Test func inlineTagLyricsStillSweepWordByWord() {
        let fraction = AppleMusicLyrics.KaraokeFill.fraction(
            elapsedTime: 1,
            lineDuration: 4,
            wordTimings: [
                .init(characterIndex: 0, timeOffset: 0),
                .init(characterIndex: 6, timeOffset: 2),
            ],
            synchronizedTextTiming: nil,
            totalCharacterCount: 12,
            mode: .characterLevel
        )
        #expect(abs(fraction - 0.25) < 0.000_001)
    }
}

@MainActor
struct StructuredLineTextLayoutTests {
    @Test func exactWordsAndSyllablesOwnTheirGlyphs() throws {
        let content = "Hello"
        let attributedString = NSAttributedString(
            string: content,
            attributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold)]
        )
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: [
                .init(
                    characterRange: 0 ..< 5,
                    timeRange: 0 ..< 2,
                    syllables: [
                        .init(characterRange: 0 ..< 3, timeRange: 0 ..< 0.5),
                        .init(characterRange: 3 ..< 5, timeRange: 0.5 ..< 2),
                    ]
                ),
            ],
            duration: 2
        )

        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: attributedString,
            content: content,
            wordTimings: [],
            synchronizedTextTiming: timing,
            languageIdentifier: "en-US",
            lineDuration: 2,
            textWidth: 400
        ))
        let word = try #require(layout.words.first)

        #expect(layout.words.count == 1)
        #expect(word.timingSource == .synchronized)
        #expect(word.characterRange == 0 ..< 5)
        #expect(word.syllables.count == 2)
        #expect(word.syllables.flatMap(\.glyphIndices).count == word.glyphs.count)
        #expect(word.emphasisDuration == 2)
        #expect(word.emphasisGlyphCount == word.glyphs.count)
        #expect(layout.languageIdentifier == "en-US")
    }

    @Test func consecutiveRapidFallbackWordsShareOneMotionEnvelope() throws {
        let rapidLineContent = "You say you say what I should do"
        let attributedString = NSAttributedString(
            string: rapidLineContent,
            attributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold)]
        )
        let expectedPhraseDuration: TimeInterval = 1.29
        let wordTimings = [
            AppleMusicLyrics.WordTimingEntry(characterIndex: 0, timeOffset: 0),
            AppleMusicLyrics.WordTimingEntry(characterIndex: 4, timeOffset: 0.16),
            AppleMusicLyrics.WordTimingEntry(characterIndex: 8, timeOffset: 0.31),
            AppleMusicLyrics.WordTimingEntry(characterIndex: 12, timeOffset: 0.45),
            AppleMusicLyrics.WordTimingEntry(characterIndex: 16, timeOffset: 0.60),
            AppleMusicLyrics.WordTimingEntry(characterIndex: 21, timeOffset: 0.75),
            AppleMusicLyrics.WordTimingEntry(characterIndex: 23, timeOffset: 0.90),
            AppleMusicLyrics.WordTimingEntry(characterIndex: 30, timeOffset: 1.12),
        ]

        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: attributedString,
            content: rapidLineContent,
            wordTimings: wordTimings,
            lineDuration: expectedPhraseDuration,
            textWidth: 800
        ))
        let expectedGlyphCount = layout.words.reduce(0) { partialCount, word in
            partialCount + word.glyphs.count
        }

        #expect(layout.words.count == wordTimings.count)
        #expect(layout.words.allSatisfy { word in
            abs(word.emphasisDuration - expectedPhraseDuration) < 0.000_001
        })
        #expect(layout.words.allSatisfy { word in
            word.emphasisGlyphCount == expectedGlyphCount
        })
    }

    @Test func isolatedRapidFallbackWordsKeepTheirOwnMotionEnvelopes() throws {
        let lineContent = "Go now"
        let attributedString = NSAttributedString(
            string: lineContent,
            attributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold)]
        )
        let wordTimings = [
            AppleMusicLyrics.WordTimingEntry(characterIndex: 0, timeOffset: 0),
            AppleMusicLyrics.WordTimingEntry(characterIndex: 3, timeOffset: 0.18),
        ]
        let expectedDurations: [TimeInterval] = [0.18, 0.22]

        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: attributedString,
            content: lineContent,
            wordTimings: wordTimings,
            lineDuration: 0.4,
            textWidth: 400
        ))

        #expect(layout.words.count == expectedDurations.count)
        #expect(
            zip(layout.words.map(\.emphasisDuration), expectedDurations)
                .allSatisfy { actualDuration, expectedDuration in
                    abs(actualDuration - expectedDuration) < 0.000_001
                }
        )
    }

    @Test func rapidStructuredWordsKeepTheirExactAppleMusicEnvelopes() throws {
        let lineContent = "ABC"
        let attributedString = NSAttributedString(
            string: lineContent,
            attributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold)]
        )
        let synchronizedTextTiming = LyricsLine.Attachments.SynchronizedTextTiming(
            words: [
                .init(characterRange: 0 ..< 1, timeRange: 0.0 ..< 0.2),
                .init(characterRange: 1 ..< 2, timeRange: 0.2 ..< 0.4),
                .init(characterRange: 2 ..< 3, timeRange: 0.4 ..< 0.6),
            ],
            duration: 0.6
        )

        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: attributedString,
            content: lineContent,
            wordTimings: [],
            synchronizedTextTiming: synchronizedTextTiming,
            lineDuration: 0.6,
            textWidth: 400
        ))

        #expect(layout.words.count == synchronizedTextTiming.words.count)
        #expect(layout.words.allSatisfy { word in
            word.timingSource == .synchronized
                && abs(word.emphasisDuration - 0.2) < 0.000_001
        })
    }
}
