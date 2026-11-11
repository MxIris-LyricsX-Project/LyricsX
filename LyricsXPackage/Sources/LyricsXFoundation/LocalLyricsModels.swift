import Foundation
import LyricsKit
import MusicPlayer

public enum LocalLyricsSource: Equatable, Sendable {
    case embedded
    case file(URL)
    /// One menu option for any LyricsX-managed source, whether it is a
    /// saved library file or the selected online result held in memory.
    case lyricsX
}

public struct LocalLyricsChoice {
    public let sessionToken: UUID
    public let track: MusicTrack
    public let source: LocalLyricsSource
    public let title: String
    public var embeddedContents: String? = nil
    /// The preferred saved file for a `.lyricsX` choice. A memory-backed
    /// online choice leaves this nil and supplies `memoryLyrics` instead.
    public var lyricsXFileURL: URL? = nil
    public var memoryLyrics: Lyrics? = nil

    public init(
        sessionToken: UUID, track: MusicTrack, source: LocalLyricsSource, title: String,
        embeddedContents: String? = nil, lyricsXFileURL: URL? = nil, memoryLyrics: Lyrics? = nil
    ) {
        self.sessionToken = sessionToken
        self.track = track
        self.source = source
        self.title = title
        self.embeddedContents = embeddedContents
        self.lyricsXFileURL = lyricsXFileURL
        self.memoryLyrics = memoryLyrics
    }
}

public enum LocalLyricsRefreshStage: Sendable {
    case cached
    case location
    case complete
    case cancelled
}

public struct LocalLyricsChange: Sendable {
    public enum Kind: Sendable { case lyricsX, embedded, embeddedRefreshRequired }
    public let trackID: String
    public let kind: Kind

    public init(trackID: String, kind: Kind) { self.trackID = trackID; self.kind = kind }
}
