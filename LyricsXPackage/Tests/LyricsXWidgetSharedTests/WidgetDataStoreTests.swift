import Testing
import Foundation
@testable import LyricsXWidgetShared

@Suite("WidgetDataStore")
struct WidgetDataStoreTests {
    private static let testSuiteName = "com.test.LyricsXWidgetSharedTests.\(UUID().uuidString)"

    @Test("Write and read round-trip")
    func writeAndRead() throws {
        let store = WidgetDataStore(groupIdentifier: WidgetDataStoreTests.testSuiteName)
        let data = LyricsWidgetData(
            trackTitle: "Hello",
            artist: "World",
            albumName: nil,
            backgroundColor: nil,
            lyricsLines: [
                LyricsLineEntry(text: "Line 1", translation: nil, startTime: 0, endTime: 5),
            ],
            currentLineIndex: 0,
            isPlaying: true,
            timestamp: Date(timeIntervalSince1970: 500),
            playbackPosition: 2.0,
            availableTranslationLanguages: []
        )

        try store.write(data)
        let readBack = store.read()

        #expect(readBack != nil)
        #expect(readBack?.trackTitle == "Hello")
        #expect(readBack?.artist == "World")
        #expect(readBack?.lyricsLines.count == 1)
    }

    @Test("Read returns nil when no data written")
    func readEmpty() {
        let store = WidgetDataStore(groupIdentifier: "com.test.nonexistent.\(UUID().uuidString)")
        #expect(store.read() == nil)
    }

    @Test("Clear removes data")
    func clearData() throws {
        let store = WidgetDataStore(groupIdentifier: WidgetDataStoreTests.testSuiteName)
        let data = LyricsWidgetData(
            trackTitle: "Song",
            artist: "Artist",
            albumName: nil,
            backgroundColor: nil,
            lyricsLines: [],
            currentLineIndex: 0,
            isPlaying: false,
            timestamp: Date(),
            playbackPosition: 0,
            availableTranslationLanguages: []
        )

        try store.write(data)
        #expect(store.read() != nil)

        store.clear()
        #expect(store.read() == nil)
    }
}
