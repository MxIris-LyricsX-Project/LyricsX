import Testing
@testable import LyricsXFoundation

// The menu bar's karaoke progress reads how much of a line is sung from its
// inline time tags, the way the desktop lyrics' progress animation does:
// linear between tags, held before the first and after the last, and filled
// to the end of the line when the line has a duration.

private typealias InlineTimeTag = LyricsLine.Attachments.InlineTimeTag
private typealias Tag = InlineTimeTag.Tag

/// "Let it go" sung word by word from 12 s into the song: "Let " at 0,
/// "it " at 0.5 s, "go" at 1 s, the line lasting 2 s.
private func letItGoTiming(duration: TimeInterval? = 2) -> KaraokeLineTiming? {
    KaraokeLineTiming(
        lineStart: 12,
        characterCount: 9,
        timeTag: InlineTimeTag(tags: [Tag(index: 0, time: 0), Tag(index: 4, time: 0.5), Tag(index: 7, time: 1)], duration: duration)
    )
}

@Test
func aLineWithoutInlineTimeTagsHasNoKaraokeTiming() {
    let line = LyricsLine(content: "Let it go", position: 12)

    #expect(KaraokeLineTiming(line: line) == nil)
}

@Test
func aLineWithInlineTimeTagsTakesItsPositionAndLength() throws {
    var line = LyricsLine(content: "Let it go", position: 12)
    line.attachments.timetag = InlineTimeTag(tags: [Tag(index: 0, time: 0), Tag(index: 4, time: 0.5)], duration: 2)

    let timing = try #require(KaraokeLineTiming(line: line))

    #expect(timing.lineStart == 12)
    #expect(timing.keyframes.last == KaraokeLineTiming.Keyframe(time: 2, sungCharacterCount: 9))
}

@Test
func theSungPartGrowsLinearlyBetweenTags() throws {
    let timing = try #require(letItGoTiming())

    #expect(timing.sungCharacterCount(atLyricsTime: 12) == 0)
    #expect(timing.sungCharacterCount(atLyricsTime: 12.25) == 2)
    #expect(timing.sungCharacterCount(atLyricsTime: 12.5) == 4)
    #expect(timing.sungCharacterCount(atLyricsTime: 12.75) == 5.5)
}

@Test
func theLastWordFillsOverTheRestOfTheLine() throws {
    let timing = try #require(letItGoTiming())

    // "go" starts at 1 s and the line ends at 2 s.
    #expect(timing.sungCharacterCount(atLyricsTime: 13.5) == 8)
    #expect(timing.sungCharacterCount(atLyricsTime: 14) == 9)
    #expect(timing.movingLyricsTimes == 12 ... 14)
}

@Test
func withoutADurationTheLineStopsAtItsLastTag() throws {
    // As on the desktop: nothing says when the last word ends.
    let timing = try #require(letItGoTiming(duration: nil))

    #expect(timing.sungCharacterCount(atLyricsTime: 13) == 7)
    #expect(timing.sungCharacterCount(atLyricsTime: 20) == 7)
    #expect(timing.movingLyricsTimes == 12 ... 13)
}

@Test
func theSungPartHoldsBeforeTheFirstTagAndAfterTheLast() throws {
    let timing = try #require(
        KaraokeLineTiming(
            lineStart: 30,
            characterCount: 6,
            timeTag: InlineTimeTag(tags: [Tag(index: 2, time: 0.4), Tag(index: 4, time: 0.8)], duration: 1.2)
        )
    )

    #expect(timing.sungCharacterCount(atLyricsTime: 0) == 2)
    #expect(timing.sungCharacterCount(atLyricsTime: 30.1) == 2)
    #expect(timing.sungCharacterCount(atLyricsTime: 99) == 6)
    #expect(timing.movingLyricsTimes == 30.4 ... 31.2)
}

@Test
func tagsOutOfOrderAreSortedByTime() throws {
    let timing = try #require(
        KaraokeLineTiming(
            lineStart: 0,
            characterCount: 9,
            timeTag: InlineTimeTag(tags: [Tag(index: 7, time: 1), Tag(index: 0, time: 0), Tag(index: 4, time: 0.5)], duration: 2)
        )
    )

    #expect(timing.keyframes.map(\.time) == [0, 0.5, 1, 2])
    #expect(timing.sungCharacterCount(atLyricsTime: 0.25) == 2)
}

@Test
func theSungPartNeverShrinks() throws {
    // A tag that points back into the line — malformed, or an index for the
    // text before a conversion changed its length — must not pull the sung
    // part back.
    let timing = try #require(
        KaraokeLineTiming(
            lineStart: 0,
            characterCount: 9,
            timeTag: InlineTimeTag(tags: [Tag(index: 0, time: 0), Tag(index: 6, time: 0.5), Tag(index: 3, time: 1)], duration: 2)
        )
    )

    #expect(timing.keyframes.map(\.sungCharacterCount) == [0, 6, 6, 9])
    #expect(timing.sungCharacterCount(atLyricsTime: 0.75) == 6)
}

@Test
func indicesAreKeptWithinTheLine() throws {
    let timing = try #require(
        KaraokeLineTiming(
            lineStart: 0,
            characterCount: 5,
            timeTag: InlineTimeTag(tags: [Tag(index: -3, time: 0), Tag(index: 40, time: 1)])
        )
    )

    #expect(timing.keyframes.map(\.sungCharacterCount) == [0, 5])
}

@Test
func tagsThatNeverMoveGiveNoTiming() {
    // One tag at the start and no duration: nothing would ever be sung.
    let timing = KaraokeLineTiming(
        lineStart: 0,
        characterCount: 9,
        timeTag: InlineTimeTag(tags: [Tag(index: 0, time: 0)])
    )

    #expect(timing == nil)
}

@Test
func tagsWithoutAFiniteTimeAreDropped() throws {
    let timing = try #require(
        KaraokeLineTiming(
            lineStart: 0,
            characterCount: 9,
            timeTag: InlineTimeTag(tags: [Tag(index: 0, time: 0), Tag(index: 4, time: .nan), Tag(index: 7, time: 1)])
        )
    )

    #expect(timing.keyframes.map(\.time) == [0, 1])
}

@Test
func twoTagsAtTheSameMomentJumpWithoutDividingByZero() throws {
    let timing = try #require(
        KaraokeLineTiming(
            lineStart: 0,
            characterCount: 9,
            timeTag: InlineTimeTag(tags: [Tag(index: 0, time: 0), Tag(index: 2, time: 0.5), Tag(index: 4, time: 0.5)], duration: 1)
        )
    )

    #expect(timing.sungCharacterCount(atLyricsTime: 0.5) == 4)
    #expect(timing.sungCharacterCount(atLyricsTime: 0.75) == 6.5)
}

@Test
func twoLinesWithTheSameTextAndRhythmAreStillDifferentLines() {
    // The menu bar restarts a scrolling line when its timing changes, which
    // is how a repeated line is told apart from the one before it.
    let first = KaraokeLineTiming(lineStart: 12, characterCount: 4, timeTag: InlineTimeTag(tags: [Tag(index: 0, time: 0)], duration: 1))
    let second = KaraokeLineTiming(lineStart: 13, characterCount: 4, timeTag: InlineTimeTag(tags: [Tag(index: 0, time: 0)], duration: 1))

    #expect(first != nil)
    #expect(first != second)
}
