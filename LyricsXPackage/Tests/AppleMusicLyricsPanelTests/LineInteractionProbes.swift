import AppKit
import LyricsXFoundation
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

/// A real row mounted in a window and driven through the events AppKit would
/// deliver — the pointer entering and leaving, the button going down, a drag
/// out and back, the button coming up — and through becoming, then ceasing to
/// be, the selected line. Checks the tree Music's `SyncedLyricsLineLayer`
/// builds and what it hands Core Animation along the way (`sub_10019D630`,
/// `sub_10019EEDC`, `sub_10016D164`, `sub_10017A270`). Opens windows.
@Suite(.serialized)
@MainActor
struct LineInteractionProbes {
    private typealias LyricsSpecs = AppleMusicLyrics.LyricsSpecs

    private nonisolated static let lyricsSource = """
    [00:00.000]I told you I changed, even when I knew I never could
    [00:00.000][tr:zh-Hans]我说过我变了，即使我知道我永远做不到
    [00:05.000]next line
    """

    private static let blurKeyPath = "filters.gaussianBlur.inputRadius"
    private static let brightnessKeyPath = "filters.colorBrightness.inputAmount"

    @MainActor
    private struct MountedRow {
        let window: NSWindow
        let rowView: AppleMusicLyrics.SyncedLyricsLineView
        let rowLayer: CALayer
        let containerLayer: CALayer
        let hostedRootLayer: CALayer
        let translationLayer: AppleMusicLyrics.LineTranslationLayer

        var contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer {
            rowView.contentLayer
        }

        var rowCenter: NSPoint {
            NSPoint(x: rowView.bounds.midX, y: rowView.bounds.midY)
        }
    }

    private static func mountRow(source: String = lyricsSource) throws -> MountedRow {
        let lyrics = try #require(Lyrics(source))
        let line = try #require(lyrics.lines.first)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let hostView = try #require(window.contentView)
        hostView.wantsLayer = true
        let rowView = AppleMusicLyrics.SyncedLyricsLineView(frame: NSRect(x: 0, y: 0, width: 520, height: 100))
        rowView.configure(
            line: line,
            translation: line.attachments.translation(),
            originalIndex: 0,
            enabledPosition: 0,
            mainFontSize: 30,
            translationFontSize: 17
        )
        hostView.addSubview(rowView)
        rowView.frame = NSRect(x: 0, y: 40, width: 520, height: rowView.preferredHeight(forWidth: 520))
        rowView.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let containerLayer = try #require(rowView.contentLayer.superlayer)
        let hostedRootLayer = try #require(containerLayer.superlayer)
        return try MountedRow(
            window: window,
            rowView: rowView,
            rowLayer: #require(rowView.layer),
            containerLayer: containerLayer,
            hostedRootLayer: hostedRootLayer,
            translationLayer: #require(
                containerLayer.sublayers?.compactMap { $0 as? AppleMusicLyrics.LineTranslationLayer }.first
            )
        )
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType,
        at pointInRow: NSPoint,
        of mountedRow: MountedRow
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: mountedRow.rowView.convert(pointInRow, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: mountedRow.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    private static func pointerEvent(_ type: NSEvent.EventType, of mountedRow: MountedRow) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(
            with: type,
            location: mountedRow.rowView.convert(mountedRow.rowCenter, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: mountedRow.window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
    }

    private static func filterValue(_ keyPath: String, on layer: CALayer) -> Double? {
        (layer.value(forKeyPath: keyPath) as? NSNumber)?.doubleValue
    }

    private static func controlPoints(of animation: CAAnimation) throws -> [Float] {
        let timingFunction = try #require(animation.timingFunction)
        var firstControlPoint = [Float](repeating: 0, count: 2)
        var secondControlPoint = [Float](repeating: 0, count: 2)
        timingFunction.getControlPoint(at: 1, values: &firstControlPoint)
        timingFunction.getControlPoint(at: 2, values: &secondControlPoint)
        return firstControlPoint + secondControlPoint
    }

    private static func expectCurve(
        _ animation: CAAnimation?,
        duration: TimeInterval,
        controlPoints expectedControlPoints: [Float]
    ) throws {
        let curve = try #require(animation as? CABasicAnimation)
        #expect(!(curve is CASpringAnimation), "\(curve.keyPath ?? "?") must run on Music's cubic curve, not a spring")
        #expect(abs(curve.duration - duration) < 0.000_001)
        let actualControlPoints = try controlPoints(of: curve)
        for (actual, expected) in zip(actualControlPoints, expectedControlPoints) {
            #expect(abs(actual - expected) < 0.001, "control points \(actualControlPoints)")
        }
    }

    private static func expectSpring(
        _ animation: CAAnimation?,
        mass: CGFloat,
        stiffness: CGFloat,
        damping: CGFloat
    ) throws {
        let spring = try #require(animation as? CASpringAnimation)
        #expect(spring.mass == mass)
        #expect(spring.stiffness == stiffness)
        #expect(spring.damping == damping)
    }

    private static func unsungColors(of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer) -> [CGColor] {
        (contentLayer.sublayers ?? []).compactMap { visualRowColorContainer -> CGColor? in
            let sublayers = visualRowColorContainer.sublayers ?? []
            guard sublayers.contains(where: { $0 is AppleMusicLyrics.LineProgressGradientLayer }) else { return nil }
            return sublayers.first { !($0 is AppleMusicLyrics.LineProgressGradientLayer) }?.backgroundColor
        }
    }

    // MARK: Structure

    @Test func lineIsBuiltLikeMusicsLineLayer() throws {
        let mountedRow = try Self.mountRow()
        let contentLayer = mountedRow.contentLayer
        let containerLayer = mountedRow.containerLayer

        #expect(mountedRow.hostedRootLayer.superlayer === mountedRow.rowLayer)
        #expect(mountedRow.hostedRootLayer.sublayers?.count == 1, "the pressed highlight is built on the first press")
        #expect(containerLayer.sublayers?.first === contentLayer)
        #expect(containerLayer.sublayers?.last === mountedRow.translationLayer)
        #expect(contentLayer.contentsAreFlipped(), "the main text needs the y-down space LineTextLayout lays it out in")

        // The container is Music's line frame: the text column, from the
        // row's top padding down past the translation.
        let mainTextHeight = contentLayer.bounds.height - contentLayer.textOutset.height * 2
        #expect(containerLayer.frame.minX == 24)
        #expect(abs(containerLayer.frame.minY - mountedRow.rowView.verticalPadding) < 0.001)
        #expect(containerLayer.bounds.width == mountedRow.rowView.bounds.width - 48)
        #expect(abs(mountedRow.translationLayer.frame.minY - (mainTextHeight + 7)) < 0.001)
        #expect(abs(containerLayer.bounds.height - mountedRow.translationLayer.frame.maxY) < 0.001)

        let translationFont = try #require(
            mountedRow.translationLayer.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        #expect(translationFont == NSFont.systemFont(ofSize: 17, weight: .bold))

        #expect(mountedRow.rowView.alphaValue == 1, "lines are dimmed by their text colour, never as a whole")
        let unsungColors = Self.unsungColors(of: contentLayer)
        #expect(!unsungColors.isEmpty)
        #expect(unsungColors.allSatisfy { $0 == CGColor(gray: 1, alpha: 0.4) })
        #expect(mountedRow.translationLayer.opacity == 0.4)
    }

    @Test func translationThatRepeatsTheLineIsLeftOut() throws {
        let repeated = try Self.mountRow(source: """
        [00:00.000]Hello World
        [00:00.000][tr:en]hello world
        """)
        let bare = try Self.mountRow(source: "[00:00.000]Hello World")
        #expect(repeated.translationLayer.isHidden)
        #expect(repeated.rowView.frame.height == bare.rowView.frame.height)
    }

    // MARK: Hover

    @Test func hoverClearsTheBlurAndBrightensAtOnce() throws {
        let mountedRow = try Self.mountRow()
        let rowView = mountedRow.rowView
        let rowLayer = mountedRow.rowLayer
        rowView.setLineBlurRadius(LyricsSpecs.deselectedLineBlurRadius, animated: false)
        let restingRadius = Double(LyricsSpecs.deselectedLineBlurRadius * LyricsSpecs.renderedBlurRadiusScale)
        #expect(Self.filterValue(Self.blurKeyPath, on: rowLayer) == restingRadius)

        try rowView.mouseEntered(with: Self.pointerEvent(.mouseEntered, of: mountedRow))
        #expect(Self.filterValue(Self.blurKeyPath, on: rowLayer) == 0)
        #expect(Self.filterValue(Self.brightnessKeyPath, on: rowLayer) == 1)
        #expect(rowLayer.animation(forKey: Self.blurKeyPath) == nil, "mouseEntered: passes animated: false")
        #expect(rowLayer.animation(forKey: Self.brightnessKeyPath) == nil)
        let filterNames = (rowLayer.filters ?? []).compactMap { ($0 as? NSObject)?.value(forKey: "name") as? String }
        #expect(filterNames == ["gaussianBlur", "colorBrightness"])
        #expect(rowLayer.shouldRasterize)

        try rowView.mouseExited(with: Self.pointerEvent(.mouseExited, of: mountedRow))
        #expect(Self.filterValue(Self.blurKeyPath, on: rowLayer) == restingRadius)
        #expect(Self.filterValue(Self.brightnessKeyPath, on: rowLayer) == 0)
        #expect(rowLayer.animation(forKey: Self.blurKeyPath) == nil)
        #expect(rowLayer.animation(forKey: Self.brightnessKeyPath) == nil)
    }

    @Test func selectedLineIsNeverFocused() throws {
        let mountedRow = try Self.mountRow()
        mountedRow.rowView.setHighlighted(true)
        try mountedRow.rowView.mouseEntered(with: Self.pointerEvent(.mouseEntered, of: mountedRow))
        #expect((Self.filterValue(Self.brightnessKeyPath, on: mountedRow.rowLayer) ?? 0) == 0)
    }

    @Test func hoveredLineThatBecomesSelectedGivesTheBrightnessUpOnTheFilterCurve() async throws {
        let mountedRow = try Self.mountRow()
        let rowLayer = mountedRow.rowLayer
        try mountedRow.rowView.mouseEntered(with: Self.pointerEvent(.mouseEntered, of: mountedRow))
        CATransaction.flush()

        mountedRow.rowView.setHighlighted(true, animated: true)

        #expect(Self.filterValue(Self.brightnessKeyPath, on: rowLayer) == 0)
        try Self.expectCurve(
            rowLayer.animation(forKey: Self.brightnessKeyPath),
            duration: 0.12,
            controlPoints: [0.33, 0, 0.2, 0.1]
        )
        #expect(!rowLayer.shouldRasterize, "the bitmap would freeze one intermediate brightness")
        try await Task.sleep(seconds: 0.18)
        #expect(rowLayer.shouldRasterize)
    }

    // MARK: Press

    @Test func pressShrinksAndDimsTheLineOnMusicsTimings() throws {
        let mountedRow = try Self.mountRow()
        let containerLayer = mountedRow.containerLayer
        mountedRow.rowView.setLineBlurRadius(LyricsSpecs.deselectedLineBlurRadius, animated: false)
        CATransaction.flush()

        try mountedRow.rowView.mouseDown(with: Self.mouseEvent(.leftMouseDown, at: mountedRow.rowCenter, of: mountedRow))

        #expect(mountedRow.rowView.isPressed)
        let backgroundLayer = try #require(mountedRow.hostedRootLayer.sublayers?.first)
        #expect(backgroundLayer !== containerLayer, "the highlight goes in at the back")
        #expect(backgroundLayer.backgroundColor == CGColor(gray: 1, alpha: 0.08))
        #expect(backgroundLayer.cornerRadius == 16)
        #expect(backgroundLayer.cornerCurve == .continuous)
        #expect(backgroundLayer.bounds.width == containerLayer.bounds.width + 32)
        #expect(backgroundLayer.bounds.height == containerLayer.bounds.height + 32)
        #expect(backgroundLayer.position == containerLayer.position)

        #expect(backgroundLayer.opacity == 1)
        #expect(containerLayer.opacity == 0.85)
        for layer in [backgroundLayer, containerLayer] {
            // Both animators touch both layers in one turn; each must keep its
            // own property rather than take the other's over.
            try Self.expectCurve(
                layer.animation(forKey: "AppleMusicLyrics.opacity"),
                duration: 0.2,
                controlPoints: [0, 0, 0.55, 1]
            )
            #expect(layer.affineTransform() == CGAffineTransform(scaleX: 0.95, y: 0.95))
            try Self.expectSpring(layer.animation(forKey: "AppleMusicLyrics.transform"), mass: 1, stiffness: 322, damping: 24)
            let beginTime = try #require(layer.animation(forKey: "AppleMusicLyrics.transform")).beginTime
            #expect(beginTime <= CACurrentMediaTime() + 0.01, "pressing starts at once")
        }

        #expect(Self.filterValue(Self.blurKeyPath, on: mountedRow.rowLayer) == 0)
        try Self.expectCurve(
            mountedRow.rowLayer.animation(forKey: Self.blurKeyPath),
            duration: 0.12,
            controlPoints: [0.33, 0, 0.2, 0.1]
        )
    }

    @Test func releaseRunsBackAfterAMomentAndTaps() throws {
        let mountedRow = try Self.mountRow()
        var tappedLines: [String] = []
        mountedRow.rowView.onTap = { tappedLines.append($0.content) }
        try mountedRow.rowView.mouseDown(with: Self.mouseEvent(.leftMouseDown, at: mountedRow.rowCenter, of: mountedRow))
        CATransaction.flush()

        try mountedRow.rowView.mouseUp(with: Self.mouseEvent(.leftMouseUp, at: mountedRow.rowCenter, of: mountedRow))

        #expect(tappedLines.count == 1)
        #expect(!mountedRow.rowView.isPressed)
        let backgroundLayer = try #require(mountedRow.hostedRootLayer.sublayers?.first)
        #expect(backgroundLayer.opacity == 0)
        #expect(mountedRow.containerLayer.opacity == 1)
        for layer in [backgroundLayer, mountedRow.containerLayer] {
            #expect(layer.affineTransform() == .identity)
            let fade = try #require(layer.animation(forKey: "AppleMusicLyrics.opacity"))
            try Self.expectCurve(fade, duration: 0.3, controlPoints: [0.25, 0.1, 0.25, 0.1])
            let spring = try #require(layer.animation(forKey: "AppleMusicLyrics.transform"))
            try Self.expectSpring(spring, mass: 2, stiffness: 300, damping: 50)
            for animation in [fade, spring] {
                let delay = animation.beginTime - CACurrentMediaTime()
                #expect(delay > 0.05 && delay <= 0.1, "released lines hold the pressed look for 0.1 s, got \(delay)")
            }
        }
    }

    @Test func draggingOutWithdrawsThePressAndReleasingOutsideDoesNotTap() throws {
        let mountedRow = try Self.mountRow()
        let rowView = mountedRow.rowView
        var tapCount = 0
        rowView.onTap = { _ in tapCount += 1 }
        let outside = NSPoint(x: rowView.bounds.midX, y: -20)

        try rowView.mouseDown(with: Self.mouseEvent(.leftMouseDown, at: mountedRow.rowCenter, of: mountedRow))
        try rowView.mouseDragged(with: Self.mouseEvent(.leftMouseDragged, at: outside, of: mountedRow))
        #expect(!rowView.isPressed)
        #expect(mountedRow.containerLayer.affineTransform() == .identity)
        try rowView.mouseDragged(with: Self.mouseEvent(.leftMouseDragged, at: mountedRow.rowCenter, of: mountedRow))
        #expect(rowView.isPressed)
        #expect(mountedRow.containerLayer.affineTransform() == CGAffineTransform(scaleX: 0.95, y: 0.95))
        try rowView.mouseDragged(with: Self.mouseEvent(.leftMouseDragged, at: outside, of: mountedRow))
        try rowView.mouseUp(with: Self.mouseEvent(.leftMouseUp, at: outside, of: mountedRow))

        #expect(!rowView.isPressed)
        #expect(tapCount == 0)
    }

    // MARK: Selection

    @Test func selectionMovesTheTextColourOnTheSpringAndTheTranslationAtOnce() throws {
        let mountedRow = try Self.mountRow()
        mountedRow.rowView.setHighlighted(true)
        let selectedColors = Self.unsungColors(of: mountedRow.contentLayer)
        #expect(!selectedColors.isEmpty)
        #expect(selectedColors.allSatisfy { $0 == CGColor(gray: 1, alpha: 0.5) })
        #expect(mountedRow.translationLayer.opacity == 0.5)
        CATransaction.flush()

        mountedRow.rowView.setHighlighted(false, animated: true)

        #expect(mountedRow.translationLayer.opacity == 0.4)
        #expect(mountedRow.translationLayer.animationKeys() == nil, "Music rebuilds the translation in its new colour at once")
        let visualRowColorContainers = (mountedRow.contentLayer.sublayers ?? []).filter { candidateLayer in
            (candidateLayer.sublayers ?? []).contains { $0 is AppleMusicLyrics.LineProgressGradientLayer }
        }
        #expect(!visualRowColorContainers.isEmpty)
        for visualRowColorContainer in visualRowColorContainers {
            let sublayers = visualRowColorContainer.sublayers ?? []
            let backgroundColorLayer = try #require(sublayers.first { !($0 is AppleMusicLyrics.LineProgressGradientLayer) })
            let progressGradientLayer = try #require(sublayers.first { $0 is AppleMusicLyrics.LineProgressGradientLayer })
            #expect(backgroundColorLayer.backgroundColor == CGColor(gray: 1, alpha: 0.4))
            try Self.expectSpring(
                backgroundColorLayer.animation(forKey: "AppleMusicLyrics.backgroundColor"),
                mass: 1,
                stiffness: 100,
                damping: 18
            )
            #expect(progressGradientLayer.opacity == 0)
            try Self.expectSpring(
                progressGradientLayer.animation(forKey: "AppleMusicLyrics.opacity"),
                mass: 1,
                stiffness: 100,
                damping: 18
            )
        }
    }

    @Test func panelHandsEveryRowTheDeselectedVariant() throws {
        let lyrics = try #require(Lyrics("""
        [00:00.000]first line
        [00:04.000]second line
        [00:08.000]third line
        """))
        let frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        let container = AppleMusicLyrics.SyncedLyricsContainerView(frame: frame)
        var variant = AppleMusicLyrics.DeselectedLineOpacityVariant.appleMusic26
        container.setDeselectedLineOpacityVariantProvider { variant }
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.update(lyrics: lyrics, highlightedLineIndex: 0, mainFontSize: 30, translationFontSize: 17)
        container.layoutSubtreeIfNeeded()

        let scrollView = try #require(container.subviews.compactMap { $0 as? NSScrollView }.first)
        let rowViews = scrollView.documentView?.subviews.compactMap { $0 as? AppleMusicLyrics.SyncedLyricsLineView } ?? []
        #expect(rowViews.count == 3)
        #expect(rowViews.allSatisfy { $0.alphaValue == 1 })
        for rowView in rowViews where !rowView.isHighlighted {
            #expect(Self.unsungColors(of: rowView.contentLayer).allSatisfy { $0 == CGColor(gray: 1, alpha: 0.4) })
        }

        variant = .legacyRecording
        container.update(lyrics: lyrics, highlightedLineIndex: 1, mainFontSize: 30, translationFontSize: 17)
        for rowView in rowViews where !rowView.isHighlighted {
            #expect(Self.unsungColors(of: rowView.contentLayer).allSatisfy { $0 == CGColor(gray: 1, alpha: 0.55) })
        }
        #expect(rowViews.allSatisfy { $0.alphaValue == 1 })
    }
}
