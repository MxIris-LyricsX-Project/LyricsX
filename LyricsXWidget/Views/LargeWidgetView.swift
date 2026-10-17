import SwiftUI
import WidgetKit
import LyricsXWidgetShared

struct LargeWidgetView: View {
    let entry: LyricsTimelineEntry

    var body: some View {
        if entry.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                Group {
                    if entry.lyricsLines.isEmpty {
                        Text("No Lyrics")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.4))
                    } else {
                        LyricsWindowView(
                            lines: entry.lyricsLines,
                            highlightedLineIndex: entry.highlightedLineIndex,
                            lineSpacing: 6,
                            showsTranslation: entry.showTranslation,
                            translationScope: .highlightedLine
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                PlaybackControlView(isPlaying: entry.isPlaying)
                    .padding(.bottom, 14)
            }
        }
    }
}
