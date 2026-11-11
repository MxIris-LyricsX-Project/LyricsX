import AppKit
import CoreText
import LyricsXFoundation

extension AppleMusicLyrics {
    /// A lyric line laid out once by Core Text and sliced into the shape Apple
    /// Music animates: a list of words, each owning its glyphs.
    ///
    /// Music's model is `Line → Word → Syllable → Glyph`. Apple Music TTML keeps
    /// that hierarchy; sources that only carry inline starts use the established
    /// phrase fallback. Everything is in the line content layer's coordinate
    /// space, which is y-down (the layer sets `isGeometryFlipped`) so it lines up
    /// with the flipped view that hosts it.
    struct LineTextLayout {
        /// Exact Core Text geometry for one visual row after wrapping.
        struct VisualLine {
            /// Typographic bounds in the content layer's y-down coordinate space.
            let typographicFrame: CGRect
        }

        /// One glyph, positioned inside its word.
        struct Glyph {
            let run: CTRun
            let glyphRange: CFRange
            /// Frame in the owning word's coordinate space.
            let frame: CGRect
            /// The run's text origin relative to the glyph frame, so the layer can
            /// place the baseline without re-measuring.
            let textPosition: CGPoint
        }

        /// One word: the unit Music emphasizes, and the unit our time tags give us.
        struct Word {
            struct Syllable {
                let characterRange: Range<Int>
                let timeRange: Range<TimeInterval>
                /// Indices into the owning word's `glyphs` array.
                let glyphIndices: [Int]
            }

            let text: String
            let characterRange: Range<Int>
            /// When this word is sung, in seconds from the start of the line.
            /// `nil` when the line carries no inline timing at all.
            let timeRange: Range<TimeInterval>?
            let syllables: [Syllable]
            let timingSource: WordEmphasisPlan.TimingSource
            let glyphs: [Glyph]
            /// Frame in the line content layer's coordinate space.
            let frame: CGRect
            let visualLineIndex: Int

            /// Duration and glyph count used by the full-emphasis policy's
            /// scheduler.
            ///
            /// Structured timing supplies the exact word duration and glyph count.
            /// The legacy inline-start path reconstructs the neighbouring phrase
            /// those timings used to describe, preserving its established motion.
            /// Under Music's gate (the default policy) an inline-tag segment is
            /// judged on its own `duration` instead, so this envelope only shapes
            /// the `fullEmphasis` look.
            ///
            /// Music's formulas assume multiple glyphs can overlap. Treating every
            /// legacy character start as a one-glyph word instead makes each
            /// character rise, park, and fall on its own.
            var emphasisDuration: TimeInterval = 0
            var emphasisGlyphCount: Int = 1

            var duration: TimeInterval {
                guard let timeRange else { return 0 }
                return timeRange.upperBound - timeRange.lowerBound
            }
        }

        let words: [Word]
        let visualLines: [VisualLine]
        let contentSize: CGSize
        let languageIdentifier: String?

        var totalTextWidth: CGFloat {
            visualLines.reduce(0) { accumulatedWidth, visualLine in
                accumulatedWidth + visualLine.typographicFrame.width
            }
        }
    }
}

extension AppleMusicLyrics.LineTextLayout.Word {
    /// One unit Music animates on its own — a `SyllableLayer` that lifts as a
    /// whole, and one step of the sung sweep.
    struct AnimatedSyllable {
        /// The syllable's own characters.
        let text: String
        let timeRange: Range<TimeInterval>
        /// Indices into the word's `glyphs`.
        let glyphIndices: [Int]
    }

    /// The units the syllable lift and the sweep step through: a structured
    /// word's own syllables, or the whole word as one — an inline-tag segment
    /// (Kugou and QQ Music tags are real per-word / per-character timing, the
    /// grain of Music's syllables) or a structured word without syllables. An
    /// untimed word has none.
    var animatedSyllables: [AnimatedSyllable] {
        guard let timeRange else { return [] }
        let wordCharacters = Array(text)
        let syllables = syllables
            .filter { !$0.glyphIndices.isEmpty }
            .map { syllable in
                let lowerBound = max(0, syllable.characterRange.lowerBound - characterRange.lowerBound)
                let upperBound = min(wordCharacters.count, syllable.characterRange.upperBound - characterRange.lowerBound)
                return AnimatedSyllable(
                    text: lowerBound < upperBound ? String(wordCharacters[lowerBound ..< upperBound]) : text,
                    timeRange: syllable.timeRange,
                    glyphIndices: syllable.glyphIndices
                )
            }
        guard syllables.isEmpty, !glyphs.isEmpty else { return syllables }
        return [AnimatedSyllable(text: text, timeRange: timeRange, glyphIndices: Array(glyphs.indices))]
    }
}

extension AppleMusicLyrics.LineTextLayout {
    /// Legacy inline timing does not carry Apple Music's word and syllable
    /// hierarchy. A source may instead emit a separate whitespace-delimited unit
    /// every one or two tenths of a second, which makes each unit request its own
    /// extremely short spring. Keep isolated short words untouched, but let a
    /// sustained rapid passage share the phrase envelope that the fallback path
    /// already uses for character-level timing.
    private static let maximumRapidFallbackWordDuration: TimeInterval = 0.25
    private static let minimumRapidFallbackWordCount = 3

    /// Lay `attributed` out and group its glyphs into words using `wordTimings`.
    ///
    /// `wordTimings` character indices are offsets into `content` counted in
    /// `Character`s (that is what LyricsKit's inline time tags carry), while Core
    /// Text reports string indices in UTF-16, so the two are reconciled here once
    /// rather than at every glyph.
    static func build(
        attributed: NSAttributedString,
        content: String,
        wordTimings: [AppleMusicLyrics.WordTimingEntry],
        synchronizedTextTiming: LyricsLine.Attachments.SynchronizedTextTiming? = nil,
        languageIdentifier: String? = nil,
        lineDuration: TimeInterval,
        textWidth: CGFloat
    ) -> AppleMusicLyrics.LineTextLayout? {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGMutablePath()
        // Unbounded height: CTFrame only emits lines that fully fit the path, so a
        // height-bounded one silently drops the last visual row.
        path.addRect(CGRect(x: 0, y: 0, width: textWidth, height: 100_000))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        guard let coreTextLines = CTFrameGetLines(frame) as? [CTLine], !coreTextLines.isEmpty else { return nil }

        var lineOrigins = [CGPoint](repeating: .zero, count: coreTextLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &lineOrigins)

        // Core Text's path space is y-up; map every baseline into a y-down space
        // whose 0 is the top of the first row.
        var firstAscent: CGFloat = 0
        _ = CTLineGetTypographicBounds(coreTextLines[0], &firstAscent, nil, nil)
        let blockTopInPathSpace = lineOrigins[0].y + firstAscent

        let wordBoundaries = unicodeCodeUnitWordBoundaries(
            content: content,
            wordTimings: wordTimings,
            synchronizedTextTiming: synchronizedTextTiming,
            lineDuration: lineDuration
        )

        var words: [Word] = []
        var visualLines: [VisualLine] = []
        var contentHeight: CGFloat = 0

        for (visualLineIndex, coreTextLine) in coreTextLines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(coreTextLine, &ascent, &descent, &leading))

            let baselineY = blockTopInPathSpace - lineOrigins[visualLineIndex].y
            visualLines.append(VisualLine(typographicFrame: CGRect(
                x: lineOrigins[visualLineIndex].x,
                y: baselineY - ascent,
                width: width,
                height: ascent + descent
            )))
            contentHeight = max(contentHeight, baselineY + descent + leading)

            words.append(contentsOf: makeWords(
                in: coreTextLine,
                row: RowMetrics(
                    visualLineIndex: visualLineIndex,
                    leftEdge: lineOrigins[visualLineIndex].x,
                    baselineY: baselineY,
                    ascent: ascent,
                    descent: descent
                ),
                boundaries: wordBoundaries,
                content: content
            ))
        }

        assignEmphasisTiming(to: &words)

        return AppleMusicLyrics.LineTextLayout(
            words: words,
            visualLines: visualLines,
            contentSize: CGSize(width: textWidth, height: ceil(contentHeight)),
            languageIdentifier: languageIdentifier
        )
    }

    /// Preserve exact word timing when available; otherwise gather neighbouring
    /// inline-start units into the phrase used by the legacy animation path.
    ///
    /// A phrase ends at whitespace (the only word boundary the text itself
    /// gives us), at a wrap, at an untimed word, and once it has grown longer
    /// than the spring period Music is willing to use — past that the period
    /// stops growing with the phrase, so letting the phrase keep growing would
    /// only stretch the tail.
    private static func assignEmphasisTiming(to words: inout [Word]) {
        var phraseStart: Int?

        func closePhrase(endingBefore end: Int) {
            guard let startingIndex = phraseStart, startingIndex < end else { return }
            let members = words[startingIndex ..< end]
            let glyphCount = members.reduce(0) { $0 + $1.glyphs.count }
            let span: TimeInterval
            if let start = members.first?.timeRange?.lowerBound,
               let finish = members.last?.timeRange?.upperBound {
                span = max(0, finish - start)
            } else {
                span = 0
            }
            for index in startingIndex ..< end {
                words[index].emphasisDuration = span
                words[index].emphasisGlyphCount = max(1, glyphCount)
            }
            phraseStart = nil
        }

        for index in words.indices {
            let word = words[index]
            if word.timingSource == .synchronized {
                closePhrase(endingBefore: index)
                let matchingWordIndices = words.indices.filter { candidateIndex in
                    words[candidateIndex].timingSource == .synchronized
                        && words[candidateIndex].characterRange == word.characterRange
                        && words[candidateIndex].timeRange == word.timeRange
                }
                let glyphCount = matchingWordIndices.reduce(0) { count, candidateIndex in
                    count + words[candidateIndex].glyphs.count
                }
                words[index].emphasisDuration = word.duration
                words[index].emphasisGlyphCount = max(1, glyphCount)
                continue
            }
            if phraseStart == nil {
                phraseStart = index
            }
            guard let startingIndex = phraseStart else { continue }
            let spanSoFar = words[startingIndex].timeRange.map { start in
                (word.timeRange?.upperBound ?? start.upperBound) - start.lowerBound
            } ?? 0
            let isLast = index + 1 == words.count
            let breaksHere = word.timeRange == nil
                || word.text.last?.isWhitespace == true
                || spanSoFar >= AppleMusicLyrics.LyricsSpecs.maximumEmphasisSpringPeriod
                || (!isLast && words[index + 1].visualLineIndex != word.visualLineIndex)
            if breaksHere {
                closePhrase(endingBefore: index + 1)
            }
        }
        closePhrase(endingBefore: words.count)
        assignRapidFallbackMotionEnvelopes(to: &words)
    }

    /// Share only the spring duration and timing glyph count for a sustained run
    /// of rapid legacy words. The words keep their own start times and ranges, so
    /// karaoke progression remains source-accurate while the lift no longer
    /// starts and reverses on a sub-quarter-second spring for every word.
    private static func assignRapidFallbackMotionEnvelopes(to words: inout [Word]) {
        var rapidWordIndices: [Int] = []

        func closeRapidWordRun() {
            defer { rapidWordIndices.removeAll(keepingCapacity: true) }
            guard rapidWordIndices.count >= minimumRapidFallbackWordCount,
                  let firstWordIndex = rapidWordIndices.first,
                  let lastWordIndex = rapidWordIndices.last,
                  let startingTime = words[firstWordIndex].timeRange?.lowerBound,
                  let endingTime = words[lastWordIndex].timeRange?.upperBound
            else {
                return
            }

            let sharedDuration = max(0, endingTime - startingTime)
            let sharedGlyphCount = rapidWordIndices.reduce(0) { glyphCount, wordIndex in
                glyphCount + words[wordIndex].glyphs.count
            }
            for wordIndex in rapidWordIndices {
                words[wordIndex].emphasisDuration = sharedDuration
                words[wordIndex].emphasisGlyphCount = max(1, sharedGlyphCount)
            }
        }

        for wordIndex in words.indices {
            let word = words[wordIndex]
            let isRapidFallbackWord = word.timingSource == .inferred
                && word.timeRange != nil
                && word.emphasisDuration > 0
                && word.emphasisDuration <= maximumRapidFallbackWordDuration
            guard isRapidFallbackWord else {
                closeRapidWordRun()
                continue
            }

            if let firstWordIndex = rapidWordIndices.first,
               let startingTime = words[firstWordIndex].timeRange?.lowerBound,
               let endingTime = word.timeRange?.upperBound {
                let changesVisualLine = words[firstWordIndex].visualLineIndex != word.visualLineIndex
                let exceedsMaximumSpringPeriod = endingTime - startingTime
                    > AppleMusicLyrics.LyricsSpecs.maximumEmphasisSpringPeriod
                if changesVisualLine || exceedsMaximumSpringPeriod {
                    closeRapidWordRun()
                }
            }
            rapidWordIndices.append(wordIndex)
        }
        closeRapidWordRun()
    }

    /// One word boundary, already converted to UTF-16 so it can be compared
    /// against Core Text's string indices directly.
    private struct WordBoundary {
        struct SyllableBoundary {
            let unicodeCodeUnitRange: Range<Int>
            let characterRange: Range<Int>
            let timeRange: Range<TimeInterval>
        }

        let unicodeCodeUnitRange: Range<Int>
        let characterRange: Range<Int>
        let timeRange: Range<TimeInterval>?
        let syllables: [SyllableBoundary]
        let timingSource: AppleMusicLyrics.WordEmphasisPlan.TimingSource
    }

    private static func unicodeCodeUnitWordBoundaries(
        content: String,
        wordTimings: [AppleMusicLyrics.WordTimingEntry],
        synchronizedTextTiming: LyricsLine.Attachments.SynchronizedTextTiming?,
        lineDuration: TimeInterval
    ) -> [WordBoundary] {
        var characterToUnicodeCodeUnitOffset: [Int] = []
        characterToUnicodeCodeUnitOffset.reserveCapacity(content.count + 1)
        var unicodeCodeUnitOffset = 0
        for character in content {
            characterToUnicodeCodeUnitOffset.append(unicodeCodeUnitOffset)
            unicodeCodeUnitOffset += character.utf16.count
        }
        characterToUnicodeCodeUnitOffset.append(unicodeCodeUnitOffset)

        let characterCount = content.count
        if let synchronizedTextTiming,
           synchronizedTextTiming.isValid(forCharacterCount: characterCount) {
            var synchronizedBoundaries: [WordBoundary] = []
            var nextUnassignedCharacterIndex = 0
            for word in synchronizedTextTiming.words {
                if nextUnassignedCharacterIndex < word.characterRange.lowerBound {
                    synchronizedBoundaries.append(WordBoundary(
                        unicodeCodeUnitRange: characterToUnicodeCodeUnitOffset[nextUnassignedCharacterIndex]
                            ..< characterToUnicodeCodeUnitOffset[word.characterRange.lowerBound],
                        characterRange: nextUnassignedCharacterIndex ..< word.characterRange.lowerBound,
                        timeRange: nil,
                        syllables: [],
                        timingSource: .inferred
                    ))
                }
                synchronizedBoundaries.append(WordBoundary(
                    unicodeCodeUnitRange: characterToUnicodeCodeUnitOffset[word.characterRange.lowerBound]
                        ..< characterToUnicodeCodeUnitOffset[word.characterRange.upperBound],
                    characterRange: word.characterRange,
                    timeRange: word.timeRange,
                    syllables: word.syllables.map { syllable in
                        WordBoundary.SyllableBoundary(
                            unicodeCodeUnitRange: characterToUnicodeCodeUnitOffset[syllable.characterRange.lowerBound]
                                ..< characterToUnicodeCodeUnitOffset[syllable.characterRange.upperBound],
                            characterRange: syllable.characterRange,
                            timeRange: syllable.timeRange
                        )
                    },
                    timingSource: .synchronized
                ))
                nextUnassignedCharacterIndex = word.characterRange.upperBound
            }
            if nextUnassignedCharacterIndex < characterCount {
                synchronizedBoundaries.append(WordBoundary(
                    unicodeCodeUnitRange: characterToUnicodeCodeUnitOffset[nextUnassignedCharacterIndex]
                        ..< characterToUnicodeCodeUnitOffset[characterCount],
                    characterRange: nextUnassignedCharacterIndex ..< characterCount,
                    timeRange: nil,
                    syllables: [],
                    timingSource: .inferred
                ))
            }
            return synchronizedBoundaries
        }

        guard !wordTimings.isEmpty else {
            // No inline timing: the whole line behaves as a single word with no
            // emphasis schedule of its own.
            return [WordBoundary(
                unicodeCodeUnitRange: 0 ..< unicodeCodeUnitOffset,
                characterRange: 0 ..< characterCount,
                timeRange: nil,
                syllables: [],
                timingSource: .inferred
            )]
        }

        var boundaries: [WordBoundary] = []
        for (index, timing) in wordTimings.enumerated() {
            let startCharacter = min(max(0, timing.characterIndex), characterCount)
            let endCharacter = index + 1 < wordTimings.count
                ? min(max(startCharacter, wordTimings[index + 1].characterIndex), characterCount)
                : characterCount
            guard startCharacter < endCharacter else { continue }
            let endTime = index + 1 < wordTimings.count ? wordTimings[index + 1].timeOffset : lineDuration
            boundaries.append(WordBoundary(
                unicodeCodeUnitRange: characterToUnicodeCodeUnitOffset[startCharacter]
                    ..< characterToUnicodeCodeUnitOffset[endCharacter],
                characterRange: startCharacter ..< endCharacter,
                timeRange: timing.timeOffset ..< max(timing.timeOffset, endTime),
                syllables: [],
                timingSource: .inferred
            ))
        }
        return boundaries
    }

    /// One glyph in row order, tagged with the word it belongs to.
    private struct TaggedGlyph {
        let boundaryIndex: Int
        let stringIndex: Int
        let run: CTRun
        let glyphRange: CFRange
        /// Frame in the visual row's coordinate space, before the word it lands
        /// in is known and its origin can be subtracted out.
        let frame: CGRect
    }

    /// Everything about one visual row that its glyphs need.
    private struct RowMetrics {
        let visualLineIndex: Int
        let leftEdge: CGFloat
        let baselineY: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// Slice one visual row's glyphs into words.
    ///
    /// A word that straddles a wrap becomes two entries sharing the same time
    /// range: Core Text can break anywhere in CJK text, and a single layer cannot
    /// span two rows.
    private static func makeWords(
        in coreTextLine: CTLine,
        row: RowMetrics,
        boundaries: [WordBoundary],
        content: String
    ) -> [Word] {
        let tagged = taggedGlyphs(in: coreTextLine, row: row, boundaries: boundaries)
        guard !tagged.isEmpty else { return [] }

        var result: [Word] = []
        var currentBoundary = tagged[0].boundaryIndex
        var currentGlyphs: [TaggedGlyph] = []

        func flush() {
            guard !currentGlyphs.isEmpty else { return }
            let wordFrame = currentGlyphs.dropFirst().reduce(currentGlyphs[0].frame) { $0.union($1.frame) }
            let boundary = boundaries.indices.contains(currentBoundary) ? boundaries[currentBoundary] : nil
            let syllables = boundary?.syllables.compactMap { syllableBoundary -> Word.Syllable? in
                let glyphIndices = currentGlyphs.indices.filter { glyphIndex in
                    syllableBoundary.unicodeCodeUnitRange.contains(currentGlyphs[glyphIndex].stringIndex)
                }
                guard !glyphIndices.isEmpty else { return nil }
                return Word.Syllable(
                    characterRange: syllableBoundary.characterRange,
                    timeRange: syllableBoundary.timeRange,
                    glyphIndices: glyphIndices
                )
            } ?? []
            result.append(Word(
                text: boundary.map { text(of: $0, in: content) } ?? "",
                characterRange: boundary?.characterRange ?? 0 ..< 0,
                timeRange: boundary?.timeRange,
                syllables: syllables,
                timingSource: boundary?.timingSource ?? .inferred,
                glyphs: currentGlyphs.map { glyph in
                    Glyph(
                        run: glyph.run,
                        glyphRange: glyph.glyphRange,
                        frame: glyph.frame.offsetBy(dx: -wordFrame.minX, dy: -wordFrame.minY),
                        // `CTRunDraw` places a glyph at its own offset *within the
                        // run*, and the layer is already sitting at that offset, so
                        // the run origin has to be pulled back by the same amount or
                        // every glyph past the first draws outside its own bounds and
                        // is clipped away. Vertically the origin is the baseline,
                        // which sits `descent` up from the frame's bottom edge.
                        textPosition: CGPoint(x: row.leftEdge - glyph.frame.minX, y: -row.descent)
                    )
                },
                frame: wordFrame,
                visualLineIndex: row.visualLineIndex
            ))
            currentGlyphs = []
        }

        for glyph in tagged {
            if glyph.boundaryIndex != currentBoundary {
                flush()
                currentBoundary = glyph.boundaryIndex
            }
            currentGlyphs.append(glyph)
        }
        flush()
        return result
    }

    private static func taggedGlyphs(
        in coreTextLine: CTLine,
        row: RowMetrics,
        boundaries: [WordBoundary]
    ) -> [TaggedGlyph] {
        guard let runs = CTLineGetGlyphRuns(coreTextLine) as? [CTRun] else { return [] }
        var tagged: [TaggedGlyph] = []
        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var advances = [CGSize](repeating: .zero, count: glyphCount)
            var stringIndices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &stringIndices)

            for glyphIndex in 0 ..< glyphCount {
                let stringIndex = stringIndices[glyphIndex]
                tagged.append(TaggedGlyph(
                    boundaryIndex: boundaryIndex(containing: stringIndex, boundaries: boundaries),
                    stringIndex: stringIndex,
                    run: run,
                    glyphRange: CFRange(location: glyphIndex, length: 1),
                    frame: CGRect(
                        x: row.leftEdge + positions[glyphIndex].x,
                        y: row.baselineY - row.ascent,
                        width: advances[glyphIndex].width,
                        height: row.ascent + row.descent
                    )
                ))
            }
        }
        return tagged
    }

    private static func boundaryIndex(containing stringIndex: Int, boundaries: [WordBoundary]) -> Int {
        if let containingIndex = boundaries.firstIndex(where: { $0.unicodeCodeUnitRange.contains(stringIndex) }) {
            return containingIndex
        }
        return boundaries.lastIndex(where: { $0.unicodeCodeUnitRange.lowerBound <= stringIndex }) ?? 0
    }

    private static func text(of boundary: WordBoundary, in content: String) -> String {
        guard boundary.characterRange.lowerBound < content.count else { return "" }
        let start = content.index(content.startIndex, offsetBy: boundary.characterRange.lowerBound)
        let end = content.index(content.startIndex, offsetBy: min(boundary.characterRange.upperBound, content.count))
        return String(content[start ..< end])
    }
}
