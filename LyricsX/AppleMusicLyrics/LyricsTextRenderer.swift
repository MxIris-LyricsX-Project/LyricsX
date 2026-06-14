import AppKit
import LyricsXFoundation

// MARK: - Word Timing Data

@available(macOS 15, *)
extension AppleMusicLyrics {
    struct WordTimingEntry {
        var characterIndex: Int
        var timeOffset: TimeInterval // seconds from line start
    }

    enum KaraokeMode {
        case wordLevel
        case characterLevel
    }

    // MARK: - Karaoke Fill Fraction

    /// Computes the fraction (`0...1`) of a lyric line that should be lit up at
    /// `elapsedTime`, from per-word timing.
    ///
    /// Ported verbatim (logic-wise) from the previous SwiftUI `LyricsTextRenderer`.
    /// The CALayer engine feeds this fraction into the progress-mask position
    /// instead of re-drawing the text every frame, which is the core of the
    /// performance win over the SwiftUI `TextRenderer` implementation.
    enum KaraokeFill {
        static func fraction(
            elapsedTime: TimeInterval,
            lineDuration: TimeInterval,
            wordTimings: [WordTimingEntry],
            totalCharacterCount: Int,
            mode: KaraokeMode
        ) -> CGFloat {
            guard lineDuration > 0 else { return 0 }

            guard !wordTimings.isEmpty else {
                // No timetag: linear progress across the whole line.
                return CGFloat(min(1, max(0, elapsedTime / lineDuration)))
            }
            guard totalCharacterCount > 0 else { return 0 }

            for (timingIndex, timing) in wordTimings.enumerated() {
                let nextTiming = timingIndex + 1 < wordTimings.count ? wordTimings[timingIndex + 1] : nil
                let nextTimeOffset = nextTiming?.timeOffset ?? lineDuration
                let nextCharacterIndex = nextTiming?.characterIndex ?? totalCharacterCount

                if elapsedTime < timing.timeOffset {
                    // Before this word starts: fill up to this word's start position.
                    return CGFloat(timing.characterIndex) / CGFloat(totalCharacterCount)
                }

                if elapsedTime >= timing.timeOffset, elapsedTime < nextTimeOffset {
                    switch mode {
                    case .wordLevel:
                        // Light up the entire current word at once.
                        return CGFloat(nextCharacterIndex) / CGFloat(totalCharacterCount)
                    case .characterLevel:
                        // Interpolate character-level progress within the word.
                        let wordDuration = nextTimeOffset - timing.timeOffset
                        guard wordDuration > 0 else { continue }
                        let progressInWord = (elapsedTime - timing.timeOffset) / wordDuration
                        let startFraction = CGFloat(timing.characterIndex) / CGFloat(totalCharacterCount)
                        let endFraction = CGFloat(nextCharacterIndex) / CGFloat(totalCharacterCount)
                        return startFraction + CGFloat(progressInWord) * (endFraction - startFraction)
                    }
                }
            }

            // Past all words.
            return 1.0
        }
    }
}

// MARK: - Helper to Extract Word Timings from LyricsKit InlineTimeTag

@available(macOS 15, *)
extension LyricsLine {
    var wordTimingEntries: [AppleMusicLyrics.WordTimingEntry]? {
        guard let timetag = attachments.timetag else { return nil }
        return timetag.tags.map { tag in
            AppleMusicLyrics.WordTimingEntry(characterIndex: tag.index, timeOffset: tag.time)
        }
    }

    var timetagDuration: TimeInterval? {
        return attachments.timetag?.duration
    }
}
