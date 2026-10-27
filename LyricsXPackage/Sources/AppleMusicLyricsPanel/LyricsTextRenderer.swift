import AppKit
import LyricsXFoundation

// MARK: - Word Timing Data

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
    /// `elapsedTime`, from per-word timing. A line without any word timing is
    /// lit whole as soon as it is current.
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
            synchronizedTextTiming: LyricsLine.Attachments.SynchronizedTextTiming? = nil,
            totalCharacterCount: Int,
            mode: KaraokeMode
        ) -> CGFloat {
            // Real libraries contain lines whose time tags index past the
            // line's own character count (mismatched or truncated tags), which
            // would push the raw ratio above 1 — the library sweep probe
            // caught one at 2.18. Clamp here so the documented `0...1`
            // contract holds regardless of the data.
            let raw = unclampedFraction(
                elapsedTime: elapsedTime,
                lineDuration: lineDuration,
                wordTimings: wordTimings,
                synchronizedTextTiming: synchronizedTextTiming,
                totalCharacterCount: totalCharacterCount,
                mode: mode
            )
            return min(1, max(0, raw))
        }

        private static func unclampedFraction(
            elapsedTime: TimeInterval,
            lineDuration: TimeInterval,
            wordTimings: [WordTimingEntry],
            synchronizedTextTiming: LyricsLine.Attachments.SynchronizedTextTiming?,
            totalCharacterCount: Int,
            mode: KaraokeMode
        ) -> CGFloat {
            if let synchronizedTextTiming,
               synchronizedTextTiming.isValid(forCharacterCount: totalCharacterCount) {
                return synchronizedFraction(
                    elapsedTime: elapsedTime,
                    timing: synchronizedTextTiming,
                    totalCharacterCount: totalCharacterCount,
                    mode: mode
                )
            }

            // No word timing at all — a line-synced LRC line, or structured
            // timing that did not fit the line: Music lights the whole line the
            // moment it becomes current. Sweeping it across the gap to the next
            // line read as word-by-word progress and trailed the singing.
            guard !wordTimings.isEmpty else { return 1 }

            guard lineDuration > 0, totalCharacterCount > 0 else { return 0 }

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

        private static func synchronizedFraction(
            elapsedTime: TimeInterval,
            timing: LyricsLine.Attachments.SynchronizedTextTiming,
            totalCharacterCount: Int,
            mode: KaraokeMode
        ) -> CGFloat {
            guard totalCharacterCount > 0 else { return 0 }

            switch mode {
            case .wordLevel:
                for word in timing.words {
                    if elapsedTime < word.timeRange.lowerBound {
                        return CGFloat(word.characterRange.lowerBound) / CGFloat(totalCharacterCount)
                    }
                    if elapsedTime <= word.timeRange.upperBound {
                        return CGFloat(word.characterRange.upperBound) / CGFloat(totalCharacterCount)
                    }
                }
            case .characterLevel:
                for word in timing.words {
                    let syllables = word.syllables.isEmpty
                        ? [LyricsLine.Attachments.SynchronizedTextTiming.Syllable(
                            characterRange: word.characterRange,
                            timeRange: word.timeRange
                        )]
                        : word.syllables
                    for syllable in syllables {
                        if elapsedTime < syllable.timeRange.lowerBound {
                            return CGFloat(syllable.characterRange.lowerBound) / CGFloat(totalCharacterCount)
                        }
                        if elapsedTime <= syllable.timeRange.upperBound {
                            let duration = syllable.timeRange.upperBound - syllable.timeRange.lowerBound
                            guard duration > 0 else {
                                return CGFloat(syllable.characterRange.upperBound) / CGFloat(totalCharacterCount)
                            }
                            let progress = min(
                                1,
                                max(0, (elapsedTime - syllable.timeRange.lowerBound) / duration)
                            )
                            let startingFraction = CGFloat(syllable.characterRange.lowerBound)
                                / CGFloat(totalCharacterCount)
                            let endingFraction = CGFloat(syllable.characterRange.upperBound)
                                / CGFloat(totalCharacterCount)
                            return startingFraction + CGFloat(progress) * (endingFraction - startingFraction)
                        }
                    }
                }
            }

            return 1
        }
    }
}

// MARK: - Helper to Extract Word Timings from LyricsKit InlineTimeTag

extension LyricsLine {
    var synchronizedTextTiming: LyricsLine.Attachments.SynchronizedTextTiming? {
        let timing = attachments.synchronizedTextTiming
        guard timing?.isValid(forCharacterCount: content.count) == true else { return nil }
        return timing
    }

    var wordTimingEntries: [AppleMusicLyrics.WordTimingEntry]? {
        guard let timetag = attachments.timetag else { return nil }
        return timetag.tags.map { tag in
            AppleMusicLyrics.WordTimingEntry(characterIndex: tag.index, timeOffset: tag.time)
        }
    }

    var timetagDuration: TimeInterval? {
        return synchronizedTextTiming?.duration ?? attachments.timetag?.duration
    }
}
