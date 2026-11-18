import Foundation
import Testing
@testable import LyricsXFoundation

private let besideTrackLRCX = URL(fileURLWithPath: "/Users/someone/Music/Album/Song.lrcx")
private let besideTrackLRC = URL(fileURLWithPath: "/Users/someone/Music/Album/Song.lrc")
private let libraryFile = URL(fileURLWithPath: "/Users/someone/Music/LyricsX/Song - Artist.lrcx")

private let everySource: [LocalLyricsSource] = [
    .embedded,
    .file(besideTrackLRCX),
    .file(besideTrackLRC),
    .file(libraryFile),
]

@Test
func lyricsReadFromAFileCheckThatFile() {
    for url in [besideTrackLRCX, besideTrackLRC, libraryFile] {
        #expect(
            LocalLyricsSource.onScreen(localURL: url, service: nil, isUserPicked: false, among: everySource)
                == .file(url)
        )
    }
}

/// A search result the user picked is saved before it is shown, so it carries
/// both its service and its file; the file is where it now lives.
@Test
func savedSearchResultsCheckTheirFile() {
    #expect(
        LocalLyricsSource.onScreen(localURL: libraryFile, service: "QQMusic", isUserPicked: true, among: everySource)
            == .file(libraryFile)
    )
}

@Test
func theSameFileSpelledDifferentlyStillMatches() {
    let spelledWithDots = URL(fileURLWithPath: "/Users/someone/Music/Album/./Song.lrcx")
    #expect(
        LocalLyricsSource.onScreen(localURL: spelledWithDots, service: nil, isUserPicked: false, among: everySource)
            == .file(besideTrackLRCX)
    )
}

@Test
func aFileTheMenuDoesNotListChecksNothing() {
    let otherFile = URL(fileURLWithPath: "/Users/someone/Music/LyricsX/Other - Artist.lrcx")
    #expect(LocalLyricsSource.onScreen(localURL: otherFile, service: nil, isUserPicked: false, among: everySource) == nil)
}

/// A file never stands for the embedded lyrics, even when the track has some.
@Test
func aFileIsNeverTakenForTheEmbeddedLyrics() {
    #expect(LocalLyricsSource.onScreen(localURL: libraryFile, service: nil, isUserPicked: false, among: [.embedded]) == nil)
}

@Test
func lyricsWithNeitherAFileNorAServiceCheckTheEmbeddedLyrics() {
    #expect(LocalLyricsSource.onScreen(localURL: nil, service: nil, isUserPicked: false, among: everySource) == .embedded)
}

@Test
func withoutEmbeddedLyricsListedFilelessLyricsCheckNothing() {
    #expect(
        LocalLyricsSource.onScreen(localURL: nil, service: nil, isUserPicked: false, among: [.file(libraryFile)]) == nil
    )
}

/// An unsaved search result is not any of the local sources yet.
@Test
func unsavedSearchResultsCheckNothing() {
    #expect(LocalLyricsSource.onScreen(localURL: nil, service: "NetEase", isUserPicked: false, among: everySource) == nil)
}

/// Imported lyrics have no file until the track changes and they are saved,
/// and the import marks them as picked by the user, which embedded lyrics
/// read by the lookup never are.
@Test
func importedLyricsAreNotTakenForTheEmbeddedLyrics() {
    #expect(LocalLyricsSource.onScreen(localURL: nil, service: nil, isUserPicked: true, among: everySource) == nil)
}
