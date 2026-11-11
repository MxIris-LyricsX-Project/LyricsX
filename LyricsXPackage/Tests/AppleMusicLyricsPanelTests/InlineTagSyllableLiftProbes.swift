import AppKit
import LyricsXFoundation
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

/// Reproduction loop for "Kugou lyrics go up and down": an inline-tag (`[tt]`)
/// line used to take the legacy full-emphasis path — every phrase swollen 14 %,
/// glowing, each glyph rising and then travelling back — while a structured
/// Apple Music line of the very same words rides Music's per-syllable soft
/// spring and never comes back down. Kugou and QQ Music tags carry real
/// per-word (English) and per-character (CJK) timing, so a tag segment is a
/// faithful stand-in for one of Music's syllables and gets the same treatment
/// under the default policy: the soft lift, and the swell only where Music's
/// gate would give the word `.factor`. The full-emphasis policy keeps the old
/// look for side-by-side comparison.
@Suite(.serialized)
@MainActor
struct InlineTagSyllableLiftProbes {
    /// Kugou's STAY, "I do the same thing I told you that I never would", with
    /// the file's own per-word timing (155 ms to 574 ms per word). Every word
    /// carries its trailing space, the way `[tt]` segments do.
    private static let kugouLineText = "I do the same thing I told you that I never would"
    private static let kugouWordDurations: [TimeInterval] = [
        0.271, 0.190, 0.178, 0.574, 0.200, 0.186, 0.171, 0.155, 0.176, 0.173, 0.167, 0.248,
    ]

    private struct InlineTagLine {
        let text: String
        let entries: [AppleMusicLyrics.WordTimingEntry]
        let lineDuration: TimeInterval
    }

    private static func makeKugouLine() -> InlineTagLine {
        var entries: [AppleMusicLyrics.WordTimingEntry] = []
        var characterIndex = 0
        var timeOffset: TimeInterval = 0
        let words = kugouLineText.split(separator: " ", omittingEmptySubsequences: false)
        for (wordIndex, word) in words.enumerated() {
            entries.append(.init(characterIndex: characterIndex, timeOffset: timeOffset))
            characterIndex += word.count + 1
            timeOffset += kugouWordDurations[wordIndex]
        }
        return InlineTagLine(text: kugouLineText, entries: entries, lineDuration: timeOffset)
    }

    /// "I stay": a short segment, then a 1.46 s one Music would swell by
    /// `min(1.461, 2) - 1 = 0.461` — the held "stay" from the same file.
    private static func makeHeldWordLine() -> InlineTagLine {
        InlineTagLine(
            text: "I stay",
            entries: [.init(characterIndex: 0, timeOffset: 0), .init(characterIndex: 2, timeOffset: 0.3)],
            lineDuration: 0.3 + 1.461
        )
    }

    private struct GlyphSample {
        let elapsedTime: TimeInterval
        let lift: CGFloat
        let scale: CGFloat
    }

    private struct WordTrack {
        let wordIndex: Int
        let timeRange: Range<TimeInterval>
        let glyphTracks: [[GlyphSample]]
    }

    // MARK: Default policy

    @Test func inlineTagWordsLiftOnMusicsSoftSpringWithoutSwelling() throws {
        let line = Self.makeKugouLine()
        let layout = try Self.makeLayout(line)
        let contentLayer = Self.makeContentLayer(layout: layout, policy: .appleMusic26)
        let wordLayers = Self.wordLayers(of: contentLayer)
        try #require(wordLayers.count == layout.words.count, "one word layer per tag segment")

        // Just past the first segment's start, well before the second's.
        contentLayer.update(elapsedTime: 0.05, fillFraction: 0.02)

        let firstWordLayer = try #require(wordLayers.first)
        let firstGlyphLayers = firstWordLayer.sublayers ?? []
        try #require(!firstGlyphLayers.isEmpty)
        for glyphLayer in firstGlyphLayers {
            let lift = glyphLayer.animation(forKey: "AppleMusicLyrics.position") as? CASpringAnimation
            #expect(lift != nil, "the sung segment lifts")
            #expect(
                abs((lift?.stiffness ?? 0) - AppleMusicLyrics.SyllableLiftPlan.springStiffness) < 0.001,
                "the lift must ride Music's soft spring, got stiffness \(lift?.stiffness ?? 0)"
            )
            #expect(glyphLayer.animation(forKey: "AppleMusicLyrics.transform") == nil, "a short segment never swells")
            #expect(CATransform3DIsIdentity(glyphLayer.transform), "a short segment never swells")
        }
        #expect(firstWordLayer.shadowOpacity == 0, "a short segment never glows")
        #expect(firstWordLayer.animation(forKey: "AppleMusicLyrics.shadowOpacity") == nil)

        for wordLayer in wordLayers.dropFirst() {
            for glyphLayer in wordLayer.sublayers ?? [] {
                #expect(glyphLayer.animation(forKey: "AppleMusicLyrics.position") == nil, "an unsung segment must not move")
            }
        }
    }

    @Test func inlineTagWordsRiseOnceAndStayLifted() async throws {
        let tracks = try await Self.trace(Self.makeKugouLine(), policy: .appleMusic26)
        let lift = AppleMusicLyrics.LyricsSpecs.syllableLift
        var failures: [String] = []

        for track in tracks {
            // 1. Nothing moves before the segment is due: Music's head start
            //    (`animationHeadstart`, 0.1 s) is the only lead.
            let dueTime = track.timeRange.lowerBound - AppleMusicLyrics.LyricsSpecs.animationHeadstart
            for (glyphIndex, glyphTrack) in track.glyphTracks.enumerated() {
                if let early = glyphTrack.first(where: { $0.elapsedTime < dueTime - 0.001 && abs($0.lift) > 0.25 }) {
                    failures.append(String(format: "word %d glyph %d moved %.2f pt at %.2fs, before its segment is due at %.2fs", track.wordIndex, glyphIndex, early.lift, early.elapsedTime, dueTime))
                    break
                }
            }
            // 2. A segment rises as one layer: no glyph-by-glyph stagger.
            let sampleCount = track.glyphTracks.map(\.count).min() ?? 0
            for sampleIndex in 0 ..< sampleCount {
                let lifts = track.glyphTracks.map { $0[sampleIndex].lift }
                if let highest = lifts.max(), let lowest = lifts.min(), highest - lowest > 0.35 {
                    failures.append(String(format: "word %d glyphs spread %.2f pt apart at %.2fs — the segment is being staggered", track.wordIndex, highest - lowest, track.glyphTracks[0][sampleIndex].elapsedTime))
                    break
                }
            }
            // 3. The rise is Music's soft spring: 90% of the lift takes the
            //    better part of a second, not a spring as short as the word.
            if let first = track.glyphTracks.first,
               let ninetyPercent = first.first(where: { $0.elapsedTime >= track.timeRange.lowerBound && $0.lift >= lift * 0.9 }) {
                let riseTime = ninetyPercent.elapsedTime - track.timeRange.lowerBound
                if riseTime < 0.5 {
                    failures.append(String(format: "word %d reached 90%% of its lift %.2fs after its start — that is the swell spring, not the syllable spring", track.wordIndex, riseTime))
                }
            } else {
                failures.append("word \(track.wordIndex) never reached 90% of its lift")
            }
            for (glyphIndex, glyphTrack) in track.glyphTracks.enumerated() {
                // 4. No swell for a word Music would leave at `.none`.
                if let swollen = glyphTrack.first(where: { abs($0.scale - 1) > 0.001 }) {
                    failures.append(String(format: "word %d glyph %d scaled to %.3f at %.2fs, but a short segment never swells", track.wordIndex, glyphIndex, swollen.scale, swollen.elapsedTime))
                }
                // 5. Up once, then stay: no travelling back after the peak, and
                //    the resting height is exactly `syllableLift`.
                guard let final = glyphTrack.last else { continue }
                let peak = glyphTrack.map(\.lift).max() ?? 0
                if peak - final.lift > 0.5 {
                    failures.append(String(format: "word %d glyph %d rose to %.2f pt and came back down to %.2f — the up-and-down the tag path used to have", track.wordIndex, glyphIndex, peak, final.lift))
                }
                if abs(final.lift - lift) > 0.5 {
                    failures.append(String(format: "word %d glyph %d ended %.2f pt high, expected %.0f", track.wordIndex, glyphIndex, final.lift, lift))
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(8).joined(separator: " ⏐ "))")
    }

    @Test func aHeldInlineTagSegmentSwellsByMusicsFactor() throws {
        let line = Self.makeHeldWordLine()
        let layout = try Self.makeLayout(line)
        let contentLayer = Self.makeContentLayer(layout: layout, policy: .appleMusic26)
        let wordLayers = Self.wordLayers(of: contentLayer)
        try #require(wordLayers.count == 2)

        // Past "stay"'s start plus the animation head start.
        contentLayer.update(elapsedTime: 0.35, fillFraction: 0.2)

        let factor: CGFloat = min(1.461, 2) - 1
        let expectedScale = AppleMusicLyrics.LyricsSpecs.emphasizingScaleRange.lowerBound
            + factor * (AppleMusicLyrics.LyricsSpecs.emphasizingScaleRange.upperBound - AppleMusicLyrics.LyricsSpecs.emphasizingScaleRange.lowerBound)
        let expectedGlow = AppleMusicLyrics.LyricsSpecs.glowOpacityRange.lowerBound
            + Float(factor) * (AppleMusicLyrics.LyricsSpecs.glowOpacityRange.upperBound - AppleMusicLyrics.LyricsSpecs.glowOpacityRange.lowerBound)

        let heldWordLayer = wordLayers[1]
        #expect(abs(heldWordLayer.shadowOpacity - expectedGlow) < 0.001, "the 1.46 s segment glows by its factor, got \(heldWordLayer.shadowOpacity)")
        for glyphLayer in heldWordLayer.sublayers ?? [] {
            let scale = CATransform3DGetAffineTransform(glyphLayer.transform).a
            #expect(abs(scale - expectedScale) < 0.001, "the 1.46 s segment swells by its factor, got scale \(scale)")
        }
        #expect(wordLayers[0].shadowOpacity == 0, "the 0.3 s segment never glows")
    }

    // MARK: Full-emphasis policy

    @Test func theFullEmphasisPolicyKeepsTheLegacyLookForInlineTags() throws {
        let line = Self.makeKugouLine()
        let layout = try Self.makeLayout(line)
        let contentLayer = Self.makeContentLayer(layout: layout, policy: .fullEmphasis)
        let wordLayers = Self.wordLayers(of: contentLayer)
        try #require(wordLayers.count == layout.words.count)

        contentLayer.update(elapsedTime: 0.05, fillFraction: 0.02)

        let firstWordLayer = try #require(wordLayers.first)
        #expect(firstWordLayer.shadowOpacity == AppleMusicLyrics.LyricsSpecs.glowOpacityRange.upperBound)
        for glyphLayer in firstWordLayer.sublayers ?? [] {
            let scale = CATransform3DGetAffineTransform(glyphLayer.transform).a
            #expect(abs(scale - AppleMusicLyrics.LyricsSpecs.emphasizingScaleRange.upperBound) < 0.001)
        }
    }

    // MARK: Harness

    private static func makeLayout(_ line: InlineTagLine, languageIdentifier: String = "en") throws -> AppleMusicLyrics.LineTextLayout {
        let attributed = NSAttributedString(
            string: line.text,
            attributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold)]
        )
        return try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: attributed,
            content: line.text,
            wordTimings: line.entries,
            languageIdentifier: languageIdentifier,
            lineDuration: line.lineDuration,
            textWidth: 1200
        ))
    }

    private static func makeContentLayer(
        layout: AppleMusicLyrics.LineTextLayout,
        policy: AppleMusicLyrics.StructuredEmphasisPolicy
    ) -> AppleMusicLyrics.SyncedLyricsLineContentLayer {
        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.structuredEmphasisPolicyProvider = { policy }
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)
        return contentLayer
    }

    private static func trace(
        _ line: InlineTagLine,
        policy: AppleMusicLyrics.StructuredEmphasisPolicy
    ) async throws -> [WordTrack] {
        let layout = try makeLayout(line)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1260, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let hostView = try #require(window.contentView)
        hostView.wantsLayer = true
        let contentLayer = makeContentLayer(layout: layout, policy: policy)
        contentLayer.anchorPoint = .zero
        contentLayer.position = CGPoint(x: 20, y: 40)
        hostView.layer?.addSublayer(contentLayer)
        contentLayer.update(elapsedTime: -0.5, fillFraction: 0)
        CATransaction.flush()

        let wordLayers = wordLayers(of: contentLayer)
        try #require(wordLayers.count == layout.words.count, "one word layer per tag segment")
        let glyphLayersByWord = wordLayers.map { $0.sublayers ?? [] }
        let restingPositions = glyphLayersByWord.map { $0.map(\.position.y) }

        let frameStep: TimeInterval = 1.0 / 20.0
        let frameCount = Int((line.lineDuration + 1.5) / frameStep)
        var samples = glyphLayersByWord.map { [[GlyphSample]](repeating: [], count: $0.count) }
        for frameIndex in 0 ..< frameCount {
            let elapsed = Double(frameIndex) * frameStep
            contentLayer.update(elapsedTime: elapsed, fillFraction: CGFloat(min(1, elapsed / line.lineDuration)))
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

        return layout.words.enumerated().compactMap { wordIndex, word in
            guard let timeRange = word.timeRange else { return nil }
            return WordTrack(wordIndex: wordIndex, timeRange: timeRange, glyphTracks: samples[wordIndex])
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
