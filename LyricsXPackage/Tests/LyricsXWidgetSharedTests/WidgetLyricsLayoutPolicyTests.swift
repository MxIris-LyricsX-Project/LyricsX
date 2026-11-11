import CoreGraphics
import Testing
@testable import LyricsXWidgetShared

// Heights are in points and stand for real widget rows: 32 is a line with its
// translation under it, 40 the highlighted line with its translation, 24 a
// plain line. Spacing is the extra-large widget's 8.

@Suite("Widget lyrics layout")
struct WidgetLyricsLayoutPolicyTests {
    @Test("lines that would overflow the lyrics area are left out")
    func linesThatWouldOverflowAreLeftOut() throws {
        // The extra-large widget with translations on used to stack nine such
        // lines (360 pt) into a 200 pt area and push its header and playback
        // controls out of the widget.
        var lineHeights = Array(repeating: CGFloat(32), count: 20)
        lineHeights[10] = 40

        let placement = try #require(WidgetLyricsLayoutPolicy.placement(
            lineHeights: lineHeights,
            highlightedLineIndex: 10,
            availableHeight: 200,
            lineSpacing: 8
        ))

        #expect(placement.visibleLineIndices == 8 ... 12)
    }

    @Test("the highlighted line stays centred between lines of different heights")
    func highlightedLineStaysCentred() throws {
        // A wrapped 52 pt line above and short lines below: the two sides end
        // up with different heights, the highlighted line does not move.
        let lineHeights: [CGFloat] = [32, 32, 52, 32, 40, 24, 24, 24, 24, 24]

        let placement = try #require(WidgetLyricsLayoutPolicy.placement(
            lineHeights: lineHeights,
            highlightedLineIndex: 4,
            availableHeight: 200,
            lineSpacing: 8
        ))

        #expect(placement.lineTops[4] + lineHeights[4] / 2 == 100)
    }

    @Test("a line that does not fit ends the lines on its side instead of being skipped")
    func lineThatDoesNotFitIsNotSkipped() throws {
        // Line 2 is too tall for what is left above, and line 1 would fit in
        // its place, but showing it would leave a gap in the lyrics.
        let lineHeights: [CGFloat] = [24, 24, 60, 24, 40, 24, 24, 24, 24, 24]

        let placement = try #require(WidgetLyricsLayoutPolicy.placement(
            lineHeights: lineHeights,
            highlightedLineIndex: 4,
            availableHeight: 200,
            lineSpacing: 8
        ))

        #expect(placement.visibleLineIndices == 3 ... 6)
    }

    @Test("at the first line, it sits at the top and the lines below fill the area")
    func firstLineFillsTheAreaBelowIt() throws {
        var lineHeights = Array(repeating: CGFloat(24), count: 10)
        lineHeights[0] = 40

        let placement = try #require(WidgetLyricsLayoutPolicy.placement(
            lineHeights: lineHeights,
            highlightedLineIndex: 0,
            availableHeight: 200,
            lineSpacing: 8
        ))

        #expect(placement.visibleLineIndices == 0 ... 5)
        #expect(placement.lineTops[0] == 0)
    }

    @Test("at the last line, it sits at the bottom and the lines above fill the area")
    func lastLineFillsTheAreaAboveIt() throws {
        var lineHeights = Array(repeating: CGFloat(24), count: 10)
        lineHeights[9] = 40

        let placement = try #require(WidgetLyricsLayoutPolicy.placement(
            lineHeights: lineHeights,
            highlightedLineIndex: 9,
            availableHeight: 200,
            lineSpacing: 8
        ))

        #expect(placement.visibleLineIndices == 4 ... 9)
        #expect(placement.lineTops[9] + lineHeights[9] == 200)
    }

    @Test("a highlighted line taller than the area is shown alone, from the top")
    func highlightedLineTallerThanTheArea() throws {
        let placement = try #require(WidgetLyricsLayoutPolicy.placement(
            lineHeights: [24, 240, 24],
            highlightedLineIndex: 1,
            availableHeight: 200,
            lineSpacing: 8
        ))

        #expect(placement.visibleLineIndices == 1 ... 1)
        #expect(placement.lineTops[1] == 0)
    }

    @Test("lines left out sit wholly outside the area, in reading order")
    func hiddenLinesSitOutsideTheArea() throws {
        // Where a hidden line sits is where the widget animates it from when
        // it scrolls into view at the next entry.
        var lineHeights = Array(repeating: CGFloat(32), count: 20)
        lineHeights[10] = 40

        let placement = try #require(WidgetLyricsLayoutPolicy.placement(
            lineHeights: lineHeights,
            highlightedLineIndex: 10,
            availableHeight: 200,
            lineSpacing: 8
        ))

        let hiddenLineIndices = lineHeights.indices.filter { !placement.visibleLineIndices.contains($0) }
        #expect(hiddenLineIndices.allSatisfy { lineIndex in
            placement.lineTops[lineIndex] + lineHeights[lineIndex] <= 0 || placement.lineTops[lineIndex] >= 200
        })
        #expect(zip(placement.lineTops, placement.lineTops.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("there is nothing to place without a highlighted line")
    func noPlacementWithoutAHighlightedLine() {
        #expect(WidgetLyricsLayoutPolicy.placement(
            lineHeights: [],
            highlightedLineIndex: 0,
            availableHeight: 200,
            lineSpacing: 8
        ) == nil)
    }
}
