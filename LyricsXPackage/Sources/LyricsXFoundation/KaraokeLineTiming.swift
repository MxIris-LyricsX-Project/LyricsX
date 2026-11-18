import Foundation

/// How far the singing of one lyrics line has got at any moment, from the
/// line's inline time tags.
///
/// A tag says that the character at its index starts being sung at its time,
/// so the characters before it are sung by then. Between two tags the sung
/// part grows linearly, which fills a word progressively over the time it is
/// sung; before the first tag it stays where that tag puts it and after the
/// last it stays where the last one does. When the line has a duration a
/// final keyframe at its end marks every character sung, so the last word
/// fills instead of stopping at its own tag — the desktop lyrics do the same.
public struct KaraokeLineTiming: Hashable, Sendable {
    public struct Keyframe: Hashable, Sendable {
        /// Seconds since the line starts.
        public var time: TimeInterval
        /// How many of the line's characters — Swift `Character`s of its
        /// content — are sung by `time`.
        public var sungCharacterCount: Int

        public init(time: TimeInterval, sungCharacterCount: Int) {
            self.time = time
            self.sungCharacterCount = sungCharacterCount
        }
    }

    /// Where the line starts, in the lyrics' own time (`LyricsLine.position`),
    /// before any offset is applied.
    public let lineStart: TimeInterval

    /// In order of time, and never fewer characters than the keyframe before.
    public let keyframes: [Keyframe]

    /// The timing of `line`, or `nil` when it has no inline time tags, or
    /// when they never move past a single place.
    public init?(line: LyricsLine) {
        guard let timeTag = line.attachments.timetag else { return nil }
        self.init(lineStart: line.position, characterCount: line.content.count, timeTag: timeTag)
    }

    /// The timing that `timeTag` gives a line of `characterCount` characters
    /// starting at `lineStart`; `nil` when the tags never move past a single
    /// place.
    ///
    /// Tags are ordered by time, indices are kept within the line, and an
    /// index lower than one before it is raised to it, so the sung part
    /// never shrinks. Tags whose time is not a finite number are dropped.
    public init?(lineStart: TimeInterval, characterCount: Int, timeTag: LyricsLine.Attachments.InlineTimeTag) {
        guard lineStart.isFinite else { return nil }
        let characterCount = max(0, characterCount)
        var keyframes = timeTag.tags
            .filter(\.time.isFinite)
            .map { Keyframe(time: $0.time, sungCharacterCount: min(max(0, $0.index), characterCount)) }
        if let duration = timeTag.duration, duration.isFinite, duration > 0 {
            keyframes.append(Keyframe(time: duration, sungCharacterCount: characterCount))
        }
        // A stable sort, so tags at the same moment keep their order.
        keyframes = keyframes.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
        var mostSungSoFar = 0
        for keyframeIndex in keyframes.indices {
            mostSungSoFar = max(mostSungSoFar, keyframes[keyframeIndex].sungCharacterCount)
            keyframes[keyframeIndex].sungCharacterCount = mostSungSoFar
        }
        guard let first = keyframes.first, let last = keyframes.last,
              last.sungCharacterCount > first.sungCharacterCount else {
            return nil
        }
        self.lineStart = lineStart
        self.keyframes = keyframes
    }

    /// The span of lyrics time over which the sung part changes: from the
    /// first keyframe to the last. Outside it nothing moves.
    public var movingLyricsTimes: ClosedRange<TimeInterval> {
        (lineStart + keyframes[0].time) ... (lineStart + keyframes[keyframes.count - 1].time)
    }

    /// How many characters are sung at `lyricsTime` — the playback position
    /// with the lyrics' offset applied — as a fraction, so a word fills
    /// smoothly rather than a character at a time.
    public func sungCharacterCount(atLyricsTime lyricsTime: TimeInterval) -> Double {
        let lineTime = lyricsTime - lineStart
        guard lineTime.isFinite else { return Double(keyframes[0].sungCharacterCount) }
        guard let nextIndex = keyframes.firstIndex(where: { $0.time > lineTime }) else {
            return Double(keyframes[keyframes.count - 1].sungCharacterCount)
        }
        guard nextIndex > 0 else {
            return Double(keyframes[0].sungCharacterCount)
        }
        let previous = keyframes[nextIndex - 1]
        let next = keyframes[nextIndex]
        let share = (lineTime - previous.time) / (next.time - previous.time)
        return Double(previous.sungCharacterCount)
            + Double(next.sungCharacterCount - previous.sungCharacterCount) * share
    }
}
