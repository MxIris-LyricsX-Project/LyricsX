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

/// Editing a track that has no lyrics yet creates the file pre-seeded with the
/// user-pick mark, so that whatever the user types into it is recognized as a
/// hand-made choice on the next play.
@Test
func preparingAFileThatDoesNotExistWritesTheInitialContents() throws {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("LyricsStoragePolicyTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    let destination = LyricsStorageDestination(
        fileURL: directoryURL.appendingPathComponent("Title - Artist.lrcx"),
        securityScopedDirectoryURL: nil
    )
    let markLine = Lyrics.userPickMarkLine(origin: .edit)
    let fileURL = try LyricsStoragePolicy.prepareEmptyFile(at: destination, initialContents: markLine)

    #expect(fileURL == destination.fileURL)
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == markLine)
}

/// The same call on a file that already exists must leave it alone: it holds
/// the lyrics the user is about to edit, and seeding over them is data loss.
@Test
func preparingAFileThatAlreadyExistsLeavesItsContentsAlone() throws {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("LyricsStoragePolicyTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let fileURL = directoryURL.appendingPathComponent("Title - Artist.lrcx")
    let existingContents = "[00:01.00]Words the user already has\n"
    try Data(existingContents.utf8).write(to: fileURL, options: .atomic)

    let destination = LyricsStorageDestination(fileURL: fileURL, securityScopedDirectoryURL: nil)
    let preparedURL = try LyricsStoragePolicy.prepareEmptyFile(
        at: destination,
        initialContents: Lyrics.userPickMarkLine(origin: .edit)
    )

    #expect(preparedURL == fileURL)
    #expect(try String(contentsOf: preparedURL, encoding: .utf8) == existingContents)
}

@Test
func rejectingLyricsReadFromBesideATrackLeavesTheUsersFileAlone() {
    // "Wrong Lyrics" and "Disable Lyrics for Entire Album" delete the file
    // the rejected lyrics came from. A file beside the track is the user's own
    // — hand-made or bought — and the verdict must not destroy it.
    let besideTrackURL = URL(fileURLWithPath: "/Users/tester/Music/Album/Song.lrc")

    let fileToRemove = LyricsStoragePolicy.fileToRemoveWhenRejected(
        localURL: besideTrackURL,
        defaultDirectoryURL: defaultDirectoryURL,
        customDirectoryURL: customDirectoryURL
    )

    #expect(fileToRemove == nil)
}

@Test
func rejectingLyricsFromTheLibraryRemovesTheLibraryCopy() {
    for libraryFileURL in [
        defaultDirectoryURL.appendingPathComponent("Title - Artist.lrcx"),
        customDirectoryURL.appendingPathComponent("Title - Artist.lrcx"),
    ] {
        let fileToRemove = LyricsStoragePolicy.fileToRemoveWhenRejected(
            localURL: libraryFileURL,
            defaultDirectoryURL: defaultDirectoryURL,
            customDirectoryURL: customDirectoryURL
        )
        #expect(fileToRemove == libraryFileURL)
    }
}

@Test
func rejectingLyricsKeepsTheUsersOwnLyricsInMusic() {
    // With automatic writing on, rejecting lyrics also clears the track's
    // lyrics in Music. Lyrics the user typed there, or that came embedded in
    // the file, were never LyricsX's, and the verdict must not destroy them.
    let clears = LyricsStoragePolicy.clearsLyricsInMusicWhenRejected(
        lyricsInMusic: "Words I wrote myself\nThe second verse",
        contentsLyricsXWrote: ["Somebody else's song\nAnother line"]
    )

    #expect(!clears)
}

@Test
func rejectingLyricsKeepsLyricsXsTextOnceTheUserEditedIt() {
    // A line corrected by hand makes the text the user's.
    let clears = LyricsStoragePolicy.clearsLyricsInMusicWhenRejected(
        lyricsInMusic: "First line\nSecond line, corrected",
        contentsLyricsXWrote: ["First line\nSecond line"]
    )

    #expect(!clears)
}

@Test
func rejectingLyricsKeepsWhatMusicHoldsWhenLyricsXWroteNothingToCompare() {
    let clears = LyricsStoragePolicy.clearsLyricsInMusicWhenRejected(
        lyricsInMusic: "Words I wrote myself",
        contentsLyricsXWrote: []
    )

    #expect(!clears)
}

@Test(arguments: [nil, "", " \n\r\n "] as [String?])
func rejectingLyricsHasNothingToClearWhenMusicHoldsNoLyrics(lyricsInMusic: String?) {
    let clears = LyricsStoragePolicy.clearsLyricsInMusicWhenRejected(
        lyricsInMusic: lyricsInMusic,
        contentsLyricsXWrote: ["First line\nSecond line"]
    )

    #expect(!clears)
}

@Test
func rejectingLyricsTakesWhatLyricsXWroteBackOutOfMusic() {
    // What the clearing is for: automatic writing put the wrong lyrics into
    // Music, and rejecting them must not leave them there.
    let written = "First line\nFirst translation\nSecond line"

    let clears = LyricsStoragePolicy.clearsLyricsInMusicWhenRejected(
        lyricsInMusic: written,
        contentsLyricsXWrote: [written]
    )

    #expect(clears)
}

@Test
func rejectingLyricsTakesBackAnEarlierWriteOfThem() {
    // The lyrics on screen gained a translation after LyricsX wrote them into
    // Music, so they now write something else; what Music holds is still the
    // earlier write, and still LyricsX's.
    let clears = LyricsStoragePolicy.clearsLyricsInMusicWhenRejected(
        lyricsInMusic: "First line\nSecond line",
        contentsLyricsXWrote: [
            "First line\nSecond line",
            "First line\nFirst translation\nSecond line\nSecond translation",
        ]
    )

    #expect(clears)
}

@Test(arguments: [
    "First line\rSecond line",
    "First line\r\nSecond line\r\n",
    "First line\n\nSecond line\n",
])
func lyricsXsWriteStillCountsWhenMusicStoresItsLineBreaksDifferently(lyricsInMusic: String) {
    let clears = LyricsStoragePolicy.clearsLyricsInMusicWhenRejected(
        lyricsInMusic: lyricsInMusic,
        contentsLyricsXWrote: ["First line\nSecond line"]
    )

    #expect(clears)
}
