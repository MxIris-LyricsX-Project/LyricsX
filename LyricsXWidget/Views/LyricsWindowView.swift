import SwiftUI
import LyricsXWidgetShared

/// The lyrics of the large and extra-large widgets: the highlighted line in
/// the middle and as many whole lines around it as fit in the space this view
/// is given, so the lyrics never push the header or the playback controls out
/// of the widget. `WidgetLyricsLayoutPolicy` decides which lines those are.
struct LyricsWindowView: View {
    enum TranslationScope {
        case everyLine
        case highlightedLine
    }

    let lines: [LyricsLineEntry]
    let highlightedLineIndex: Int
    let lineSpacing: CGFloat
    let showsTranslation: Bool
    let translationScope: TranslationScope

    /// Further from the highlighted line than any widget has room for; lines
    /// beyond it are not laid out at all.
    private static let candidateLineRadius = 16

    var body: some View {
        if lines.indices.contains(highlightedLineIndex) {
            let candidateLineIndices = max(0, highlightedLineIndex - Self.candidateLineRadius)
                ... min(lines.count - 1, highlightedLineIndex + Self.candidateLineRadius)
            LyricsWindowLayout(
                highlightedSubviewIndex: highlightedLineIndex - candidateLineIndices.lowerBound,
                lineSpacing: lineSpacing
            ) {
                // A line's position in `lines` is its identity: the provider
                // never reorders or edits the lines within a timeline.
                ForEach(candidateLineIndices, id: \.self) { lineIndex in
                    let isHighlighted = lineIndex == highlightedLineIndex
                    LyricsLineView(
                        line: lines[lineIndex],
                        isHighlighted: isHighlighted,
                        showTranslation: showsTranslation && (translationScope == .everyLine || isHighlighted)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }
}

/// Measures every line at the full width and puts it where
/// `WidgetLyricsLayoutPolicy` says, centred horizontally. A widget draws
/// everything it lays out, so the lines left out are put outside the bounds,
/// where `LyricsWindowView` clips them.
private struct LyricsWindowLayout: Layout {
    let highlightedSubviewIndex: Int
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max()
            ?? 0
        // Takes the height it is offered: lines that do not fit are left out
        // rather than making the lyrics taller.
        if let height = proposal.height, height.isFinite {
            return CGSize(width: width, height: height)
        }
        let lineProposal = ProposedViewSize(width: width, height: nil)
        let stackedHeight = subviews.reduce(0) { $0 + $1.sizeThatFits(lineProposal).height }
            + lineSpacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: width, height: stackedHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lineProposal = ProposedViewSize(width: bounds.width, height: nil)
        let lineHeights = subviews.map { $0.sizeThatFits(lineProposal).height }
        let placement = WidgetLyricsLayoutPolicy.placement(
            lineHeights: lineHeights,
            highlightedLineIndex: highlightedSubviewIndex,
            availableHeight: bounds.height,
            lineSpacing: lineSpacing
        )
        for (subviewIndex, subview) in subviews.enumerated() {
            let top = placement?.lineTops[subviewIndex] ?? bounds.height
            subview.place(
                at: CGPoint(x: bounds.midX, y: bounds.minY + top),
                anchor: .top,
                proposal: ProposedViewSize(width: bounds.width, height: lineHeights[subviewIndex])
            )
        }
    }
}
