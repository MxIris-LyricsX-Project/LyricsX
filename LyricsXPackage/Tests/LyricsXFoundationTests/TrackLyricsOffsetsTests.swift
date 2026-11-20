import Foundation
import Testing
@testable import LyricsXFoundation

@Suite("Per-track lyrics offsets")
struct TrackLyricsOffsetsTests {
    @Test
    func offsetsBelongToTheirTrackAndCanBeReplaced() {
        var offsets = TrackLyricsOffsets()
        offsets.setOffset(200, for: "track-a", fingerprint: "source")
        offsets.setOffset(-300, for: "track-b", fingerprint: "source")
        offsets.setOffset(500, for: "track-a", fingerprint: "source")

        #expect(offsets.offset(for: "track-a", fingerprint: "source") == 500)
        #expect(offsets.offset(for: "track-b", fingerprint: "source") == -300)
        #expect(offsets.offset(for: "track-c", fingerprint: "source") == nil)
    }

    @Test
    func replacementLyricsKeepTheirOwnOffsetUntilAdjusted() {
        var offsets = TrackLyricsOffsets()
        offsets.setOffset(200, for: "track", fingerprint: "original")

        #expect(offsets.offset(for: "track", fingerprint: "replacement") == nil)
        offsets.setOffset(-100, for: "track", fingerprint: "replacement")
        #expect(offsets.offset(for: "track", fingerprint: "original") == nil)
        #expect(offsets.offset(for: "track", fingerprint: "replacement") == -100)
    }

    @Test
    func zeroOverridesAnExistingTagAndSurvivesReload() {
        var offsets = TrackLyricsOffsets()
        offsets.setOffset(0, for: "track", fingerprint: "source")

        let reloaded = TrackLyricsOffsets(storedData: offsets.storedData)
        #expect(reloaded.offset(for: "track", fingerprint: "source") == 0)
        #expect(reloaded.offset(for: "track", fingerprint: "replacement") == nil)
    }

    @Test
    func savedOffsetsUseTrackIDsAsKeys() {
        let data = Data(#"{"track":{"fingerprint":"source","offset":250}}"#.utf8)
        let offsets = TrackLyricsOffsets(storedData: data)

        #expect(offsets.offset(for: "track", fingerprint: "source") == 250)
    }

    @Test(arguments: ["invalid", #"{"track":200}"#])
    func dataWithoutAFingerprintLeavesTheSourceTagInEffect(storedValue: String) {
        let offsets = TrackLyricsOffsets(storedData: Data(storedValue.utf8))
        #expect(offsets.offset(for: "track", fingerprint: "source") == nil)
    }

    @Test
    func fingerprintUsesLineTextTimestampsAndOriginalOffset() throws {
        let lyrics = try #require(Lyrics("[00:10.000]Example"))
        let source = makeSource(lyrics)
        #expect(source.fingerprint == "Gn92WHhbA5WpBiPbD3z6NQd1NxODlfJaK7gC6PhHdJc=:0")

        lyrics.offset = 300
        #expect(source.offset == 0)
        #expect(makeSource(lyrics).fingerprint != source.fingerprint)
        #expect(try makeSource(#require(Lyrics("[00:10.000]Replacement"))).fingerprint != source.fingerprint)
        #expect(try makeSource(#require(Lyrics("[00:11.000]Example"))).fingerprint != source.fingerprint)
    }

    @Test
    func cachedReselectionAndFreshLoadUseTheSameFingerprint() throws {
        let text = "[00:10.000]Example"
        let lyrics = try #require(Lyrics(text))
        let cachedSource = makeSource(lyrics)
        var offsets = TrackLyricsOffsets()
        let initialAdjustment = offsets.recordAdjustment(
            300, for: "track", source: cachedSource, currentFileURL: nil, writesBackInPlace: false
        )
        #expect(initialAdjustment)
        lyrics.offset = try #require(offsets.restoration(for: "track", source: cachedSource, writesBackInPlace: false)).offset

        let reselected = try #require(offsets.restoration(for: "track", source: cachedSource, writesBackInPlace: false))
        #expect(reselected.offset == 300)
        #expect(!reselected.needsPersist)
        let nextAdjustment = offsets.recordAdjustment(
            400, for: "track", source: cachedSource, currentFileURL: nil, writesBackInPlace: false
        )
        #expect(nextAdjustment)

        let freshSource = try makeSource(#require(Lyrics(text)))
        let restored = try #require(offsets.restoration(for: "track", source: freshSource, writesBackInPlace: false))
        #expect(restored.offset == 400)
    }

    @Test
    func recordsAdjustmentsForReadOnlySourcesMovedSavesAndPendingOverrides() throws {
        let source = try makeSource(#require(Lyrics("[00:10.000]Example")), fileURL: originalFile)
        var offsets = TrackLyricsOffsets()

        let directWrite = offsets.recordAdjustment(
            100, for: "track", source: source, currentFileURL: originalFile, writesBackInPlace: true
        )
        #expect(!directWrite)
        let readOnly = offsets.recordAdjustment(
            200, for: "read-only", source: source, currentFileURL: originalFile, writesBackInPlace: false
        )
        #expect(readOnly)
        let movedSave = offsets.recordAdjustment(
            300, for: "track", source: source, currentFileURL: libraryCopy, writesBackInPlace: true
        )
        #expect(movedSave)
        let pendingWrite = offsets.recordAdjustment(
            400, for: "track", source: source, currentFileURL: originalFile, writesBackInPlace: true
        )
        #expect(pendingWrite)
        #expect(offsets.restoration(for: "track", source: source, writesBackInPlace: true)?.offset == 400)
    }

    @Test
    func restorationMarksOnlyADifferentWritableOffsetForSaving() throws {
        let source = try makeSource(#require(Lyrics("[offset:100]\n[00:10.000]Example")), fileURL: originalFile)
        let replacement = try makeSource(#require(Lyrics("[offset:200]\n[00:10.000]Example")), fileURL: originalFile)
        var offsets = TrackLyricsOffsets()
        offsets.setOffset(0, for: "override", fingerprint: source.fingerprint)
        offsets.setOffset(100, for: "same", fingerprint: source.fingerprint)

        let writable = try #require(offsets.restoration(for: "override", source: source, writesBackInPlace: true))
        #expect(writable.offset == 0)
        #expect(writable.needsPersist)
        #expect(offsets.restoration(for: "override", source: source, writesBackInPlace: false)?.needsPersist == false)
        #expect(offsets.restoration(for: "same", source: source, writesBackInPlace: true)?.needsPersist == false)
        #expect(offsets.restoration(for: "override", source: replacement, writesBackInPlace: true) == nil)
    }

    @Test
    func savingToTheOriginalFileRetiresOnlyTheMatchingOverrideAndRefreshesTheSource() throws {
        let source = try makeSource(#require(Lyrics("[00:10.000]Example")), fileURL: originalFile)
        let replacement = try makeSource(#require(Lyrics("[00:10.000]Replacement")), fileURL: originalFile)
        var offsets = TrackLyricsOffsets()
        offsets.setOffset(300, for: "track", fingerprint: source.fingerprint)

        let savedCopy = offsets.recordWriteBack(for: "track", source: source, savedFileURL: libraryCopy, offset: 300)
        #expect(savedCopy == nil)
        let unrelated = offsets.recordWriteBack(for: "track", source: replacement, savedFileURL: originalFile, offset: 200)
        #expect(unrelated?.removedOverride == false)
        #expect(offsets.restoration(for: "track", source: source, writesBackInPlace: true)?.offset == 300)

        let result = offsets.recordWriteBack(for: "track", source: source, savedFileURL: originalFile, offset: 300)
        let savedSource = try #require(result)
        #expect(savedSource.removedOverride)
        #expect(savedSource.source.offset == 300)
        #expect(offsets.restoration(for: "track", source: source, writesBackInPlace: true) == nil)
        let freshlyRead = try makeSource(#require(Lyrics("[offset:300]\n[00:10.000]Example")), fileURL: originalFile)
        #expect(savedSource.source == freshlyRead)
    }

    @Test
    func savingAnEmbeddedLyricsCopyKeepsTheOverride() throws {
        let source = try makeSource(#require(Lyrics("[00:10.000]Example")))
        var offsets = TrackLyricsOffsets()
        offsets.setOffset(300, for: "track", fingerprint: source.fingerprint)

        let savedCopy = offsets.recordWriteBack(for: "track", source: source, savedFileURL: libraryCopy, offset: 300)
        #expect(savedCopy == nil)
        #expect(offsets.restoration(for: "track", source: source, writesBackInPlace: false)?.offset == 300)
    }

    @Test
    func embeddedLyricsKeepEveryAdjustmentUntilThePlayerHoldsIt() throws {
        let source = try makeSource(#require(Lyrics("[offset:100]\n[00:10.000]Example")), isEmbedded: true)
        var offsets = TrackLyricsOffsets()

        let recorded = offsets.recordAdjustment(
            300, for: "track", source: source, currentFileURL: nil, writesBackInPlace: true
        )
        #expect(recorded)
        let restored = try #require(offsets.restoration(for: "track", source: source, writesBackInPlace: true))
        #expect(restored.offset == 300)
        #expect(restored.needsPersist)

        let result = offsets.recordEmbeddedWriteBack(for: "track", source: source, offset: 300)
        let written = try #require(result)
        #expect(written.removedOverride)
        #expect(written.source.offset == 300)
        #expect(offsets.restoration(for: "track", source: source, writesBackInPlace: true) == nil)
    }

    @Test
    func aFileSourceIsNotRetiredByAnEmbeddedWriteBack() throws {
        let source = try makeSource(#require(Lyrics("[00:10.000]Example")), fileURL: originalFile)
        var offsets = TrackLyricsOffsets()
        offsets.setOffset(300, for: "track", fingerprint: source.fingerprint)

        #expect(offsets.recordEmbeddedWriteBack(for: "track", source: source, offset: 300) == nil)
        #expect(offsets.restoration(for: "track", source: source, writesBackInPlace: true)?.offset == 300)
    }

    private let originalFile = URL(fileURLWithPath: "/Music/Example.lrc")
    private let libraryCopy = URL(fileURLWithPath: "/LyricsX/Example.lrcx")

    private func makeSource(_ lyrics: Lyrics, fileURL: URL? = nil, isEmbedded: Bool = false) -> TrackLyricsOffsets.Source {
        TrackLyricsOffsets.Source(lyrics: lyrics, fileURL: fileURL, isEmbedded: isEmbedded)
    }
}
