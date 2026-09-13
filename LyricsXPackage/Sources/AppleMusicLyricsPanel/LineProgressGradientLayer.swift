import AppKit
import QuartzCore

extension AppleMusicLyrics {
    /// A layer that never runs an implicit animation. Apple Music uses one of
    /// these everywhere a layer is positioned by hand, so Core Animation's default
    /// quarter-second fade never fights an explicitly scheduled spring.
    class NoAnimationLayer: CALayer {
        override func action(forKey event: String) -> CAAction? {
            nil
        }
    }

    /// The sung/un-sung boundary of a line, as Apple Music draws it.
    ///
    /// Ported from `LineProgressGradientLayer` (`sub_10016A8F8` builds it,
    /// `sub_1001EB740` lays it out). It is a solid `fillLayer` covering the sung
    /// side plus a `gradientLayer` `featherWidth` points wide at the leading edge,
    /// and it is advanced by moving the whole thing sideways — so the boundary is
    /// a continuous ramp *across pixels* rather than a per-glyph opacity. Fading
    /// whole glyphs, which is what this replaces, leaves one or two letters parked
    /// at a flat mid opacity and reads as a blocky step.
    ///
    /// **One deliberate difference from Music.** Music resizes this layer as the
    /// line progresses; its sublayers are laid out from the *model* bounds, so
    /// mid-animation the presentation layer clips a feather that has not moved
    /// with it. We keep the width fixed and animate position only, which puts the
    /// ramp exactly where it belongs on every interpolated frame and never
    /// re-runs layout during a sweep. Same picture, fewer moving parts.
    final class LineProgressGradientLayer: CALayer {
        /// Which way the line is sung.
        enum Direction {
            case leadingToTrailing
            case trailingToLeading
        }

        private final class NoAnimationGradientLayer: CAGradientLayer {
            override func action(forKey event: String) -> CAAction? {
                nil
            }
        }

        let featherWidth: CGFloat
        let direction: Direction
        /// Extra height above and below the line, so an emphasized glyph that has
        /// grown and lifted is still covered by the sweep.
        let verticalPadding: CGFloat

        private let fillLayer = NoAnimationLayer()
        private let gradientLayer = NoAnimationGradientLayer()

        /// Width of the text this sweeps across; the layer itself is wider so the
        /// ramp can start and finish clear of both ends.
        private let lineWidth: CGFloat

        init(
            lineWidth: CGFloat,
            lineHeight: CGFloat,
            verticalPadding: CGFloat,
            featherWidth: CGFloat = LyricsSpecs.lineProgressionGradientFeather,
            direction: Direction = .leadingToTrailing,
            color: CGColor
        ) {
            self.lineWidth = lineWidth
            self.featherWidth = featherWidth
            self.direction = direction
            self.verticalPadding = verticalPadding
            super.init()

            masksToBounds = true
            addSublayer(fillLayer)
            addSublayer(gradientLayer)
            // Horizontal ramp, opaque on the sung side and clear on the leading
            // side, so the two sublayers meet without a seam.
            gradientLayer.startPoint = CGPoint(x: direction == .leadingToTrailing ? 0 : 1, y: 0.5)
            gradientLayer.endPoint = CGPoint(x: direction == .leadingToTrailing ? 1 : 0, y: 0.5)
            self.color = color
            // Swift never fires property observers for assignments made inside
            // the owning class's initializer, so the line above does not reach
            // the sublayers on its own — without this call every freshly built
            // sweep is colorless, and nothing downstream re-assigns `color`
            // after a rebuild.
            applyColor()
            bounds = CGRect(x: 0, y: 0, width: lineWidth + 2 * featherWidth, height: lineHeight + 2 * verticalPadding)
            anchorPoint = .zero
            layoutSublayers()
        }

        /// Core Animation calls this to build the presentation copy — for
        /// `presentation()` on this layer, and for any ancestor's copy that is
        /// then walked, as Xcode's view debugger does to the whole tree. The
        /// copy has to know the same geometry, or `originX(forFillEdge:)`
        /// answers for a zero-width line; the sublayers come from the render
        /// tree and need no copying here.
        override init(layer: Any) {
            if let source = layer as? LineProgressGradientLayer {
                self.lineWidth = source.lineWidth
                self.featherWidth = source.featherWidth
                self.direction = source.direction
                self.verticalPadding = source.verticalPadding
                self.color = source.color
            } else {
                // Unreachable in practice: Core Animation only ever passes an
                // instance of the same class.
                self.lineWidth = 0
                self.featherWidth = LyricsSpecs.lineProgressionGradientFeather
                self.direction = .leadingToTrailing
                self.verticalPadding = 0
            }
            super.init(layer: layer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func action(forKey event: String) -> CAAction? {
            nil
        }

        var color: CGColor = .init(gray: 1, alpha: 1) {
            didSet { applyColor() }
        }

        private func applyColor() {
            fillLayer.backgroundColor = color
            let clear = color.copy(alpha: 0) ?? CGColor(gray: 1, alpha: 0)
            gradientLayer.colors = direction == .leadingToTrailing ? [color, clear] : [clear, color]
        }

        override func layoutSublayers() {
            super.layoutSublayers()
            let size = bounds.size
            let solidWidth = max(0, size.width - featherWidth)
            switch direction {
            case .leadingToTrailing:
                fillLayer.frame = CGRect(x: 0, y: 0, width: solidWidth, height: size.height)
                gradientLayer.frame = CGRect(x: solidWidth, y: 0, width: featherWidth, height: size.height)
            case .trailingToLeading:
                gradientLayer.frame = CGRect(x: 0, y: 0, width: featherWidth, height: size.height)
                fillLayer.frame = CGRect(x: featherWidth, y: 0, width: solidWidth, height: size.height)
            }
        }

        /// Where this layer's origin has to sit for the middle of the ramp to land
        /// on `fillEdge`, measured in the line's coordinate space.
        ///
        /// `fillEdge` is a distance from the leading end of the text, so 0 is
        /// "nothing sung" and `lineWidth` is "all sung". Both ends overshoot by
        /// half a feather so the ramp is fully clear of the text at 0 and fully
        /// past it at the end.
        func originX(forFillEdge fillEdge: CGFloat) -> CGFloat {
            switch direction {
            case .leadingToTrailing:
                // The ramp spans [width - feather, width] from the origin, so its
                // middle is `width - feather / 2` along.
                return fillEdge - bounds.width + featherWidth / 2
            case .trailingToLeading:
                // Mirrored: the ramp is at the origin end.
                return lineWidth - fillEdge - featherWidth / 2
            }
        }

        /// Origin for a line that is completely sung, with the ramp pushed clear
        /// of the text so no part of it lands on a glyph.
        func originXForCompletelyFilled() -> CGFloat {
            originX(forFillEdge: lineWidth + featherWidth)
        }
    }
}
