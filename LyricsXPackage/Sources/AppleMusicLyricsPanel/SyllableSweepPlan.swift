import CoreGraphics
import Foundation

extension AppleMusicLyrics {
    /// Music 26.6's sung/un-sung sweep, worked out once for a laid-out line.
    ///
    /// Music gives every visual row its own `LineProgressGradientLayer` and
    /// moves it in steps, one per syllable, rather than placing it every frame
    /// (`sub_1001689D4`, called per row with the playback time plus
    /// `animationHeadstart`):
    ///
    /// - when the time first falls inside a syllable, the gradient's clear end
    ///   travels at constant speed to that syllable's ``Syllable/clearEdge``,
    ///   over the syllable's duration (`sub_100169874`, `.linear`);
    /// - between syllables, and between words, nothing new is sent, so the
    ///   gradient waits where the last syllable left it;
    /// - before the row's first syllable the row is dark; once its last
    ///   syllable has ended it is lit end to end.
    ///
    /// Every target is measured on the laid-out glyphs, so the boundary follows
    /// what is being sung however wide each letter is — the previous sweep used
    /// the share of sung *characters* times the line's width, which a line of
    /// proportional Latin text, or one that wraps, does not obey.
    struct SyllableSweepPlan: Equatable {
        struct Syllable: Equatable {
            /// When the syllable is sung, in seconds from the start of the line.
            let timeRange: Range<TimeInterval>
            /// Where the ramp's clear end comes to rest once this syllable has
            /// been sung, from the row's leading edge.
            let clearEdge: CGFloat
        }

        struct Row: Equatable {
            /// The row's syllables in reading order. Syllables that last no time
            /// at all are left out: the time can never fall inside them, so Music
            /// never moves towards them either.
            let syllables: [Syllable]
            /// The row's typographic width.
            let width: CGFloat
            let featherWidth: CGFloat
            /// Before this the row is dark.
            let startTime: TimeInterval
            /// From this on the row is lit end to end.
            let endTime: TimeInterval

            /// Nothing lit: the whole ramp sits before the text.
            var emptyClearEdge: CGFloat {
                0
            }

            /// Everything lit: the whole ramp sits past the text.
            var filledClearEdge: CGFloat {
                width + featherWidth
            }

            /// The syllable being sung at `cursor`, the way `sub_1001689D4`
            /// finds it: the first one whose range contains the time. `nil` in a
            /// gap, and before or after the row.
            func indexOfSyllable(sungAt cursor: TimeInterval) -> Int? {
                syllables.firstIndex { $0.timeRange.contains(cursor) }
            }

            /// Where the ramp's clear end stands at `cursor` if playback has run
            /// through the row without a jump: each syllable's travel starts
            /// from the previous syllable's target when the syllable starts — or
            /// when the previous one ends, if the two overlap, since that is
            /// when the search above moves on — and reaches its own target as
            /// the syllable ends.
            func clearEdge(at cursor: TimeInterval) -> CGFloat {
                if cursor < startTime {
                    return emptyClearEdge
                }
                if cursor >= endTime {
                    return filledClearEdge
                }
                var previousClearEdge = emptyClearEdge
                var previousEndTime = -TimeInterval.infinity
                for syllable in syllables {
                    let travelStartTime = max(syllable.timeRange.lowerBound, previousEndTime)
                    let travelEndTime = syllable.timeRange.upperBound
                    if cursor < travelStartTime {
                        return previousClearEdge
                    }
                    if cursor < travelEndTime {
                        let travelDuration = travelEndTime - travelStartTime
                        guard travelDuration > 0 else { return syllable.clearEdge }
                        let progress = CGFloat((cursor - travelStartTime) / travelDuration)
                        return previousClearEdge + (syllable.clearEdge - previousClearEdge) * progress
                    }
                    previousClearEdge = syllable.clearEdge
                    previousEndTime = max(previousEndTime, travelEndTime)
                }
                return previousClearEdge
            }
        }

        let rows: [Row]

        /// How far past the sung text the ramp's clear end is pushed, as a
        /// fraction of the feather — the four cases `sub_1001689D4` checks in
        /// this order. The fully lit part of the ramp ends one feather before
        /// the clear end, so a small fraction leaves most of the syllable's last
        /// letter in the ramp until the next syllable takes over.
        static func featherLeadFraction(
            isLastSyllableOfRow: Bool,
            wordLength: Int,
            syllableLength: Int,
            isFollowedBySyllable: Bool
        ) -> CGFloat {
            if isLastSyllableOfRow {
                return 1
            }
            if (1 ... 2).contains(wordLength) {
                return 0.5
            }
            if isFollowedBySyllable, syllableLength < 3 {
                return 0.25
            }
            return 0.12
        }

        static func make(
            for layout: LineTextLayout,
            featherWidth: CGFloat = LyricsSpecs.lineProgressionGradientFeather
        ) -> SyllableSweepPlan {
            let syllablesByRow = layout.visualLines.indices.map { rowIndex in
                makeSyllables(inRow: rowIndex, of: layout, featherWidth: featherWidth)
            }
            let rows = layout.visualLines.enumerated().map { rowIndex, visualLine in
                let syllables = syllablesByRow[rowIndex]
                let anchorTime = timeAnchor(forRowAt: rowIndex, syllablesByRow: syllablesByRow)
                return Row(
                    syllables: syllables,
                    width: visualLine.typographicFrame.width,
                    featherWidth: featherWidth,
                    startTime: syllables.first?.timeRange.lowerBound ?? anchorTime,
                    endTime: syllables.map(\.timeRange.upperBound).max() ?? anchorTime
                )
            }
            return SyllableSweepPlan(rows: rows)
        }

        /// One row's syllables with their targets.
        ///
        /// A syllable's target is the trailing edge of its last glyph — or, when
        /// it is the last syllable of its word and another word follows on the
        /// row, where that next word begins, so the space between the two is
        /// swept while the word is still being sung. Only timed words count:
        /// the untimed runs between structured words are those spaces.
        private static func makeSyllables(
            inRow rowIndex: Int,
            of layout: LineTextLayout,
            featherWidth: CGFloat
        ) -> [Syllable] {
            let rowLeadingEdge = layout.visualLines[rowIndex].typographicFrame.minX
            let timedWords = layout.words.filter { word in
                word.visualLineIndex == rowIndex && word.timeRange != nil && !word.glyphs.isEmpty
            }

            struct Candidate {
                let timeRange: Range<TimeInterval>
                let sungEdge: CGFloat
                let wordLength: Int
                let syllableLength: Int
            }

            var candidates: [Candidate] = []
            for (wordPosition, word) in timedWords.enumerated() {
                let wordLength = word.text.trimmingCharacters(in: .whitespacesAndNewlines).count
                let nextWord = wordPosition + 1 < timedWords.count ? timedWords[wordPosition + 1] : nil
                let syllables = sweptSyllables(of: word)
                for (syllablePosition, syllable) in syllables.enumerated() {
                    let isLastSyllableOfWord = syllablePosition == syllables.count - 1
                    let glyphTrailingEdge = syllable.glyphIndices.map { glyphIndex in
                        word.frame.minX + word.glyphs[glyphIndex].frame.maxX
                    }.max() ?? word.frame.maxX
                    let sungEdge = if isLastSyllableOfWord, let nextWord {
                        nextWord.frame.minX
                    } else {
                        glyphTrailingEdge
                    }
                    candidates.append(Candidate(
                        timeRange: syllable.timeRange,
                        sungEdge: sungEdge - rowLeadingEdge,
                        wordLength: wordLength,
                        syllableLength: syllable.text.trimmingCharacters(in: .whitespacesAndNewlines).count
                    ))
                }
            }

            return candidates.enumerated().compactMap { candidateIndex, candidate in
                guard candidate.timeRange.upperBound > candidate.timeRange.lowerBound else { return nil }
                let leadFraction = featherLeadFraction(
                    isLastSyllableOfRow: candidateIndex == candidates.count - 1,
                    wordLength: candidate.wordLength,
                    syllableLength: candidate.syllableLength,
                    isFollowedBySyllable: candidateIndex + 1 < candidates.count
                )
                return Syllable(
                    timeRange: candidate.timeRange,
                    clearEdge: candidate.sungEdge + leadFraction * featherWidth
                )
            }
        }

        private struct SweptSyllable {
            let text: String
            let timeRange: Range<TimeInterval>
            let glyphIndices: [Int]
        }

        /// The syllables the sweep steps through for one word: a structured
        /// word's own, or the whole word as one — an inline-tag segment, or a
        /// structured word without syllables. The same grouping the syllable
        /// lift uses.
        private static func sweptSyllables(of word: LineTextLayout.Word) -> [SweptSyllable] {
            guard let wordTimeRange = word.timeRange else { return [] }
            let wordCharacters = Array(word.text)
            let syllables = word.syllables
                .filter { !$0.glyphIndices.isEmpty }
                .map { syllable in
                    let lowerBound = max(0, syllable.characterRange.lowerBound - word.characterRange.lowerBound)
                    let upperBound = min(
                        wordCharacters.count,
                        syllable.characterRange.upperBound - word.characterRange.lowerBound
                    )
                    return SweptSyllable(
                        text: lowerBound < upperBound ? String(wordCharacters[lowerBound ..< upperBound]) : word.text,
                        timeRange: syllable.timeRange,
                        glyphIndices: syllable.glyphIndices
                    )
                }
            guard syllables.isEmpty else { return syllables }
            return [SweptSyllable(
                text: word.text,
                timeRange: wordTimeRange,
                glyphIndices: Array(word.glyphs.indices)
            )]
        }

        /// When a row with nothing timed in it lights up: as the last timed
        /// syllable before it ends, or, with none before it, as the first one
        /// after it starts. A line with no timing at all is lit from the start,
        /// the way Music shows line-synced lyrics.
        private static func timeAnchor(forRowAt rowIndex: Int, syllablesByRow: [[Syllable]]) -> TimeInterval {
            if let precedingEnd = syllablesByRow[..<rowIndex].joined().map(\.timeRange.upperBound).max() {
                return precedingEnd
            }
            if let followingStart = syllablesByRow[(rowIndex + 1)...].joined().first?.timeRange.lowerBound {
                return followingStart
            }
            return -.infinity
        }
    }
}
