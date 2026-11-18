import Foundation
import Testing
@testable import LyricsXFoundation

private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

@Test
func aRecordedSelectionReadsBackAsItsFilePath() {
    let table = LyricsSelectionOverrideTable.recording(
        filePath: "/Users/someone/Music/LyricsX/Title - Artist.lrcx",
        forTrackId: "track-1",
        in: [:],
        at: referenceDate
    )

    #expect(
        LyricsSelectionOverrideTable.filePath(forTrackId: "track-1", in: table)
            == "/Users/someone/Music/LyricsX/Title - Artist.lrcx"
    )
    #expect(LyricsSelectionOverrideTable.filePath(forTrackId: "track-2", in: table) == nil)
}

@Test
func recordingTwiceForOneTrackKeepsOnlyTheLatestPick() {
    var table = LyricsSelectionOverrideTable.recording(
        filePath: "/first.lrcx",
        forTrackId: "track-1",
        in: [:],
        at: referenceDate
    )
    table = LyricsSelectionOverrideTable.recording(
        filePath: "/second.lrcx",
        forTrackId: "track-1",
        in: table,
        at: referenceDate.addingTimeInterval(60)
    )

    #expect(table.count == 1)
    #expect(LyricsSelectionOverrideTable.filePath(forTrackId: "track-1", in: table) == "/second.lrcx")
}

@Test
func aPathContainingTheFieldSeparatorSurvivesTheRoundTrip() {
    // Tab is legal in a POSIX filename; splitting on the last separator or
    // trimming would corrupt such a path.
    let awkwardPath = "/Users/someone/Music/od\td - Artist.lrcx"
    let table = LyricsSelectionOverrideTable.recording(
        filePath: awkwardPath,
        forTrackId: "track-1",
        in: [:],
        at: referenceDate
    )

    #expect(LyricsSelectionOverrideTable.filePath(forTrackId: "track-1", in: table) == awkwardPath)
}

@Test
func aLegacyEntryWithoutATimestampStillReadsAsAPath() {
    let table = ["track-1": "/hand-written.lrcx"]

    #expect(LyricsSelectionOverrideTable.filePath(forTrackId: "track-1", in: table) == "/hand-written.lrcx")
}

@Test
func removingATrackDropsItsEntry() {
    let table = LyricsSelectionOverrideTable.recording(
        filePath: "/only.lrcx",
        forTrackId: "track-1",
        in: [:],
        at: referenceDate
    )

    #expect(LyricsSelectionOverrideTable.removing(trackId: "track-1", from: table).isEmpty)
}

@Test
func pastTheCeilingTheOldestEntriesAreTheOnesDropped() {
    var table: [String: String] = [:]
    // One entry per second, oldest first, up to one past the ceiling.
    for entryIndex in 0 ... LyricsSelectionOverrideTable.entryLimit {
        table = LyricsSelectionOverrideTable.recording(
            filePath: "/lyrics-\(entryIndex).lrcx",
            forTrackId: "track-\(entryIndex)",
            in: table,
            at: referenceDate.addingTimeInterval(TimeInterval(entryIndex))
        )
    }

    #expect(table.count == LyricsSelectionOverrideTable.trimmedEntryCount)
    // The newest survives, the oldest does not.
    #expect(LyricsSelectionOverrideTable.filePath(
        forTrackId: "track-\(LyricsSelectionOverrideTable.entryLimit)",
        in: table
    ) != nil)
    #expect(LyricsSelectionOverrideTable.filePath(forTrackId: "track-0", in: table) == nil)
}

@Test
func stayingUnderTheCeilingNeverTrims() {
    var table: [String: String] = [:]
    for entryIndex in 0 ..< LyricsSelectionOverrideTable.entryLimit {
        table = LyricsSelectionOverrideTable.recording(
            filePath: "/lyrics-\(entryIndex).lrcx",
            forTrackId: "track-\(entryIndex)",
            in: table,
            at: referenceDate.addingTimeInterval(TimeInterval(entryIndex))
        )
    }

    #expect(table.count == LyricsSelectionOverrideTable.entryLimit)
}

// MARK: - Picks of any local source

private let embeddedPickTrackId = "track-embedded"
private let libraryFile = URL(fileURLWithPath: "/Users/someone/Music/LyricsX/Title - Artist.lrcx")
private let besideTrackFile = URL(fileURLWithPath: "/Users/someone/Music/Album/Title.lrc")

@Test
func theEmbeddedLyricsReadBackAsTheEmbeddedLyrics() {
    let table = LyricsSelectionOverrideTable.recording(
        .embedded,
        forTrackId: "track-1",
        in: [:],
        at: referenceDate
    )

    #expect(LyricsSelectionOverrideTable.selection(forTrackId: "track-1", in: table) == .embedded)
    // Not a file, so nothing that reads paths may take it for one.
    #expect(LyricsSelectionOverrideTable.filePath(forTrackId: "track-1", in: table) == nil)
}

@Test
func aFileReadsBackAsThatFile() {
    let table = LyricsSelectionOverrideTable.recording(
        .file(besideTrackFile),
        forTrackId: "track-1",
        in: [:],
        at: referenceDate
    )

    #expect(LyricsSelectionOverrideTable.selection(forTrackId: "track-1", in: table) == .file(besideTrackFile))
    #expect(LyricsSelectionOverrideTable.filePath(forTrackId: "track-1", in: table) == besideTrackFile.path)
}

@Test
func aPathEntryWrittenBeforeTheEmbeddedLyricsCouldBePickedReadsBackAsAFile() {
    let table = ["track-1": "1700000000.0\t/Users/someone/Music/LyricsX/Title - Artist.lrcx"]

    #expect(LyricsSelectionOverrideTable.selection(forTrackId: "track-1", in: table) == .file(libraryFile))
}

/// With "load lyrics beside the track" off — the default — the lookup never
/// reads the embedded lyrics, so a pick of them has to be written down or the
/// next play shows the library copy or a search result instead.
@Test(arguments: [LocalLyricsSource.file(libraryFile), nil])
func pickingTheEmbeddedLyricsIsRememberedWhenTheLookupWouldShowSomethingElse(
    automaticLookupResult: LocalLyricsSource?
) {
    let table = LyricsSelectionOverrideTable.remembering(
        .embedded,
        forTrackId: embeddedPickTrackId,
        automaticLookupResult: automaticLookupResult,
        in: [:],
        at: referenceDate
    )

    #expect(LyricsSelectionOverrideTable.selection(forTrackId: embeddedPickTrackId, in: table) == .embedded)
}

@Test
func pickingTheEmbeddedLyricsTheLookupReadsFirstLeavesNoEntry() {
    let earlierPick = LyricsSelectionOverrideTable.recording(
        .file(besideTrackFile),
        forTrackId: embeddedPickTrackId,
        in: [:],
        at: referenceDate
    )

    let table = LyricsSelectionOverrideTable.remembering(
        .embedded,
        forTrackId: embeddedPickTrackId,
        automaticLookupResult: .embedded,
        in: earlierPick,
        at: referenceDate.addingTimeInterval(60)
    )

    #expect(LyricsSelectionOverrideTable.selection(forTrackId: embeddedPickTrackId, in: table) == nil)
}

/// A file picked from the Local Lyrics menu, then a search result picked
/// in the search panel and saved to the library: the earlier entry must not
/// outlive the later pick, or the next play goes back to the earlier file.
@Test
func aPickTheLookupShowsOnItsOwnDropsAnEarlierPick() {
    let earlierPick = LyricsSelectionOverrideTable.recording(
        .file(besideTrackFile),
        forTrackId: "track-1",
        in: [:],
        at: referenceDate
    )

    let table = LyricsSelectionOverrideTable.remembering(
        .file(libraryFile),
        forTrackId: "track-1",
        automaticLookupResult: .file(libraryFile),
        in: earlierPick,
        at: referenceDate.addingTimeInterval(60)
    )

    #expect(table.isEmpty)
}

@Test(arguments: [LocalLyricsSource.embedded, .file(besideTrackFile), nil])
func aPickTheLookupWouldNotReachIsRecorded(automaticLookupResult: LocalLyricsSource?) {
    let table = LyricsSelectionOverrideTable.remembering(
        .file(libraryFile),
        forTrackId: "track-1",
        automaticLookupResult: automaticLookupResult,
        in: [:],
        at: referenceDate
    )

    #expect(LyricsSelectionOverrideTable.selection(forTrackId: "track-1", in: table) == .file(libraryFile))
}

@Test
func aLaterPickReplacesAnEarlierOne() {
    let earlierPick = LyricsSelectionOverrideTable.remembering(
        .embedded,
        forTrackId: "track-1",
        automaticLookupResult: nil,
        in: [:],
        at: referenceDate
    )

    let table = LyricsSelectionOverrideTable.remembering(
        .file(besideTrackFile),
        forTrackId: "track-1",
        automaticLookupResult: .file(libraryFile),
        in: earlierPick,
        at: referenceDate.addingTimeInterval(60)
    )

    #expect(LyricsSelectionOverrideTable.selection(forTrackId: "track-1", in: table) == .file(besideTrackFile))
}

@Test
func theSameFileSpelledDifferentlyCountsAsWhatTheLookupShows() {
    let spelledWithDots = URL(fileURLWithPath: "/Users/someone/Music/LyricsX/./Title - Artist.lrcx")

    let table = LyricsSelectionOverrideTable.remembering(
        .file(spelledWithDots),
        forTrackId: "track-1",
        automaticLookupResult: .file(libraryFile),
        in: ["track-1": "1700000000.0\t/elsewhere.lrcx"],
        at: referenceDate
    )

    #expect(table.isEmpty)
}
