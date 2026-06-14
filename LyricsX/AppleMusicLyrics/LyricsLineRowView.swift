import AppKit
import CoreText
import QuartzCore
import LyricsXFoundation
import OpenCC

@available(macOS 15, *)
extension AppleMusicLyrics {
    /// One lyric line, rendered as a layer-backed `NSView`.
    ///
    /// Mirrors Apple Music's `SyncedLyricsLineView`: the text is laid out once
    /// and cached in the view's backing store. Non-highlighted lines never
    /// redraw — distance fading is a cheap `alphaValue` animation. Only the
    /// single highlighted line repaints (driven by the container's display
    /// link) to advance the karaoke fill, and that repaint is one short
    /// Core Graphics text pass, not a SwiftUI view-graph re-evaluation — which
    /// is the performance win over the previous SwiftUI `TextRenderer`.
    ///
    /// The fill is drawn with a two-pass technique inside `draw(_:)`:
    /// 1. the whole line at a dim "un-sung" opacity,
    /// 2. the sung prefix at full brightness, clipped to the fill edge.
    ///
    /// Drawing in `draw(_:)` keeps everything in the view's (flipped)
    /// coordinate space, which AppKit sets up correctly — avoiding the
    /// flipped-backing-layer geometry pitfalls of manual sublayers.
    ///
    /// > Phase 3 will swap the per-frame redraw for a zero-redraw
    /// > `CAGradientLayer` mask (Apple's `LineProgressGradientLayer`) and add a
    /// > feathered edge + per-visual-line distribution for wrapped lines, once
    /// > the exact feather/geometry can be verified at runtime.
    final class SyncedLyricsLineView: NSView {
        // MARK: Model

        private(set) var line: LyricsLine?
        private(set) var originalIndex: Int = -1
        /// Position among the *enabled* lines (used for distance-based fading).
        var enabledPosition: Int = 0

        var onTap: ((LyricsLine) -> Void)?

        private var mainFontSize: CGFloat = 32
        private var translationFontSize: CGFloat = 18

        // MARK: State

        private(set) var isHighlighted = false
        private var karaokeFraction: CGFloat = 0
        private var lastDrawnFraction: CGFloat = -1

        // MARK: Cached layout

        private var mainAttributed: NSAttributedString?
        private var translationAttributed: NSAttributedString?
        private var mainTextSize: CGSize = .zero
        private var translationTextSize: CGSize = .zero
        private var sizedForWidth: CGFloat = -1
        /// Per-visual-line widths of the (possibly wrapped) main text, so the
        /// karaoke fill cascades line-by-line instead of filling every wrapped
        /// row in lockstep.
        private var visualLineWidths: [CGFloat] = []

        // MARK: Layout / appearance constants (tuned against Apple's values in Phase 3)

        private let verticalPadding: CGFloat = 28
        private let horizontalPadding: CGFloat = 24
        private let mainToTranslationSpacing: CGFloat = 4
        private let unsungOpacity: CGFloat = 0.4
        /// Subtle "pop" of the current line, mirroring Apple Music's emphasis.
        /// Kept modest so it never overlaps neighbours given the line padding.
        private let highlightScale: CGFloat = 1.05

        // MARK: Lifecycle

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool { true }

        // MARK: Configuration

        func configure(line: LyricsLine, originalIndex: Int, enabledPosition: Int, mainFontSize: CGFloat, translationFontSize: CGFloat) {
            self.line = line
            self.originalIndex = originalIndex
            self.enabledPosition = enabledPosition
            self.mainFontSize = mainFontSize
            self.translationFontSize = translationFontSize
            rebuildAttributedStrings()
        }

        func updateFonts(mainFontSize: CGFloat, translationFontSize: CGFloat) {
            guard mainFontSize != self.mainFontSize || translationFontSize != self.translationFontSize else { return }
            self.mainFontSize = mainFontSize
            self.translationFontSize = translationFontSize
            rebuildAttributedStrings()
        }

        /// Re-reads the bilingual / Chinese-conversion preferences and rebuilds
        /// the attributed strings. Called when those preferences change while a
        /// track is already displayed.
        func refreshTranslation() {
            rebuildAttributedStrings()
        }

        private func rebuildAttributedStrings() {
            guard let line else {
                mainAttributed = nil
                translationAttributed = nil
                return
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byWordWrapping

            mainAttributed = NSAttributedString(
                string: line.content,
                attributes: [
                    .font: NSFont.systemFont(ofSize: mainFontSize, weight: .bold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: paragraph,
                ]
            )

            translationAttributed = Self.makeTranslationAttributedString(
                for: line,
                fontSize: translationFontSize,
                paragraph: paragraph
            )

            sizedForWidth = -1 // force re-measure
            needsDisplay = true
        }

        private static func makeTranslationAttributedString(for line: LyricsLine, fontSize: CGFloat, paragraph: NSParagraphStyle) -> NSAttributedString? {
            guard defaults[.preferBilingualLyrics],
                  let translation = line.attachments.translation() else {
                return nil
            }
            let displayText: String
            if let converter = ChineseConverter.shared {
                displayText = converter.convert(translation)
            } else {
                displayText = translation
            }
            return NSAttributedString(
                string: displayText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.7),
                    .paragraphStyle: paragraph,
                ]
            )
        }

        // MARK: Measurement

        func preferredHeight(forWidth width: CGFloat) -> CGFloat {
            measureIfNeeded(forWidth: width)
            var height = verticalPadding * 2 + mainTextSize.height
            if translationAttributed != nil {
                height += mainToTranslationSpacing + translationTextSize.height
            }
            return ceil(height)
        }

        private func measureIfNeeded(forWidth width: CGFloat) {
            guard width != sizedForWidth else { return }
            sizedForWidth = width
            let textWidth = max(1, width - horizontalPadding * 2)
            let constraint = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
            let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

            if let mainAttributed {
                let rect = mainAttributed.boundingRect(with: constraint, options: options)
                mainTextSize = CGSize(width: ceil(rect.width), height: ceil(rect.height))
                visualLineWidths = Self.computeVisualLineWidths(mainAttributed, maxWidth: textWidth)
            } else {
                mainTextSize = .zero
                visualLineWidths = []
            }

            if let translationAttributed {
                let rect = translationAttributed.boundingRect(with: constraint, options: options)
                translationTextSize = CGSize(width: ceil(rect.width), height: ceil(rect.height))
            } else {
                translationTextSize = .zero
            }
            needsDisplay = true
        }

        // MARK: Drawing

        override func draw(_ dirtyRect: NSRect) {
            measureIfNeeded(forWidth: bounds.width)
            lastDrawnFraction = karaokeFraction

            let textWidth = max(1, bounds.width - horizontalPadding * 2)
            let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
            let mainRect = CGRect(x: horizontalPadding, y: verticalPadding, width: textWidth, height: mainTextSize.height)

            if let mainAttributed {
                if isHighlighted {
                    drawMainKaraoke(mainAttributed, in: mainRect, options: options)
                } else {
                    drawAttributed(mainAttributed, in: mainRect, options: options, alpha: 1.0)
                }
            }

            if let translationAttributed {
                let translationY = verticalPadding + mainTextSize.height + mainToTranslationSpacing
                translationAttributed.draw(
                    with: CGRect(x: horizontalPadding, y: translationY, width: textWidth, height: translationTextSize.height),
                    options: options
                )
            }
        }

        private func drawMainKaraoke(_ attributed: NSAttributedString, in rect: CGRect, options: NSString.DrawingOptions) {
            // Pass 1: whole line at un-sung opacity.
            drawAttributed(attributed, in: rect, options: options, alpha: unsungOpacity)

            // Pass 2: sung prefix at full brightness, cascading across wrapped
            // visual lines — the fill advances along visual line 0, then 1, …,
            // rather than lighting every wrapped row in lockstep.
            let fraction = min(1, max(0, karaokeFraction))
            guard fraction > 0, let context = NSGraphicsContext.current?.cgContext else { return }

            let widths = visualLineWidths.isEmpty ? [mainTextSize.width] : visualLineWidths
            let totalWidth = widths.reduce(0, +)
            guard totalWidth > 0 else { return }

            let rowHeight = mainTextSize.height / CGFloat(widths.count)
            let totalFilledWidth = totalWidth * fraction
            var consumedWidth: CGFloat = 0

            for (visualLineIndex, lineWidth) in widths.enumerated() {
                let remainingFill = totalFilledWidth - consumedWidth
                consumedWidth += lineWidth
                guard lineWidth > 0, remainingFill > 0 else { continue }

                let fillWidth = min(lineWidth, remainingFill)
                let rowY = rect.minY + CGFloat(visualLineIndex) * rowHeight
                context.saveGState()
                context.clip(to: CGRect(x: rect.minX, y: rowY, width: fillWidth, height: rowHeight))
                drawAttributed(attributed, in: rect, options: options, alpha: 1.0)
                context.restoreGState()
            }
        }

        /// Lays the wrapped text out once via Core Text to recover the width of
        /// each visual line; cached in `measureIfNeeded`, never per frame.
        private static func computeVisualLineWidths(_ attributed: NSAttributedString, maxWidth: CGFloat) -> [CGFloat] {
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGMutablePath()
            // Unbounded height: CoreText's per-line advance can exceed
            // NSStringDrawing's boundingRect height by a fraction, and CTFrame
            // only emits lines that fully fit the path — a height-bounded path
            // would silently drop the last visual line(s), making widths.count
            // smaller than the rows actually drawn and corrupting the cascade.
            path.addRect(CGRect(x: 0, y: 0, width: maxWidth, height: 100_000))
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            guard let lines = CTFrameGetLines(frame) as? [CTLine] else { return [] }
            return lines.map { line in
                CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
        }

        private func drawAttributed(_ attributed: NSAttributedString, in rect: CGRect, options: NSString.DrawingOptions, alpha: CGFloat) {
            guard let context = NSGraphicsContext.current?.cgContext else {
                attributed.draw(with: rect, options: options)
                return
            }
            context.saveGState()
            context.setAlpha(alpha)
            attributed.draw(with: rect, options: options)
            context.restoreGState()
        }

        // MARK: Highlight / Fade

        func setHighlighted(_ highlighted: Bool) {
            guard isHighlighted != highlighted else { return }
            isHighlighted = highlighted
            if !highlighted {
                karaokeFraction = 0
            }
            needsDisplay = true
            updateScaleEmphasis(animated: true)
        }

        // MARK: Scale emphasis (current line "pops")
        //
        // Known minor limitation: the scale is a purely visual `layer.transform`,
        // so hit-testing still uses the unscaled frame. The ~2.4pt enlarged
        // sliver of the current line is not clickable (a tap there routes to the
        // neighbour). Accepted: the scale is small, the text body stays well
        // inside the unscaled bounds, and the current line is the playing one.

        private func updateScaleEmphasis(animated: Bool) {
            guard let layer else { return }
            let target = leadingScaleTransform(isHighlighted ? highlightScale : 1.0)
            if animated {
                let animation = CABasicAnimation(keyPath: "transform")
                animation.fromValue = layer.presentation()?.transform ?? layer.transform
                animation.toValue = target
                animation.duration = 0.4
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: "scaleEmphasis")
            }
            layer.transform = target
        }

        /// Scales around the **leading edge** (text start), vertical center —
        /// regardless of the backing layer's `anchorPoint` (which AppKit owns).
        /// Anchoring at the center would push a short, left-aligned line leftward
        /// (more the wider the view), drifting it out of alignment with the other
        /// lines and clipping it against the scroll view; anchoring at the leading
        /// edge keeps the text start fixed and grows rightward. `layer.transform`
        /// is not in AppKit's view→layer property sync set, so it is safe to set.
        private func leadingScaleTransform(_ scale: CGFloat) -> CATransform3D {
            guard scale != 1.0, let layer else { return CATransform3DIdentity }
            let offsetX = horizontalPadding - bounds.width * layer.anchorPoint.x
            let offsetY = bounds.midY - bounds.height * layer.anchorPoint.y
            var transform = CATransform3DIdentity
            transform = CATransform3DTranslate(transform, offsetX, offsetY, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            transform = CATransform3DTranslate(transform, -offsetX, -offsetY, 0)
            return transform
        }

        override func layout() {
            super.layout()
            // Re-derive the leading-scale transform after a size change.
            if isHighlighted {
                updateScaleEmphasis(animated: false)
            }
        }

        func animateAlpha(to target: CGFloat, duration: TimeInterval) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().alphaValue = target
            }
        }

        // MARK: Karaoke (per-frame, highlighted line only)

        func updateKaraoke(elapsedTime: TimeInterval, lineDuration: TimeInterval, mode: KaraokeMode) {
            guard let line, isHighlighted else { return }
            let fraction = KaraokeFill.fraction(
                elapsedTime: elapsedTime,
                lineDuration: lineDuration,
                wordTimings: line.wordTimingEntries ?? [],
                totalCharacterCount: line.content.count,
                mode: mode
            )
            karaokeFraction = fraction
            // Repaint only when the fill edge moved by at least half a point,
            // so a paused or slow-moving line does not repaint every frame.
            if abs(fraction - lastDrawnFraction) * max(1, mainTextSize.width) >= 0.5 {
                needsDisplay = true
            }
        }

        // MARK: Hit testing

        override func mouseDown(with event: NSEvent) {
            // Swallow so `mouseUp` is delivered to this view.
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), let line else { return }
            onTap?(line)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    /// The "•••" instrumental indicator shown during a long intro (and, later,
    /// interludes), mirroring Apple Music. Three dots light up left-to-right and
    /// swell slightly as the gap nears its end. Drawn as plain circles, so it is
    /// orientation-agnostic (no flipped-layer concerns).
    final class SyncedLyricsInstrumentalView: NSView {
        private var progress: CGFloat = 0
        private var lastDrawnProgress: CGFloat = -1

        private let horizontalPadding: CGFloat = 24
        private let dotRadius: CGFloat = 7
        private let dotSpacing: CGFloat = 26
        private let dotCount = 3

        var preferredHeight: CGFloat { 72 }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool { true }

        func setProgress(_ value: CGFloat) {
            let clamped = min(1, max(0, value))
            progress = clamped
            if abs(clamped - lastDrawnProgress) >= 0.01 {
                needsDisplay = true
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            lastDrawnProgress = progress
            guard let context = NSGraphicsContext.current?.cgContext else { return }

            // Anticipation swell over the last 15% of the gap.
            let anticipation = 1 + 0.18 * max(0, (progress - 0.85) / 0.15)
            let centerY = bounds.midY

            for dotIndex in 0 ..< dotCount {
                let segmentStart = CGFloat(dotIndex) / CGFloat(dotCount)
                let local = min(1, max(0, (progress - segmentStart) * CGFloat(dotCount)))
                let alpha = 0.25 + 0.75 * local
                let radius = dotRadius * (0.8 + 0.2 * local) * anticipation
                let centerX = horizontalPadding + dotRadius + CGFloat(dotIndex) * dotSpacing
                context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
                context.fillEllipse(in: CGRect(x: centerX - radius, y: centerY - radius, width: radius * 2, height: radius * 2))
            }
        }
    }
}
