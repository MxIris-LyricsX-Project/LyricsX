import SwiftUI
import Combine
import LyricsXFoundation

@available(macOS 15, *)
extension AppleMusicLyrics {

struct LyricsScrollView: View {

    var lyrics: Lyrics
    var highlightedLineIndex: Int?
    var playbackTimeModel: PlaybackTimeModel
    var karaokeMode: KaraokeMode
    var interactionState: InteractionStateModel
    var mainFontSize: CGFloat
    var translationFontSize: CGFloat

    var onSeek: (TimeInterval) -> Void

    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var containerSize: CGSize = .zero
    @State private var contentOffset: [Int: CGFloat] = [:]
    @State private var lineHeights: [Int: CGFloat] = [:]
    @State private var lastHighlightTime: Date = .distantPast

    private static let cascadeSpring: Animation = .spring(duration: 0.6, bounce: 0.275)
    private static let settleAnimation: Animation = .smooth(duration: 0.5)
    private static let cascadeStagger: TimeInterval = 0.08
    private static let aboveLineCount = 3
    private static let belowLineCount = 6
    private static let jumpThreshold = 5
    private static let rapidThreshold: TimeInterval = 0.4

    var body: some View {
        let enabledIndices = lyrics.lines.indices.filter {
            lyrics.lines[$0].enabled && !lyrics.lines[$0].content.isEmpty
        }

        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(enabledIndices, id: \.self) { lineIndex in
                    lineContent(at: lineIndex, enabledIndices: enabledIndices)
                        .id(lineIndex)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            lineHeights[lineIndex] = height
                        }
                        .offset(y: contentOffset[lineIndex] ?? 0)
                }
            }
            .padding(.vertical, containerSize.height / 2)
        }
        .scrollPosition($scrollPosition, anchor: .center)
        .scrollIndicators(.never)
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
        .onAppear {
            if let highlightedLineIndex {
                scrollPosition.scrollTo(id: highlightedLineIndex, anchor: .center)
            }
        }
        .onChange(of: highlightedLineIndex) { oldValue, newValue in
            guard let newValue else { return }
            let now = Date()
            let timeSinceLast = now.timeIntervalSince(lastHighlightTime)
            lastHighlightTime = now
            let isJump = oldValue.map { abs(newValue - $0) > Self.jumpThreshold } ?? true
            let isRapid = timeSinceLast < Self.rapidThreshold && !isJump
            scrollToHighlighted(index: newValue, jumped: isJump, rapid: isRapid, enabledIndices: enabledIndices)
        }
    }

    // MARK: - Line Content

    @ViewBuilder
    private func lineContent(at index: Int, enabledIndices: [Int]) -> some View {
        let line = lyrics.lines[index]
        let isHighlighted = highlightedLineIndex == index
        let highlightedIndex = highlightedLineIndex ?? 0

        // Only compute time-dependent values for the highlighted line (karaoke).
        // Non-highlighted lines get constant 0, so the Equatable check on
        // LyricsLineRowView prevents their body from re-evaluating at 30fps.
        let elapsedTime = isHighlighted ? (playbackTimeModel.playbackTime + lyrics.adjustedTimeDelay - line.position) : 0
        let lineDuration = isHighlighted ? computeLineDuration(at: index, enabledIndices: enabledIndices) : 0

        LyricsLineRowView(
            line: line,
            index: index,
            isHighlighted: isHighlighted,
            highlightedIndex: highlightedIndex,
            elapsedTime: elapsedTime,
            lineDuration: lineDuration,
            karaokeMode: karaokeMode,
            mainFontSize: mainFontSize,
            translationFontSize: translationFontSize,
            onTap: {
                onSeek(line.position + 0.01)
                interactionState.returnToFollowing()
            }
        )
        .equatable()
    }

    // MARK: - Line Duration

    private func computeLineDuration(at index: Int, enabledIndices: [Int]) -> TimeInterval {
        if let duration = lyrics.lines[index].timetagDuration, duration > 0 {
            return duration
        }
        let nextEnabledIndex = enabledIndices.first(where: { $0 > index })
        if let nextIndex = nextEnabledIndex {
            return lyrics.lines[nextIndex].position - lyrics.lines[index].position
        }
        return 5.0
    }

    // MARK: - Scroll Animation

    private func scrollToHighlighted(index: Int, jumped: Bool, rapid: Bool, enabledIndices: [Int]) {
        guard interactionState.isFollowing else { return }

        // Large jump: reset all offsets, scroll instantly
        if jumped {
            withAnimation(nil) {
                contentOffset.removeAll()
                scrollPosition.scrollTo(id: index, anchor: .center)
            }
            return
        }

        // Rapid succession: cancel in-flight cascades, simple smooth scroll
        if rapid {
            withAnimation(nil) {
                for key in contentOffset.keys {
                    contentOffset[key] = 0
                }
            }
            withAnimation(Self.settleAnimation) {
                scrollPosition.scrollTo(id: index, anchor: .center)
            }
            return
        }

        // Normal: full cascade
        let offset = lineHeights[index] ?? 50
        let previousEnabledIndex = enabledIndices.last(where: { $0 < index })
        let previousHeight = previousEnabledIndex.flatMap { lineHeights[$0] } ?? offset
        let compensate = (previousHeight - offset) / 2
        let displacement = offset + compensate
        let aboveIndices = Array(enabledIndices.filter { $0 < index }.suffix(Self.aboveLineCount))
        let belowIndices = Array(enabledIndices.filter { $0 >= index }.prefix(Self.belowLineCount))

        // Phase 1: Set displacement + scroll with NO animation
        withAnimation(nil) {
            for lineIndex in aboveIndices {
                contentOffset[lineIndex] = displacement
            }
            for lineIndex in belowIndices {
                contentOffset[lineIndex] = displacement
            }
            scrollPosition.scrollTo(id: index, anchor: .center)
        }

        // Phase 2: Lines above — smooth settle (no bounce, saves frames)
        for lineIndex in aboveIndices {
            withAnimation(Self.settleAnimation) {
                contentOffset[lineIndex] = 0
            }
        }

        // Phase 3: Lines at/below — cascade spring back to 0
        var delay = Self.cascadeStagger
        for lineIndex in belowIndices {
            delay += Self.cascadeStagger
            withAnimation(Self.cascadeSpring.delay(delay)) {
                contentOffset[lineIndex] = 0
            }
        }
    }
}

}
