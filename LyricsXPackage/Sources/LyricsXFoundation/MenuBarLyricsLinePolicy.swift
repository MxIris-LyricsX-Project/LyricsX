import Foundation

/// What the menu bar's lyric line shows for the lyrics on screen and the state
/// of playback.
public enum MenuBarLyricsLinePolicy {
    public enum Display: Equatable, Sendable {
        /// The text the line starts with, before there are any lyrics.
        case placeholder
        /// The line at this index of the lyrics.
        case line(index: Int)
        /// Whatever the line shows now.
        case unchanged
    }

    /// No lyrics, or lyrics hidden while paused, show the placeholder. A line
    /// index that is missing is left alone rather than shown as the
    /// placeholder: before the first line of a song the placeholder is up
    /// already — a track change clears the lyrics — and in the middle of one
    /// the index is only missing while the lyrics on screen are replaced.
    ///
    /// - Parameters:
    ///   - lineCount: How many lines the lyrics on screen have, or `nil` when
    ///     there are none.
    ///   - currentLineIndex: The line playback is at; `nil` before the first
    ///     line, and for a moment while the lyrics on screen are replaced.
    ///   - hidesLyricsWhenPaused: The "Hide lyrics when paused" setting.
    public static func display(
        lineCount: Int?,
        currentLineIndex: Int?,
        isPlaying: Bool,
        hidesLyricsWhenPaused: Bool
    ) -> Display {
        if hidesLyricsWhenPaused, !isPlaying {
            return .placeholder
        }
        guard let lineCount else { return .placeholder }
        guard let currentLineIndex, (0 ..< lineCount).contains(currentLineIndex) else {
            return .unchanged
        }
        return .line(index: currentLineIndex)
    }
}
