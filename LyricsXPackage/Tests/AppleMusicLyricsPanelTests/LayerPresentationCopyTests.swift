import AppKit
import CoreGraphics
import CoreText
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

/// Core Animation builds every presentation copy through `init(layer:)`: for
/// `presentation()` on the layer itself, and for any ancestor's copy that is
/// then walked — which is what Xcode's view debugger does to the whole tree.
/// A `CALayer` subclass that declares its own designated initializer stops
/// inheriting that one; Swift then leaves a stand-in behind that traps with
/// "Use of unimplemented initializer 'init(layer:)'" the moment Core
/// Animation reaches it. These tests reach it the same way, once per panel
/// layer class that has its own initializer.
///
/// Only the state the subclass stores in Swift is checked. Outside a
/// transaction the base copy carries none of Core Animation's own attributes
/// (`bounds`, `contentsScale`, `isGeometryFlipped`, …); a real presentation
/// copy reads those from the render tree, so they are never the override's
/// job to carry across.
struct LayerPresentationCopyTests {
    /// Copies a layer the way Core Animation does: allocate the layer's own
    /// class and hand it the original through `init(layer:)`, dispatched
    /// dynamically. A subclass that lost the initializer traps here exactly as
    /// it does under `presentation()`; a static call would not even compile.
    private func makeCopyAsCoreAnimationDoes(of layer: CALayer) -> CALayer {
        let layerClass: CALayer.Type = type(of: layer)
        return layerClass.init(layer: layer)
    }

    @Test func lineProgressGradientLayerCopyKeepsItsGeometry() throws {
        let original = AppleMusicLyrics.LineProgressGradientLayer(
            lineWidth: 240,
            lineHeight: 32,
            verticalPadding: 6,
            featherWidth: 24,
            direction: .trailingToLeading,
            color: CGColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        )

        let copy = try #require(makeCopyAsCoreAnimationDoes(of: original) as? AppleMusicLyrics.LineProgressGradientLayer)

        #expect(copy.featherWidth == original.featherWidth)
        #expect(copy.direction == original.direction)
        #expect(copy.verticalPadding == original.verticalPadding)
        #expect(copy.color == original.color)
        // `lineWidth` is private. In the trailing-to-leading direction
        // `originX(forFillEdge:)` is computed from `lineWidth` and
        // `featherWidth` alone, without touching `bounds`, so agreeing on it
        // is the copy proving it received the line width.
        #expect(copy.originX(forFillEdge: 100) == original.originX(forFillEdge: 100))
    }

    @Test func glyphRunLayerCopyStillDrawsItsRun() throws {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "copy"))
        let run = try #require((CTLineGetGlyphRuns(line) as? [CTRun])?.first)
        // A detached layer is not flipped, so the layer draws the text origin
        // at `-textPosition.y` in a y-up context: a negative y puts the
        // baseline inside the bitmap below.
        let original = AppleMusicLyrics.GlyphRunLayer(
            run: run,
            glyphRange: CFRange(location: 0, length: 0),
            textPosition: CGPoint(x: 2, y: -12),
            contentsScale: 2
        )

        let copy = try #require(makeCopyAsCoreAnimationDoes(of: original) as? AppleMusicLyrics.GlyphRunLayer)

        // The run is private state, and the only way to see that it came
        // across is to draw: the fallback run is a single space and covers
        // nothing.
        let originalInkedPixelCount = try inkedPixelCount(drawing: original)
        let copyInkedPixelCount = try inkedPixelCount(drawing: copy)
        #expect(originalInkedPixelCount > 0)
        #expect(copyInkedPixelCount == originalInkedPixelCount)
        // The run belongs to the line; keep the line alive until both draws
        // are done rather than trusting the optimizer to.
        withExtendedLifetime(line) {}
    }

    /// Draws `layer` into a small, cleared alpha-only bitmap and counts the
    /// pixels it covered. That is the kind of surface the glyph mask layer
    /// renders into, and it sidesteps colour altogether: Core Text draws a run
    /// in the attributed string's own foreground colour (black by default)
    /// rather than the context's fill colour, which on a grey canvas would
    /// look exactly like drawing nothing.
    private func inkedPixelCount(drawing layer: CALayer) throws -> Int {
        let sideLength = 40
        let context = try #require(CGContext(
            data: nil,
            width: sideLength,
            height: sideLength,
            bitsPerComponent: 8,
            bytesPerRow: sideLength,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: sideLength, height: sideLength))
        layer.draw(in: context)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0 ..< sideLength * sideLength).count { pixels[$0] > 0 }
    }

    @Test func syncedLyricsLineContentLayerCopyDoesNotTrap() throws {
        let original = AppleMusicLyrics.SyncedLyricsLineContentLayer()

        // The class stores nothing a presentation copy needs; reaching the
        // initializer at all is the whole assertion.
        let copy = try #require(makeCopyAsCoreAnimationDoes(of: original) as? AppleMusicLyrics.SyncedLyricsLineContentLayer)

        #expect(copy !== original)
    }
}
