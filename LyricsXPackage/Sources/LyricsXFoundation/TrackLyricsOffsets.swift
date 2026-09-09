import Foundation

/// Per-track overrides for lyric sources that LyricsX does not update in place.
public struct TrackLyricsOffsets: Equatable, Sendable {
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

    /// A nil offset leaves the source's tag in effect. Zero can override a nonzero tag.
    public func offset(for trackID: String, fingerprint: String) -> Int? {
        guard let entry = offsets[trackID], entry.fingerprint == fingerprint else { return nil }
        return entry.offset
    }

    public mutating func setOffset(_ offset: Int, for trackID: String, fingerprint: String) {
        offsets[trackID] = Entry(fingerprint: fingerprint, offset: offset)
    }

    @discardableResult
    public mutating func removeOffset(for trackID: String, fingerprint: String) -> Bool {
        guard offset(for: trackID, fingerprint: fingerprint) != nil else { return false }
        offsets.removeValue(forKey: trackID)
        return true
    }
}
