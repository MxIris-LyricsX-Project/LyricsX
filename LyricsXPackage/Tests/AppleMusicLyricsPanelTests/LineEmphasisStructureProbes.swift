import AppKit
import LyricsXFoundation
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

private let generatedWrappedLyrics = [
    "没有获得授权时，不得翻唱、翻录、改编或通过任何方式公开使用这段作品。",
    "凌晨四点的风穿过空荡的站台，我仍然沿着灯光一步一步向前走。",
    "We kept walking into the headwind while every streetlight disappeared behind us.",
    "Bridge 之后的最后一句很长，Mmm, mmm, mmm 也必须严格按照视觉行从上到下推进。",
]

@MainActor
struct LineEmphasisStructureProbes {
    private static let copyrightLine = "（未经著作权人许可，不得翻唱翻录或使用。）"

    private static func makeLayout(
        text: String,
        timing: LyricsLine.Attachments.SynchronizedTextTiming,
        languageIdentifier: String = "en"
    ) -> AppleMusicLyrics.LineTextLayout? {
        let attributedString = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold)]
        )
        return AppleMusicLyrics.LineTextLayout.build(
            attributed: attributedString,
            content: text,
            wordTimings: [],
            synchronizedTextTiming: timing,
            languageIdentifier: languageIdentifier,
            lineDuration: timing.duration ?? 0,
            textWidth: 460
        )
    }

    private static func wordLayers(
        of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer
    ) -> [CALayer] {
        visualRowColorContainers(of: contentLayer).flatMap { visualRowColorContainer in
            (visualRowColorContainer.mask?.sublayers ?? []).compactMap(\.mask)
        }
    }

    private static func glyphLayers(
        of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer
    ) -> [CALayer] {
        wordLayers(of: contentLayer).flatMap { $0.sublayers ?? [] }
    }

    private static func visualRowColorContainers(
        of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer
    ) -> [CALayer] {
        (contentLayer.sublayers ?? []).filter { candidateLayer in
            (candidateLayer.sublayers ?? []).contains { sublayer in
                sublayer is AppleMusicLyrics.LineProgressGradientLayer
            }
        }
    }

    private static func generatedLayout(for text: String) -> AppleMusicLyrics.LineTextLayout? {
        let attributedString = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold)]
        )
        return AppleMusicLyrics.LineTextLayout.build(
            attributed: attributedString,
            content: text,
            wordTimings: [],
            lineDuration: 4,
            textWidth: 360
        )
    }

    @Test func glowLivesOnRasterizedWordLayersAndResetRemovesIt() throws {
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: [.init(characterRange: 0 ..< 5, timeRange: 0 ..< 2)],
            duration: 2
        )
        let layout = try #require(Self.makeLayout(text: "Hello", timing: timing))
        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)

        let wordLayers = Self.wordLayers(of: contentLayer)
        let glyphLayers = Self.glyphLayers(of: contentLayer)
        #expect(!wordLayers.isEmpty)
        #expect(wordLayers.allSatisfy { $0.shouldRasterize })
        #expect(wordLayers.allSatisfy { $0.rasterizationScale == 2 })
        #expect(wordLayers.allSatisfy { $0.shadowRadius == AppleMusicLyrics.LyricsSpecs.glowRadius })
        #expect(glyphLayers.allSatisfy { $0.shadowColor == nil && $0.shadowOpacity == 0 })

        contentLayer.update(elapsedTime: 0, fillFraction: 0)
        let firstWordLayer = try #require(wordLayers.first)
        #expect(firstWordLayer.shadowOpacity == AppleMusicLyrics.LyricsSpecs.glowOpacityRange.upperBound)
        #expect(firstWordLayer.animation(forKey: "AppleMusicLyrics.shadowOpacity") is CASpringAnimation)

        contentLayer.resetEmphasis()
        #expect(firstWordLayer.shadowOpacity == AppleMusicLyrics.LyricsSpecs.glowOpacityRange.lowerBound)
        #expect(firstWordLayer.animation(forKey: "AppleMusicLyrics.shadowOpacity") == nil)
        #expect(glyphLayers.allSatisfy { $0.animationKeys()?.isEmpty != false })
    }

    /// Chinese structured lyrics are where the two policies differ most: under
    /// Apple Music's gate a `zh` word is `.none` — its syllable lifts on the soft
    /// spring and nothing swells — while the full-emphasis look swells and
    /// glows exactly like an inline-tag word, on the word-length spring.
    @Test(arguments: [
        (AppleMusicLyrics.StructuredEmphasisPolicy.appleMusic26, Float(0), AppleMusicLyrics.SyllableLiftPlan.springStiffness),
        (AppleMusicLyrics.StructuredEmphasisPolicy.fullEmphasis, Float(0.4), AppleMusicLyrics.SpringTimingParameters(dampingRatio: 1, period: 0.5).stiffness),
    ])
    func structuredChineseWordGlowsOnlyUnderTheFullEmphasisPolicy(
        policy: AppleMusicLyrics.StructuredEmphasisPolicy,
        expectedGlowOpacity: Float,
        expectedLiftStiffness: CGFloat
    ) throws {
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: [.init(characterRange: 0 ..< 2, timeRange: 0 ..< 0.5)],
            duration: 0.5
        )
        let layout = try #require(Self.makeLayout(text: "风走", timing: timing, languageIdentifier: "zh-Hans"))
        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.structuredEmphasisPolicyProvider = { policy }
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)

        contentLayer.update(elapsedTime: 0, fillFraction: 0)

        let wordLayer = try #require(Self.wordLayers(of: contentLayer).first)
        #expect(wordLayer.shadowOpacity == expectedGlowOpacity)
        #expect((wordLayer.animation(forKey: "AppleMusicLyrics.shadowOpacity") != nil) == (expectedGlowOpacity > 0))
        let liftSprings = Self.glyphLayers(of: contentLayer).map { glyphLayer in
            glyphLayer.animation(forKey: "AppleMusicLyrics.position") as? CASpringAnimation
        }
        #expect(liftSprings.allSatisfy { $0 != nil }, "the lift is scheduled under both policies")
        #expect(
            liftSprings.allSatisfy { spring in abs((spring?.stiffness ?? 0) - expectedLiftStiffness) < 0.001 },
            "the lift must ride the spring the policy implies: \(liftSprings.map { $0?.stiffness ?? 0 }) vs \(expectedLiftStiffness)"
        )
    }

    @Test func seekWithinTheSelectedLineResynchronizesTheActiveWord() throws {
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: [
                .init(characterRange: 0 ..< 5, timeRange: 0 ..< 2),
                .init(characterRange: 5 ..< 10, timeRange: 2 ..< 4),
            ],
            duration: 4
        )
        let layout = try #require(Self.makeLayout(text: "HelloWorld", timing: timing))
        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)
        let wordLayers = Self.wordLayers(of: contentLayer)
        #expect(wordLayers.count == 2)

        contentLayer.update(elapsedTime: 2.5, fillFraction: 0.625)
        #expect(wordLayers[0].animation(forKey: "AppleMusicLyrics.shadowOpacity") == nil)
        #expect(wordLayers[1].animation(forKey: "AppleMusicLyrics.shadowOpacity") is CASpringAnimation)

        contentLayer.update(elapsedTime: 0.5, fillFraction: 0.125)
        #expect(wordLayers[0].animation(forKey: "AppleMusicLyrics.shadowOpacity") is CASpringAnimation)
        #expect(wordLayers[1].animation(forKey: "AppleMusicLyrics.shadowOpacity") == nil)
    }

    @Test func wrappedRowsRemainInLogicalTopToBottomOrderInsideTheLineView() throws {
        let mainFontSize: CGFloat = 48
        let rowWidth: CGFloat = 620
        let attributedString = NSAttributedString(
            string: Self.copyrightLine,
            attributes: [.font: NSFont.systemFont(ofSize: mainFontSize, weight: .bold)]
        )
        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: attributedString,
            content: Self.copyrightLine,
            wordTimings: [],
            lineDuration: 4,
            textWidth: rowWidth - 48
        ))
        #expect(layout.visualLines.count == 2)
        let firstVisualRowMinimumVerticalPosition = try #require(
            layout.words.filter { $0.visualLineIndex == 0 }.map(\.frame.minY).min()
        )
        let secondVisualRowMinimumVerticalPosition = try #require(
            layout.words.filter { $0.visualLineIndex == 1 }.map(\.frame.minY).min()
        )
        #expect(firstVisualRowMinimumVerticalPosition < secondVisualRowMinimumVerticalPosition)

        let lyrics = try #require(Lyrics("[00:00.000]\(Self.copyrightLine)"))
        let lineView = AppleMusicLyrics.SyncedLyricsLineView(
            frame: NSRect(x: 0, y: 0, width: rowWidth, height: 300)
        )
        let line = try #require(lyrics.lines.first)
        try lineView.configure(
            line: line,
            translation: line.attachments.translation(),
            originalIndex: 0,
            enabledPosition: 0,
            mainFontSize: mainFontSize,
            translationFontSize: 18
        )
        lineView.frame.size.height = lineView.preferredHeight(forWidth: rowWidth)
        // AppKit decides the hosted content layer's orientation at commit time,
        // so the row has to live in a window and the transaction has to land
        // before the orientation means anything.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: rowWidth, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        try #require(window.contentView).addSubview(lineView)
        lineView.layoutSubtreeIfNeeded()
        CATransaction.flush()

        // The content layer is the layer of a hosting subview, so reach it
        // through the view rather than through the row's own sublayer list.
        let contentLayer = try #require(
            lineView.subviews.compactMap {
                $0.layer as? AppleMusicLyrics.SyncedLyricsLineContentLayer
            }.first
        )
        #expect(
            contentLayer.contentsAreFlipped(),
            "the content layer must be effectively y-down, the space LineTextLayout produces its frames in"
        )
        let visualRowColorContainers = Self.visualRowColorContainers(of: contentLayer)
        #expect(visualRowColorContainers.count == layout.visualLines.count)
        #expect(visualRowColorContainers.allSatisfy { visualRowColorContainer in
            visualRowColorContainer.isGeometryFlipped
        })
        #expect(visualRowColorContainers.allSatisfy { visualRowColorContainer in
            visualRowColorContainer.mask?.isGeometryFlipped == true
        }, "each mask container that positions wrapped words must use the same y-down coordinates")
    }

    @Test(arguments: generatedWrappedLyrics)
    func wrappedRowsUseIndependentSungColorContainers(text: String) throws {
        let layout = try #require(Self.generatedLayout(for: text))
        #expect(layout.visualLines.count >= 2)

        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)

        let visualRowColorContainers = Self.visualRowColorContainers(of: contentLayer)
        #expect(
            visualRowColorContainers.count == layout.visualLines.count,
            "each wrapped visual row needs its own masked color container so one row cannot illuminate another"
        )

        for (visualRowIndex, visualRowColorContainer) in visualRowColorContainers.enumerated() {
            let visualRowMask = try #require(visualRowColorContainer.mask)
            let expectedWordCount = layout.words.count { word in
                word.visualLineIndex == visualRowIndex
            }
            #expect(visualRowMask.sublayers?.count == expectedWordCount)

            let progressGradient = try #require(
                visualRowColorContainer.sublayers?.first { sublayer in
                    sublayer is AppleMusicLyrics.LineProgressGradientLayer
                } as? AppleMusicLyrics.LineProgressGradientLayer
            )
            let typographicFrame = layout.visualLines[visualRowIndex].typographicFrame
            #expect(
                visualRowColorContainer.frame.minY + progressGradient.position.y
                    == contentLayer.textOutset.height + typographicFrame.minY - progressGradient.verticalPadding
            )
            #expect(
                visualRowColorContainer.frame.minX + progressGradient.position.x
                    == contentLayer.textOutset.width + typographicFrame.minX
                    + progressGradient.originX(forFillEdge: 0)
            )
            #expect(
                progressGradient.bounds.height
                    == typographicFrame.height + progressGradient.verticalPadding * 2
            )
            #expect(
                visualRowColorContainer.frame.height
                    == typographicFrame.height + contentLayer.textOutset.height * 2
            )
        }

        let firstProgressGradient = try #require(
            visualRowColorContainers[0].sublayers?.first { sublayer in
                sublayer is AppleMusicLyrics.LineProgressGradientLayer
            } as? AppleMusicLyrics.LineProgressGradientLayer
        )
        let secondProgressGradient = try #require(
            visualRowColorContainers[1].sublayers?.first { sublayer in
                sublayer is AppleMusicLyrics.LineProgressGradientLayer
            } as? AppleMusicLyrics.LineProgressGradientLayer
        )
        let initialFirstGradientPosition = firstProgressGradient.position.x
        let initialSecondGradientPosition = secondProgressGradient.position.x
        let firstVisualRowWidth = layout.visualLines[0].typographicFrame.width
        let secondVisualRowWidth = layout.visualLines[1].typographicFrame.width

        contentLayer.update(
            elapsedTime: 1,
            fillFraction: firstVisualRowWidth * 0.5 / layout.totalTextWidth
        )
        #expect(firstProgressGradient.position.x > initialFirstGradientPosition)
        #expect(secondProgressGradient.position.x == initialSecondGradientPosition)

        contentLayer.update(
            elapsedTime: 2,
            fillFraction: (firstVisualRowWidth + secondVisualRowWidth * 0.25) / layout.totalTextWidth
        )
        #expect(secondProgressGradient.position.x > initialSecondGradientPosition)
    }
}
