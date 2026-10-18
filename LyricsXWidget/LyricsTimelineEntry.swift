import CoreGraphics
import WidgetKit
import LyricsXWidgetShared

struct LyricsTimelineEntry: TimelineEntry {
    let date: Date
    let trackTitle: String
    let artist: String
    let albumName: String?
    let backgroundColor: CodableColor?
    /// Decoded once per timeline and shared by its entries.
    let coverImage: CGImage?
    let lyricsLines: [LyricsLineEntry]
    let highlightedLineIndex: Int
    let isPlaying: Bool
    let showTranslation: Bool
    let translationLanguage: String?
    let isEmpty: Bool

    static var empty: LyricsTimelineEntry {
        LyricsTimelineEntry(
            date: Date(),
            trackTitle: "",
            artist: "",
            albumName: nil,
            backgroundColor: nil,
            coverImage: nil,
            lyricsLines: [],
            highlightedLineIndex: 0,
            isPlaying: false,
            showTranslation: false,
            translationLanguage: nil,
            isEmpty: true
        )
    }
}
