import Foundation

/// When each character of a lyrics line starts being sung, by its inline time
/// tags.
///
/// A tag says the character at its index starts being sung at its time, and
/// the characters up to the next tag are sung with it, so they all start at
/// the earlier tag: a word tagged at its first letter starts as a whole. This
/// is what the tags themselves say, with nothing interpolated between them —
/// what someone checking the tags against the song wants to see. The tags are
/// read through `KaraokeLineTiming`, so they are in order of time and never
/// move backwards; untagged characters before the first tag start with it,
/// and those after the last tag start with that one.
public struct KaraokeCharacterOnsets: Hashable, Sendable {
    /// Where the line starts, in the lyrics' own time (`LyricsLine.position`),
    /// before any offset is applied.
    public let lineStart: TimeInterval

    /// Seconds since the line starts at which each character — a Swift
    /// `Character` of the line's content — starts being sung. One per
    /// character, never decreasing.
    public let onsetTimes: [TimeInterval]

    /// The onsets of `line`, or `nil` when it has no inline time tags, or when
    /// they never move past a single place.
    public init?(line: LyricsLine) {
        guard let timeTag = line.attachments.timetag else {
            return nil
        }
        self.init(lineStart: line.position, characterCount: line.content.count, timeTag: timeTag)
    }

    /// The onsets that `timeTag` gives a line of `characterCount` characters
    /// starting at `lineStart`; `nil` when the line is empty or the tags never
    /// move past a single place.
    public init?(lineStart: TimeInterval, characterCount: Int, timeTag: LyricsLine.Attachments.InlineTimeTag) {
        guard characterCount > 0,
              let timing = KaraokeLineTiming(lineStart: lineStart, characterCount: characterCount, timeTag: timeTag) else {
            return nil
        }
        let keyframes = timing.keyframes
        var onsetTimes = Array(repeating: keyframes[0].time, count: characterCount)
        for (keyframe, nextKeyframe) in zip(keyframes, keyframes.dropFirst())
            where nextKeyframe.sungCharacterCount > keyframe.sungCharacterCount {
            for characterIndex in keyframe.sungCharacterCount ..< nextKeyframe.sungCharacterCount {
                onsetTimes[characterIndex] = keyframe.time
            }
        }
        let lastKeyframe = keyframes[keyframes.count - 1]
        for characterIndex in lastKeyframe.sungCharacterCount ..< characterCount {
            onsetTimes[characterIndex] = lastKeyframe.time
        }
        self.lineStart = timing.lineStart
        self.onsetTimes = onsetTimes
    }

    /// How many characters, counted from the start of the line, have started
    /// being sung at `lyricsTime` — the playback position with the lyrics'
    /// offset applied. A character counts from its onset on.
    public func startedCharacterCount(atLyricsTime lyricsTime: TimeInterval) -> Int {
        let lineTime = lyricsTime - lineStart
        guard !lineTime.isNaN else {
            return 0
        }
        // The first character whose onset is still ahead.
        var lowerBound = onsetTimes.startIndex
        var upperBound = onsetTimes.endIndex
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if onsetTimes[middle] <= lineTime {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    /// The lyrics time after `lyricsTime` at which the next character starts
    /// being sung, or `nil` once every character has started.
    public func nextOnset(afterLyricsTime lyricsTime: TimeInterval) -> TimeInterval? {
        let startedCharacterCount = startedCharacterCount(atLyricsTime: lyricsTime)
        guard startedCharacterCount < onsetTimes.count else {
            return nil
        }
        return lineStart + onsetTimes[startedCharacterCount]
    }
}
