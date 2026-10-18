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
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.trackTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(entry.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                            showsTranslation: entry.showsTranslation,
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
