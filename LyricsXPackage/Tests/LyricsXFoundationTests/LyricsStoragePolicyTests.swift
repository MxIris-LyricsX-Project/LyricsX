import Foundation
import Testing
@testable import LyricsXFoundation

private let defaultDirectoryURL = URL(fileURLWithPath: "/Users/tester/Music/LyricsX", isDirectory: true)
private let customDirectoryURL = URL(fileURLWithPath: "/Volumes/Media/Lyrics", isDirectory: true)

/// The saving-path pop-up holds four rows — default, user path, a separator and
/// "Other…" — so its selected index reaches 2 and 3. Choosing "Other…" leaves the
/// bound preference at 3 because the completion handler re-selects the user-path
/// row programmatically, which does not write back through the binding. Reads go
/// through `lyricsSavingPath()` (any non-zero index means custom), so writes have
/// to agree or lyrics land in a directory they are never read back from.
@Test
func everyNonDefaultSavingPathIndexResolvesToTheCustomDirectory() {
    for popUpIndex in [1, 2, 3] {
        let destination = LyricsStoragePolicy.destination(
            locationRawValue: popUpIndex,
            title: "Title",
            artist: "Artist",
            defaultDirectoryURL: defaultDirectoryURL,
            customDirectoryURL: customDirectoryURL
        )
        #expect(
            destination?.fileURL == customDirectoryURL.appendingPathComponent("Title - Artist.lrcx"),
            "pop-up index \(popUpIndex) should write to the custom directory"
        )
        #expect(destination?.securityScopedDirectoryURL == customDirectoryURL)
    }
}

@Test
func theDefaultSavingPathIndexResolvesToTheLyricsXDirectory() {
    let destination = LyricsStoragePolicy.destination(
        locationRawValue: 0,
        title: "Title",
        artist: "Artist",
        defaultDirectoryURL: defaultDirectoryURL,
        customDirectoryURL: customDirectoryURL
    )
    #expect(destination?.fileURL == defaultDirectoryURL.appendingPathComponent("Title - Artist.lrcx"))
    #expect(destination?.securityScopedDirectoryURL == nil)
}

@Test
func aNonDefaultIndexWithoutACustomDirectoryFallsBackToTheLyricsXDirectory() {
    let destination = LyricsStoragePolicy.destination(
        locationRawValue: 3,
        title: "Title",
        artist: "Artist",
        defaultDirectoryURL: defaultDirectoryURL,
        customDirectoryURL: nil
    )
    #expect(destination?.fileURL == defaultDirectoryURL.appendingPathComponent("Title - Artist.lrcx"))
    #expect(destination?.securityScopedDirectoryURL == nil)
}

/// A plain `.lrc` sitting in the library is still marked "needs searching" on
/// every load, so overwriting it in place means no `.lrcx` is ever produced and
/// the track is searched again on every play. Persist has to produce the LRCX
/// file next to it instead.
@Test
func persistingLibraryLyricsLoadedFromAPlainLRCWritesTheLRCXFile() {
    let libraryDestination = LyricsStorageDestination(
        fileURL: defaultDirectoryURL.appendingPathComponent("Title - Artist.lrcx"),
        securityScopedDirectoryURL: nil
    )
    let destination = LyricsStoragePolicy.persistDestination(
        localURL: defaultDirectoryURL.appendingPathComponent("Title - Artist.lrc"),
        allowUnmanagedLocalWriteBack: false,
        defaultDirectoryURL: defaultDirectoryURL,
        customDirectoryURL: customDirectoryURL,
        libraryDestination: libraryDestination
    )
    #expect(destination?.fileURL == libraryDestination.fileURL)
}

@Test
func persistingLibraryLyricsLoadedFromAnLRCXWritesBackToThatFile() {
    let legacyNameURL = defaultDirectoryURL.appendingPathComponent("Title - Artist (legacy).lrcx")
    let destination = LyricsStoragePolicy.persistDestination(
        localURL: legacyNameURL,
        allowUnmanagedLocalWriteBack: false,
        defaultDirectoryURL: defaultDirectoryURL,
        customDirectoryURL: customDirectoryURL,
        libraryDestination: LyricsStorageDestination(
            fileURL: defaultDirectoryURL.appendingPathComponent("Title - Artist.lrcx"),
            securityScopedDirectoryURL: nil
        )
    )
    #expect(destination?.fileURL == legacyNameURL)
}

/// Lyrics sitting next to the audio file belong to the user. Only the explicit
/// opt-in may rewrite them; without it persist has to fall back to the library.
@Test
func besideTrackLyricsAreOnlyRewrittenWhenTheUserOptsIn() {
    let besideTrackURL = URL(fileURLWithPath: "/Users/tester/Music/Album/Song.lrc")
    let libraryDestination = LyricsStorageDestination(
        fileURL: defaultDirectoryURL.appendingPathComponent("Title - Artist.lrcx"),
        securityScopedDirectoryURL: nil
    )

    let withoutOptIn = LyricsStoragePolicy.persistDestination(
        localURL: besideTrackURL,
        allowUnmanagedLocalWriteBack: false,
        defaultDirectoryURL: defaultDirectoryURL,
        customDirectoryURL: customDirectoryURL,
        libraryDestination: libraryDestination
    )
    #expect(withoutOptIn?.fileURL == libraryDestination.fileURL)

    let withOptIn = LyricsStoragePolicy.persistDestination(
        localURL: besideTrackURL,
        allowUnmanagedLocalWriteBack: true,
        defaultDirectoryURL: defaultDirectoryURL,
        customDirectoryURL: customDirectoryURL,
        libraryDestination: libraryDestination
    )
    #expect(withOptIn?.fileURL == besideTrackURL)
}
