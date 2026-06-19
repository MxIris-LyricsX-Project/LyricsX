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

        // MARK: Per-glyph karaoke layout (highlighted line only)

        /// One laid-out glyph of the highlighted line's main text. The karaoke
        /// fill is drawn glyph-by-glyph so the sung prefix lights up per visual
        /// line — wrapped lines fill in cascade, not in lockstep. Non-highlighted
        /// lines stay a static `NSStringDrawing` pass with no glyph machinery.
        private struct GlyphLayoutEntry {
            let glyph: CGGlyph
            let font: CTFont
            /// Glyph origin (baseline, left edge) in the view's flipped coords.
            let baselineInView: CGPoint
            let visualLineIndex: Int
        }
        private var glyphLayoutEntries: [GlyphLayoutEntry] = []
        private var glyphLayoutWidth: CGFloat = -1
        /// Left edge (view x) of each visual line's text, parallel to
        /// `visualLineWidths`, used to place the karaoke fill edge per glyph.
        private var visualLineContentLeftX: [CGFloat] = []

        // MARK: Layout / appearance constants (tuned against Apple's values in Phase 3)

        private let verticalPadding: CGFloat = 28
        private let horizontalPadding: CGFloat = 24
        private let mainToTranslationSpacing: CGFloat = 4
        // Active line's not-yet-sung text = 50% white (`selectedUpcomingTextColor`
        // α=0.5, from lldb dump of the live LyricsSpecs); the sung prefix fills to
        // 100%. Other (non-active) lines sit at 40% via the container's alpha.
        private let unsungOpacity: CGFloat = 0.5

        // Apple Music's `deselectedTransform` is the IDENTITY (no whole-line
        // scale) — confirmed by lldb dump of the live LyricsSpecs (2026-06-17).
        // Non-active lines are differentiated by opacity (40%) + blur ONLY, never
        // by scale. (The 0.98 seen in static disassembly was a different field.)
        // Keeping the field at 1.0 so `setLineSelected` is a no-op scale.
        private let deselectedLineScale: CGFloat = 1.0
        private var didCenterAnchorLayer = false

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
            glyphLayoutWidth = -1 // force glyph re-layout
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
                    buildGlyphLayoutIfNeeded(forWidth: bounds.width)
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

        /// Draw the highlighted line glyph-by-glyph with a two-pass karaoke fill:
        /// the whole glyph at a dim "un-sung" opacity, then the sung portion at
        /// full brightness clipped to the fill edge. The fill edge cascades per
        /// visual line so wrapped rows light up one after another, not at once.
        private func drawMainKaraoke(_ attributed: NSAttributedString, in rect: CGRect, options: NSString.DrawingOptions) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            guard !glyphLayoutEntries.isEmpty else {
                // No glyph layout yet (e.g. zero width): fall back to the flat
                // two-pass NSStringDrawing fill so the line is never blank.
                drawAttributed(attributed, in: rect, options: options, alpha: unsungOpacity)
                return
            }

            let fraction = min(1, max(0, karaokeFraction))
            let widths = visualLineWidths.isEmpty ? [mainTextSize.width] : visualLineWidths
            let totalWidth = max(0.0001, widths.reduce(0, +))
            let totalFilledWidth = totalWidth * fraction
            // Cumulative width before each visual line, so the fill cascades line
            // by line instead of lighting every wrapped row at once.
            var cumulativeBefore = [CGFloat](repeating: 0, count: widths.count)
            var running: CGFloat = 0
            for index in widths.indices {
                cumulativeBefore[index] = running
                running += widths[index]
            }

            context.saveGState()
            // Flip into a y-up text space so Core Text glyphs render upright in
            // this flipped view; +y is now up on screen.
            context.textMatrix = .identity
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            let viewHeight = bounds.height

            for entry in glyphLayoutEntries {
                let baselineY = viewHeight - entry.baselineInView.y

                // Karaoke fill edge for this glyph's visual line (view x).
                let lineIndex = entry.visualLineIndex
                let lineLeftX = lineIndex < visualLineContentLeftX.count ? visualLineContentLeftX[lineIndex] : horizontalPadding
                let lineWidth = lineIndex < widths.count ? widths[lineIndex] : totalWidth
                let filledInLine = min(max(0, totalFilledWidth - cumulativeBefore[lineIndex]), lineWidth)
                let fillEdgeX = lineLeftX + filledInLine

                var glyph = entry.glyph
                var position = CGPoint(x: entry.baselineInView.x, y: baselineY)

                // Pass 1: un-sung (dim) — the whole glyph.
                context.setFillColor(NSColor.white.withAlphaComponent(unsungOpacity).cgColor)
                CTFontDrawGlyphs(entry.font, &glyph, &position, 1, context)

                // Pass 2: sung (bright) — the same glyph clipped to the fill edge.
                if fillEdgeX > entry.baselineInView.x {
                    context.saveGState()
                    context.clip(to: CGRect(x: -1_000_000, y: -1_000_000, width: fillEdgeX + 1_000_000, height: 2_000_000))
                    context.setFillColor(NSColor.white.cgColor)
                    CTFontDrawGlyphs(entry.font, &glyph, &position, 1, context)
                    context.restoreGState()
                }
            }
            context.restoreGState()
        }

        /// Lay the highlighted line's main text out via Core Text into per-glyph
        /// entries (glyph id, font, baseline in flipped view coords, advance,
        /// scale-anchor height, visual line, first character). Cached by width;
        /// rebuilt on width / font / translation change. Also refreshes
        /// `visualLineWidths` + `visualLineContentLeftX` from the same frame so
        /// the karaoke fill stays consistent with the glyph positions.
        private func buildGlyphLayoutIfNeeded(forWidth width: CGFloat) {
            guard width > 0 else { return }
            if glyphLayoutWidth == width, !glyphLayoutEntries.isEmpty { return }
            glyphLayoutWidth = width
            glyphLayoutEntries = []
            visualLineContentLeftX = []

            guard let mainAttributed else { return }
            let textWidth = max(1, width - horizontalPadding * 2)
            let framesetter = CTFramesetterCreateWithAttributedString(mainAttributed)
            let path = CGMutablePath()
            // Unbounded height (see `computeVisualLineWidths`): a height-bounded
            // path can silently drop the last visual line(s).
            path.addRect(CGRect(x: 0, y: 0, width: textWidth, height: 100_000))
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            guard let ctLines = CTFrameGetLines(frame) as? [CTLine], !ctLines.isEmpty else { return }

            var lineOrigins = [CGPoint](repeating: .zero, count: ctLines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &lineOrigins)

            // Path coordinates are y-up; the very top of the first line sits at
            // `origin0.y + ascent0`. Map every baseline down from the view's top
            // inset so line 0's baseline lands at `verticalPadding + ascent0`.
            var ascent0: CGFloat = 0
            _ = CTLineGetTypographicBounds(ctLines[0], &ascent0, nil, nil)
            let blockTopPathY = lineOrigins[0].y + ascent0

            var entries: [GlyphLayoutEntry] = []
            var widths: [CGFloat] = []
            var leftXs: [CGFloat] = []
            for (lineIndex, ctLine) in ctLines.enumerated() {
                let typographicWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
                widths.append(typographicWidth)
                let lineContentLeftX = horizontalPadding + lineOrigins[lineIndex].x
                leftXs.append(lineContentLeftX)
                let baselineInView = verticalPadding + (blockTopPathY - lineOrigins[lineIndex].y)

                guard let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] else { continue }
                for run in runs {
                    let glyphCount = CTRunGetGlyphCount(run)
                    guard glyphCount > 0 else { continue }
                    var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
                    var positions = [CGPoint](repeating: .zero, count: glyphCount)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)

                    let runAttributes = CTRunGetAttributes(run) as NSDictionary
                    let runFont: CTFont
                    if let fontValue = runAttributes[kCTFontAttributeName as String] {
                        // The attribute value is a CTFont (CFTypeRef); a force
                        // cast from `Any` is the documented bridge.
                        runFont = fontValue as! CTFont
                    } else {
                        // Never hit in practice (the string always carries a
                        // font); NSFont is toll-free bridged to CTFont.
                        runFont = unsafeBitCast(NSFont.systemFont(ofSize: mainFontSize, weight: .bold), to: CTFont.self)
                    }

                    for glyphIndex in 0 ..< glyphCount {
                        let baselineX = lineContentLeftX + positions[glyphIndex].x
                        entries.append(GlyphLayoutEntry(
                            glyph: glyphs[glyphIndex],
                            font: runFont,
                            baselineInView: CGPoint(x: baselineX, y: baselineInView),
                            visualLineIndex: lineIndex
                        ))
                    }
                }
            }

            glyphLayoutEntries = entries
            visualLineWidths = widths
            visualLineContentLeftX = leftXs
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
            if highlighted {
                buildGlyphLayoutIfNeeded(forWidth: bounds.width)
            } else {
                karaokeFraction = 0
            }
            needsDisplay = true
        }

        func animateAlpha(to target: CGFloat, duration: TimeInterval) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().alphaValue = target
            }
        }

        /// Apple Music's line-level discrete transform: the selected line rests
        /// at 1.0, every other line shrinks to `deselectedLineScale` (0.98),
        /// animated by the line-select spring. Scales about the line's centre so
        /// it never drifts sideways. The active line is intentionally left at
        /// 1.0 — all of its growth is per-syllable, not whole-line.
        func setLineSelected(_ selected: Bool, animated: Bool) {
            guard let layer else { return }
            ensureCenterAnchor(layer)
            let targetScale: CGFloat = selected ? 1.0 : deselectedLineScale
            let newTransform = CATransform3DMakeScale(targetScale, targetScale, 1)
            if CATransform3DEqualToTransform(layer.transform, newTransform) { return }
            if animated, window != nil {
                let animation = CASpringAnimation(keyPath: "transform")
                animation.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
                animation.toValue = NSValue(caTransform3D: newTransform)
                animation.mass = 1
                animation.stiffness = 14
                animation.damping = 7
                animation.duration = animation.settlingDuration
                layer.add(animation, forKey: "lineSelectScale")
            }
            layer.transform = newTransform
        }

        /// Move the backing layer's anchor to its centre (once) so the
        /// line-select scale grows/shrinks about the middle. AppKit keeps
        /// `position` in sync with the view's frame afterwards, so the cascade's
        /// `setFrameOrigin` still works.
        private func ensureCenterAnchor(_ layer: CALayer) {
            guard !didCenterAnchorLayer else { return }
            didCenterAnchorLayer = true
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: frame.midX, y: frame.midY)
        }

        // MARK: Karaoke (per-frame, highlighted line only)

        func updateKaraoke(elapsedTime: TimeInterval, lineDuration: TimeInterval, mode: KaraokeMode) {
            guard let line, isHighlighted else { return }
            buildGlyphLayoutIfNeeded(forWidth: bounds.width)

            let fraction = KaraokeFill.fraction(
                elapsedTime: elapsedTime,
                lineDuration: lineDuration,
                wordTimings: line.wordTimingEntries ?? [],
                totalCharacterCount: line.content.count,
                mode: mode
            )
            karaokeFraction = fraction

            // Repaint only when the fill edge moved by at least half a point, so a
            // paused line does not repaint forever.
            let fillMoved = abs(fraction - lastDrawnFraction) * max(1, mainTextSize.width) >= 0.5
            if fillMoved {
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
