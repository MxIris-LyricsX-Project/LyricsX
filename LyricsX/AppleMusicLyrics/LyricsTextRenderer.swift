import SwiftUI
import LyricsXFoundation

// MARK: - Word Timing Data

@available(macOS 15, *)
struct WordTimingEntry {
    var characterIndex: Int
    var timeOffset: TimeInterval // seconds from line start
}

@available(macOS 15, *)
enum KaraokeMode {
    case wordLevel
    case characterLevel
}

// MARK: - LyricsTextRenderer

@available(macOS 15, *)
struct LyricsTextRenderer: TextRenderer {

    var elapsedTime: TimeInterval // seconds since line start
    var lineDuration: TimeInterval // total line duration in seconds
    var wordTimings: [WordTimingEntry]
    var mode: KaraokeMode
    var inactiveOpacity: Double = 0.55
    var highlightBrightness: Double = 0.5
    var blendRadius: CGFloat = 8

    var animatableData: Double {
        get { elapsedTime }
        set { elapsedTime = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // Pass 1: draw all text at inactive opacity
        var inactiveContext = context
        inactiveContext.opacity = inactiveOpacity
        for line in layout {
            inactiveContext.draw(line)
        }

        // Pass 2: draw highlighted portion with gradient clipping
        guard lineDuration > 0 else { return }

        let filledFraction = computeFilledFraction(layout: layout)
        guard filledFraction > 0 else { return }

        for line in layout {
            let lineRect = line.typographicBounds.rect
            guard lineRect.width > 0 else { continue }

            let filledWidth = lineRect.width * filledFraction

            var highlightContext = context
            highlightContext.clipToLayer { clipContext in
                // Create a gradient mask: fully opaque up to the filled point,
                // then a smooth blend region of `blendRadius` to transparent
                let gradientStart = CGPoint(
                    x: lineRect.minX + filledWidth - blendRadius / 2,
                    y: lineRect.midY
                )
                let gradientEnd = CGPoint(
                    x: lineRect.minX + filledWidth + blendRadius / 2,
                    y: lineRect.midY
                )
                clipContext.fill(
                    Path(lineRect),
                    with: .linearGradient(
                        Gradient(colors: [.white, .clear]),
                        startPoint: gradientStart,
                        endPoint: gradientEnd
                    )
                )
            }
            highlightContext.addFilter(.brightness(highlightBrightness))
            highlightContext.draw(line)
        }
    }

    // MARK: - Filled Fraction Computation

    private func computeFilledFraction(layout: Text.Layout) -> CGFloat {
        let totalCharacterCount = estimateTotalCharacterCount()

        switch mode {
        case .wordLevel:
            return wordLevelProgress(totalCharacterCount: totalCharacterCount)
        case .characterLevel:
            return characterLevelProgress(totalCharacterCount: totalCharacterCount)
        }
    }

    // MARK: - Word-Level Progress

    private func wordLevelProgress(totalCharacterCount: Int) -> CGFloat {
        guard !wordTimings.isEmpty else {
            // No timetag: use linear progress across the whole line
            return CGFloat(min(1, max(0, elapsedTime / lineDuration)))
        }

        guard totalCharacterCount > 0 else { return 0 }

        // Find the active word and light up the entire word at once
        for (timingIndex, timing) in wordTimings.enumerated() {
            let nextTiming = timingIndex + 1 < wordTimings.count ? wordTimings[timingIndex + 1] : nil
            let nextTimeOffset = nextTiming?.timeOffset ?? lineDuration

            if elapsedTime < timing.timeOffset {
                // Before this word starts: show up to this word's start position
                return CGFloat(timing.characterIndex) / CGFloat(totalCharacterCount)
            }

            if elapsedTime >= timing.timeOffset && elapsedTime < nextTimeOffset {
                // Currently in this word: light up through the end of this word
                let endCharacterIndex = nextTiming?.characterIndex ?? totalCharacterCount
                return CGFloat(endCharacterIndex) / CGFloat(totalCharacterCount)
            }
        }

        // Past all words
        return 1.0
    }

    // MARK: - Character-Level Progress

    private func characterLevelProgress(totalCharacterCount: Int) -> CGFloat {
        guard !wordTimings.isEmpty else {
            // No timetag: use linear progress across the whole line
            return CGFloat(min(1, max(0, elapsedTime / lineDuration)))
        }

        guard totalCharacterCount > 0 else { return 0 }

        // Find the active word and interpolate within it proportionally
        for (timingIndex, timing) in wordTimings.enumerated() {
            let nextTiming = timingIndex + 1 < wordTimings.count ? wordTimings[timingIndex + 1] : nil
            let nextTimeOffset = nextTiming?.timeOffset ?? lineDuration
            let nextCharacterIndex = nextTiming?.characterIndex ?? totalCharacterCount

            if elapsedTime < timing.timeOffset {
                // Before this word starts
                return CGFloat(timing.characterIndex) / CGFloat(totalCharacterCount)
            }

            if elapsedTime >= timing.timeOffset && elapsedTime < nextTimeOffset {
                // Inside this word: interpolate character-level progress
                let wordDuration = nextTimeOffset - timing.timeOffset
                guard wordDuration > 0 else { continue }

                let progressInWord = (elapsedTime - timing.timeOffset) / wordDuration
                let startFraction = CGFloat(timing.characterIndex) / CGFloat(totalCharacterCount)
                let endFraction = CGFloat(nextCharacterIndex) / CGFloat(totalCharacterCount)
                return startFraction + CGFloat(progressInWord) * (endFraction - startFraction)
            }
        }

        // Past all words
        return 1.0
    }

    // MARK: - Helpers

    private func estimateTotalCharacterCount() -> Int {
        // Use the last word timing's character index as an estimate,
        // adding 1 to account for the final segment beyond the last tag
        if let lastTiming = wordTimings.last {
            return max(lastTiming.characterIndex + 1, wordTimings.count)
        }
        return 1
    }
}

// MARK: - Helper to Extract Word Timings from LyricsKit InlineTimeTag

@available(macOS 15, *)
extension LyricsLine {
    var wordTimingEntries: [WordTimingEntry]? {
        guard let timetag = attachments.timetag else { return nil }
        return timetag.tags.map { tag in
            WordTimingEntry(characterIndex: tag.index, timeOffset: tag.time)
        }
    }

    var timetagDuration: TimeInterval? {
        return attachments.timetag?.duration
    }
}
