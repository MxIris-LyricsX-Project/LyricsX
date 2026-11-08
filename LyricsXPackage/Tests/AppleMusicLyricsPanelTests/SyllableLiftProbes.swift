import AppKit
import LyricsXFoundation
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

/// Reproduction loop for "structured lyrics move in lurches": Music lifts a
/// `.none` word syllable by syllable on a soft spring (mass 1 / stiffness 14 /
/// damping 7, `sub_1001897C0`), with nothing else moving, and only a `.factor`
/// word (over a second, at most seven characters, a language with the
/// `emphasis` capability) gets the per-glyph swell. A line of short English
/// words therefore ripples gently under the sweep. The port used to run every
/// structured word through the per-word swell schedule instead — a critically
/// damped spring as short as the word, staggered glyph by glyph — which made
/// each word pop up on its own beat.
@Suite(.serialized)
@MainActor
struct SyllableLiftProbes {
    /// 《Slowly》 "Slowly slowly we fall in love" with the library file's own
    /// word timing: six words between 0.21 s and 0.75 s long, none of which
    /// Music would swell.
    private static let shortWords: [(Range<Int>, Range<TimeInterval>)] = [
        (0 ..< 6, 0 ..< 0.746),
        (7 ..< 13, 0.746 ..< 1.322),
        (14 ..< 16, 1.322 ..< 1.630),
        (17 ..< 21, 1.630 ..< 1.844),
        (22 ..< 24, 1.844 ..< 2.064),
        (25 ..< 29, 2.064 ..< 2.790),
    ]
    private static let shortWordsText = "Slowly slowly we fall in love"

    private struct GlyphSample {
        let elapsedTime: TimeInterval
        let lift: CGFloat
        let scale: CGFloat
    }

    private struct SyllableTrack {
        let wordIndex: Int
        let timeRange: Range<TimeInterval>
        let glyphTracks: [[GlyphSample]]
    }

    @Test func shortStructuredWordsLiftPerSyllableOnMusicsSoftSpring() async throws {
        let tracks = try await Self.trace(
            text: Self.shortWordsText,
            words: Self.shortWords,
            lineDuration: 2.79,
            languageIdentifier: "en"
        )
        let lift = AppleMusicLyrics.LyricsSpecs.syllableLift
        var failures: [String] = []

        for track in tracks {
            // 1. Nothing moves before the syllable is due: Music's head start
            //    (`animationHeadstart`, 0.1 s) is the only lead, and there is
            //    no per-word batch that fires at the word's own start.
            let dueTime = track.timeRange.lowerBound - AppleMusicLyrics.LyricsSpecs.animationHeadstart
            for (glyphIndex, glyphTrack) in track.glyphTracks.enumerated() {
                if let early = glyphTrack.first(where: { $0.elapsedTime < dueTime - 0.001 && abs($0.lift) > 0.25 }) {
                    failures.append(String(format: "word %d glyph %d moved %.2f pt at %.2fs, before its syllable is due at %.2fs", track.wordIndex, glyphIndex, early.lift, early.elapsedTime, dueTime))
                    break
                }
            }
            // 2. A syllable rises as one layer: no glyph-by-glyph stagger.
            let sampleCount = track.glyphTracks.map(\.count).min() ?? 0
            for sampleIndex in 0 ..< sampleCount {
                let lifts = track.glyphTracks.map { $0[sampleIndex].lift }
                if let highest = lifts.max(), let lowest = lifts.min(), highest - lowest > 0.35 {
                    failures.append(String(format: "word %d glyphs spread %.2f pt apart at %.2fs — the syllable is being staggered", track.wordIndex, highest - lowest, track.glyphTracks[0][sampleIndex].elapsedTime))
                    break
                }
            }
            // 3. The rise is Music's soft spring, not a spring as short as the
            //    word: 90% of the lift takes the better part of a second.
            if let first = track.glyphTracks.first,
               let ninetyPercent = first.first(where: { $0.elapsedTime >= track.timeRange.lowerBound && $0.lift >= lift * 0.9 }) {
                let riseTime = ninetyPercent.elapsedTime - track.timeRange.lowerBound
                if riseTime < 0.5 {
                    failures.append(String(format: "word %d reached 90%% of its lift %.2fs after its start — that is the per-word swell spring, not the syllable spring", track.wordIndex, riseTime))
                }
            } else {
                failures.append("word \(track.wordIndex) never reached 90% of its lift")
            }
            // 4. No swell for a word Music would leave at `.none`.
            if let swollen = track.glyphTracks.flatMap({ $0 }).first(where: { abs($0.scale - 1) > 0.001 }) {
                failures.append(String(format: "word %d scaled to %.3f at %.2fs, but a short word never swells", track.wordIndex, swollen.scale, swollen.elapsedTime))
            }
            // 5. Every sung glyph settles `syllableLift` high and stays there.
            for (glyphIndex, glyphTrack) in track.glyphTracks.enumerated() {
                if let final = glyphTrack.last, abs(final.lift - lift) > 0.5 {
                    failures.append(String(format: "word %d glyph %d ended %.2f pt high, expected %.0f", track.wordIndex, glyphIndex, final.lift, lift))
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(8).joined(separator: " ⏐ "))")
    }

    /// The other side of the same rule: a word Music would give `.factor` still
    /// swells, and its glyphs are moved by the swell alone — the syllable lift
    /// does not stack on top of it.
    @Test func aLongStructuredWordStillSwellsWithoutAnExtraSyllableLift() async throws {
        let tracks = try await Self.trace(
            text: "Slowly slowly",
            words: [(0 ..< 6, 0 ..< 1.4), (7 ..< 13, 1.4 ..< 1.9)],
            lineDuration: 1.9,
            languageIdentifier: "en"
        )
        let long = try #require(tracks.first)
        let short = try #require(tracks.last)
        let lift = AppleMusicLyrics.LyricsSpecs.syllableLift

        let peakScale = long.glyphTracks.flatMap { $0 }.map(\.scale).max() ?? 1
        #expect(peakScale > 1.03, "the 1.4 s word must swell (peak scale \(peakScale))")
        let peakLift = long.glyphTracks.flatMap { $0 }.map(\.lift).max() ?? 0
        #expect(peakLift < lift * 2, "the swell rose \(peakLift) pt — the syllable lift is stacking on the per-glyph lift")
        for glyphTrack in long.glyphTracks {
            if let final = glyphTrack.last {
                #expect(abs(final.lift - lift) < 0.5, "a swollen glyph still settles \(lift) pt high, got \(final.lift)")
            }
        }

        let shortPeakScale = short.glyphTracks.flatMap { $0 }.map(\.scale).max() ?? 1
        #expect(abs(shortPeakScale - 1) < 0.001, "the 0.5 s word must not swell")
    }

    // MARK: Harness

    private static func trace(
        text: String,
        words: [(Range<Int>, Range<TimeInterval>)],
        lineDuration: TimeInterval,
        languageIdentifier: String
    ) async throws -> [SyllableTrack] {
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: words.map { characterRange, timeRange in
                .init(
                    characterRange: characterRange,
                    timeRange: timeRange,
                    syllables: [.init(characterRange: characterRange, timeRange: timeRange)]
                )
            },
            duration: lineDuration
        )
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold)]
        )
        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: attributed,
            content: text,
            wordTimings: [],
            synchronizedTextTiming: timing,
            languageIdentifier: languageIdentifier,
            lineDuration: lineDuration,
            textWidth: 900
        ))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let hostView = try #require(window.contentView)
        hostView.wantsLayer = true
        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)
        contentLayer.anchorPoint = .zero
        contentLayer.position = CGPoint(x: 20, y: 40)
        hostView.layer?.addSublayer(contentLayer)
        contentLayer.update(elapsedTime: -0.5, fillFraction: 0)
        CATransaction.flush()

        let wordLayers = Self.wordLayers(of: contentLayer)
        try #require(wordLayers.count == layout.words.count, "one word layer per word")
        let glyphLayersByWord = wordLayers.map { $0.sublayers ?? [] }
        let restingPositions = glyphLayersByWord.map { $0.map(\.position.y) }

        let frameStep: TimeInterval = 1.0 / 20.0
        let frameCount = Int((lineDuration + 1.5) / frameStep)
        var samples = glyphLayersByWord.map { [[GlyphSample]](repeating: [], count: $0.count) }
        for frameIndex in 0 ..< frameCount {
            let elapsed = Double(frameIndex) * frameStep
            contentLayer.update(elapsedTime: elapsed, fillFraction: CGFloat(min(1, elapsed / lineDuration)))
            CATransaction.flush()
            try await Task.sleep(seconds: frameStep)
            for (wordIndex, glyphLayers) in glyphLayersByWord.enumerated() {
                for (glyphIndex, glyphLayer) in glyphLayers.enumerated() {
                    let presented = glyphLayer.presentation() ?? glyphLayer
                    samples[wordIndex][glyphIndex].append(GlyphSample(
                        elapsedTime: elapsed,
                        lift: restingPositions[wordIndex][glyphIndex] - presented.position.y,
                        scale: presented.affineTransform().a
                    ))
                }
            }
        }

        return layout.words.enumerated().flatMap { wordIndex, word in
            word.syllables.map { syllable in
                SyllableTrack(
                    wordIndex: wordIndex,
                    timeRange: syllable.timeRange,
                    glyphTracks: syllable.glyphIndices.map { samples[wordIndex][$0] }
                )
            }
        }
    }

    private static func wordLayers(of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer) -> [CALayer] {
        let visualRowColorContainers = (contentLayer.sublayers ?? []).filter { candidateLayer in
            (candidateLayer.sublayers ?? []).contains { sublayer in
                sublayer is AppleMusicLyrics.LineProgressGradientLayer
            }
        }
        return visualRowColorContainers.flatMap { visualRowColorContainer in
            (visualRowColorContainer.mask?.sublayers ?? []).compactMap(\.mask)
        }
    }
}
