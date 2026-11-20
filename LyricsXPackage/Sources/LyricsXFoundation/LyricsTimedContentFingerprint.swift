import LyricsKit

extension Lyrics {
    /// Identifies lyrics by line timestamps and text. Providers can return the
    /// same timed words with different tags or attachments, so only the timed
    /// text determines whether two candidates represent the same lyrics.
    /// The candidate pool and translation key use this identity. Stored track
    /// offsets hash it, so changing its format requires a migration.
    public var timedContentFingerprint: String {
        lines.map { "\($0.position)|\($0.content)" }.joined(separator: "\n")
    }
}
