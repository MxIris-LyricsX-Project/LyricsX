import Testing
import Foundation
@testable import LyricsXWidgetShared

@Suite("LyricsWidgetData Serialization")
struct LyricsWidgetDataTests {
    @Test("Round-trip encode/decode preserves all fields")
    func roundTripEncoding() throws {
        let original = LyricsWidgetData(
            trackTitle: "Test Song",
            artist: "Test Artist",
            albumName: "Test Album",
            backgroundColor: CodableColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1.0),
            lyricsLines: [
                LyricsLineEntry(text: "First line", translation: "第一行", startTime: 10.5, endTime: 15.0),
                LyricsLineEntry(text: "Second line", translation: nil, startTime: 15.0, endTime: 20.0),
            ],
            currentLineIndex: 0,
            isPlaying: true,
            timestamp: Date(timeIntervalSince1970: 1000),
            playbackPosition: 10.5,
            showsTranslation: true,
            availableTranslationLanguages: ["zh-Hans", "ja"]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LyricsWidgetData.self, from: encoded)

        #expect(decoded.trackTitle == "Test Song")
        #expect(decoded.artist == "Test Artist")
        #expect(decoded.albumName == "Test Album")
        #expect(decoded.backgroundColor?.red == 0.2)
        #expect(decoded.backgroundColor?.green == 0.4)
        #expect(decoded.backgroundColor?.blue == 0.6)
        #expect(decoded.lyricsLines.count == 2)
        #expect(decoded.lyricsLines[0].text == "First line")
        #expect(decoded.lyricsLines[0].translation == "第一行")
        #expect(decoded.lyricsLines[0].startTime == 10.5)
        #expect(decoded.lyricsLines[1].translation == nil)
        #expect(decoded.currentLineIndex == 0)
        #expect(decoded.isPlaying == true)
        #expect(decoded.playbackPosition == 10.5)
        #expect(decoded.showsTranslation == true)
        #expect(decoded.availableTranslationLanguages == ["zh-Hans", "ja"])
    }

    @Test("Encode/decode with nil optional fields")
    func nilOptionalFields() throws {
        let original = LyricsWidgetData(
            trackTitle: "Song",
            artist: "Artist",
            albumName: nil,
            backgroundColor: nil,
            lyricsLines: [],
            currentLineIndex: 0,
            isPlaying: false,
            timestamp: Date(),
            playbackPosition: 0,
            showsTranslation: false,
            availableTranslationLanguages: []
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LyricsWidgetData.self, from: encoded)

        #expect(decoded.albumName == nil)
        #expect(decoded.backgroundColor == nil)
        #expect(decoded.lyricsLines.isEmpty)
    }

    @Test("a snapshot an earlier version wrote reads as one that shows no translation")
    func snapshotFromAnEarlierVersionShowsNoTranslation() throws {
        // What the app wrote before the widget took its settings from it:
        // whether to show translations was each widget's own setting.
        let earlierSnapshot = Data("""
        {
          "trackTitle": "Song",
          "artist": "Artist",
          "albumName": "Album",
          "lyricsLines": [{ "text": "First line", "translation": "第一行", "startTime": 0, "endTime": 5 }],
          "currentLineIndex": 0,
          "isPlaying": true,
          "timestamp": 1000,
          "playbackPosition": 2,
          "availableTranslationLanguages": ["zh-Hans"]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(LyricsWidgetData.self, from: earlierSnapshot)

        #expect(decoded.trackTitle == "Song")
        #expect(decoded.lyricsLines.first?.translation == "第一行")
        #expect(decoded.showsTranslation == false)
    }
}
