import Foundation

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
    public let availableTranslationLanguages: [String]

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
        availableTranslationLanguages: [String]
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
        self.availableTranslationLanguages = availableTranslationLanguages
    }
}

public struct LyricsLineEntry: Codable, Sendable {
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

public struct CodableColor: Codable, Sendable {
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
