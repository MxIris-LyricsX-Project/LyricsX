import SwiftUI
import WidgetKit
import LyricsXWidgetShared

struct ExtraLargeWidgetView: View {
    let entry: LyricsTimelineEntry

    var body: some View {
        if entry.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if let coverImage = entry.coverImage {
                        Image(decorative: coverImage, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.trackTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 0) {
                            Text(entry.artist)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                            if let albumName = entry.albumName {
                                Text(" — \(albumName)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Group {
                    if entry.lyricsLines.isEmpty {
                        Text("No Lyrics")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.4))
                    } else {
                        LyricsWindowView(
                            lines: entry.lyricsLines,
                            highlightedLineIndex: entry.highlightedLineIndex,
                            lineSpacing: 8,
                            showsTranslation: entry.showsTranslation,
                            translationScope: .everyLine
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                PlaybackControlView(isPlaying: entry.isPlaying)
                    .padding(.bottom, 16)
            }
        }
    }
}
