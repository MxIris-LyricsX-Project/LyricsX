import Testing
@testable import LyricsXFoundation

// The search panel's preview lights each character of the playing line when
// its inline time tag says it starts being sung, so that the tags can be
// checked against the song character by character. Nothing is interpolated:
// a word tagged at its first letter starts as a whole.

private typealias InlineTimeTag = LyricsLine.Attachments.InlineTimeTag
private typealias Tag = InlineTimeTag.Tag

/// "Let it go" sung word by word from 12 s into the song: "Let " at 0,
/// "it " at 0.5 s, "go" at 1 s, the line lasting 2 s.
private func letItGoOnsets(duration: TimeInterval? = 2) -> KaraokeCharacterOnsets? {
    KaraokeCharacterOnsets(
        lineStart: 12,
        characterCount: 9,
        timeTag: InlineTimeTag(tags: [Tag(index: 0, time: 0), Tag(index: 4, time: 0.5), Tag(index: 7, time: 1)], duration: duration)
    )
}

@Test
func aLineWithoutInlineTimeTagsHasNoCharacterOnsets() {
    let line = LyricsLine(content: "Let it go", position: 12)

    #expect(KaraokeCharacterOnsets(line: line) == nil)
}

@Test
func everyCharacterBetweenTwoTagsStartsWithTheEarlierTag() throws {
    let onsets = try #require(letItGoOnsets())

    #expect(onsets.onsetTimes == [0, 0, 0, 0, 0.5, 0.5, 0.5, 1, 1])
}

@Test
func theCharactersAfterTheLastTagStartWithItWithoutADuration() throws {
    let onsets = try #require(letItGoOnsets(duration: nil))

    #expect(onsets.onsetTimes == [0, 0, 0, 0, 0.5, 0.5, 0.5, 1, 1])
}

@Test
func aCharacterCountsAsStartedFromItsOnsetOn() throws {
    let onsets = try #require(letItGoOnsets())

    #expect(onsets.startedCharacterCount(atLyricsTime: 11.9) == 0)
    #expect(onsets.startedCharacterCount(atLyricsTime: 12) == 4)
    #expect(onsets.startedCharacterCount(atLyricsTime: 12.49) == 4)
    #expect(onsets.startedCharacterCount(atLyricsTime: 12.5) == 7)
    #expect(onsets.startedCharacterCount(atLyricsTime: 13) == 9)
    #expect(onsets.startedCharacterCount(atLyricsTime: 20) == 9)
}

@Test
func theNextOnsetIsTheNextCharacterToStartInLyricsTime() throws {
    let onsets = try #require(letItGoOnsets())

    #expect(onsets.nextOnset(afterLyricsTime: 11) == 12)
    #expect(onsets.nextOnset(afterLyricsTime: 12) == 12.5)
    #expect(onsets.nextOnset(afterLyricsTime: 12.7) == 13)
    #expect(onsets.nextOnset(afterLyricsTime: 13) == nil)
}

@Test
func oneTagPerCharacterStartsEachCharacterAtItsOwnTag() throws {
    // 听到我 — a Chinese line from a word-by-word source, one tag per character.
    var line = LyricsLine(content: "听到我", position: 30)
    line.attachments.timetag = InlineTimeTag(
        tags: [Tag(index: 0, time: 0), Tag(index: 1, time: 0.3), Tag(index: 2, time: 0.55)],
        duration: 1.2
    )

    let onsets = try #require(KaraokeCharacterOnsets(line: line))

    #expect(onsets.lineStart == 30)
    #expect(onsets.onsetTimes == [0, 0.3, 0.55])
    #expect(onsets.startedCharacterCount(atLyricsTime: 30.3) == 2)
}

@Test
func tagsOutOfOrderAreReadInOrderOfTime() throws {
    let onsets = try #require(KaraokeCharacterOnsets(
        lineStart: 0,
        characterCount: 3,
        timeTag: InlineTimeTag(tags: [Tag(index: 2, time: 0.6), Tag(index: 0, time: 0), Tag(index: 1, time: 0.3)])
    ))

    #expect(onsets.onsetTimes == [0, 0.3, 0.6])
}

@Test
func aTagRepeatingAnIndexStartsThatCharacterWhenTheSungPartMovesOn() throws {
    // The second tag at index 1 holds the line still until 0.9 s; the
    // character then starts with it, as the desktop lyrics' fill does.
    let onsets = try #require(KaraokeCharacterOnsets(
        lineStart: 0,
        characterCount: 3,
        timeTag: InlineTimeTag(tags: [Tag(index: 0, time: 0), Tag(index: 1, time: 0.5), Tag(index: 1, time: 0.9), Tag(index: 2, time: 1.2)])
    ))

    #expect(onsets.onsetTimes == [0, 0.9, 1.2])
}

@Test
func untaggedCharactersBeforeTheFirstTagStartWithIt() throws {
    let onsets = try #require(KaraokeCharacterOnsets(
        lineStart: 0,
        characterCount: 4,
        timeTag: InlineTimeTag(tags: [Tag(index: 2, time: 0.4), Tag(index: 3, time: 0.8)])
    ))

    #expect(onsets.onsetTimes == [0.4, 0.4, 0.4, 0.8])
}

@Test
func tagsThatNeverMovePastOnePlaceGiveNoOnsets() {
    let onsets = KaraokeCharacterOnsets(
        lineStart: 0,
        characterCount: 3,
        timeTag: InlineTimeTag(tags: [Tag(index: 0, time: 0), Tag(index: 0, time: 1)])
    )

    #expect(onsets == nil)
}
