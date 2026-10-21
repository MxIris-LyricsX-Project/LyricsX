import AppKit
import QuartzCore
import OSToolbox

extension AppleMusicLyrics {
    /// One lyric line's main text, built the way Apple Music builds it.
    ///
    /// ```
    /// SyncedLyricsLineContentLayer
    /// └── visual row colour container × rows  mask = that row's glyph mask
    ///     ├── background colour layer         the un-sung colour
    ///     ├── LineProgressGradientLayer       the sung colour + feathered edge
    ///     └── visual row glyph mask
    ///         └── word colour layer × words   mask = word layer
    ///             └── word layer              carries the glow; holds the glyphs
    ///                 └── GlyphRunLayer × glyphs
    /// ```
    ///
    /// Colour and sweep live *outside* the mask; glyph geometry lives *inside* it.
    /// That is the whole trick: a glyph can scale and lift while the sung/un-sung
    /// boundary sweeping across it stays a continuous ramp, because the two are
    /// composited rather than drawn together. Reproducing this with a per-frame
    /// `draw(_:)` is not possible — which is why the previous CPU implementation
    /// never looked right no matter how the constants were tuned.
    ///
    /// Built from `sub_100169AC8` (the line), `sub_10018C12C` (the word) and
    /// `sub_10018B2B4` (the emphasis schedule).
    @Loggable(
        isEnabled: AppleMusicLyrics.PanelDiagnostics.isKaraokeEnabled,
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics",
        category: "InlineKaraoke"
    )
    @Signpostable(
        isEnabled: AppleMusicLyrics.PanelDiagnostics.isKaraokeEnabled,
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics",
        category: "InlineKaraoke"
    )
    final class SyncedLyricsLineContentLayer: CALayer {
        /// The colour and glyph-mask subtree belonging to exactly one wrapped row.
        /// Keeping the mask row-local prevents a padded gradient from exposing
        /// glyphs in an adjacent row.
        private final class VisualRowNode {
            let colorContainerLayer: NoAnimationLayer
            let backgroundColorLayer: NoAnimationLayer
            let glyphMaskContainerLayer: NoAnimationLayer
            let progressGradientLayer: LineProgressGradientLayer

            init(
                colorContainerLayer: NoAnimationLayer,
                backgroundColorLayer: NoAnimationLayer,
                glyphMaskContainerLayer: NoAnimationLayer,
                progressGradientLayer: LineProgressGradientLayer
            ) {
                self.colorContainerLayer = colorContainerLayer
                self.backgroundColorLayer = backgroundColorLayer
                self.glyphMaskContainerLayer = glyphMaskContainerLayer
                self.progressGradientLayer = progressGradientLayer
            }
        }

        /// A word, plus the layers standing in for it.
        private final class WordNode {
            let word: LineTextLayout.Word
            let colorLayer: NoAnimationLayer
            let wordLayer: NoAnimationLayer
            let glyphLayers: [GlyphRunLayer]
            /// How far the glyph layers sit inside the padded word box. Glyph
            /// geometry is computed in the word's *text* box — the way Music
            /// computes it — and then shifted by this to land in the padded one.
            let glyphOffset: CGPoint
            /// Set once the word's emphasis batch has been scheduled, so a display
            /// link running at 120Hz does not re-schedule it 120 times a second.
            var isEmphasisScheduled = false
            /// Pending "travel back to rest" work, kept so it can be cancelled if
            /// the line is recycled mid-word.
            var pendingGlyphReturns: [DispatchWorkItem] = []
            /// Glow has its own slower spring and lifecycle in Music.
            var pendingDeglow: DispatchWorkItem?

            /// One of Music's `SyllableLayer`s: the glyphs that rise together
            /// when their syllable turns sung. Only structured words have these.
            struct SyllableGroup {
                /// The syllable's own characters, for the diagnostics trace.
                let text: String
                let timeRange: Range<TimeInterval>
                /// Indices into the owning node's `glyphLayers`.
                let glyphIndices: [Int]
                var isLifted = false
            }

            /// What Music would have decided for `Lyrics.Word.emphasis`.
            enum EmphasisDecision {
                /// `.none`: no per-glyph animation, syllables lift on their own.
                case syllableLift
                /// `.factor`: the per-glyph swell, which brings its own lift.
                case wordEmphasis(WordEmphasisPlan)
            }

            var syllableGroups: [SyllableGroup]
            /// Decided the first time the word is due, so a policy change still
            /// lands on the next word rather than the next line.
            var emphasisDecision: EmphasisDecision?

            init(
                word: LineTextLayout.Word,
                colorLayer: NoAnimationLayer,
                wordLayer: NoAnimationLayer,
                glyphLayers: [GlyphRunLayer],
                glyphOffset: CGPoint,
                syllableGroups: [SyllableGroup]
            ) {
                self.word = word
                self.colorLayer = colorLayer
                self.wordLayer = wordLayer
                self.glyphLayers = glyphLayers
                self.glyphOffset = glyphOffset
                self.syllableGroups = syllableGroups
            }

            /// Where glyph `index` sits when nothing is emphasizing it.
            func restingOrigin(ofGlyphAt index: Int) -> CGPoint {
                let origin = word.glyphs[index].frame.origin
                return CGPoint(x: origin.x + glyphOffset.x, y: origin.y + glyphOffset.y)
            }

            /// Where glyph `index` stays once it has been sung: the resting
            /// origin raised by `syllableLift`. Music never lowers a sung glyph
            /// again until the line is rewound or deselected.
            func sungOrigin(ofGlyphAt index: Int) -> CGPoint {
                let rest = restingOrigin(ofGlyphAt: index)
                return CGPoint(x: rest.x, y: rest.y - LyricsSpecs.syllableLift)
            }
        }

        // MARK: Appearance

        /// Colour of the selected line's text that has not been sung yet —
        /// Music's `selectedUpcomingTextColor`.
        var unsungColor: CGColor = .init(gray: 1, alpha: LyricsSpecs.selectedUpcomingTextOpacity) {
            didSet {
                guard highlightState else { return }
                applySelectionAppearance()
            }
        }

        /// Colour of the text of every line other than the selected one —
        /// Music's `deselectedTextColor`.
        var deselectedColor: CGColor = .init(gray: 1, alpha: LyricsSpecs.deselectedTextOpacity) {
            didSet {
                guard !highlightState else { return }
                applySelectionAppearance()
            }
        }

        /// Colour of text that has been sung. Only visible while `isHighlighted`.
        var sungColor: CGColor = .init(gray: 1, alpha: 1) {
            didSet {
                visualRowNodes.forEach { visualRowNode in
                    visualRowNode.progressGradientLayer.color = sungColor
                }
            }
        }

        /// Whether this is the selected line. While false the sweep is faded
        /// out and the line reads as one flat `deselectedColor`, which is what
        /// every line other than the active one looks like. Assigning switches
        /// at once; `setHighlighted(_:animatedWith:)` can animate the switch.
        var isHighlighted: Bool {
            get { highlightState }
            set { setHighlighted(newValue, animatedWith: nil) }
        }

        private var highlightState = false

        /// How timed words — structured or inline-tag — are emphasized; see
        /// `StructuredEmphasisPolicy`. Read as each word starts so the hidden
        /// defaults key can be flipped mid-song. Probes inject a fixed policy.
        var structuredEmphasisPolicyProvider: () -> StructuredEmphasisPolicy = {
            StructuredEmphasisPolicy.resolve()
        }

        // MARK: Layers

        private var visualRowNodes: [VisualRowNode] = []
        private var wordNodes: [WordNode] = []
        private var layout: LineTextLayout?
        /// The first characters of the current line, so every diagnostics
        /// event below reads back to its lyric without an index.
        private var lineLabel = ""
        private var precedingElapsedTime: TimeInterval?
        private static let maximumContinuousElapsedTimeStep: TimeInterval = 0.5
        /// Cumulative text width before each visual row, so the sweep cascades row
        /// by row instead of lighting every wrapped row at once.
        private var cumulativeWidthBeforeRow: [CGFloat] = []
        /// How far this layer extends past the text block on every side.
        ///
        /// Each visual row colour container has its own glyph mask, and a mask is
        /// confined to the bounds of the layer it masks — so without room here,
        /// everything emphasis adds (the lift, the swell, the glow) is cut off
        /// flush with the edge of the text. Whoever positions this layer has to
        /// subtract it, or the text lands `textOutset` away from where it was
        /// measured to go.
        private(set) var textOutset: CGSize = .zero

        override init() {
            super.init()
            isGeometryFlipped = true
        }

        override init(layer: Any) {
            super.init(layer: layer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func action(forKey event: String) -> CAAction? {
            nil
        }

        // MARK: Selection

        /// Switch between the selected and the deselected look the way
        /// `sub_10016D164` does: the un-sung colour moves between `unsungColor`
        /// and `deselectedColor` while the sung sweep fades in or out. Given a
        /// timing, both travel on it together; without one they switch at once.
        ///
        /// A line that stops being selected keeps its sweep where it was, so the
        /// part that was sung is what fades out; its glyphs still settle back at
        /// once. A line that becomes selected starts from an empty sweep.
        func setHighlighted(_ highlighted: Bool, animatedWith timing: (any LayerAnimationTiming)?) {
            guard highlighted != highlightState else { return }
            highlightState = highlighted
            if highlighted {
                resetSweep()
            } else {
                resetGlyphEmphasis()
            }
            let selectionLayers = visualRowNodes.flatMap { visualRowNode -> [CALayer] in
                [visualRowNode.backgroundColorLayer, visualRowNode.progressGradientLayer]
            }
            guard let timing else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                selectionLayers.forEach(LayerPropertyAnimator.removeAllAnimations(from:))
                applySelectionAppearance()
                CATransaction.commit()
                return
            }
            let animator = LayerPropertyAnimator(layers: selectionLayers, timing: timing)
            animator.addChange {
                self.applySelectionAppearance()
            }
            animator.run()
        }

        private func applySelectionAppearance() {
            let backgroundColor = highlightState ? unsungColor : deselectedColor
            let sweepOpacity: Float = highlightState ? 1 : 0
            for visualRowNode in visualRowNodes {
                visualRowNode.backgroundColorLayer.backgroundColor = backgroundColor
                visualRowNode.progressGradientLayer.opacity = sweepOpacity
            }
        }

        // MARK: Building

        /// Tear the tree down and build it again for `layout`. Called when the
        /// line, the font, or the available width changes — never per frame.
        func rebuild(with layout: LineTextLayout, contentsScale: CGFloat) {
            let rebuildInterval = #signpost(
                .begin,
                "LineLayerRebuild",
                "visualRowCount=\(layout.visualLines.count, privacy: .public) wordCount=\(layout.words.count, privacy: .public)"
            )
            defer { #signpost(.end, rebuildInterval) }
            resetEmphasis()
            self.layout = layout

            visualRowNodes.forEach { visualRowNode in
                visualRowNode.colorContainerLayer.removeFromSuperlayer()
            }
            wordNodes = []
            visualRowNodes = []

            let rowCount = max(1, layout.visualLines.count)
            let maximumVisualLineHeight = layout.visualLines.map(\.typographicFrame.height).max()
                ?? layout.contentSize.height
            let widestWord = layout.words.map(\.frame.width).max() ?? 0
            let headroom = Self.emphasisHeadroom(forWordSize: CGSize(
                width: widestWord,
                height: maximumVisualLineHeight
            ))
            textOutset = CGSize(width: ceil(headroom.width), height: ceil(headroom.height))

            bounds = CGRect(origin: .zero, size: CGSize(
                width: layout.contentSize.width + textOutset.width * 2,
                height: layout.contentSize.height + textOutset.height * 2
            ))

            var runningWidth: CGFloat = 0
            cumulativeWidthBeforeRow = layout.visualLines.map { visualLine in
                defer { runningWidth += visualLine.typographicFrame.width }
                return runningWidth
            }

            buildVisualRows(for: layout)
            for word in layout.words {
                wordNodes.append(makeWordNode(for: word, contentsScale: contentsScale))
            }
            let renderedGlyphCount = wordNodes.reduce(0) { partialCount, wordNode in
                partialCount + wordNode.glyphLayers.count
            }
            let renderedWordCount = wordNodes.count
            lineLabel = Self.makeLineLabel(for: layout)
            let currentLineLabel = lineLabel
            let languageIdentifier = layout.languageIdentifier ?? "-"
            let wordSummary = Self.makeWordSummary(for: layout)
            #log(
                .info,
                """
                Line layer rebuilt line=\(currentLineLabel, privacy: .public) \
                language=\(languageIdentifier, privacy: .public) \
                visualRowCount=\(rowCount, privacy: .public) \
                wordCount=\(renderedWordCount, privacy: .public) \
                glyphCount=\(renderedGlyphCount, privacy: .public) \
                contentsScale=\(contentsScale, privacy: .public) \
                width=\(layout.contentSize.width, privacy: .public) \
                height=\(layout.contentSize.height, privacy: .public) \
                words=\(wordSummary, privacy: .public)
                """
            )
        }

        private static func makeLineLabel(for layout: LineTextLayout) -> String {
            let lineText = layout.words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return String(lineText.prefix(24))
        }

        /// One entry per word: its text, its time range in seconds from the line
        /// start, `s` for structured (synchronized) timing or `i` for the inline
        /// tag fallback, and the syllable count when there is more than one.
        private static func makeWordSummary(for layout: LineTextLayout) -> String {
            layout.words.map { word -> String in
                let wordText = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let timeRange = word.timeRange else { return "\(wordText)[untimed]" }
                let source = word.timingSource == .synchronized ? "s" : "i"
                let syllableSuffix = word.syllables.count > 1 ? "/\(word.syllables.count)syl" : ""
                let start = Self.formatSeconds(timeRange.lowerBound)
                let end = Self.formatSeconds(timeRange.upperBound)
                return "\(wordText)[\(start)-\(end)\(source)\(syllableSuffix)]"
            }.joined(separator: " ")
        }

        private static func formatSeconds(_ value: TimeInterval) -> String {
            String(format: "%.3f", value)
        }

        private static func formatSeconds(_ values: [TimeInterval]) -> String {
            values.map(formatSeconds).joined(separator: ",")
        }

        private func makeWordNode(for word: LineTextLayout.Word, contentsScale: CGFloat) -> WordNode {
            // Glyph geometry is computed in the word's own text box, the way Music
            // computes it, then shifted into a box with room to swell and into this
            // layer's outset.
            let headroom = Self.emphasisHeadroom(forWordSize: word.frame.size)
            let paddedFrameInContentLayer = word.frame
                .insetBy(dx: -headroom.width, dy: -headroom.height)
                .offsetBy(dx: textOutset.width, dy: textOutset.height)
            let visualRowColorContainer = visualRowNodes[word.visualLineIndex].colorContainerLayer
            let paddedFrameInVisualRow = paddedFrameInContentLayer.offsetBy(
                dx: -visualRowColorContainer.frame.minX,
                dy: -visualRowColorContainer.frame.minY
            )
            let glyphOffset = CGPoint(x: headroom.width, y: headroom.height)

            let wordLayer = NoAnimationLayer()
            wordLayer.frame = CGRect(origin: .zero, size: paddedFrameInVisualRow.size)
            wordLayer.contentsScale = contentsScale
            wordLayer.shouldRasterize = true
            wordLayer.rasterizationScale = contentsScale
            wordLayer.shadowColor = CGColor(gray: 1, alpha: 1)
            wordLayer.shadowRadius = LyricsSpecs.glowRadius
            wordLayer.shadowOpacity = LyricsSpecs.glowOpacityRange.lowerBound
            wordLayer.shadowOffset = .zero

            var glyphLayers: [GlyphRunLayer] = []
            for glyph in word.glyphs {
                let glyphLayer = GlyphRunLayer(
                    run: glyph.run,
                    glyphRange: glyph.glyphRange,
                    textPosition: glyph.textPosition,
                    contentsScale: contentsScale
                )
                glyphLayer.frame = glyph.frame.offsetBy(dx: glyphOffset.x, dy: glyphOffset.y)
                glyphLayer.shadowColor = nil
                glyphLayer.shadowRadius = 0
                glyphLayer.shadowOpacity = 0
                glyphLayer.shadowOffset = .zero
                wordLayer.addSublayer(glyphLayer)
                glyphLayers.append(glyphLayer)
            }

            // Inside a mask only alpha counts, so this is opaque white: the word's
            // brightness comes from the colour layers underneath the mask, not
            // from here. Music uses this layer for its word-level colour crossfade,
            // which the per-character sweep makes unnecessary for us.
            let colorLayer = NoAnimationLayer()
            colorLayer.frame = paddedFrameInVisualRow
            colorLayer.backgroundColor = CGColor(gray: 1, alpha: 1)
            colorLayer.mask = wordLayer
            visualRowNodes[word.visualLineIndex].glyphMaskContainerLayer.addSublayer(colorLayer)

            return WordNode(
                word: word,
                colorLayer: colorLayer,
                wordLayer: wordLayer,
                glyphLayers: glyphLayers,
                glyphOffset: glyphOffset,
                syllableGroups: Self.makeSyllableGroups(for: word)
            )
        }

        /// Music builds a `.none` word from one `SyllableLayer` per syllable;
        /// a structured word without syllables of its own is one syllable, and
        /// so is an inline-tag segment — Kugou and QQ Music tags are real
        /// per-word / per-character timing, the same grain as Music's
        /// syllables. An untimed word gets none.
        private static func makeSyllableGroups(for word: LineTextLayout.Word) -> [WordNode.SyllableGroup] {
            guard let timeRange = word.timeRange else { return [] }
            let wordCharacters = Array(word.text)
            let groups = word.syllables
                .filter { !$0.glyphIndices.isEmpty }
                .map { syllable -> WordNode.SyllableGroup in
                    let lowerBound = max(0, syllable.characterRange.lowerBound - word.characterRange.lowerBound)
                    let upperBound = min(
                        wordCharacters.count,
                        syllable.characterRange.upperBound - word.characterRange.lowerBound
                    )
                    let syllableText = lowerBound < upperBound
                        ? String(wordCharacters[lowerBound ..< upperBound])
                        : word.text
                    return WordNode.SyllableGroup(
                        text: syllableText,
                        timeRange: syllable.timeRange,
                        glyphIndices: syllable.glyphIndices
                    )
                }
            if groups.isEmpty, !word.glyphs.isEmpty {
                return [WordNode.SyllableGroup(
                    text: word.text,
                    timeRange: timeRange,
                    glyphIndices: Array(word.glyphs.indices)
                )]
            }
            return groups
        }

        /// Room an emphasized word needs beyond its own text box, on each side:
        /// half the swell (the glyph grows about its centre), the lift, and enough
        /// for the glow's blur. A mask cannot paint outside the layer it masks, so
        /// both the word's colour layer and this whole layer have to reserve it —
        /// otherwise emphasis is silently cut back to the text box.
        private static func emphasisHeadroom(forWordSize size: CGSize) -> CGSize {
            let swell = LyricsSpecs.emphasizingScaleRange.upperBound - 1
            return CGSize(
                width: size.width * swell * 0.5 + LyricsSpecs.glowRadius * 2,
                height: size.height * swell * 0.5 + LyricsSpecs.syllableLift + LyricsSpecs.glowRadius * 2
            )
        }

        private func buildVisualRows(for layout: LineTextLayout) {
            for visualLine in layout.visualLines {
                let typographicFrame = visualLine.typographicFrame
                let colorContainerLayer = NoAnimationLayer()
                colorContainerLayer.frame = CGRect(
                    x: typographicFrame.minX,
                    y: typographicFrame.minY,
                    width: typographicFrame.width + textOutset.width * 2,
                    height: typographicFrame.height + textOutset.height * 2
                )
                colorContainerLayer.isGeometryFlipped = true

                let backgroundColorLayer = NoAnimationLayer()
                backgroundColorLayer.frame = colorContainerLayer.bounds
                backgroundColorLayer.backgroundColor = highlightState ? unsungColor : deselectedColor
                colorContainerLayer.addSublayer(backgroundColorLayer)

                let gradient = LineProgressGradientLayer(
                    lineWidth: typographicFrame.width,
                    lineHeight: typographicFrame.height,
                    verticalPadding: LyricsSpecs.syllableLift + LyricsSpecs.glowRadius,
                    color: sungColor
                )
                gradient.opacity = highlightState ? 1 : 0
                gradient.position = CGPoint(
                    x: textOutset.width + gradient.originX(forFillEdge: 0),
                    y: textOutset.height - gradient.verticalPadding
                )
                colorContainerLayer.addSublayer(gradient)

                let glyphMaskContainerLayer = NoAnimationLayer()
                glyphMaskContainerLayer.frame = colorContainerLayer.bounds
                glyphMaskContainerLayer.isGeometryFlipped = true
                colorContainerLayer.mask = glyphMaskContainerLayer

                addSublayer(colorContainerLayer)
                visualRowNodes.append(VisualRowNode(
                    colorContainerLayer: colorContainerLayer,
                    backgroundColorLayer: backgroundColorLayer,
                    glyphMaskContainerLayer: glyphMaskContainerLayer,
                    progressGradientLayer: gradient
                ))
            }
        }

        // MARK: Per-frame update

        /// Advance the sweep and schedule any word whose turn has come.
        ///
        /// `elapsedTime` is seconds since the line started. Nothing here animates
        /// glyphs directly: it only decides *when* to hand a word to
        /// `LayerPropertyAnimator`, which is what keeps the per-frame cost to a few
        /// comparisons even at 120Hz.
        func update(elapsedTime: TimeInterval, fillFraction: CGFloat) {
            guard let layout, isHighlighted else { return }
            if FramePerformanceDiagnosticsPolicy.detailedFrameSignpostingIsEnabled {
                #signpostInterval("KaraokeSweepUpdate") {
                    updateSweepAndEmphasis(
                        layout: layout,
                        elapsedTime: elapsedTime,
                        fillFraction: fillFraction
                    )
                }
            } else {
                updateSweepAndEmphasis(
                    layout: layout,
                    elapsedTime: elapsedTime,
                    fillFraction: fillFraction
                )
            }
        }

        private func updateSweepAndEmphasis(
            layout: LineTextLayout,
            elapsedTime: TimeInterval,
            fillFraction: CGFloat
        ) {
            if shouldSynchronizeEmphasisState(forElapsedTime: elapsedTime) {
                synchronizeEmphasisState(forElapsedTime: elapsedTime)
            }
            precedingElapsedTime = elapsedTime
            updateSweep(layout: layout, fillFraction: fillFraction)
            scheduleDueWords(elapsedTime: elapsedTime)
            updateSyllableLifts(elapsedTime: elapsedTime)
        }

        private func shouldSynchronizeEmphasisState(forElapsedTime elapsedTime: TimeInterval) -> Bool {
            guard let precedingElapsedTime else { return true }
            return elapsedTime < precedingElapsedTime - 0.1
                || elapsedTime - precedingElapsedTime > Self.maximumContinuousElapsedTimeStep
        }

        private func synchronizeEmphasisState(forElapsedTime elapsedTime: TimeInterval) {
            let previousElapsedTime = precedingElapsedTime ?? -1
            let synchronizedWordCount = wordNodes.count
            let currentLineLabel = lineLabel
            #log(
                .info,
                """
                Emphasis state synchronized line=\(currentLineLabel, privacy: .public) \
                elapsedTime=\(elapsedTime, privacy: .public) \
                previousElapsedTime=\(previousElapsedTime, privacy: .public) \
                wordCount=\(synchronizedWordCount, privacy: .public)
                """
            )
            #signpost(
                .event,
                "EmphasisStateSynchronized",
                "elapsedTime=\(elapsedTime, privacy: .public)"
            )
            resetEmphasis()
            for node in wordNodes {
                if let timeRange = node.word.timeRange,
                   timeRange.upperBound <= elapsedTime {
                    node.isEmphasisScheduled = true
                }
            }
        }

        private func updateSweep(layout: LineTextLayout, fillFraction: CGFloat) {
            let totalWidth = max(0.0001, layout.totalTextWidth)
            let filledWidth = totalWidth * min(1, max(0, fillFraction))

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (rowIndex, visualRowNode) in visualRowNodes.enumerated() {
                let gradient = visualRowNode.progressGradientLayer
                let typographicFrame = layout.visualLines[rowIndex].typographicFrame
                let rowWidth = typographicFrame.width
                let filledInRow = min(max(0, filledWidth - cumulativeWidthBeforeRow[rowIndex]), rowWidth)
                let originX = filledInRow >= rowWidth
                    ? gradient.originXForCompletelyFilled()
                    : gradient.originX(forFillEdge: filledInRow)
                gradient.position.x = textOutset.width + originX
            }
            CATransaction.commit()
        }

        private func scheduleDueWords(elapsedTime: TimeInterval) {
            // Music starts a word's animation `animationHeadstart` before its own
            // timing, otherwise the swell reads as half a beat late.
            let cursor = elapsedTime + LyricsSpecs.animationHeadstart
            for node in wordNodes where !node.isEmphasisScheduled {
                guard let timeRange = node.word.timeRange, cursor >= timeRange.lowerBound else { continue }
                node.isEmphasisScheduled = true
                if case .wordEmphasis(let plan) = decideEmphasis(for: node) {
                    emphasize(node, plan: plan)
                }
            }
        }

        /// Music's `Lyrics.Word.emphasis`, resolved once per word from the
        /// current policy. `nil` from the plan is Music's `.none`.
        private func decideEmphasis(for node: WordNode) -> WordNode.EmphasisDecision {
            if let decision = node.emphasisDecision {
                return decision
            }
            let structuredEmphasisPolicy = structuredEmphasisPolicyProvider()
            // Under Music's gate an inline-tag segment is judged on its own
            // duration and glyphs. The phrase envelope `LineTextLayout` builds
            // for the legacy look would make a whole English line count as one
            // long word and swell every segment in it.
            let judgesTheSegmentOnItsOwn = node.word.timingSource == .inferred
                && structuredEmphasisPolicy == .appleMusic26
            let duration: TimeInterval
            let timingGlyphCount: Int
            if judgesTheSegmentOnItsOwn {
                duration = node.word.duration
                timingGlyphCount = node.glyphLayers.count
            } else {
                duration = node.word.emphasisDuration > 0 ? node.word.emphasisDuration : node.word.duration
                timingGlyphCount = node.word.emphasisGlyphCount
            }
            // `[tt]` segments carry their trailing space; Music's seven-character
            // gate counts the word itself.
            let wordLength = node.word.text.trimmingCharacters(in: .whitespacesAndNewlines).count
            let plan = WordEmphasisPlan.make(
                wordDuration: duration,
                wordLength: wordLength,
                renderedGlyphCount: node.glyphLayers.count,
                timingGlyphCount: timingGlyphCount,
                languageIdentifier: layout?.languageIdentifier,
                structuredEmphasisPolicy: structuredEmphasisPolicy
            )
            let decision: WordNode.EmphasisDecision = plan.map { .wordEmphasis($0) } ?? .syllableLift
            node.emphasisDecision = decision
            if plan == nil {
                let characterCount = node.word.characterRange.count
                let currentLineLabel = lineLabel
                let wordText = node.word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let syllableCount = node.syllableGroups.count
                #log(
                    .debug,
                    """
                    Word emphasis withheld line=\(currentLineLabel, privacy: .public) \
                    text=\(wordText, privacy: .public) \
                    characterCount=\(characterCount, privacy: .public) \
                    duration=\(duration, privacy: .public) \
                    syllableCount=\(syllableCount, privacy: .public) syllablesLiftOnTheirOwn=true
                    """
                )
            }
            return decision
        }

        // MARK: Syllable lift

        /// `sub_1001689D4`'s per-syllable pass: a syllable that has just turned
        /// sung rises by `syllableLift`, one that the time has rewound past
        /// settles back, both on Music's soft spring. Only `.none` words take
        /// part; a `.factor` word's swell carries its own lift.
        private func updateSyllableLifts(elapsedTime: TimeInterval) {
            for node in wordNodes where !node.syllableGroups.isEmpty {
                guard let wordStart = node.word.timeRange?.lowerBound else { continue }
                let isDueOrLifted = elapsedTime >= wordStart || node.syllableGroups.contains(where: \.isLifted)
                guard isDueOrLifted, case .syllableLift = decideEmphasis(for: node) else { continue }
                for index in node.syllableGroups.indices {
                    let shouldBeLifted = elapsedTime >= node.syllableGroups[index].timeRange.lowerBound
                    guard shouldBeLifted != node.syllableGroups[index].isLifted else { continue }
                    node.syllableGroups[index].isLifted = shouldBeLifted
                    moveSyllable(
                        node.syllableGroups[index],
                        of: node,
                        lifted: shouldBeLifted,
                        elapsedTime: elapsedTime
                    )
                }
            }
        }

        private func moveSyllable(
            _ group: WordNode.SyllableGroup,
            of node: WordNode,
            lifted: Bool,
            elapsedTime: TimeInterval
        ) {
            let currentLineLabel = lineLabel
            let syllableText = group.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstGlyphIndex = group.glyphIndices.first ?? -1
            let lastGlyphIndex = group.glyphIndices.last ?? -1
            let syllableStart = group.timeRange.lowerBound
            let motion = lifted ? "lifted" : "lowered"
            #log(
                .debug,
                """
                Syllable \(motion, privacy: .public) line=\(currentLineLabel, privacy: .public) \
                text=\(syllableText, privacy: .public) \
                glyphs=\(firstGlyphIndex, privacy: .public)-\(lastGlyphIndex, privacy: .public) \
                start=\(syllableStart, privacy: .public) elapsedTime=\(elapsedTime, privacy: .public)
                """
            )
            let glyphLayers = group.glyphIndices.map { node.glyphLayers[$0] }
            let animator = LayerPropertyAnimator(layers: glyphLayers, timing: SyllableLiftPlan.springTiming)
            animator.addChange {
                for glyphIndex in group.glyphIndices {
                    let target = lifted
                        ? node.sungOrigin(ofGlyphAt: glyphIndex)
                        : node.restingOrigin(ofGlyphAt: glyphIndex)
                    Self.place(node.glyphLayers[glyphIndex], atRestingOrigin: target)
                }
            }
            animator.run()
        }

        // MARK: Emphasis

        /// Schedule one word's ripple: every glyph springs up to the emphasized
        /// size, staggered against its neighbours, then travels back.
        private func emphasize(_ node: WordNode, plan: WordEmphasisPlan) {
            let glyphCount = node.glyphLayers.count
            guard glyphCount > 0 else { return }
            let duration = plan.wordDuration
            let structuredEmphasisPolicy = structuredEmphasisPolicyProvider()
            let spring = SpringTimingParameters(
                dampingRatio: LyricsSpecs.emphasisDampingRatio,
                period: plan.springPeriod
            )
            let timingSourceName = node.word.timingSource == .synchronized ? "synchronized" : "inferred"
            let currentLineLabel = lineLabel
            let wordText = node.word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let riseDelaySummary = Self.formatSeconds(plan.riseDelays)
            let returnDelaySummary = Self.formatSeconds(plan.returnDelays)
            #log(
                .debug,
                """
                Word emphasis scheduled line=\(currentLineLabel, privacy: .public) \
                text=\(wordText, privacy: .public) \
                characterCount=\(node.word.characterRange.count, privacy: .public) \
                glyphCount=\(glyphCount, privacy: .public) \
                duration=\(duration, privacy: .public) \
                timingSource=\(timingSourceName, privacy: .public) \
                policy=\(structuredEmphasisPolicy.rawValue, privacy: .public) \
                scale=\(plan.scale, privacy: .public) \
                springPeriod=\(plan.springPeriod, privacy: .public) \
                glowOpacity=\(plan.glowOpacity, privacy: .public) \
                riseDelays=\(riseDelaySummary, privacy: .public) \
                returnDelays=\(returnDelaySummary, privacy: .public)
                """
            )
            #signpost(
                .event,
                "WordEmphasisScheduled",
                "glyphCount=\(glyphCount, privacy: .public) duration=\(duration, privacy: .public)"
            )

            for (glyphIndex, glyphLayer) in node.glyphLayers.enumerated() {
                let target = emphasizedOrigin(ofGlyphAt: glyphIndex, in: node, scale: plan.scale)
                let animator = LayerPropertyAnimator(layers: [glyphLayer], timing: spring)
                animator.addChange {
                    Self.place(glyphLayer, atRestingOrigin: target)
                    glyphLayer.setAffineTransform(CGAffineTransform(scaleX: plan.scale, y: plan.scale))
                }
                animator.run(afterDelay: plan.riseDelays[glyphIndex])
            }

            if plan.glowOpacity > LyricsSpecs.glowOpacityRange.lowerBound {
                let glowAnimator = LayerPropertyAnimator(layers: [node.wordLayer], timing: spring)
                glowAnimator.addChange {
                    node.wordLayer.shadowOpacity = plan.glowOpacity
                }
                glowAnimator.run(afterDelay: plan.riseDelays.first ?? 0)
            }

            scheduleReturns(for: node, spring: spring, plan: plan)
            scheduleDeglow(for: node, plan: plan)
        }

        /// Apple Music's emphasized position for one glyph.
        ///
        /// `sub_10018B2B4` moves the glyph to
        /// `x = (originX + W(1-s)/2 + s·originX) / 2`, which expands to
        /// "scale the *word* about its centre by `(1 + s) / 2`". So the word
        /// spreads at half the rate each glyph grows, and neighbouring glyphs
        /// crowd slightly — that squeeze is the look, not a bug to compensate for.
        private func emphasizedOrigin(
            ofGlyphAt glyphIndex: Int,
            in node: WordNode,
            scale: CGFloat
        ) -> CGPoint {
            let origin = node.word.glyphs[glyphIndex].frame.origin
            let size = node.word.frame.size
            let horizontalSlack = (size.width - scale * size.width) * 0.5
            let verticalSlack = size.height - scale * size.height
            return CGPoint(
                x: (origin.x + horizontalSlack + scale * origin.x) * 0.5 + node.glyphOffset.x,
                // Music's own y is `(originY + verticalSlack + s·originY) * 0.25 -
                // syllableLift`, which for its layout (glyphs sit at the word's
                // top, so originY is 0) is the same as this. Anchoring on the
                // laid-out origin keeps every glyph's lift exactly `syllableLift`
                // above its rest, which is also where the return pass leaves it.
                y: origin.y + node.glyphOffset.y + verticalSlack * 0.25 - LyricsSpecs.syllableLift
            )
        }

        /// Move `layer` so that its *untransformed* frame origin lands on `origin`.
        ///
        /// Assigning `frame` would be wrong here: Core Animation derives `position`
        /// from the frame as the transform leaves it, so a glyph that is mid-swell
        /// creeps a few points every time it is repositioned, and the drift never
        /// washes out.
        private static func place(_ layer: CALayer, atRestingOrigin origin: CGPoint) {
            layer.position = CGPoint(
                x: origin.x + layer.bounds.width * layer.anchorPoint.x,
                y: origin.y + layer.bounds.height * layer.anchorPoint.y
            )
        }

        /// The return pass runs `2 · wordDuration / glyphCount` after each glyph's
        /// own start, exactly as Music schedules it, and only takes back the swell:
        /// `sub_10018B2B4` hands `sub_1001678FC` the frame origin *minus*
        /// `syllableLift` with an identity transform, so the sung glyph settles
        /// three points high and stays there. Dropping it all the way back to rest
        /// is what made lift-only (zh/ja) words read as a bounce. Only a rewind or
        /// deselection (`resetEmphasis()`) lowers the line again.
        ///
        /// It has to be a real timer rather than a second animation queued up front:
        /// two `beginTime`-delayed animations on the same key path would have the
        /// later one's backwards fill override the earlier one for its whole run,
        /// pinning the glyph at rest instead of letting it swell.
        private func scheduleReturns(
            for node: WordNode,
            spring: SpringTimingParameters,
            plan: WordEmphasisPlan
        ) {
            node.pendingGlyphReturns.forEach { $0.cancel() }
            node.pendingGlyphReturns = node.glyphLayers.enumerated().map { glyphIndex, glyphLayer in
                let work = DispatchWorkItem { [weak self, weak node, weak glyphLayer] in
                    guard let self, let node, let glyphLayer else { return }
                    let currentLineLabel = self.lineLabel
                    let wordText = node.word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    #log(
                        .debug,
                        """
                        Glyph return started line=\(currentLineLabel, privacy: .public) \
                        text=\(wordText, privacy: .public) glyphIndex=\(glyphIndex, privacy: .public)
                        """
                    )
                    let sungOrigin = node.sungOrigin(ofGlyphAt: glyphIndex)
                    let animator = LayerPropertyAnimator(layers: [glyphLayer], timing: spring)
                    animator.addChange {
                        Self.place(glyphLayer, atRestingOrigin: sungOrigin)
                        glyphLayer.setAffineTransform(.identity)
                    }
                    animator.run()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + plan.returnDelays[glyphIndex], execute: work)
                return work
            }
        }

        private func scheduleDeglow(for node: WordNode, plan: WordEmphasisPlan) {
            node.pendingDeglow?.cancel()
            guard plan.glowOpacity > LyricsSpecs.glowOpacityRange.lowerBound else {
                node.pendingDeglow = nil
                return
            }
            let work = DispatchWorkItem { [weak node] in
                guard let node else { return }
                let deglowSpring = SpringTimingParameters(
                    mass: WordEmphasisPlan.deglowSpringMass,
                    stiffness: WordEmphasisPlan.deglowSpringStiffness,
                    damping: WordEmphasisPlan.deglowSpringDamping
                )
                let animator = LayerPropertyAnimator(layers: [node.wordLayer], timing: deglowSpring)
                animator.addChange {
                    node.wordLayer.shadowOpacity = LyricsSpecs.glowOpacityRange.lowerBound
                }
                animator.run()
            }
            node.pendingDeglow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + plan.deglowDelay, execute: work)
        }

        /// Put every glyph back at rest and the sweep back at the start,
        /// immediately, cancelling anything pending. Called when the line is
        /// recycled for a different lyric, or the playback time jumps.
        func resetEmphasis() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            resetGlyphEmphasis()
            resetSweep()
            CATransaction.commit()
        }

        /// The glyph half of `resetEmphasis()`, which is all a line that stops
        /// being the active one gives up at once: its sweep fades out instead.
        private func resetGlyphEmphasis() {
            if wordNodes.contains(where: { $0.isEmphasisScheduled }) {
                let emphasisWordCount = wordNodes.count
                let currentLineLabel = lineLabel
                #log(
                    .debug,
                    """
                    Emphasis reset line=\(currentLineLabel, privacy: .public) \
                    wordCount=\(emphasisWordCount, privacy: .public)
                    """
                )
                #signpost(.event, "EmphasisReset")
            }
            precedingElapsedTime = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for node in wordNodes {
                node.pendingGlyphReturns.forEach { $0.cancel() }
                node.pendingGlyphReturns = []
                node.pendingDeglow?.cancel()
                node.pendingDeglow = nil
                node.isEmphasisScheduled = false
                for index in node.syllableGroups.indices {
                    node.syllableGroups[index].isLifted = false
                }
                LayerPropertyAnimator.removeAllAnimations(from: node.wordLayer)
                node.wordLayer.shadowOpacity = LyricsSpecs.glowOpacityRange.lowerBound
                for (glyphIndex, glyphLayer) in node.glyphLayers.enumerated() {
                    glyphLayer.removeAllAnimations()
                    Self.place(glyphLayer, atRestingOrigin: node.restingOrigin(ofGlyphAt: glyphIndex))
                    glyphLayer.setAffineTransform(.identity)
                }
            }
            CATransaction.commit()
        }

        private func resetSweep() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for visualRowNode in visualRowNodes {
                let gradient = visualRowNode.progressGradientLayer
                gradient.position.x = textOutset.width + gradient.originX(forFillEdge: 0)
            }
            CATransaction.commit()
        }
    }
}
