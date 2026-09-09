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
    func onlyTheMatchingEntryIsRetiredAfterWriteBack() {
        var offsets = TrackLyricsOffsets()
        offsets.setOffset(200, for: "track", fingerprint: "original")

        let removedReplacement = offsets.removeOffset(for: "track", fingerprint: "replacement")
        #expect(!removedReplacement)
        #expect(offsets.offset(for: "track", fingerprint: "original") == 200)
        let removedOriginal = offsets.removeOffset(for: "track", fingerprint: "original")
        #expect(removedOriginal)
        #expect(offsets.offset(for: "track", fingerprint: "original") == nil)
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
}
