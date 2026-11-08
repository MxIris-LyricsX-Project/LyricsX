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
                HStack(spacing: 10) {
                    // Smaller than the extra-large widget's 60 pt cover: the
                    // large widget is about half as wide, and every point the
                    // header grows comes out of the lyrics area below it.
                    if let coverImage = entry.coverImage {
                        Image(decorative: coverImage, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

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

                    Spacer(minLength: 0)
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
