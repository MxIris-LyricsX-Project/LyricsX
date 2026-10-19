import Foundation
@_exported import FoundationToolbox

/// Data snapshot written by the main app for the widget extension to consume.
public struct LyricsWidgetData: Codable, Sendable {
    public let trackTitle: String
    public let artist: String
    public let albumName: String?
    public let backgroundColor: CodableColor?
    public let lyricsLines: [LyricsLineEntry]
    public let currentLineIndex: Int
    public let isPlaying: Bool
    public let timestamp: Date
    public let playbackPosition: TimeInterval
    /// Whether the widget shows each line's translation under it: the app's
    /// Prefer bilingual lyrics setting. Every widget takes it from here, so
    /// none has a setting of its own, and all of them share one configuration.
    public let showsTranslation: Bool

    public init(
        trackTitle: String,
        artist: String,
        albumName: String?,
        backgroundColor: CodableColor?,
        lyricsLines: [LyricsLineEntry],
        currentLineIndex: Int,
        isPlaying: Bool,
        timestamp: Date,
        playbackPosition: TimeInterval,
        showsTranslation: Bool
    ) {
        self.trackTitle = trackTitle
        self.artist = artist
        self.albumName = albumName
        self.backgroundColor = backgroundColor
        self.lyricsLines = lyricsLines
        self.currentLineIndex = currentLineIndex
        self.isPlaying = isPlaying
        self.timestamp = timestamp
        self.playbackPosition = playbackPosition
        self.showsTranslation = showsTranslation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.trackTitle = try container.decode(String.self, forKey: .trackTitle)
        self.artist = try container.decode(String.self, forKey: .artist)
        self.albumName = try container.decodeIfPresent(String.self, forKey: .albumName)
        self.backgroundColor = try container.decodeIfPresent(CodableColor.self, forKey: .backgroundColor)
        self.lyricsLines = try container.decode([LyricsLineEntry].self, forKey: .lyricsLines)
        self.currentLineIndex = try container.decode(Int.self, forKey: .currentLineIndex)
        self.isPlaying = try container.decode(Bool.self, forKey: .isPlaying)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.playbackPosition = try container.decode(TimeInterval.self, forKey: .playbackPosition)
        // A snapshot an earlier version of the app left behind has no such
        // key: back then each widget had its own setting, off by default.
        self.showsTranslation = try container.decodeIfPresent(Bool.self, forKey: .showsTranslation) ?? false
    }
}

public struct LyricsLineEntry: Codable, Equatable, Sendable {
    public let text: String
    public let translation: String?
    public let startTime: TimeInterval
    public let endTime: TimeInterval?

    public init(text: String, translation: String?, startTime: TimeInterval, endTime: TimeInterval?) {
        self.text = text
        self.translation = translation
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct CodableColor: Codable, Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}
