import AppKit
import CoreText
import QuartzCore
import LyricsXFoundation
import OSToolbox

extension AppleMusicLyrics {
    /// One lyric line, rendered as a layer-backed `NSView`.
    ///
    /// The line is a Core Animation layer tree arranged the way Music's
    /// `SyncedLyricsLineLayer` arranges its own:
    ///
    /// ```
    /// row's backing layer          blur and hover-brightness filters, rasterized
    /// └── line host view's layer   y-down, hosted by a flipped view
    ///     ├── pressed highlight    built on the first press, always at the back
    ///     └── container            what a press shrinks and dims
    ///         ├── SyncedLyricsLineContentLayer   the main text
    ///         └── LineTranslationLayer           the translation
    /// ```
    ///
    /// The tree is built once per line and then driven entirely by scheduled
    /// animations. The view itself measures, follows the pointer, and decides
    /// *when* to hand the line its playback position; it never draws a glyph.
    ///
    /// This replaced a per-frame `draw(_:)` that solved Apple Music's emphasis
    /// spring on the CPU and composited the karaoke fill by hand. That could not
    /// be made to look right: Music scales each glyph *inside* a mask while the
    /// sung/un-sung gradient sweeps *outside* it, and a single drawing pass cannot
    /// separate the two. Everything visual now lives in the layer tree.
    @Loggable(
        isEnabled: AppleMusicLyrics.PanelDiagnostics.isLyricsEnabled,
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics",
        category: "LyricsLine"
    )
    @Signpostable(
        isEnabled: AppleMusicLyrics.PanelDiagnostics.isLyricsEnabled,
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics",
        category: "LyricsLine"
    )
    final class SyncedLyricsLineView: NSView {
        // MARK: Model

        private(set) var line: LyricsLine?
        private(set) var originalIndex: Int = -1
        private var displayTranslation: String?
        /// Position among the *enabled* lines (used for distance-based fading).
        var enabledPosition: Int = 0

        var onTap: ((LyricsLine) -> Void)?

        private var mainFontSize: CGFloat = 32
        private var translationFontSize: CGFloat = 18

        // MARK: State

        private(set) var isHighlighted = false
        /// The pointer is over the row, between `mouseEntered:` and
        /// `mouseExited:`.
        private(set) var isPointerInside = false
        /// The mouse button went down on the row and the pointer is still on it.
        private(set) var isPressed = false
        /// The mouse button that went down on the row is still down, wherever
        /// the pointer has gone since.
        private var isTrackingPress = false
        private var karaokeFraction: CGFloat = 0
        /// The radius the container's contextual blur plan asks for; see
        /// `LineBlurPlan`.
        private var requestedBlurRadius: CGFloat = 0
        /// The radius on the blur filter, after the hover and press exemptions.
        private var blurRadius: CGFloat = 0
        /// The amount on the brightness filter.
        private var brightnessAmount = 0
        /// Opacity of the text of every line but the selected one; see
        /// `DeselectedLineOpacityVariant`.
        private var deselectedTextOpacity = DeselectedLineOpacityVariant.default.textOpacity
        /// Filters whose input is animating. The row must not be cached while
        /// any is, or the bitmap would freeze one intermediate value; see
        /// `updateRasterization`.
        private var animatingFilters: Set<LineFilter> = []
        /// Bumped by every change to a filter's input, so the timer that ends an
        /// animation can tell whether a newer change has replaced it.
        private var filterChangeGenerations: [LineFilter: Int] = [:]
        private var hoverTrackingArea: NSTrackingArea?

        // MARK: Cached layout

        private var mainAttributed: NSAttributedString?
        private var translationAttributed: NSAttributedString?
        private var mainTextSize: CGSize = .zero
        private var translationTextSize: CGSize = .zero
        private var textLayout: LineTextLayout?
        private var laidOutForWidth: CGFloat = -1

        // MARK: Layers

        /// The main text. Internal so probes can reach it without walking the
        /// tree.
        let contentLayer = SyncedLyricsLineContentLayer()
        private let translationLayer = LineTranslationLayer()
        /// Music's `containerLayer`: the main text and the translation, which a
        /// press shrinks and dims together.
        private let containerLayer = NoAnimationLayer()
        /// Music's `backgroundLayer`: the rounded highlight behind a pressed
        /// line, built the first time the line is pressed.
        private var pressedBackgroundLayer: NoAnimationLayer?
        /// The root of the line's tree, hosted by `lineHostView`.
        private let lineHostLayer = NoAnimationLayer()
        /// The tree is hosted by a flipped view rather than added to this view's
        /// backing layer by hand. `LineTextLayout` produces y-down coordinates,
        /// and only AppKit knows which layers in the ancestry carry
        /// `isGeometryFlipped`: it puts the flag wherever flippedness changes
        /// between a view and its superview (on the NSScrollView's layer inside
        /// the panel, on this row's own layer when the row is hosted alone) and
        /// re-applies it at commit time, so a layer we position ourselves can
        /// only guess the parity — and both guesses this code has made
        /// (`!layer.isGeometryFlipped`, then a hard-coded `true` in 8445f2e)
        /// reversed the wrapped rows once the ancestry changed. A layer-hosting
        /// flipped view hands the orientation to AppKit for good: the root's
        /// flag is AppKit's alone, and everything under it inherits a y-down
        /// space.
        private let lineHostView = LineHostView()

        private final class LineHostView: NSView {
            override var isFlipped: Bool {
                true
            }

            /// Clicks belong to the row.
            override func hitTest(_ point: NSPoint) -> NSView? {
                nil
            }
        }

        /// The two filters Music's `SyncedLyricsLineLayer` can carry, in the
        /// order it keeps them: `filters = [blurFilter, brightnessFilter]`. Each
        /// goes on the first time it is needed and stays for life.
        private enum LineFilter: CaseIterable {
            case blur
            case brightness

            /// The `CAFilter` type, also used as the filter's `name` — which is
            /// what makes `keyPath` resolve. With the two matching, the key
            /// paths are byte-for-byte the ones in Music's disassembly.
            var name: String {
                switch self {
                case .blur: "gaussianBlur"
                case .brightness: "colorBrightness"
                }
            }

            var inputKey: String {
                switch self {
                case .blur: "inputRadius"
                case .brightness: "inputAmount"
                }
            }

            var keyPath: String {
                "filters.\(name).\(inputKey)"
            }
        }

        // MARK: Layout constants

        /// Half the line spacing: Music lays text-only line frames that far
        /// apart, and two of these paddings meet between neighbouring rows.
        /// Unlike Music's flat 50 pt it follows the font size, so a full-screen
        /// window does not crowd its much larger text
        /// (`NowPlayingLyricsLayoutPolicy.lineSpacing(forMainFontSize:)`).
        var verticalPadding: CGFloat {
            NowPlayingLyricsLayoutPolicy.lineSpacing(forMainFontSize: mainFontSize) / 2
        }

        private let horizontalPadding: CGFloat = 24

        // MARK: Lifecycle

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            // `SyncedLyricsLineContentLayer` flips its own geometry for use on
            // its own, where it is the root of its space. Here it sits under the
            // host root, which AppKit already keeps y-down, and a second flip
            // would turn its rows back over.
            contentLayer.isGeometryFlipped = false
            containerLayer.addSublayer(contentLayer)
            containerLayer.addSublayer(translationLayer)
            lineHostLayer.addSublayer(containerLayer)
            lineHostView.layer = lineHostLayer
            lineHostView.wantsLayer = true
            addSubview(lineHostView)
            updateTranslationOpacity()
            updateRasterization()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateRasterization()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            guard let scale = window?.backingScaleFactor else { return }
            contentLayer.contentsScale = scale
            updateRasterization()
            laidOutForWidth = -1
            needsLayout = true
        }

        /// Apple Music's `SyncedLyricsLineLayer` sets `shouldRasterize = true` in
        /// its initializer (`sub_1001A5294`) and keeps its filters installed for
        /// life, so a line that is merely scrolling is one cached bitmap to the
        /// render server instead of a tree of nested masks, word glow and a blur
        /// pass. It only drops the cache while the blur radius animates
        /// (`sub_1001DC498`), because the bitmap includes the filters and would
        /// hold one intermediate radius for the whole transition. The hover
        /// brightness animates on the same curve and is treated the same way.
        ///
        /// `rasterizationScale` defaults to 1, which would cache Retina text at
        /// half resolution; it follows the window's backing scale instead.
        private func updateRasterization() {
            guard let layer else { return }
            layer.shouldRasterize = animatingFilters.isEmpty
            if let backingScaleFactor = window?.backingScaleFactor {
                layer.rasterizationScale = backingScaleFactor
            }
        }

        // MARK: Configuration

        func configure(
            line: LyricsLine,
            translation: String?,
            originalIndex: Int,
            enabledPosition: Int,
            mainFontSize: CGFloat,
            translationFontSize: CGFloat
        ) {
            self.line = line
            displayTranslation = translation
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
        /// track is already displayed. The translation is passed in rather than
        /// re-read from the line, so it goes through the host's language choice
        /// instead of the file's first translation.
        func refreshTranslation(_ translation: String?) {
            displayTranslation = translation
            rebuildAttributedStrings()
        }

        private func rebuildAttributedStrings() {
            defer {
                translationLayer.attributedText = translationAttributed
                translationLayer.isHidden = translationAttributed == nil
            }
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
                translation: displayTranslation,
                forLineContent: line.content,
                fontSize: translationFontSize
            )

            laidOutForWidth = -1
            needsLayout = true
        }

        /// `sub_10017A270`'s translation: `translationLargeFont`, which is bold
        /// (its size is the caller's, the main size × 0.57), under a paragraph
        /// style with line break strategy 3. The text is white; the layer's
        /// opacity carries Music's colour — see `updateTranslationOpacity()`.
        private static func makeTranslationAttributedString(
            translation: String?,
            forLineContent lineContent: String,
            fontSize: CGFloat
        ) -> NSAttributedString? {
            guard AppleMusicLyrics.hostEnvironment.isBilingualPreferred(),
                  let translation else {
                return nil
            }
            let displayText = AppleMusicLyrics.hostEnvironment.transformTranslation(translation)
            guard shouldDisplayTranslation(displayText, forLineContent: lineContent) else { return nil }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineBreakStrategy = [.pushOut, .hangulWordPriority]
            return NSAttributedString(
                string: displayText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: paragraph,
                ]
            )
        }

        /// `sub_10017A8D0` leaves a translation out when, ignoring case, it is
        /// the line itself.
        nonisolated static func shouldDisplayTranslation(_ translation: String, forLineContent lineContent: String) -> Bool {
            translation.lowercased() != lineContent.lowercased()
        }

        // MARK: Measurement & layout

        func preferredHeight(forWidth width: CGFloat) -> CGFloat {
            buildLayoutIfNeeded(forWidth: width)
            return ceil(verticalPadding * 2 + contentHeight)
        }

        /// Distance from the row's top edge to the first main-text baseline.
        /// The container uses this to translate Music's text-relative anchor into
        /// this view's padded coordinate system.
        var mainTextFirstBaselineOffset: CGFloat {
            let mainFont = NSFont.systemFont(ofSize: mainFontSize, weight: .bold)
            return verticalPadding + mainFont.ascender
        }

        /// Distance from the row's top edge to the centre of its content block —
        /// the main text plus, when shown, the translation. Music's `.center`
        /// anchor (`sub_10015CD84`) centres the whole line frame, and for Music
        /// the line frame is exactly this block. Lays the row out for `width`
        /// first, so it is usable before the row has been given a frame.
        func contentCenterOffset(forWidth width: CGFloat) -> CGFloat {
            buildLayoutIfNeeded(forWidth: width)
            return verticalPadding + contentHeight / 2
        }

        /// The main text plus, when shown, the translation under it.
        private var contentHeight: CGFloat {
            guard translationAttributed != nil else { return mainTextSize.height }
            return mainTextSize.height + LyricsSpecs.translationSpacing + translationTextSize.height
        }

        /// Music's line frame, inside this row: the text column, as tall as the
        /// content block. The padding around it is this row's own.
        private var lineFrame: CGRect {
            CGRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: max(1, bounds.width - horizontalPadding * 2),
                height: contentHeight
            )
        }

        override func layout() {
            super.layout()
            buildLayoutIfNeeded(forWidth: bounds.width)
            // The host is a flipped view inside a flipped view, so its frame is
            // y-down like everything else here, and AppKit keeps the hosted root
            // effectively y-down.
            lineHostView.frame = bounds
            layoutLineLayers()
        }

        private func layoutLineLayers() {
            let currentLineFrame = lineFrame
            let lineCenter = CGPoint(x: currentLineFrame.midX, y: currentLineFrame.midY)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Bounds and position rather than frame: a pressed container and its
            // highlight carry a transform, and a frame assigned through one comes
            // out scaled. Both scale about the line's centre.
            containerLayer.bounds = CGRect(origin: .zero, size: currentLineFrame.size)
            containerLayer.position = lineCenter
            // The content layer is bigger than the text it holds — see
            // `textOutset` — so back its origin off by that much to put the
            // *text* at the container's origin.
            contentLayer.frame = CGRect(
                origin: CGPoint(x: -contentLayer.textOutset.width, y: -contentLayer.textOutset.height),
                size: contentLayer.bounds.size
            )
            translationLayer.frame = CGRect(
                x: 0,
                y: mainTextSize.height + LyricsSpecs.translationSpacing,
                width: currentLineFrame.width,
                height: translationTextSize.height
            )
            if let pressedBackgroundLayer {
                let margin = LyricsSpecs.highlightViewMargin
                pressedBackgroundLayer.bounds = CGRect(
                    origin: .zero,
                    size: currentLineFrame.insetBy(dx: -margin, dy: -margin).size
                )
                pressedBackgroundLayer.position = lineCenter
            }
            CATransaction.commit()
        }

        /// Lay the main text out and rebuild the layer tree. Cached by width, and
        /// invalidated when the line, the fonts, or the backing scale change.
        private func buildLayoutIfNeeded(forWidth width: CGFloat) {
            guard width > 0, laidOutForWidth != width else { return }
            let lineOriginalIndex = originalIndex
            let layoutInterval = #signpost(
                .begin,
                "BuildLineLayout",
                "originalIndex=\(lineOriginalIndex, privacy: .public) width=\(width, privacy: .public)"
            )
            defer { #signpost(.end, layoutInterval) }
            let textWidth = max(1, width - horizontalPadding * 2)

            guard let mainAttributed, let line else {
                textLayout = nil
                mainTextSize = .zero
                translationTextSize = .zero
                return
            }
            laidOutForWidth = width

            let contentsScale = window?.backingScaleFactor ?? 2
            let layout = LineTextLayout.build(
                attributed: mainAttributed,
                content: line.content,
                wordTimings: line.wordTimingEntries ?? [],
                synchronizedTextTiming: line.synchronizedTextTiming,
                languageIdentifier: line.lyrics?.idTags[.init("lang")],
                lineDuration: line.timetagDuration ?? 0,
                textWidth: textWidth
            )
            textLayout = layout
            mainTextSize = layout?.contentSize ?? .zero

            if let layout {
                contentLayer.rebuild(with: layout, contentsScale: contentsScale)
                let renderedGlyphCount = layout.words.reduce(0) { partialCount, word in
                    partialCount + word.glyphs.count
                }
                let lineText = line.content
                #log(
                    .info,
                    """
                    Line layout built originalIndex=\(lineOriginalIndex, privacy: .public) \
                    text=\(lineText, privacy: .public) \
                    characterCount=\(line.content.count, privacy: .public) \
                    visualRowCount=\(layout.visualLines.count, privacy: .public) \
                    wordCount=\(layout.words.count, privacy: .public) \
                    glyphCount=\(renderedGlyphCount, privacy: .public) \
                    textWidth=\(textWidth, privacy: .public)
                    """
                )
            }

            if let translationAttributed {
                let constraint = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
                let rect = translationAttributed.boundingRect(with: constraint, options: [.usesLineFragmentOrigin, .usesFontLeading])
                translationTextSize = CGSize(width: ceil(rect.width), height: ceil(rect.height))
                if translationLayer.contentsScale != contentsScale {
                    translationLayer.contentsScale = contentsScale
                    translationLayer.setNeedsDisplay()
                }
            } else {
                translationTextSize = .zero
            }
        }

        // MARK: Selection

        /// Make this the selected line, or stop it being one. `animated` moves
        /// the main text's colours on Music's line-change spring
        /// (`LineSelectionPlan`); the translation's colour switches at once
        /// either way, as Music's does.
        func setHighlighted(_ highlighted: Bool, animated: Bool = false) {
            guard isHighlighted != highlighted else { return }
            isHighlighted = highlighted
            if !highlighted {
                karaokeFraction = 0
            }
            contentLayer.setHighlighted(highlighted, animatedWith: animated ? LineSelectionPlan.springTiming : nil)
            updateTranslationOpacity()
            // The selected line is never focused. A hovered line that becomes
            // the selected one gives its brightness up on the filter curve —
            // the one path on which `sub_10019E6C4` asks `sub_10019EEDC` to
            // animate.
            applyBrightness(animated: animated)
        }

        /// The text opacity of every line but the selected one, from the
        /// current `DeselectedLineOpacityVariant`. Handed to every row on every
        /// line change.
        func setDeselectedTextOpacity(_ opacity: CGFloat) {
            guard opacity != deselectedTextOpacity else { return }
            deselectedTextOpacity = opacity
            contentLayer.deselectedColor = CGColor(gray: 1, alpha: opacity)
            updateTranslationOpacity()
        }

        /// `sub_10017A270` colours the translation `selectedUpcomingTextColor`
        /// on the selected line and `deselectedTextColor` on every other one.
        private func updateTranslationOpacity() {
            let opacity = isHighlighted ? LyricsSpecs.selectedUpcomingTextOpacity : deselectedTextOpacity
            translationLayer.opacity = Float(opacity)
        }

        /// Apple Music's `deselectedTransform` is the identity — re-confirmed by
        /// the 2026-07-26 lldb dump — so this is deliberately a no-op scale. All
        /// of the active line's growth is per-glyph, never whole-line.
        func setLineSelected(_ selected: Bool, animated: Bool) {
            _ = selected
            _ = animated
        }

        // MARK: Hover

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea {
                removeTrackingArea(hoverTrackingArea)
            }
            // `.activeAlways`: the panel usually floats over whichever app is in
            // front, and a hover that only worked while it was key would rarely
            // be seen.
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(trackingArea)
            hoverTrackingArea = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            setPointerInside(true)
        }

        override func mouseExited(with event: NSEvent) {
            setPointerInside(false)
        }

        /// `mouseEntered:` and `mouseExited:` both reach `sub_10019EEDC` with
        /// `animated: false`: the focus look comes and goes at once.
        private func setPointerInside(_ pointerInside: Bool) {
            guard pointerInside != isPointerInside else { return }
            isPointerInside = pointerInside
            let lineOriginalIndex = originalIndex
            let transition = pointerInside ? "entered" : "exited"
            #log(.debug, "Line pointer \(transition, privacy: .public) originalIndex=\(lineOriginalIndex, privacy: .public)")
            applyBrightness(animated: false)
            applyBlurRadius(animated: false)
        }

        /// Music's focused line: one the pointer rests on, unless it is the
        /// selected line. It is not blurred, and it is brightened.
        private var isFocused: Bool {
            isPointerInside && !isHighlighted
        }

        private func applyBrightness(animated: Bool) {
            let target = isFocused ? LyricsSpecs.focusedLineBrightnessAmount : 0
            guard target != brightnessAmount, installFilterIfNeeded(.brightness) else { return }
            brightnessAmount = target
            setFilterInput(NSNumber(value: target), of: .brightness, animated: animated)
        }

        // MARK: Press

        override func mouseDown(with event: NSEvent) {
            // Taking the event is what routes the drag and the `mouseUp` here.
            isTrackingPress = true
            setPressed(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard isTrackingPress else { return }
            // `NSControl` tracking takes a control's highlight away while the
            // pointer is outside it and gives it back on the way in, and Music's
            // press look follows that highlight.
            setPressed(bounds.contains(convert(event.locationInWindow, from: nil)))
        }

        override func mouseUp(with event: NSEvent) {
            guard isTrackingPress else { return }
            isTrackingPress = false
            let isReleasedInside = bounds.contains(convert(event.locationInWindow, from: nil))
            setPressed(false)
            // Music's `mouseUp:` sends its action wherever the button comes up;
            // a click that has left the line is dropped here instead.
            guard isReleasedInside, let line else { return }
            onTap?(line)
        }

        private func setPressed(_ pressed: Bool) {
            guard pressed != isPressed else { return }
            isPressed = pressed
            let lineOriginalIndex = originalIndex
            let transition = pressed ? "pressed" : "released"
            #log(.debug, "Line \(transition, privacy: .public) originalIndex=\(lineOriginalIndex, privacy: .public)")
            animatePressAppearance(pressed: pressed)
            // `sub_10019D630` takes the blur away for as long as the line is
            // held and puts it back on release, both on the filter curve.
            applyBlurRadius(animated: true)
        }

        /// `sub_10019D630`: the highlight fades in behind the line while the
        /// container fades to `highlightLabelOpacity`, both on a cubic curve,
        /// and the two shrink to `touchDownTransform` on a spring. Releasing
        /// runs both back `LinePressPlan.releaseDelay` later.
        private func animatePressAppearance(pressed: Bool) {
            let backgroundLayer = pressedBackgroundLayerCreatingIfNeeded()
            let containerLayer = self.containerLayer
            let delay = pressed ? 0 : LinePressPlan.releaseDelay

            let opacityAnimator = LayerPropertyAnimator(
                layers: [backgroundLayer, containerLayer],
                timing: pressed ? LinePressPlan.pressOpacityTiming : LinePressPlan.releaseOpacityTiming
            )
            opacityAnimator.addChange {
                backgroundLayer.opacity = pressed ? 1 : 0
                containerLayer.opacity = pressed ? LyricsSpecs.highlightLabelOpacity : 1
            }

            let transform = pressed ? LyricsSpecs.touchDownTransform : .identity
            let transformAnimator = LayerPropertyAnimator(
                layers: [containerLayer, backgroundLayer],
                timing: pressed ? LinePressPlan.pressTransformTiming : LinePressPlan.releaseTransformTiming
            )
            transformAnimator.addChange {
                containerLayer.setAffineTransform(transform)
                backgroundLayer.setAffineTransform(transform)
            }

            opacityAnimator.run(afterDelay: delay)
            transformAnimator.run(afterDelay: delay)
        }

        private func pressedBackgroundLayerCreatingIfNeeded() -> NoAnimationLayer {
            if let pressedBackgroundLayer {
                return pressedBackgroundLayer
            }
            let backgroundLayer = NoAnimationLayer()
            backgroundLayer.backgroundColor = LyricsSpecs.highlightViewBackgroundColor
            backgroundLayer.cornerCurve = .continuous
            backgroundLayer.cornerRadius = LyricsSpecs.highlightViewCornerRadius
            backgroundLayer.opacity = 0
            lineHostLayer.insertSublayer(backgroundLayer, at: 0)
            pressedBackgroundLayer = backgroundLayer
            layoutLineLayers()
            return backgroundLayer
        }

        // MARK: Blur

        /// The radius the current contextual blur plan selects for this line.
        ///
        /// `SyncedLyricsLineLayer` carries a Gaussian blur filter for its whole
        /// life and only ever animates the radius — `sub_10019EBAC` writes
        /// `filters.gaussianBlur.inputRadius`, `sub_10019EEDC` drives it, and the
        /// selected line is exempted before any of that runs. This uses the same
        /// private `CAFilter` Music does (this app never ships through App
        /// Review), so the filter type, the key path, and the render-server-side
        /// evaluation are all Music's own — no `layerUsesCoreImageFilters`, no
        /// in-process Core Image pass.
        ///
        /// What reaches the filter is derived rather than stored: a focused or
        /// pressed line is not blurred, whatever the plan says. Music zeroes the
        /// radius on press and writes back the one it had on release instead;
        /// the two agree for any click that starts on a hovered line, and the
        /// derived one never writes back a radius a line change has made stale
        /// in between.
        func setLineBlurRadius(_ requestedRadius: CGFloat, animated: Bool) {
            requestedBlurRadius = requestedRadius
            applyBlurRadius(animated: animated)
        }

        private func applyBlurRadius(animated: Bool) {
            let effectiveRadius = isFocused || isPressed ? 0 : requestedBlurRadius
            let musicRadius = min(max(0, effectiveRadius), LyricsSpecs.maximumLineBlurRadius)
            let target = musicRadius * LyricsSpecs.renderedBlurRadiusScale
            guard target != blurRadius, let layer, installFilterIfNeeded(.blur) else { return }
            let visibleRadius = (layer.presentation()?.value(forKeyPath: LineFilter.blur.keyPath) as? NSNumber)
                .map(CGFloat.init(truncating:)) ?? blurRadius
            let lineOriginalIndex = originalIndex
            #log(
                .debug,
                """
                Line blur changed originalIndex=\(lineOriginalIndex, privacy: .public) \
                visibleRadius=\(visibleRadius, privacy: .public) \
                targetRadius=\(target, privacy: .public) \
                animated=\(animated, privacy: .public)
                """
            )
            #signpost(
                .event,
                "LineBlurChanged",
                """
                originalIndex=\(lineOriginalIndex, privacy: .public) \
                targetRadius=\(target, privacy: .public) \
                animated=\(animated, privacy: .public)
                """
            )
            blurRadius = target
            setFilterInput(NSNumber(value: Double(target)), of: .blur, animated: animated)
        }

        // MARK: Filters

        /// Set one filter's input, at once or along `LyricsSpecs.lineFilterTiming`
        /// from what is on screen now.
        private func setFilterInput(_ value: NSNumber, of filter: LineFilter, animated: Bool) {
            guard let layer else { return }
            let keyPath = filter.keyPath
            let visibleValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.setValue(value, forKeyPath: keyPath)
            CATransaction.commit()

            let generation = (filterChangeGenerations[filter] ?? 0) + 1
            filterChangeGenerations[filter] = generation
            guard animated else {
                layer.removeAnimation(forKey: keyPath)
                animatingFilters.remove(filter)
                updateRasterization()
                return
            }
            let animation = LyricsSpecs.lineFilterTiming.makePropertyAnimation(keyPath: keyPath)
            animation.fromValue = visibleValue
            animation.toValue = value
            layer.add(animation, forKey: keyPath)
            animatingFilters.insert(filter)
            updateRasterization()
            let restorationDeadline = DispatchTime.now() + LyricsSpecs.lineFilterTiming.totalDuration
            DispatchQueue.main.asyncAfter(deadline: restorationDeadline) { [weak self] in
                guard let self, self.filterChangeGenerations[filter] == generation else { return }
                self.animatingFilters.remove(filter)
                self.updateRasterization()
            }
        }

        /// Installs `filter` next to whatever is already there, in Music's
        /// order. The filters already installed are read back from the layer,
        /// so their current inputs come along.
        private func installFilterIfNeeded(_ filter: LineFilter) -> Bool {
            guard let layer else { return false }
            var installedFilters = (layer.filters ?? []).compactMap { $0 as? NSObject }
            if installedFilters.contains(where: { Self.name(of: $0) == filter.name }) {
                return true
            }
            guard let newFilter = Self.makePrivateFilter(filter) else { return false }
            installedFilters.append(newFilter)
            installedFilters.sort { firstFilter, secondFilter in
                Self.order(of: firstFilter) < Self.order(of: secondFilter)
            }
            layer.filters = installedFilters
            return true
        }

        private static func name(of installedFilter: NSObject) -> String? {
            installedFilter.value(forKey: "name") as? String
        }

        private static func order(of installedFilter: NSObject) -> Int {
            let installedName = name(of: installedFilter)
            return LineFilter.allCases.firstIndex { $0.name == installedName } ?? LineFilter.allCases.count
        }

        /// `CAFilter` is private API, reached through the runtime so there is
        /// nothing to link against. If a future macOS removes it this returns
        /// nil and the panel simply loses its depth blur and hover brightness —
        /// nothing else breaks.
        private static func makePrivateFilter(_ filter: LineFilter) -> NSObject? {
            guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
                  let privateFilter = filterClass
                  .perform(NSSelectorFromString("filterWithType:"), with: filter.name)?
                  .takeUnretainedValue() as? NSObject
            else { return nil }
            privateFilter.setValue(filter.name, forKey: "name")
            privateFilter.setValue(NSNumber(value: 0), forKey: filter.inputKey)
            return privateFilter
        }

        // MARK: Karaoke (per-frame, highlighted line only)

        func updateKaraoke(elapsedTime: TimeInterval, lineDuration: TimeInterval, mode: KaraokeMode) {
            guard let line, isHighlighted else { return }
            if FramePerformanceDiagnosticsPolicy.detailedFrameSignpostingIsEnabled {
                #signpostInterval("KaraokeLineUpdate") {
                    updateKaraokeContent(
                        line: line,
                        elapsedTime: elapsedTime,
                        lineDuration: lineDuration,
                        mode: mode
                    )
                }
            } else {
                updateKaraokeContent(
                    line: line,
                    elapsedTime: elapsedTime,
                    lineDuration: lineDuration,
                    mode: mode
                )
            }
        }

        private func updateKaraokeContent(
            line: LyricsLine,
            elapsedTime: TimeInterval,
            lineDuration: TimeInterval,
            mode: KaraokeMode
        ) {
            buildLayoutIfNeeded(forWidth: bounds.width)
            karaokeFraction = KaraokeFill.fraction(
                elapsedTime: elapsedTime,
                lineDuration: lineDuration,
                wordTimings: line.wordTimingEntries ?? [],
                synchronizedTextTiming: line.synchronizedTextTiming,
                totalCharacterCount: line.content.count,
                mode: mode
            )
            contentLayer.update(
                elapsedTime: elapsedTime,
                fillFraction: karaokeFraction
            )
        }

        // MARK: Cursor

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

        var preferredHeight: CGFloat {
            72
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool {
            true
        }

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
