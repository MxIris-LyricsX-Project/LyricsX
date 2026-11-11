import AppKit
import QuartzCore

extension AppleMusicLyrics {
    /// A line's translation, drawn into a layer of its own.
    ///
    /// Music lays the translation out next to the main text inside the line's
    /// container (`sub_10017A8D0` puts it `translationSpacing` below the text
    /// block), so a press shrinks and dims the two together. The text is drawn
    /// in white and the row sets this layer's opacity to the colour Music would
    /// pick (`sub_10017A270`), which lets a selection change switch it at once
    /// without drawing the text again.
    final class LineTranslationLayer: CALayer {
        var attributedText: NSAttributedString? {
            didSet { setNeedsDisplay() }
        }

        override init() {
            super.init()
            needsDisplayOnBoundsChange = true
            isOpaque = false
        }

        /// Core Animation calls this to build presentation and copy layers; the
        /// text has to come along or the copy draws nothing.
        override init(layer: Any) {
            self.attributedText = (layer as? LineTranslationLayer)?.attributedText
            super.init(layer: layer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func action(forKey event: String) -> CAAction? {
            nil
        }

        override func draw(in context: CGContext) {
            guard let attributedText else { return }
            // `NSAttributedString` lays text out top-down in a flipped graphics
            // context. Whether the context Core Animation hands over is already
            // y-down depends on the whole ancestor chain, so ask rather than
            // assume, and flip it here only when it is not.
            context.saveGState()
            if !contentsAreFlipped() {
                context.translateBy(x: 0, y: bounds.height)
                context.scaleBy(x: 1, y: -1)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            attributedText.draw(
                with: CGRect(origin: .zero, size: bounds.size),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
        }
    }
}
