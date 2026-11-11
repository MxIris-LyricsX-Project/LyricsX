import Testing
@testable import LyricsXFoundation

@Suite
struct MusicLyricsOperationTests {
    @Test(arguments: ["one\rtwo", "one\r\ntwo", "one\ntwo"])
    func musicLineEndingsDoNotMakeSuccessfulWritesFail(actual: String) {
        var written: String?
        let result = MusicLyricsOperation.write("one\ntwo", overwrite: true, read: { actual },
                                                beforeWrite: { true }, write: { written = $0 })
        #expect(written == "one\ntwo")
        #expect(result == .verified(actual))
    }

    @Test
    func nonmatchingReadBackRequestsRevalidation() {
        let result = MusicLyricsOperation.write("new", overwrite: true, read: { "old" }, beforeWrite: { true }, write: { _ in })
        #expect(result == .unverified)
    }

    @Test
    func existingLyricsAreNotTouchedWithoutOverwritePermission() {
        let result = MusicLyricsOperation.write("new", overwrite: false, read: { "existing" }, beforeWrite: {
            Issue.record("A skipped write must not begin a state transaction")
            return true
        }, write: { _ in Issue.record("Existing lyrics must not be overwritten") })
        #expect(result == .skipped)
    }

    @Test
    func anObsoleteSelectionDoesNotWriteToMusic() {
        let result = MusicLyricsOperation.write("obsolete", overwrite: true,
            read: { Issue.record("A skipped write has no read-back"); return nil },
            beforeWrite: { false }, write: { _ in Issue.record("The selection was invalidated") })
        #expect(result == .skipped)
    }
}
