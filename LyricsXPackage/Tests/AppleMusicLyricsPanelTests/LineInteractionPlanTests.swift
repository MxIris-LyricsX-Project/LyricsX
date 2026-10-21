import AppKit
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

/// What a line hands Core Animation when it is pressed (`sub_10019D630`),
/// hovered (`sub_10019EEDC`), selected or deselected (`sub_10016D164`), and how
/// its translation is styled (`sub_10017A270`, `sub_10017A8D0`) — all read from
/// Music 26.6. The selection switch runs on a real content layer. Nothing here
/// opens a window; `LineInteractionProbes` drives the same paths through a
/// mounted row.
struct LineInteractionPlanTests {
    private typealias LyricsSpecs = AppleMusicLyrics.LyricsSpecs

    // MARK: Values

    @Test func pressRunsMusicsCurvesAndSpringsAndReleasesLate() {
        let pressOpacityTiming = AppleMusicLyrics.LinePressPlan.pressOpacityTiming
        #expect(pressOpacityTiming.duration == 0.2)
        #expect(pressOpacityTiming.controlPoint1 == CGPoint(x: 0, y: 0))
        #expect(pressOpacityTiming.controlPoint2 == CGPoint(x: 0.55, y: 1))

        let releaseOpacityTiming = AppleMusicLyrics.LinePressPlan.releaseOpacityTiming
        #expect(releaseOpacityTiming.duration == 0.3)
        #expect(releaseOpacityTiming.controlPoint1 == CGPoint(x: 0.25, y: 0.1))
        #expect(releaseOpacityTiming.controlPoint2 == CGPoint(x: 0.25, y: 0.1))

        let pressTransformTiming = AppleMusicLyrics.LinePressPlan.pressTransformTiming
        #expect(pressTransformTiming.mass == 1)
        #expect(pressTransformTiming.stiffness == 322)
        #expect(pressTransformTiming.damping == 24)

        let releaseTransformTiming = AppleMusicLyrics.LinePressPlan.releaseTransformTiming
        #expect(releaseTransformTiming.mass == 2)
        #expect(releaseTransformTiming.stiffness == 300)
        #expect(releaseTransformTiming.damping == 50)

        #expect(AppleMusicLyrics.LinePressPlan.releaseDelay == 0.1)
    }

    @Test func pressedLookUsesTheNowPlayingSpecs() {
        #expect(LyricsSpecs.touchDownTransform == CGAffineTransform(scaleX: 0.95, y: 0.95))
        #expect(LyricsSpecs.highlightLabelOpacity == 0.85)
        #expect(LyricsSpecs.highlightViewBackgroundColor == CGColor(gray: 1, alpha: 0.08))
        #expect(LyricsSpecs.highlightViewCornerRadius == 16)
        #expect(LyricsSpecs.highlightViewMargin == 16)
        #expect(LyricsSpecs.focusedLineBrightnessAmount == 1, "the Now Playing window's focus style is `.bright`")
    }

    @Test func linesAreToldApartByTextColourOnTheLineChangeSpring() {
        #expect(LyricsSpecs.selectedUpcomingTextOpacity == 0.5)
        #expect(LyricsSpecs.deselectedTextOpacity == 0.4)
        let timing = AppleMusicLyrics.LineSelectionPlan.springTiming
        #expect(timing.mass == 1)
        #expect(timing.stiffness == 100)
        #expect(timing.damping == 18)
    }

    @Test func filterCurveIsAFixedDurationCubic() throws {
        let animation = LyricsSpecs.lineFilterTiming.makePropertyAnimation(keyPath: "opacity")
        #expect(!(animation is CASpringAnimation))
        #expect(abs(animation.duration - 0.12) < 0.000_001)
        let timingFunction = try #require(animation.timingFunction)
        var firstControlPoint = [Float](repeating: 0, count: 2)
        var secondControlPoint = [Float](repeating: 0, count: 2)
        timingFunction.getControlPoint(at: 1, values: &firstControlPoint)
        timingFunction.getControlPoint(at: 2, values: &secondControlPoint)
        #expect(abs(firstControlPoint[0] - 0.33) < 0.001)
        #expect(abs(firstControlPoint[1] - 0) < 0.001)
        #expect(abs(secondControlPoint[0] - 0.2) < 0.001)
        #expect(abs(secondControlPoint[1] - 0.1) < 0.001)
    }

    @Test func deselectedLineOpacityVariantDefaultsToMusic26() throws {
        typealias Variant = AppleMusicLyrics.DeselectedLineOpacityVariant
        let suiteName = "LineInteractionPlanTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        #expect(Variant.resolve(from: userDefaults) == .appleMusic26)
        #expect(Variant.appleMusic26.textOpacity == 0.4)
        userDefaults.set(Variant.legacyRecording.rawValue, forKey: Variant.userDefaultsKey)
        #expect(Variant.resolve(from: userDefaults) == .legacyRecording)
        #expect(Variant.legacyRecording.textOpacity == 0.55)
        userDefaults.set("unknown", forKey: Variant.userDefaultsKey)
        #expect(Variant.resolve(from: userDefaults) == .appleMusic26)
    }

    // MARK: Translation

    @Test(arguments: [
        ("hello world", "Hello World"),
        ("高中三年", "高中三年"),
        ("ÉTÉ", "été"),
    ])
    func translationThatRepeatsTheLineIsLeftOut(translation: String, lineContent: String) {
        #expect(!AppleMusicLyrics.SyncedLyricsLineView.shouldDisplayTranslation(translation, forLineContent: lineContent))
    }

    @Test func translationThatSaysSomethingElseIsShown() {
        #expect(AppleMusicLyrics.SyncedLyricsLineView.shouldDisplayTranslation(
            "高中三年 我为什么",
            forLineContent: "高中三年 我為什麼"
        ))
    }

    // MARK: Selection on the content layer

    private struct VisualRow {
        let backgroundColorLayer: CALayer
        let progressGradientLayer: AppleMusicLyrics.LineProgressGradientLayer
    }

    private static func makeContentLayer(highlighted: Bool) throws -> AppleMusicLyrics.SyncedLyricsLineContentLayer {
        let text = "Walking into the headwind while every streetlight disappears behind us"
        let attributedString = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold)]
        )
        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: attributedString,
            content: text,
            wordTimings: [],
            lineDuration: 4,
            textWidth: 360
        ))
        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.isHighlighted = highlighted
        contentLayer.rebuild(with: layout, contentsScale: 2)
        try #require(layout.visualLines.count >= 2, "the fixture must wrap, so every visual row is covered")
        return contentLayer
    }

    private static func visualRows(of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer) throws -> [VisualRow] {
        let visualRowColorContainers = (contentLayer.sublayers ?? []).filter { candidateLayer in
            (candidateLayer.sublayers ?? []).contains { $0 is AppleMusicLyrics.LineProgressGradientLayer }
        }
        return try visualRowColorContainers.map { visualRowColorContainer in
            let sublayers = visualRowColorContainer.sublayers ?? []
            return try VisualRow(
                backgroundColorLayer: #require(sublayers.first { !($0 is AppleMusicLyrics.LineProgressGradientLayer) }),
                progressGradientLayer: #require(sublayers.compactMap { $0 as? AppleMusicLyrics.LineProgressGradientLayer }.first)
            )
        }
    }

    /// An animation's `fromValue` / `toValue` as a colour. Core Foundation
    /// types cannot be checked with `as?`, so compare the type ID first.
    private static func color(_ value: Any?) throws -> CGColor {
        let object = try #require(value) as AnyObject
        try #require(CFGetTypeID(object) == CGColor.typeID, "expected a CGColor, got \(object)")
        return unsafeDowncast(object, to: CGColor.self)
    }

    private static func expectSelectionSpring(_ animation: CAAnimation?, keyPath: String) throws -> CASpringAnimation {
        let spring = try #require(animation as? CASpringAnimation, "\(keyPath) must move on a spring")
        #expect(spring.keyPath == keyPath)
        #expect(spring.mass == 1)
        #expect(spring.stiffness == 100)
        #expect(spring.damping == 18)
        return spring
    }

    @Test func deselectingFadesTheSungPartOutWhereItWas() throws {
        let contentLayer = try Self.makeContentLayer(highlighted: true)
        contentLayer.update(elapsedTime: 1, fillFraction: 0.5)
        let rows = try Self.visualRows(of: contentLayer)
        let sweptPositions = rows.map(\.progressGradientLayer.position)

        contentLayer.setHighlighted(false, animatedWith: AppleMusicLyrics.LineSelectionPlan.springTiming)

        #expect(!contentLayer.isHighlighted)
        for (rowIndex, row) in rows.enumerated() {
            #expect(row.backgroundColorLayer.backgroundColor == CGColor(gray: 1, alpha: 0.4))
            let colourSpring = try Self.expectSelectionSpring(
                row.backgroundColorLayer.animation(forKey: "AppleMusicLyrics.backgroundColor"),
                keyPath: "backgroundColor"
            )
            #expect(try Self.color(colourSpring.fromValue) == CGColor(gray: 1, alpha: 0.5))
            #expect(try Self.color(colourSpring.toValue) == CGColor(gray: 1, alpha: 0.4))

            #expect(row.progressGradientLayer.opacity == 0)
            let fadeSpring = try Self.expectSelectionSpring(
                row.progressGradientLayer.animation(forKey: "AppleMusicLyrics.opacity"),
                keyPath: "opacity"
            )
            #expect(fadeSpring.fromValue as? Float == 1)
            #expect(fadeSpring.toValue as? Float == 0)

            #expect(
                row.progressGradientLayer.position == sweptPositions[rowIndex],
                "the sweep must stay put while it fades, or nothing sung is left to fade"
            )
            #expect(row.progressGradientLayer.animation(forKey: "AppleMusicLyrics.position") == nil)
        }
    }

    @Test func selectingStartsFromAnEmptySweep() throws {
        let contentLayer = try Self.makeContentLayer(highlighted: true)
        let rows = try Self.visualRows(of: contentLayer)
        let emptySweepPositions = rows.map(\.progressGradientLayer.position)
        contentLayer.update(elapsedTime: 1, fillFraction: 0.75)
        contentLayer.isHighlighted = false
        #expect(
            rows[0].progressGradientLayer.position != emptySweepPositions[0],
            "the fixture must have swept before it was deselected, or the reset proves nothing"
        )

        contentLayer.setHighlighted(true, animatedWith: AppleMusicLyrics.LineSelectionPlan.springTiming)

        for (rowIndex, row) in rows.enumerated() {
            #expect(row.progressGradientLayer.position == emptySweepPositions[rowIndex])
            #expect(row.progressGradientLayer.opacity == 1)
            let fadeSpring = try Self.expectSelectionSpring(
                row.progressGradientLayer.animation(forKey: "AppleMusicLyrics.opacity"),
                keyPath: "opacity"
            )
            #expect(fadeSpring.fromValue as? Float == 0)
            #expect(row.backgroundColorLayer.backgroundColor == CGColor(gray: 1, alpha: 0.5))
            let colourSpring = try Self.expectSelectionSpring(
                row.backgroundColorLayer.animation(forKey: "AppleMusicLyrics.backgroundColor"),
                keyPath: "backgroundColor"
            )
            #expect(try Self.color(colourSpring.fromValue) == CGColor(gray: 1, alpha: 0.4))
        }
    }

    @Test func assigningTheSelectionSwitchesAtOnce() throws {
        let contentLayer = try Self.makeContentLayer(highlighted: false)
        let rows = try Self.visualRows(of: contentLayer)
        for row in rows {
            #expect(row.backgroundColorLayer.backgroundColor == CGColor(gray: 1, alpha: 0.4))
            #expect(row.progressGradientLayer.opacity == 0)
        }

        contentLayer.isHighlighted = true
        for row in rows {
            #expect(row.backgroundColorLayer.backgroundColor == CGColor(gray: 1, alpha: 0.5))
            #expect(row.progressGradientLayer.opacity == 1)
            #expect(row.backgroundColorLayer.animationKeys() == nil)
            #expect(row.progressGradientLayer.animationKeys() == nil)
        }
    }

    @Test func deselectedColourFollowsTheVariant() throws {
        let contentLayer = try Self.makeContentLayer(highlighted: false)
        contentLayer.deselectedColor = CGColor(gray: 1, alpha: 0.55)
        for row in try Self.visualRows(of: contentLayer) {
            #expect(row.backgroundColorLayer.backgroundColor == CGColor(gray: 1, alpha: 0.55))
        }
    }
}
