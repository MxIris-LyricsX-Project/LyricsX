import AppKit
import QuartzCore

extension AppleMusicLyrics {
    /// The subset of Apple Music's `LyricsSpecs` that drives a synced lyric line.
    ///
    /// Music keeps these in a 880-byte struct that its own view controller injects
    /// into `SyncedLyricsLineLayer`, so the values are not compiled into the
    /// animation code. The first section was read out of a live `LyricsSpecs` by
    /// attaching lldb to Music 1.6.5 and breaking on the per-Word emphasis
    /// scheduler, whose X0 is the specs pointer (2026-07-26; scratchpad
    /// `dump_specs.py`); the Music 26.6 section was read from the initializer
    /// that fills the struct in. The offsets are the ones the disassembly reads,
    /// kept here so a future dump can be checked field by field.
    ///
    /// The constants at the bottom are different in kind: they are literals
    /// compiled into the animation code itself, so they came from the
    /// disassembly rather than from a dump.
    enum LyricsSpecs {
        // MARK: Read from a live LyricsSpecs

        /// `emphasizingScaleRange` (+0x100). A word's glyphs scale to
        /// `lowerBound + t * (upperBound - lowerBound)`, where `t` is the word's
        /// own emphasis factor — so `t = 0` is no swell at all and `t = 1` is the
        /// full 14%.
        static let emphasizingScaleRange: ClosedRange<CGFloat> = 1.0 ... 1.14
        /// `syllableLift` (+0x2D0) — how far an emphasized glyph rises, in points.
        static let syllableLift: CGFloat = 3
        /// `animationHeadstart` (+0x220) — how far ahead of the lyric timing the
        /// animation starts, so it does not read as half a beat late.
        static let animationHeadstart: TimeInterval = 0.1
        /// `glowRadius` (+0x238) — the active word's `shadowRadius`.
        static let glowRadius: CGFloat = 5
        /// `glowRange` (+0x240) — the active word's `shadowOpacity`, interpolated
        /// by the same `t` as the scale.
        static let glowOpacityRange: ClosedRange<Float> = 0 ... 0.4
        /// `lineProgressionGradientFeather` (+0x250) — width of the sung/un-sung
        /// ramp, in points.
        static let lineProgressionGradientFeather: CGFloat = 30
        /// `lineFinishProgressAnimationDuration` (+0x2E8) — how long the sweep
        /// takes to run out to the end once the line is done.
        static let lineFinishProgressAnimationDuration: TimeInterval = 0.25

        // MARK: Line blur

        /// What `SyncedLyricsLineLayer.blurRadius` is set to when a line stops
        /// being the selected one (`sub_1001E9420`, and the same literal in the
        /// scroll controller's own branch). The selected line goes to 0.
        ///
        /// Measured against a screen recording of Music 26.5.2 as a check: the
        /// selected line's stroke edges cross 20%→80% of their own amplitude in
        /// 1 pixel, every other line in 7–8 — the same width whether the line is
        /// one away or four, which is what says this is a switch and not a
        /// distance ramp.
        static let deselectedLineBlurRadius: CGFloat = 3
        /// `sub_1001E3148` clamps whatever it is handed to this before setting it.
        static let maximumLineBlurRadius: CGFloat = 4
        /// The two radii above are Music's stored constants, but Music's screen
        /// does not show a raw radius-3 gaussian: its un-selected lines measure a
        /// 7–8 pixel 20%→80% stroke edge at 2×, which both `CAFilter` and
        /// `CIGaussianBlur` reach at an `inputRadius` near 1.875, not 3 — the two
        /// filter classes render identically per unit of radius (measured
        /// side-by-side on a step edge: both 10px at 3, so this is not a
        /// private-vs-public semantic gap). Music evidently scales the stored
        /// value somewhere before it reaches the filter; until that spot is
        /// found in the disassembly, this factor reproduces the *screen*, which
        /// is the part that can be checked.
        static let renderedBlurRadiusScale: CGFloat = 0.625
        /// Duration and cubic curve used for `filters.gaussianBlur.inputRadius`.
        static let lineBlurAnimationDuration: TimeInterval = 0.12
        static let lineBlurTimingControlPoint1 = CGPoint(x: 0.33, y: 0)
        static let lineBlurTimingControlPoint2 = CGPoint(x: 0.2, y: 0.1)
        /// The three values above as one curve. `sub_10019EBAC` animates every
        /// line filter on it — the blur radius, and the hover brightness when a
        /// hovered line becomes the selected one.
        static let lineFilterTiming = CubicTimingParameters(
            duration: lineBlurAnimationDuration,
            controlPoint1: lineBlurTimingControlPoint1,
            controlPoint2: lineBlurTimingControlPoint2
        )

        // MARK: Read from Music 26.6's LyricsSpecs initializer

        // The values below come from the 26.6 binary rather than a live dump:
        // `sub_1001D1C28` fills in the defaults and `sub_1001D0A1C`, the closure
        // the Now Playing ("pretty") window applies on top, overrides some of
        // them. The field names are the struct's own, from its type metadata.

        /// `selectedUpcomingTextColor` (+368): the selected line's text that has
        /// not been sung yet, and the selected line's translation.
        static let selectedUpcomingTextOpacity: CGFloat = 0.5
        /// `deselectedTextColor` (+384): the text and translation of every other
        /// line. Music dims those lines by colour; the line layer itself stays
        /// fully opaque.
        static let deselectedTextOpacity: CGFloat = 0.4
        /// `translationSpacing` (+296): the gap between the main text block and
        /// the translation under it.
        static let translationSpacing: CGFloat = 7
        /// `touchDownTransform` (+0x258): what a pressed line's container and
        /// highlight shrink to, about their centres.
        static let touchDownTransform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        /// `highlightLabelAlpha` (+0x288): the pressed line's container opacity.
        static let highlightLabelOpacity: Float = 0.85
        /// `highlightViewBackgroundColor` (+0x290): the rounded highlight behind
        /// a pressed line — `NSColor(white: 1, alpha: 0.08)`.
        static let highlightViewBackgroundColor = CGColor(gray: 1, alpha: 0.08)
        /// `highlightViewCornerRadius` (+0x2A0), drawn with a continuous corner
        /// curve.
        static let highlightViewCornerRadius: CGFloat = 16
        /// `highlightViewMargin` (+0x2A8): how far the highlight reaches past
        /// the line's frame on every side.
        static let highlightViewMargin: CGFloat = 16
        /// `inputAmount` of the `colorBrightness` filter on a hovered line.
        /// `sub_10019EEDC` uses −1 when `focusStyle` (+0x2F4) is `.dark` and +1
        /// otherwise; the Now Playing window sets `.bright`.
        static let focusedLineBrightnessAmount = 1

        // MARK: Literals compiled into the animation code

        /// `sub_10018B2B4` clamps the emphasis spring's period to this.
        static let maximumEmphasisSpringPeriod: TimeInterval = 3
        /// Per-glyph stagger is `min(wordDuration / glyphCount * this, maximumGlyphStagger)`.
        static let glyphStaggerFraction: Double = 0.4
        /// Upper bound on the per-glyph stagger, so a long word does not turn the
        /// ripple into a crawl.
        static let maximumGlyphStagger: TimeInterval = 0.4
        /// The emphasis spring is critically damped: the bounce comes from the
        /// glyphs being staggered against each other, not from any one glyph
        /// ringing.
        static let emphasisDampingRatio: CGFloat = 1
        /// Every animation Music schedules here asks for this range, so the
        /// ripple keeps up on a ProMotion display.
        static let preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

        // MARK: Derived

        /// How long after its emphasis a glyph starts travelling back, as a
        /// multiple of the stagger — `sub_10018B2B4` schedules the return pass at
        /// `stagger * (index + 1) + 2 * wordDuration / glyphCount`.
        static func returnDelay(wordDuration: TimeInterval, glyphCount: Int) -> TimeInterval {
            guard glyphCount > 0 else { return 0 }
            return 2 * wordDuration / TimeInterval(glyphCount)
        }

        /// Per-glyph stagger for a word, exactly as `sub_10018B2B4` computes it.
        static func glyphStagger(wordDuration: TimeInterval, glyphCount: Int) -> TimeInterval {
            guard glyphCount > 0 else { return 0 }
            return min(wordDuration / TimeInterval(glyphCount) * glyphStaggerFraction, maximumGlyphStagger)
        }

        /// Period of the emphasis spring for a word.
        static func emphasisSpringPeriod(wordDuration: TimeInterval) -> TimeInterval {
            min(wordDuration, maximumEmphasisSpringPeriod)
        }
    }
}
