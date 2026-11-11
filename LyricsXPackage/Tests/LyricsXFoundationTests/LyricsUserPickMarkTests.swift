import Foundation
import Testing
@testable import LyricsXFoundation

private let plainLyricsFile = """
[ti:Song Title]
[ar:Song Artist]
[by:Kugou]
[00:01.00]First line
[00:05.50]Second line
"""

/// The mark's entire value is that it survives being written to disk and read
/// back — a mark that does not round-trip through `.lrcx` would leave every
/// hand-picked file looking automatic on the very next play.
@Test
func theUserPickMarkSurvivesSerializationAndReparsing() throws {
    let lyrics = try #require(Lyrics(plainLyricsFile))
    #expect(!lyrics.isUserPicked)

    lyrics.markAsUserPicked(origin: .searchPanel)
    let reparsedLyrics = try #require(Lyrics(lyrics.description))

    #expect(reparsedLyrics.isUserPicked)
    #expect(reparsedLyrics.idTags[.userPick] == LyricsUserPickOrigin.searchPanel.rawValue)
}

/// Marking must not disturb the file it marks: the lyrics lines and every tag
/// already in the file have to come back unchanged.
@Test
func markingLeavesTheLyricsLinesAndOtherTagsUntouched() throws {
    let lyrics = try #require(Lyrics(plainLyricsFile))
    lyrics.markAsUserPicked(origin: .import)
    let reparsedLyrics = try #require(Lyrics(lyrics.description))

    #expect(reparsedLyrics.lines.map(\.content) == ["First line", "Second line"])
    #expect(reparsedLyrics.lines.map(\.position) == [1.0, 5.5])
    #expect(reparsedLyrics.idTags[.title] == "Song Title")
    #expect(reparsedLyrics.idTags[.artist] == "Song Artist")
    #expect(reparsedLyrics.idTags[.lrcBy] == "Kugou")
}

/// Every origin has to produce a mark that reads back as one. The origin is
/// diagnostic only, so a new case must never be able to change the verdict.
@Test(arguments: LyricsUserPickOrigin.allCases)
func everyOriginProducesAReadableMark(origin: LyricsUserPickOrigin) throws {
    let lyrics = try #require(Lyrics(plainLyricsFile))
    lyrics.markAsUserPicked(origin: origin)
    let reparsedLyrics = try #require(Lyrics(lyrics.description))

    #expect(reparsedLyrics.isUserPicked)
    #expect(reparsedLyrics.idTags[.userPick] == origin.rawValue)
}

/// A file written by a later release may carry an origin this build has never
/// heard of. It still came from a person, so it still counts.
@Test
func anUnknownOriginStillCountsAsAHandMadeChoice() throws {
    let lyrics = try #require(Lyrics("[lxpick:some-future-entry-point]\n" + plainLyricsFile))
    #expect(lyrics.isUserPicked)
}

/// The lookup consults the mark on files it just read off disk, where an
/// unmarked file must be discarded while the bypass switch is on. A tag with no
/// value is what a truncated or hand-edited file looks like, and it is not a
/// choice anyone made.
@Test
func aFileWithNoMarkOrAnEmptyMarkIsNotUserPicked() throws {
    let unmarkedLyrics = try #require(Lyrics(plainLyricsFile))
    #expect(!unmarkedLyrics.isUserPicked)

    let emptyMarkLyrics = try #require(Lyrics("[lxpick:]\n" + plainLyricsFile))
    #expect(!emptyMarkLyrics.isUserPicked)
}

/// Marking twice is what a user re-picking lyrics for the same track does. The
/// second mark has to win, so the recorded origin describes the most recent
/// deliberate act rather than the first one ever made.
@Test
func remarkingReplacesTheRecordedOrigin() throws {
    let lyrics = try #require(Lyrics(plainLyricsFile))
    lyrics.markAsUserPicked(origin: .searchPanel)
    lyrics.markAsUserPicked(origin: .nextCandidate)
    let reparsedLyrics = try #require(Lyrics(lyrics.description))

    #expect(reparsedLyrics.idTags[.userPick] == LyricsUserPickOrigin.nextCandidate.rawValue)
    #expect(reparsedLyrics.isUserPicked)
}

/// The edit entry point pre-seeds a brand new file with nothing but the mark
/// line. That is only safe because such a file does not parse as lyrics: if it
/// did, an empty file the user abandoned would win the lookup over a real
/// search result.
@Test
func aFileHoldingOnlyTheMarkLineDoesNotParseAsLyrics() {
    for origin in LyricsUserPickOrigin.allCases {
        #expect(Lyrics(Lyrics.userPickMarkLine(origin: origin)) == nil)
    }
}

/// The pre-seeded line has to be the same tag the reader looks for — spelling
/// it by hand in the edit path is exactly how the two would drift apart.
@Test
func theMarkLineParsesBackAsTheMark() throws {
    let markedFile = Lyrics.userPickMarkLine(origin: .edit) + plainLyricsFile
    let lyrics = try #require(Lyrics(markedFile))

    #expect(lyrics.isUserPicked)
    #expect(lyrics.idTags[.userPick] == LyricsUserPickOrigin.edit.rawValue)
}
