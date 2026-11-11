import CoreGraphics

/// Which lyric lines a large or extra-large widget shows, and where each one
/// goes, given how tall every line came out at the widget's width.
///
/// The widgets used to show a fixed number of lines at whatever height they
/// needed. With translations on, or with long lines wrapping, that stack
/// outgrew the space between the header and the playback controls, and the
/// widget pushed both out of its bounds to make room. Instead, this fits the
/// lines to the space: the highlighted line sits at the vertical centre, whole
/// lines are added above and below it while they fit, and a line that would be
/// cut off is left out.
public enum WidgetLyricsLayoutPolicy {
    public struct Placement: Equatable, Sendable {
        /// The lines the widget shows. They are consecutive and always include
        /// the highlighted line.
        public let visibleLineIndices: ClosedRange<Int>
        /// Where the top edge of every line goes, measured from the top of the
        /// lyrics area, in the order of the heights passed in. Lines outside
        /// `visibleLineIndices` sit wholly above or below the area, still in
        /// reading order, so that moving to the next entry scrolls them out of
        /// and into view instead of across it.
        public let lineTops: [CGFloat]
    }

    /// - Returns: `nil` when `highlightedLineIndex` is not a line.
    public static func placement(
        lineHeights: [CGFloat],
        highlightedLineIndex: Int,
        availableHeight: CGFloat,
        lineSpacing: CGFloat
    ) -> Placement? {
        guard lineHeights.indices.contains(highlightedLineIndex) else { return nil }

        let highlightedLineHeight = lineHeights[highlightedLineIndex]
        let spaceBesideHighlightedLine = max(availableHeight - highlightedLineHeight, 0)
        let halfSpace = spaceBesideHighlightedLine / 2

        // Each side first takes what fits in its half, which keeps the
        // highlighted line centred whenever there are lines on both sides.
        var linesAbove = Run(nearestIndex: highlightedLineIndex - 1, step: -1)
        var linesBelow = Run(nearestIndex: highlightedLineIndex + 1, step: 1)
        linesAbove.extend(lineHeights: lineHeights, lineSpacing: lineSpacing, heightLimit: halfSpace)
        linesBelow.extend(lineHeights: lineHeights, lineSpacing: lineSpacing, heightLimit: halfSpace)

        // Near the start or the end of the lyrics one side runs out of lines
        // before it runs out of space, and the other side takes what it left.
        if !linesAbove.hasMoreLines(in: lineHeights) {
            linesBelow.extend(
                lineHeights: lineHeights,
                lineSpacing: lineSpacing,
                heightLimit: spaceBesideHighlightedLine - linesAbove.height
            )
        } else if !linesBelow.hasMoreLines(in: lineHeights) {
            linesAbove.extend(
                lineHeights: lineHeights,
                lineSpacing: lineSpacing,
                heightLimit: spaceBesideHighlightedLine - linesBelow.height
            )
        }

        // Centre the highlighted line, then keep the lines inside the area: at
        // the start of the lyrics that puts the first line at the top edge, at
        // the end it puts the last line at the bottom edge.
        let visibleHeight = linesAbove.height + highlightedLineHeight + linesBelow.height
        let centredTop = halfSpace - linesAbove.height
        let firstVisibleTop = min(max(centredTop, 0), max(availableHeight - visibleHeight, 0))

        let visibleLineIndices = (highlightedLineIndex - linesAbove.count) ... (highlightedLineIndex + linesBelow.count)
        var lineTops = Array(repeating: CGFloat(0), count: lineHeights.count)

        var nextTop = firstVisibleTop
        for index in visibleLineIndices {
            lineTops[index] = nextTop
            nextTop += lineHeights[index] + lineSpacing
        }
        for index in (visibleLineIndices.upperBound + 1) ..< lineHeights.count {
            let top = max(nextTop, availableHeight)
            lineTops[index] = top
            nextTop = top + lineHeights[index] + lineSpacing
        }

        var topOfLineUnderneath = firstVisibleTop
        for index in stride(from: visibleLineIndices.lowerBound - 1, through: 0, by: -1) {
            let top = min(topOfLineUnderneath - lineSpacing - lineHeights[index], -lineHeights[index])
            lineTops[index] = top
            topOfLineUnderneath = top
        }

        return Placement(visibleLineIndices: visibleLineIndices, lineTops: lineTops)
    }

    /// The lines taken on one side of the highlighted line, nearest first.
    private struct Run {
        let nearestIndex: Int
        let step: Int
        private(set) var count = 0
        /// The taken lines' heights plus the spacing in front of each of them.
        private(set) var height: CGFloat = 0

        init(nearestIndex: Int, step: Int) {
            self.nearestIndex = nearestIndex
            self.step = step
        }

        private var nextIndex: Int {
            nearestIndex + step * count
        }

        func hasMoreLines(in lineHeights: [CGFloat]) -> Bool {
            lineHeights.indices.contains(nextIndex)
        }

        /// Takes lines while the run stays within `heightLimit`, stopping at
        /// the first line that does not fit, so no line is ever skipped.
        mutating func extend(lineHeights: [CGFloat], lineSpacing: CGFloat, heightLimit: CGFloat) {
            while hasMoreLines(in: lineHeights) {
                let extendedHeight = height + lineSpacing + lineHeights[nextIndex]
                guard extendedHeight <= heightLimit else { return }
                height = extendedHeight
                count += 1
            }
        }
    }
}
