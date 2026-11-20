import Foundation
import Testing
@testable import LyricsXFoundation

private let adjustedLyricsFile = """
[ti:无限]
[offset:-600]
[00:00.000]无限 - F.I.R.飞儿乐团
[00:12.720]In a small island
[00:12.720][tr:zh-Hans]某座小岛上
[00:13.410]People are still building there
[00:13.410][tt]<0,0><400,7><900,10><1500>
"""

/// A player that ignores `[offset:]` must still see the adjusted times, and a
/// player that reads it must not apply the offset a second time.
@Test
func theOffsetMovesIntoEveryLineTimeAndItsTagIsLeftOut() throws {
    let lyrics = try #require(Lyrics(adjustedLyricsFile))
    let written = try #require(Lyrics(lyrics.withOffsetInLineTimes.description))

    #expect(written.idTags[.offset] == nil)
    #expect(written.offset == 0)
    #expect(written.lines.map(\.timeTag) == ["00:00.600", "00:13.320", "00:14.010"])
    #expect(written.idTags[.title] == "无限")
}

/// Translations and word timings belong to their line: they move with it.
@Test
func attachmentsMoveWithTheirLine() throws {
    let lyrics = try #require(Lyrics(adjustedLyricsFile))
    let written = try #require(Lyrics(lyrics.withOffsetInLineTimes.description))

    #expect(written.lines[1].attachments.translation() == "某座小岛上")
    #expect(
        written.lines[2].attachments[.timetag] == lyrics.lines[2].attachments[.timetag]
    )
}

/// The lyrics on screen keep their own times: the panel and saved
/// translations recognise a line by them.
@Test
func theLyricsOnScreenKeepTheirTimesAndOffset() throws {
    let lyrics = try #require(Lyrics(adjustedLyricsFile))
    _ = lyrics.withOffsetInLineTimes

    #expect(lyrics.offset == -600)
    #expect(lyrics.lines.map(\.timeTag) == ["00:00.000", "00:12.720", "00:13.410"])
}

/// An offset that shows the lyrics earlier would put the opening lines before
/// the track starts; they wait at zero, still in order.
@Test
func aLinePushedBeforeTheStartWaitsAtZero() throws {
    let lyrics = try #require(Lyrics("[offset:800]\n[00:00.000]Title\n[00:00.500]Intro\n[00:02.000]Verse"))
    let written = try #require(Lyrics(lyrics.withOffsetInLineTimes.description))

    #expect(written.lines.map(\.timeTag) == ["00:00.000", "00:00.000", "00:01.200"])
    #expect(written.lines.map(\.content) == ["Title", "Intro", "Verse"])
}

/// Files beside a track are read by other players; LyricsX's own library
/// keeps the tag, because saved translations match a source's lines by time.
@Test
func onlyFilesOutsideTheLibraryGetTheOffsetInTheirLineTimes() {
    let library = URL(fileURLWithPath: "/Users/me/Music/LyricsX")
    let custom = URL(fileURLWithPath: "/Volumes/Lyrics")

    #expect(LyricsStoragePolicy.putsOffsetInLineTimes(
        savingTo: URL(fileURLWithPath: "/Users/me/Music/Album/Song.lrc"),
        defaultDirectoryURL: library,
        customDirectoryURL: custom
    ))
    #expect(!LyricsStoragePolicy.putsOffsetInLineTimes(
        savingTo: library.appendingPathComponent("Song - Artist.lrcx"),
        defaultDirectoryURL: library,
        customDirectoryURL: custom
    ))
    #expect(!LyricsStoragePolicy.putsOffsetInLineTimes(
        savingTo: custom.appendingPathComponent("Song - Artist.lrcx"),
        defaultDirectoryURL: library,
        customDirectoryURL: custom
    ))
}
