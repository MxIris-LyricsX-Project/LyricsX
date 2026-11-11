import AppKit
import CoreText
import QuartzCore

extension AppleMusicLyrics {
    /// One glyph of a lyric line, as its own layer.
    ///
    /// This is Apple Music's `SyncedLyricsLineLayer.Glyph.GlyphLayer`, whose
    /// superclass is `CTRun.PartialRunLayer` in MusicUtilities. It keeps a
    /// reference to the `CTRun` it came from plus the range of that run it is
    /// responsible for, and draws exactly those glyphs and nothing else — so the
    /// line is laid out once by Core Text and then sliced into layers, rather
    /// than being re-laid-out per glyph.
    ///
    /// It draws **white on a grayscale layer** (`sub_1001FDE5C` sets the fill to
    /// `CGColorCreateGenericGray(1, 1)` and the factory sets
    /// `contentsFormat = .gray8Uint`). That is not the text colour: the whole
    /// glyph tree is used as a *mask*, and the colour comes from the layers
    /// underneath it. Keeping shape and colour in separate layers is what lets a
    /// glyph scale while the sung/un-sung boundary sweeping across it stays
    /// pixel-continuous.
    final class GlyphRunLayer: CALayer {
        private let run: CTRun
        private let glyphRange: CFRange
        /// Where the run's text origin sits inside this layer's bounds.
        private let textPosition: CGPoint

        init(run: CTRun, glyphRange: CFRange, textPosition: CGPoint, contentsScale: CGFloat) {
            self.run = run
            self.glyphRange = glyphRange
            self.textPosition = textPosition
            super.init()
            needsDisplayOnBoundsChange = true
            self.contentsScale = contentsScale
            isOpaque = false
            // Documented as the format to use for mask layers: one 8-bit coverage
            // value per pixel, a quarter the memory of RGBA for the same result.
            contentsFormat = .gray8Uint
        }

        /// Core Animation calls this to build presentation and copy layers; the
        /// stored text state has to come along or the presentation layer draws
        /// nothing.
        override init(layer: Any) {
            if let source = layer as? GlyphRunLayer {
                self.run = source.run
                self.glyphRange = source.glyphRange
                self.textPosition = source.textPosition
            } else {
                // Unreachable in practice: Core Animation only ever passes an
                // instance of the same class.
                self.run = Self.emptyRun
                self.glyphRange = CFRange(location: 0, length: 0)
                self.textPosition = .zero
            }
            super.init(layer: layer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Music's `PartialRunLayer` returns nil here. Every animation on these
        /// layers is scheduled explicitly by `LayerPropertyAnimator`, so implicit
        /// actions would only fight it — a `frame` change during layout would
        /// otherwise pick up CoreAnimation's default quarter-second fade.
        override func action(forKey event: String) -> CAAction? {
            nil
        }

        override func draw(in context: CGContext) {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            // Core Text lays glyphs out y-up. Whether the context we are handed is
            // y-up or y-down depends on the geometry of the whole ancestor chain,
            // so ask rather than assume — getting it backwards silently renders
            // every glyph upside down.
            context.textMatrix = contentsAreFlipped()
                ? CGAffineTransform(translationX: textPosition.x, y: bounds.height + textPosition.y).scaledBy(x: 1, y: -1)
                : CGAffineTransform(translationX: textPosition.x, y: -textPosition.y)
            CTRunDraw(run, context, glyphRange)
        }

        /// A run with no glyphs, for the `init(layer:)` path that cannot happen.
        private static let emptyRun: CTRun = {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: " "))
            // A single-space line always produces exactly one run.
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], let first = runs.first else {
                fatalError("Core Text produced no runs for a non-empty string")
            }
            return first
        }()
    }
}
