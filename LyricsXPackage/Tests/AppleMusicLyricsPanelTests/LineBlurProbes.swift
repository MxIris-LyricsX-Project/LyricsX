import AppKit
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

@Suite(.serialized)
@MainActor
struct LineBlurProbes {
    @Test func blurUsesRecoveredCurveAndRestoresRasterization() async throws {
        let frame = NSRect(x: 0, y: 0, width: 500, height: 160)
        let lineView = AppleMusicLyrics.SyncedLyricsLineView(frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = lineView
        defer { window.contentView = nil }

        let lineLayer = try #require(lineView.layer)
        lineLayer.shouldRasterize = true
        lineView.setLineBlurRadius(AppleMusicLyrics.LyricsSpecs.deselectedLineBlurRadius, animated: true)

        let animationKey = "filters.gaussianBlur.inputRadius"
        let animation = try #require(lineLayer.animation(forKey: animationKey) as? CABasicAnimation)
        #expect(abs(animation.duration - 0.12) < 0.000_001)
        #expect(lineLayer.shouldRasterize == false)

        let timingFunction = try #require(animation.timingFunction)
        var firstControlPoint = [Float](repeating: 0, count: 2)
        var secondControlPoint = [Float](repeating: 0, count: 2)
        timingFunction.getControlPoint(at: 1, values: &firstControlPoint)
        timingFunction.getControlPoint(at: 2, values: &secondControlPoint)
        #expect(abs(firstControlPoint[0] - 0.33) < 0.001)
        #expect(abs(firstControlPoint[1] - 0) < 0.001)
        #expect(abs(secondControlPoint[0] - 0.2) < 0.001)
        #expect(abs(secondControlPoint[1] - 0.1) < 0.001)

        try await Task.sleep(seconds: 0.18)
        #expect(lineLayer.shouldRasterize == true)
    }

    /// Apple Music's `SyncedLyricsLineLayer` is rasterized from `init` on and only
    /// drops the bitmap while its blur radius animates. A row that is never
    /// rasterized is recomposited — nested masks, word glow and gaussian blur —
    /// on every frame of a line cascade, which is what pushed full-screen line
    /// changes down to 30 FPS.
    @Test func rowLayersRasterizeLikeAppleMusicWithoutBeingAsked() async throws {
        let frame = NSRect(x: 0, y: 0, width: 500, height: 160)
        let lineView = AppleMusicLyrics.SyncedLyricsLineView(frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = lineView
        defer { window.contentView = nil }
        lineView.layoutSubtreeIfNeeded()

        let lineLayer = try #require(lineView.layer)
        #expect(lineLayer.shouldRasterize == true)
        #expect(lineLayer.rasterizationScale == window.backingScaleFactor)

        lineView.setLineBlurRadius(AppleMusicLyrics.LyricsSpecs.deselectedLineBlurRadius, animated: true)
        #expect(lineLayer.shouldRasterize == false)

        try await Task.sleep(seconds: 0.18)
        #expect(lineLayer.shouldRasterize == true)
        #expect(lineLayer.rasterizationScale == window.backingScaleFactor)
    }
}
