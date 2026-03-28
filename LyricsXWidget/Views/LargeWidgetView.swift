import SwiftUI
import WidgetKit
import LyricsXWidgetShared

struct LargeWidgetView: View {
    let entry: LyricsTimelineEntry

    private let visibleLineCount = 7

    var body: some View {
        if entry.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(gradientBackground)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(entry.trackTitle) — \(entry.artist)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                Spacer(minLength: 8)

                if !entry.lyricsLines.isEmpty {
                    lyricsSection
                } else {
                    Text("No Lyrics")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer(minLength: 8)

                PlaybackControlView(isPlaying: entry.isPlaying)
                    .padding(.bottom, 14)
            }
            .background(gradientBackground)
        }
    }

    private var lyricsSection: some View {
        let halfWindow = visibleLineCount / 2
        let startIndex = max(0, entry.highlightedLineIndex - halfWindow)
        let endIndex = min(entry.lyricsLines.count - 1, startIndex + visibleLineCount - 1)
        let adjustedStartIndex = max(0, endIndex - visibleLineCount + 1)

        return VStack(spacing: 6) {
            ForEach(adjustedStartIndex...endIndex, id: \.self) { lineIndex in
                let line = entry.lyricsLines[lineIndex]
                let isHighlighted = (lineIndex == entry.highlightedLineIndex)
                LyricsLineView(
                    line: line,
                    isHighlighted: isHighlighted,
                    showTranslation: entry.showTranslation && isHighlighted,
                    translationLanguage: entry.translationLanguage
                )
            }
        }
        .padding(.horizontal, 16)
    }

    private var gradientBackground: some View {
        LinearGradient(
            colors: entry.backgroundColor?.gradientColors ?? Color.defaultGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
