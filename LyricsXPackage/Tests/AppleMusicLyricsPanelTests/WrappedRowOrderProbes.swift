import AppKit
import LyricsXFoundation
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

/// Reproduction loop for "the second visual row renders above the first": a
/// wrapped lyric mounted in a window, with every visual row container projected
/// into the window's root layer, the way Core Animation will actually place it
/// on screen. A layer's effective orientation is the XOR of every
/// `isGeometryFlipped` above it, and AppKit puts that flag on the
/// NSScrollView's backing layer, so the same row view sees a flipped backing
/// layer inside the panel and an unflipped one on its own. Both hostings are
/// covered: the content layer has to come out y-down either way.
@MainActor
struct WrappedRowOrderProbes {
    private static let wrappingLine = "I told you I changed, even when I knew I never could"

    @Test func wrappedRowsProjectTopToBottomInsideAMountedContainer() throws {
        let lyrics = try #require(Lyrics("[00:00.000]\(Self.wrappingLine)\n[00:05.000]next line"))
        let frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        let container = AppleMusicLyrics.SyncedLyricsContainerView(frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.update(lyrics: lyrics, highlightedLineIndex: 0, mainFontSize: 30, translationFontSize: 16)
        container.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let scrollView = try #require(container.subviews.compactMap { $0 as? NSScrollView }.first)
        let rowView = try #require(
            scrollView.documentView?.subviews
                .compactMap { $0 as? AppleMusicLyrics.SyncedLyricsLineView }
                .first { $0.originalIndex == 0 }
        )
        try Self.expectRowsProjectTopToBottom(in: rowView, window: window)
    }

    @Test func wrappedRowsProjectTopToBottomWhenTheRowIsHostedOnItsOwn() throws {
        let lyrics = try #require(Lyrics("[00:00.000]\(Self.wrappingLine)"))
        let frame = NSRect(x: 0, y: 0, width: 520, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hostView = try #require(window.contentView)
        hostView.wantsLayer = true
        let rowView = AppleMusicLyrics.SyncedLyricsLineView(frame: NSRect(x: 0, y: 0, width: 520, height: 100))
        let line = try #require(lyrics.lines.first)
        try rowView.configure(
            line: line,
            translation: line.attachments.translation(),
            originalIndex: 0,
            enabledPosition: 0,
            mainFontSize: 30,
            translationFontSize: 16
        )
        hostView.addSubview(rowView)
        rowView.frame = NSRect(x: 0, y: 40, width: 520, height: rowView.preferredHeight(forWidth: 520))
        rowView.layoutSubtreeIfNeeded()
        CATransaction.flush()
        try Self.expectRowsProjectTopToBottom(in: rowView, window: window)
    }

    private static func expectRowsProjectTopToBottom(
        in rowView: AppleMusicLyrics.SyncedLyricsLineView,
        window: NSWindow
    ) throws {
        let rowLayer = try #require(rowView.layer)
        let contentLayer = rowView.contentLayer
        let rowContainers = (contentLayer.sublayers ?? []).filter { candidate in
            (candidate.sublayers ?? []).contains { $0 is AppleMusicLyrics.LineProgressGradientLayer }
        }
        try #require(rowContainers.count == 2, "the fixture line must wrap into two visual rows at this width")

        // The content layer's own space is y-down, so the first row has the
        // smaller frame.minY there. The window's root layer is y-up, so on
        // screen the first row must come out with the *larger* minY.
        #expect(rowContainers[0].frame.minY < rowContainers[1].frame.minY)
        let rootLayer = try #require(window.contentView?.layer)
        let projected = rowContainers.map { $0.convert($0.bounds, to: rootLayer) }
        #expect(
            projected[0].minY > projected[1].minY,
            """
            the first wrapped row projects below the second: \
            root \(projected.map(\.minY)), \
            row layer flipped=\(rowLayer.isGeometryFlipped) effective=\(rowLayer.contentsAreFlipped()) \
            content flipped=\(contentLayer.isGeometryFlipped) effective=\(contentLayer.contentsAreFlipped()) \
            chain=\(Self.flipChain(from: contentLayer, to: rootLayer))
            """
        )
        let contentInRow = contentLayer.convert(contentLayer.bounds, to: rowLayer)
        let topInset = rowLayer.contentsAreFlipped() ? contentInRow.minY : rowLayer.bounds.height - contentInRow.maxY
        #expect(
            abs(topInset - (rowView.verticalPadding - contentLayer.textOutset.height)) < 0.001,
            "the text block must hang from the row's top padding, got a top inset of \(topInset)"
        )
    }

    /// `geometryFlipped` of every layer from `layer` up to `root`, innermost first.
    private static func flipChain(from layer: CALayer, to root: CALayer) -> [String] {
        var chain: [String] = []
        var current: CALayer? = layer
        while let layer = current, layer !== root {
            chain.append("\(type(of: layer))=\(layer.isGeometryFlipped)")
            current = layer.superlayer
        }
        chain.append("\(type(of: root))=\(root.isGeometryFlipped)")
        return chain
    }
}
