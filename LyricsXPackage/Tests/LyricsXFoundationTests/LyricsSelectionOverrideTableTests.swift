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
