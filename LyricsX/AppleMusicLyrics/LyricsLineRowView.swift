import AppKit
import CoreText
import CoreImage
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

        // MARK: Per-glyph breathing emphasis (highlighted line only)

        /// One laid-out glyph of the highlighted line's main text. Apple Music
        /// drives a per-glyph scale (`emphasizingScaleRange` 1.0…1.13) and lift
        /// (`syllableLift` 2pt) as the karaoke sweep crosses each glyph — the
        /// "breathing" that makes one line's motion feel like it carries the
        /// whole stanza. We replicate it by stepping a critically-damped spring
        /// per glyph (parameters reverse-engineered from Music 26.5.1; see memory
        /// `applemusic-lyrics-animation-params`) and redrawing only this one line
        /// per display-link frame. Non-highlighted lines stay a static
        /// `NSStringDrawing` pass with no glyph machinery.
        private struct GlyphLayoutEntry {
            let glyph: CGGlyph
            let font: CTFont
            /// Glyph origin (baseline, left edge) in the view's flipped coords.
            let baselineInView: CGPoint
            let advanceWidth: CGFloat
            /// Distance of the glyph's visual centre above its baseline — the
            /// scale anchor, matching Apple's per-glyph bbox-centre scaling.
            let centerHeightAboveBaseline: CGFloat
            let visualLineIndex: Int
            /// Index of the first character this glyph renders (for mapping the
            /// glyph onto an inline-timetag syllable and the karaoke sweep).
            let characterIndex: Int
        }
        private var glyphLayoutEntries: [GlyphLayoutEntry] = []
        private var glyphEmphasis: [CGFloat] = []
        private var glyphEmphasisVelocity: [CGFloat] = []
        private var glyphLayoutWidth: CGFloat = -1
        /// Left edge (view x) of each visual line's text, parallel to
        /// `visualLineWidths`, used to place the karaoke fill edge per glyph.
        private var visualLineContentLeftX: [CGFloat] = []
        // Per-glyph timing, parallel to `glyphLayoutEntries`, rebuilt when the
        // line duration is known: the sweep arrival time, the owning syllable's
        // end time, and that syllable's duration (the emphasis spring response).
        private var glyphActivationTimes: [TimeInterval] = []
        private var glyphSyllableEndTimes: [TimeInterval] = []
        private var glyphSyllableDurations: [TimeInterval] = []
        private var glyphTimingLineDuration: TimeInterval = -1
        private var lastEmphasisTickTimestamp: CFTimeInterval = 0

        // MARK: Layout / appearance constants (tuned against Apple's values in Phase 3)

        private let verticalPadding: CGFloat = 28
        private let horizontalPadding: CGFloat = 24
        private let mainToTranslationSpacing: CGFloat = 4
        // Active line's not-yet-sung text = 50% white (`selectedUpcomingTextColor`
        // α=0.5, from lldb dump of the live LyricsSpecs); the sung prefix fills to
        // 100%. Other (non-active) lines sit at 40% via the container's alpha.
        private let unsungOpacity: CGFloat = 0.5

        // Reverse-engineered from Apple Music 26.5.1 (`LyricsSpecs`, see memory
        // `applemusic-lyrics-animation-params`). The active line's glyphs scale
        // up `emphasizingScaleRange` (1.0…1.13) and lift `syllableLift` (2pt) as
        // they are sung, then relax. The rise is a critically-damped spring whose
        // `response` is the owning syllable's duration (capped at 3s); the relax
        // is a critically-damped 1.5s spring. Both convert to a stiffness/damping
        // pair exactly as `CASpringAnimation(response:dampingRatio:)` does:
        // `stiffness = (2π/response)²`, `damping = dampingRatio · 4π/response`
        // (mass 1). Emphasis begins `animationHeadstart` (0.1s) before a syllable
        // is sung.
        // `emphasizingScaleRange` 1.0 → 1.14 and `syllableLift` 3.0 pt — exact values
        // read at runtime from Apple Music's live LyricsSpecs (lldb, 2026-06-17).
        private let emphasisScaleRange: CGFloat = 0.14
        private let syllableLift: CGFloat = 3.0
        private let emphasisHeadstart: TimeInterval = 0.1
        private let emphasisRelaxResponse: TimeInterval = 1.5
        private let emphasisMaxResponse: TimeInterval = 3.0
        // Floor the response so a near-zero syllable duration cannot blow the
        // semi-implicit spring up (stable while `response > π · maxFrameStep`).
        private let emphasisMinResponse: TimeInterval = 0.12
        // Apple's per-glyph glow (`glowRange` 0…0.4, `glowRadius` 5) follows the
        // SAME emphasis weight as the scale, so `glow = emphasis · 0.4`. Drawn as
        // a white blur behind the glyph; skipped below the threshold so the
        // per-frame blur only costs the handful of currently-emphasised glyphs.
        private let glowOpacityRange: CGFloat = 0.4
        private let glowRadius: CGFloat = 5
        private let glowEmphasisThreshold: CGFloat = 0.02

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
            // Allow a Core Image Gaussian blur on non-active lines (`lineBlurEnabled`).
            layerUsesCoreImageFilters = true
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
            glyphTimingLineDuration = -1
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
                    drawMainBreathing(mainAttributed, in: mainRect, options: options)
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

        /// Draw the highlighted line glyph-by-glyph: each glyph carries its own
        /// spring-driven scale + lift (the per-syllable "breathing") and a
        /// two-pass karaoke fill (dim whole glyph, then the sung portion at full
        /// brightness clipped to the fill edge). Per-glyph emphasis is stepped in
        /// `stepEmphasis`; here we only render the current state.
        private func drawMainBreathing(_ attributed: NSAttributedString, in rect: CGRect, options: NSString.DrawingOptions) {
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

            for index in glyphLayoutEntries.indices {
                let entry = glyphLayoutEntries[index]
                let emphasis = index < glyphEmphasis.count ? glyphEmphasis[index] : 0
                let scale = 1.0 + emphasis * emphasisScaleRange
                let lift = emphasis * syllableLift

                let baselineY = viewHeight - entry.baselineInView.y
                let centerX = entry.baselineInView.x + entry.advanceWidth / 2
                let centerY = baselineY + entry.centerHeightAboveBaseline

                // Karaoke fill edge for this glyph's visual line (view x).
                let lineIndex = entry.visualLineIndex
                let lineLeftX = lineIndex < visualLineContentLeftX.count ? visualLineContentLeftX[lineIndex] : horizontalPadding
                let lineWidth = lineIndex < widths.count ? widths[lineIndex] : totalWidth
                let filledInLine = min(max(0, totalFilledWidth - cumulativeBefore[lineIndex]), lineWidth)
                let fillEdgeX = lineLeftX + filledInLine

                var glyph = entry.glyph
                var position = CGPoint(x: entry.baselineInView.x, y: baselineY)

                // Pass 1: un-sung (dim) — the whole glyph, scaled + lifted, with
                // the emphasis-driven white glow behind it.
                context.saveGState()
                context.translateBy(x: centerX, y: centerY + lift)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -centerX, y: -centerY)
                if emphasis > glowEmphasisThreshold {
                    context.setShadow(offset: .zero, blur: glowRadius, color: NSColor.white.withAlphaComponent(emphasis * glowOpacityRange).cgColor)
                }
                context.setFillColor(NSColor.white.withAlphaComponent(unsungOpacity).cgColor)
                CTFontDrawGlyphs(entry.font, &glyph, &position, 1, context)
                context.restoreGState()

                // Pass 2: sung (bright) — the same glyph clipped to the fill edge.
                // The clip is set in the un-scaled y-up space (so it stays fixed
                // at the sweep position) before the per-glyph scale is applied.
                if fillEdgeX > entry.baselineInView.x {
                    context.saveGState()
                    context.clip(to: CGRect(x: -1_000_000, y: -1_000_000, width: fillEdgeX + 1_000_000, height: 2_000_000))
                    context.translateBy(x: centerX, y: centerY + lift)
                    context.scaleBy(x: scale, y: scale)
                    context.translateBy(x: -centerX, y: -centerY)
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
            glyphEmphasis = []
            glyphEmphasisVelocity = []
            glyphActivationTimes = []
            glyphTimingLineDuration = -1
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
            var ascent0: CGFloat = 0, descent0: CGFloat = 0, leading0: CGFloat = 0
            _ = CTLineGetTypographicBounds(ctLines[0], &ascent0, &descent0, &leading0)
            let blockTopPathY = lineOrigins[0].y + ascent0

            var entries: [GlyphLayoutEntry] = []
            var widths: [CGFloat] = []
            var leftXs: [CGFloat] = []
            for (lineIndex, ctLine) in ctLines.enumerated() {
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let typographicWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
                widths.append(typographicWidth)
                let lineContentLeftX = horizontalPadding + lineOrigins[lineIndex].x
                leftXs.append(lineContentLeftX)
                let baselineInView = verticalPadding + (blockTopPathY - lineOrigins[lineIndex].y)
                let centerHeightAboveBaseline = (ascent - descent) / 2

                guard let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] else { continue }
                for run in runs {
                    let glyphCount = CTRunGetGlyphCount(run)
                    guard glyphCount > 0 else { continue }
                    var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
                    var positions = [CGPoint](repeating: .zero, count: glyphCount)
                    var advances = [CGSize](repeating: .zero, count: glyphCount)
                    var stringIndices = [CFIndex](repeating: 0, count: glyphCount)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                    CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                    CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &stringIndices)

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
                            advanceWidth: advances[glyphIndex].width,
                            centerHeightAboveBaseline: centerHeightAboveBaseline,
                            visualLineIndex: lineIndex,
                            characterIndex: stringIndices[glyphIndex]
                        ))
                    }
                }
            }

            glyphLayoutEntries = entries
            glyphEmphasis = [CGFloat](repeating: 0, count: entries.count)
            glyphEmphasisVelocity = [CGFloat](repeating: 0, count: entries.count)
            visualLineWidths = widths
            visualLineContentLeftX = leftXs
        }

        /// Map every glyph onto an inline-timetag syllable to get its sweep
        /// arrival time, the syllable's end time, and the syllable's duration
        /// (the emphasis spring `response`). Recomputed only when the line
        /// duration changes; cheap enough to leave keyed on it.
        private func rebuildGlyphTiming(lineDuration: TimeInterval) {
            guard !glyphLayoutEntries.isEmpty else {
                glyphActivationTimes = []
                glyphSyllableEndTimes = []
                glyphSyllableDurations = []
                return
            }
            if glyphActivationTimes.count == glyphLayoutEntries.count, glyphTimingLineDuration == lineDuration { return }
            glyphTimingLineDuration = lineDuration

            let totalCharacterCount = max(1, line?.content.count ?? 1)
            let timings = line?.wordTimingEntries ?? []
            var activations = [TimeInterval](repeating: 0, count: glyphLayoutEntries.count)
            var endTimes = [TimeInterval](repeating: lineDuration, count: glyphLayoutEntries.count)
            var durations = [TimeInterval](repeating: lineDuration, count: glyphLayoutEntries.count)

            for (index, entry) in glyphLayoutEntries.enumerated() {
                let characterIndex = entry.characterIndex
                if timings.isEmpty {
                    // No word timing: a single linear sweep across the whole line.
                    activations[index] = lineDuration * Double(characterIndex) / Double(totalCharacterCount)
                    endTimes[index] = lineDuration
                    durations[index] = lineDuration
                    continue
                }
                // Find the syllable segment [startChar, endChar) containing this
                // character, and its [startTime, endTime).
                let startCharacter: Int
                let startTime: TimeInterval
                let endCharacter: Int
                let endTime: TimeInterval
                if characterIndex < timings[0].characterIndex {
                    startCharacter = 0
                    startTime = 0
                    endCharacter = timings[0].characterIndex
                    endTime = timings[0].timeOffset
                } else {
                    var segmentIndex = 0
                    for candidate in timings.indices where timings[candidate].characterIndex <= characterIndex {
                        segmentIndex = candidate
                    }
                    startCharacter = timings[segmentIndex].characterIndex
                    startTime = timings[segmentIndex].timeOffset
                    endCharacter = segmentIndex + 1 < timings.count ? timings[segmentIndex + 1].characterIndex : totalCharacterCount
                    endTime = segmentIndex + 1 < timings.count ? timings[segmentIndex + 1].timeOffset : lineDuration
                }
                let segmentCharacterSpan = max(1, endCharacter - startCharacter)
                let segmentDuration = max(0, endTime - startTime)
                // Apple staggers a syllable's glyphs by `min(perGlyphDur · 0.4,
                // 0.4)` each, so the whole syllable swells almost together with a
                // quick left-to-right ripple — not a slow per-character crawl.
                // The glyph then ramps to 1.13 over the syllable duration (the
                // spring response) and relaxes after the syllable's end time.
                let perCharacterDuration = segmentDuration / Double(segmentCharacterSpan)
                let staggerStep = min(perCharacterDuration * 0.4, 0.4)
                activations[index] = startTime + staggerStep * Double(characterIndex - startCharacter)
                endTimes[index] = endTime
                durations[index] = segmentDuration
            }

            glyphActivationTimes = activations
            glyphSyllableEndTimes = endTimes
            glyphSyllableDurations = durations
        }

        /// Step every glyph's emphasis spring one display-link frame toward its
        /// target (1 while its syllable is being sung — `animationHeadstart`
        /// early — else 0). The rise uses the syllable-duration response; the
        /// relax uses the fixed 1.5s response. Returns whether anything is still
        /// moving, so the caller knows to keep repainting.
        @discardableResult
        private func stepEmphasis(elapsedTime: TimeInterval) -> Bool {
            guard isHighlighted, !glyphLayoutEntries.isEmpty,
                  glyphActivationTimes.count == glyphLayoutEntries.count,
                  glyphEmphasis.count == glyphLayoutEntries.count else { return false }

            let timestamp = CACurrentMediaTime()
            var deltaTime = lastEmphasisTickTimestamp == 0 ? (1.0 / 60.0) : (timestamp - lastEmphasisTickTimestamp)
            lastEmphasisTickTimestamp = timestamp
            deltaTime = min(max(deltaTime, 1.0 / 240.0), 1.0 / 30.0)
            let step = CGFloat(deltaTime)

            var anyMoved = false
            for index in glyphLayoutEntries.indices {
                let isActive = (elapsedTime + emphasisHeadstart) >= glyphActivationTimes[index]
                    && elapsedTime < glyphSyllableEndTimes[index]
                let target: CGFloat = isActive ? 1.0 : 0.0
                let response = isActive
                    ? max(emphasisMinResponse, min(glyphSyllableDurations[index], emphasisMaxResponse))
                    : emphasisRelaxResponse
                // Angular frequency from the same `response → stiffness` mapping a
                // `CASpringAnimation(response:dampingRatio:1)` uses: ω = 2π/response.
                let angularFrequency = 2 * CGFloat.pi / CGFloat(response)

                // EXACT analytic step of a critically-damped (ζ = 1) spring toward
                // `target`. The previous semi-implicit Euler integrator DIVERGED for
                // short syllables — with `damping·Δt = 2ω·Δt > 2` (true once the
                // response drops below ~0.13 s even at 60 Hz) the velocity update
                // flips sign and amplifies every frame, so the clamped emphasis
                // oscillated between 0 and 1: that was the per-syllable "抖动".
                // The closed-form solution below is unconditionally stable for any Δt
                // and reproduces a real CASpringAnimation's curve precisely.
                let displacement = glyphEmphasis[index] - target            // y₀
                let coefficient = glyphEmphasisVelocity[index] + angularFrequency * displacement // B = v₀ + ω·y₀
                let decay = CGFloat(exp(Double(-angularFrequency * step)))
                let nextDisplacement = (displacement + coefficient * step) * decay
                let nextVelocity = (coefficient - angularFrequency * (displacement + coefficient * step)) * decay
                var emphasis = target + nextDisplacement
                var velocity = nextVelocity
                if abs(emphasis - target) < 0.001, abs(velocity) < 0.01 {
                    emphasis = target
                    velocity = 0
                } else {
                    anyMoved = true
                }
                glyphEmphasis[index] = min(1.0, max(0.0, emphasis))
                glyphEmphasisVelocity[index] = velocity
            }
            return anyMoved
        }

        private func resetEmphasis() {
            for index in glyphEmphasis.indices { glyphEmphasis[index] = 0 }
            for index in glyphEmphasisVelocity.indices { glyphEmphasisVelocity[index] = 0 }
            lastEmphasisTickTimestamp = 0
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
            // Start (or end) every per-glyph spring from rest so a re-highlighted
            // line never inherits a stale mid-animation emphasis.
            resetEmphasis()
            needsDisplay = true
        }

        func animateAlpha(to target: CGFloat, duration: TimeInterval) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().alphaValue = target
            }
        }

        private var currentBlurRadius: CGFloat = -1
        /// Apple Music blurs every NON-active line (`lineBlurEnabled = true`,
        /// implemented there as a Metal two-pass gaussian). We approximate it with a
        /// Core Image Gaussian blur applied as the view's content filter — the
        /// AppKit-safe path (the layer's `filters` are synced from `contentFilters`,
        /// so setting it directly would be overwritten). The active line is sharp
        /// (radius 0). Idempotent so the per-frame distance update is cheap.
        func setLineBlur(radius: CGFloat) {
            guard abs(radius - currentBlurRadius) > 0.05 else { return }
            currentBlurRadius = radius
            if radius <= 0.05 {
                contentFilters = []
            } else if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]) {
                contentFilters = [blur]
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
            rebuildGlyphTiming(lineDuration: lineDuration)

            let fraction = KaraokeFill.fraction(
                elapsedTime: elapsedTime,
                lineDuration: lineDuration,
                wordTimings: line.wordTimingEntries ?? [],
                totalCharacterCount: line.content.count,
                mode: mode
            )
            karaokeFraction = fraction

            // Advance the per-glyph breathing springs every frame; they keep
            // moving (rising as each syllable is sung, relaxing afterwards) even
            // when the fill edge itself is momentarily static.
            let emphasisMoved = stepEmphasis(elapsedTime: elapsedTime)
            // Repaint when the fill edge moved by at least half a point or any
            // glyph is still breathing, so a paused line does not repaint forever.
            let fillMoved = abs(fraction - lastDrawnFraction) * max(1, mainTextSize.width) >= 0.5
            if fillMoved || emphasisMoved {
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
