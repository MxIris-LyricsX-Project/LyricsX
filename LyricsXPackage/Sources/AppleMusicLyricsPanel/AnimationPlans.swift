import AppKit

extension AppleMusicLyrics {
    struct WordEmphasisPlan: Equatable {
        enum TimingSource: Equatable {
            case synchronized
            case inferred
        }

        let factor: CGFloat
        let scale: CGFloat
        let glowOpacity: Float
        /// The duration the schedule was built for: the word's own under
        /// Music's gate, the phrase envelope under the full-emphasis policy.
        let wordDuration: TimeInterval
        let springPeriod: TimeInterval
        let glyphStagger: TimeInterval
        let riseDelays: [TimeInterval]
        let returnDelays: [TimeInterval]
        let deglowDelay: TimeInterval

        static let deglowSpringMass: CGFloat = 1
        static let deglowSpringStiffness: CGFloat = 14
        static let deglowSpringDamping: CGFloat = 7

        /// The per-glyph swell Music schedules for a word, or `nil` for a word
        /// Music does not animate glyph by glyph at all.
        ///
        /// `Lyrics.Word.emphasis` is `enum { case factor(Double), case none }`,
        /// decided when the model is built (`sub_1001C2DD4`): `.factor` needs
        /// the line's language to carry the `emphasis` capability
        /// (`sub_1001C28A4` withholds it from ar/he/zh/ja), a duration over one
        /// second, at most seven characters, and a positive `min(d, 2) - 1`.
        /// Everything else is `.none`, and `sub_10018B2B4` returns before
        /// touching a glyph for `.none` — those words are built from syllable
        /// layers instead and only get the ``SyllableLiftPlan`` lift.
        ///
        /// An inline-tag (`[tt]`) segment is judged the same way: Kugou and QQ
        /// Music tags carry real per-word / per-character timing, so a segment
        /// stands in for one of Music's syllables. Only the policy decides —
        /// `fullEmphasis` keeps the legacy look (factor 1, no leading stagger)
        /// for every timed word, whichever source it came from.
        static func make(
            wordDuration: TimeInterval,
            wordLength: Int,
            renderedGlyphCount: Int,
            timingGlyphCount: Int,
            languageIdentifier: String?,
            structuredEmphasisPolicy: StructuredEmphasisPolicy = .appleMusic26
        ) -> WordEmphasisPlan? {
            let safeDuration = max(0, wordDuration)
            let safeRenderedGlyphCount = max(0, renderedGlyphCount)
            let safeTimingGlyphCount = max(1, timingGlyphCount)
            let factor: CGFloat
            // Music offsets every glyph by `index + 1`, which costs a whole
            // stagger before its first glyph moves. The full-emphasis look
            // drops that leading offset.
            let leadsWithAStagger: Bool
            switch structuredEmphasisPolicy {
            case .appleMusic26:
                guard LyricsLanguageCapabilities.allowsAdditionalEmphasis(languageIdentifier: languageIdentifier),
                      safeDuration > 1,
                      wordLength <= 7 else {
                    return nil
                }
                factor = CGFloat(min(safeDuration, 2) - 1)
                guard factor > 0 else { return nil }
                leadsWithAStagger = true
            case .fullEmphasis:
                factor = 1
                leadsWithAStagger = false
            }

            let scale = LyricsSpecs.emphasizingScaleRange.lowerBound
                + factor * (LyricsSpecs.emphasizingScaleRange.upperBound - LyricsSpecs.emphasizingScaleRange.lowerBound)
            let glowOpacity = LyricsSpecs.glowOpacityRange.lowerBound
                + Float(factor) * (LyricsSpecs.glowOpacityRange.upperBound - LyricsSpecs.glowOpacityRange.lowerBound)
            let glyphStagger = LyricsSpecs.glyphStagger(
                wordDuration: safeDuration,
                glyphCount: safeTimingGlyphCount
            )
            let returnInterval = LyricsSpecs.returnDelay(
                wordDuration: safeDuration,
                glyphCount: safeTimingGlyphCount
            )
            let riseDelays = (0 ..< safeRenderedGlyphCount).map { glyphIndex in
                glyphStagger * TimeInterval(glyphIndex + (leadsWithAStagger ? 1 : 0))
            }
            let returnDelays = riseDelays.map { $0 + returnInterval }

            return WordEmphasisPlan(
                factor: factor,
                scale: scale,
                glowOpacity: glowOpacity,
                wordDuration: safeDuration,
                springPeriod: LyricsSpecs.emphasisSpringPeriod(wordDuration: safeDuration),
                glyphStagger: glyphStagger,
                riseDelays: riseDelays,
                returnDelays: returnDelays,
                deglowDelay: safeDuration
            )
        }
    }

    /// Music's per-syllable lift, the only motion a `.none` word gets.
    ///
    /// `sub_1001689D4` runs every syllable of every word through
    /// `sub_1001897C0` each frame; when a syllable turns sung its
    /// `SyllableLayer` takes `translation(0, -syllableLift)` (change closure
    /// `sub_100189C0C`) on a `CASpringAnimation(mass 1, stiffness 14,
    /// damping 7)` timed by that spring's own `settlingDuration`, and a rewind
    /// runs the same spring back to identity. It is the same spring the glow
    /// decays on, and it takes about a second to settle — which is why a line
    /// of short words reads as a soft ripple under the sweep rather than a
    /// row of pops. `.factor` words are built from glyph layers instead
    /// (`sub_10018DA78`), so the lift and the swell never stack.
    enum SyllableLiftPlan {
        static let springMass: CGFloat = 1
        static let springStiffness: CGFloat = 14
        static let springDamping: CGFloat = 7

        static let springTiming = SpringTimingParameters(
            mass: springMass,
            stiffness: springStiffness,
            damping: springDamping
        )
    }

    enum LyricsLanguageCapabilities {
        /// `sub_1001C28A4`: these languages get `[gradient, lift]`, every
        /// other one `[gradient, lift, emphasis]`.
        private static let languagesWithoutAdditionalEmphasis: Set<String> = ["ar", "he", "zh", "ja"]

        static func allowsAdditionalEmphasis(languageIdentifier: String?) -> Bool {
            guard let languageIdentifier, !languageIdentifier.isEmpty else { return true }
            let baseLanguage = languageIdentifier
                .lowercased()
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first
                .map(String.init) ?? languageIdentifier.lowercased()
            return !languagesWithoutAdditionalEmphasis.contains(baseLanguage)
        }
    }

    enum LineTransitionPlan {
        static let selectedLineBaselineViewportFraction: CGFloat = 0.4
        /// `LyricsSpecs.lineChangeSpringTimingParametersValues` as Music 26.6's
        /// `LyricsSpecs` initializer (`sub_1001D1C28`) fills it in. This is the
        /// fallback for line-timed lyrics or a missing sung gap; timedWords uses
        /// `automaticSpringTiming(sungGap:)` instead.
        static let normalSpringMass: CGFloat = 1
        static let normalSpringStiffness: CGFloat = 100
        static let normalSpringDamping: CGFloat = 18
        /// `LyricsSpecs.lineDelay` in the full-window (pretty) mode; the sidebar
        /// uses 0.02. `sub_1001DCBD4` uses `max(rowIndex - 1, 0)`, so the first
        /// two participating rows start together.
        static let appleMusicLineDelay: TimeInterval = 0.05
        /// When the lyrics move backwards the same function hands the delays out
        /// from the bottom row up and halves them.
        static let appleMusicBackwardLineDelayScale: Double = 0.5
        static let interactiveSpringMass: CGFloat = 2
        static let interactiveSpringStiffness: CGFloat = 260
        static let interactiveSpringDamping: CGFloat = 50
        static let cascadeSpringPeriod: TimeInterval = 0.6
        static let cascadeSpringDampingRatio: CGFloat = 0.725
        static let cascadeSettleDuration: TimeInterval = 0.5
        static let cascadeStagger: TimeInterval = 0.08
        static let cascadeAboveLineCount = 3
        static let cascadeBelowLineCount = 6
        static let rapidTransitionThreshold: TimeInterval = 0.4
        static let rapidSettleSpringPeriod: TimeInterval = 0.5
        static let rapidSettleDampingRatio: CGFloat = 1

        /// Music's timedWords dispatch (`sub_1001E0994`) passes the gap between
        /// the next line's start and the previous selected line's sung end to
        /// `sub_1001D1A10`. The clamp handles overlapping vocals as well as rests.
        static func automaticSpringTiming(sungGap: TimeInterval?) -> SpringTimingParameters {
            guard let sungGap, sungGap.isFinite else {
                return SpringTimingParameters(
                    mass: normalSpringMass,
                    stiffness: normalSpringStiffness,
                    damping: normalSpringDamping
                )
            }
            let interpolationFraction = min(max((sungGap - 0.2) / 0.55, 0), 1)
            return SpringTimingParameters(
                dampingRatio: CGFloat((1 - interpolationFraction) * 0.12 + 0.78),
                period: interpolationFraction * 0.27 + 0.48
            )
        }

        /// Apple Music's `.topRelative` value positions the text baseline at a
        /// percentage of the visible card height. Our row frame also includes its
        /// own top padding, so subtract the complete baseline offset rather than
        /// only the font ascent recovered from Music's text-only line frame.
        static func selectedLineTopInset(
            visibleHeight: CGFloat,
            firstBaselineOffset: CGFloat
        ) -> CGFloat {
            selectedLineTopInset(
                anchor: .baselineViewportFraction(selectedLineBaselineViewportFraction),
                visibleHeight: visibleHeight,
                contentCenterOffset: 0,
                firstBaselineOffset: firstBaselineOffset
            )
        }

        /// How far the first line starts below the document's top so that the
        /// selected line lands on the anchor. Music's `.center(rect:)`
        /// (`sub_10015CD84`) centres the whole line frame on the anchor's y;
        /// the project's row carries its own padding, so the centre is measured
        /// from the row's top edge with `contentCenterOffset`.
        static func selectedLineTopInset(
            anchor: SelectedLineAnchor,
            visibleHeight: CGFloat,
            contentCenterOffset: CGFloat,
            firstBaselineOffset: CGFloat
        ) -> CGFloat {
            switch anchor {
            case .baselineViewportFraction(let fraction):
                return max(0, visibleHeight * fraction - firstBaselineOffset)
            case .contentCenter(let anchorY):
                return max(0, anchorY - contentCenterOffset)
            }
        }
    }

    struct LineBlurPlan: Equatable {
        let blurredLinePositions: Set<Int>
        let radius: CGFloat

        static func make(visibleLinePositions: Set<Int>, selectedLinePosition: Int?) -> LineBlurPlan {
            guard let selectedLinePosition else {
                return LineBlurPlan(blurredLinePositions: [], radius: 0)
            }
            return LineBlurPlan(
                blurredLinePositions: visibleLinePositions.subtracting([selectedLinePosition]),
                radius: LyricsSpecs.deselectedLineBlurRadius
            )
        }
    }
}
