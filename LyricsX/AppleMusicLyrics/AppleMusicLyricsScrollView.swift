import SwiftUI
import Combine
import LyricsXFoundation

@available(macOS 15, *)
struct AppleMusicLyricsScrollView: View {

    var lyrics: Lyrics
    var highlightedLineIndex: Int?
    var playbackTime: TimeInterval
    var karaokeMode: KaraokeMode
    var interactionState: InteractionStateModel

    var onSeek: (TimeInterval) -> Void

    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var containerSize: CGSize = .zero
    @State private var contentOffset: [Int: CGFloat] = [:]
    @State private var lineHeights: [Int: CGFloat] = [:]
    @State private var previousHighlightedIndex: Int?
    @Namespace private var coordinateSpace

    private let interludeThreshold: TimeInterval = 4.5

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(enabledLineIndices, id: \.self) { lineIndex in
                    lineContent(at: lineIndex)
                        .id(lineIndex)
                }
            }
            .padding(.vertical, containerSize.height / 2)
        }
        .scrollPosition($scrollPosition, anchor: .center)
        .scrollIndicators(interactionState.isFollowing ? .hidden : .visible)
        .onGeometryChange(for: CGSize.self) { geometryProxy in
            geometryProxy.size
        } action: { newSize in
            containerSize = newSize
        }
        .onScrollPhaseChange { _, newPhase in
            if newPhase == .interacting {
                interactionState.userDidScroll()
            }
        }
        .onChange(of: highlightedLineIndex) { oldValue, newValue in
            previousHighlightedIndex = oldValue
            guard let newValue else { return }
            scrollToHighlighted(index: newValue)
        }
        .onChange(of: lyrics.description) { _, _ in
            // Track changed: reset all offsets
            contentOffset.removeAll()
            lineHeights.removeAll()
            previousHighlightedIndex = nil
        }
    }

    // MARK: - Enabled Lines

    private var enabledLineIndices: [Int] {
        lyrics.lines.indices.filter { lyrics.lines[$0].enabled }
    }

    // MARK: - Line Content

    @ViewBuilder
    private func lineContent(at index: Int) -> some View {
        let line = lyrics.lines[index]
        let isHighlighted = highlightedLineIndex == index
        let highlightedIndex = highlightedLineIndex ?? 0
        let lineStartTime = line.position
        let elapsedTime = playbackTime + lyrics.adjustedTimeDelay - lineStartTime
        let lineDuration = computeLineDuration(at: index)

        VStack(spacing: 0) {
            // Interlude dots
            interludeDotsIfNeeded(beforeIndex: index)

            LyricsLineRowView(
                line: line,
                index: index,
                isHighlighted: isHighlighted,
                highlightedIndex: highlightedIndex,
                elapsedTime: elapsedTime,
                lineDuration: lineDuration,
                karaokeMode: karaokeMode,
                onTap: {
                    onSeek(line.position + 0.01)
                    interactionState.returnToFollowing()
                }
            )
        }
        .onGeometryChange(for: CGFloat.self) { geometryProxy in
            geometryProxy.size.height
        } action: { newHeight in
            lineHeights[index] = newHeight
        }
        .offset(y: contentOffset[index] ?? 0)
    }

    // MARK: - Line Duration

    private func computeLineDuration(at index: Int) -> TimeInterval {
        // Use timetag duration if available
        if let duration = lyrics.lines[index].timetagDuration, duration > 0 {
            return duration
        }
        // Otherwise compute from next line's position
        let nextEnabledIndex = enabledLineIndices.first(where: { $0 > index })
        if let nextIndex = nextEnabledIndex {
            return lyrics.lines[nextIndex].position - lyrics.lines[index].position
        }
        return 5.0 // fallback for last line
    }

    // MARK: - Interlude Dots

    @ViewBuilder
    private func interludeDotsIfNeeded(beforeIndex index: Int) -> some View {
        let previousEnabledIndex = enabledLineIndices.last(where: { $0 < index })
        if let previousIndex = previousEnabledIndex {
            let gap = lyrics.lines[index].position - lyrics.lines[previousIndex].position
            if gap >= interludeThreshold {
                let gapStart = lyrics.lines[previousIndex].position
                let adjustedPlayback = playbackTime + lyrics.adjustedTimeDelay
                let gapProgress = max(0, min(1, (adjustedPlayback - gapStart) / gap))
                ProgressDotsView(progress: gapProgress)
                    .frame(height: 40)
            }
        }
    }

    // MARK: - Cascade Scroll Animation

    private func scrollToHighlighted(index: Int) {
        guard interactionState.isFollowing else { return }

        let currentLineHeight = lineHeights[index] ?? 40
        let offset = currentLineHeight / 2

        // Phase 1: spring lines before highlight back to zero
        for lineIndex in max(0, index - 10) ..< index {
            withAnimation(.spring(duration: 0.6, bounce: 0.275)) {
                contentOffset[lineIndex] = 0
            }
        }

        // Phase 2: stagger-animate lines at and after highlight
        var staggerDelay: TimeInterval = 0.08
        let previousLineHeight = lineHeights[previousHighlightedIndex ?? index] ?? 40
        let compensationOffset: CGFloat = {
            guard let previousHighlightedIndex else { return 0 }
            let differenceBeforeHighlight = abs(previousLineHeight - currentLineHeight)
            let nextLineHeight = lineHeights[index + 1] ?? 40
            let differenceAfterHighlight = abs(nextLineHeight - currentLineHeight)
            if abs(index - previousHighlightedIndex) > 3 {
                return 0
            } else if differenceBeforeHighlight > differenceAfterHighlight {
                return (previousLineHeight - currentLineHeight) / 2
            } else {
                return (nextLineHeight - currentLineHeight) / 2
            }
        }()

        for lineIndex in index ..< min(lyrics.lines.count, index + 10) {
            staggerDelay += 0.08
            withAnimation(.spring(duration: 0.6, bounce: 0.275).delay(staggerDelay)) {
                contentOffset[lineIndex] = offset + compensationOffset
            }
        }

        // Scroll to center
        withAnimation(.spring(duration: 0.6, bounce: 0.275)) {
            scrollPosition.scrollTo(id: index, anchor: .center)
        }
    }
}
