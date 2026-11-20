import CryptoKit
import Foundation
import LyricsKit

/// Per-track overrides for lyric offsets that are not in the source yet: a source
/// LyricsX does not update in place, or an adjustment still waiting for the write
/// that puts it there.
public struct TrackLyricsOffsets: Equatable, Sendable {
    /// The source as read, independent of adjustments to the displayed lyrics.
    public struct Source: Equatable, Sendable {
        public let fileURL: URL?
        /// The lyrics came from the player's own lyrics field, not from a file.
        public let isEmbedded: Bool
        public private(set) var offset: Int
        private let contentDigest: String

        public init(lyrics: Lyrics, fileURL: URL?, isEmbedded: Bool = false) {
            self.fileURL = fileURL
            self.isEmbedded = isEmbedded
            offset = lyrics.offset
            let digest = SHA256.hash(data: Data(lyrics.timedContentFingerprint.utf8))
            contentDigest = Data(digest).base64EncodedString()
        }

        var fingerprint: String { "\(contentDigest):\(offset)" }

        fileprivate func writtenBack(offset: Int) -> Self {
            var source = self
            source.offset = offset
            return source
        }
    }

    private struct Entry: Codable, Equatable, Sendable {
        let fingerprint: String
        let offset: Int
    }

    private var offsets: [String: Entry]

    public init(storedData: Data? = nil) {
        offsets = storedData.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    public var storedData: Data {
        (try? JSONEncoder().encode(offsets)) ?? Data("{}".utf8)
    }

    public mutating func recordAdjustment(
        _ offset: Int,
        for trackID: String,
        source: Source,
        currentFileURL: URL?,
        writesBackInPlace: Bool
    ) -> Bool {
        // Back at the source's own offset, an override has nothing to add.
        if offset == source.offset {
            return removeOffset(for: trackID, fingerprint: source.fingerprint)
        }
        // Embedded lyrics are saved to the player when the track ends, never to
        // the file `persist()` writes, so every adjustment waits on that write.
        let hasDifferentSaveFile = source.isEmbedded || source.fileURL != currentFileURL
        let hasPendingWriteBack = self.offset(for: trackID, fingerprint: source.fingerprint) != nil
        guard !writesBackInPlace || hasDifferentSaveFile || hasPendingWriteBack else { return false }
        setOffset(offset, for: trackID, fingerprint: source.fingerprint)
        return true
    }

    public func restoration(
        for trackID: String,
        source: Source,
        writesBackInPlace: Bool
    ) -> (offset: Int, needsPersist: Bool)? {
        guard let offset = offset(for: trackID, fingerprint: source.fingerprint) else { return nil }
        return (offset, writesBackInPlace && offset != source.offset)
    }

    /// Called with the destination of a successful save.
    public mutating func recordWriteBack(
        for trackID: String,
        source: Source,
        savedFileURL: URL,
        offset: Int
    ) -> (source: Source, removedOverride: Bool)? {
        guard source.fileURL == savedFileURL else { return nil }
        let removed = removeOffset(for: trackID, fingerprint: source.fingerprint)
        return (source.writtenBack(offset: offset), removed)
    }

    /// Called once the player holds the lyrics with `offset` in them.
    public mutating func recordEmbeddedWriteBack(
        for trackID: String,
        source: Source,
        offset: Int
    ) -> (source: Source, removedOverride: Bool)? {
        guard source.isEmbedded else { return nil }
        let removed = removeOffset(for: trackID, fingerprint: source.fingerprint)
        return (source.writtenBack(offset: offset), removed)
    }

    /// A nil offset leaves the source's tag in effect. Zero can override a nonzero tag.
    func offset(for trackID: String, fingerprint: String) -> Int? {
        guard let entry = offsets[trackID], entry.fingerprint == fingerprint else { return nil }
        return entry.offset
    }

    mutating func setOffset(_ offset: Int, for trackID: String, fingerprint: String) {
        offsets[trackID] = Entry(fingerprint: fingerprint, offset: offset)
    }

    private mutating func removeOffset(for trackID: String, fingerprint: String) -> Bool {
        guard offset(for: trackID, fingerprint: fingerprint) != nil else { return false }
        offsets.removeValue(forKey: trackID)
        return true
    }
}
