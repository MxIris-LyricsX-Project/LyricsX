import SwiftUI
import WidgetKit
import LyricsXWidgetShared

struct ExtraLargeWidgetView: View {
    let entry: LyricsTimelineEntry

    private let visibleLineCount = 9

    var body: some View {
        if entry.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if let coverURL = entry.coverImageURL,
                       let nsImage = NSImage(contentsOf: coverURL) {
                        Image(nsImage: nsImage)
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

                Spacer(minLength: 12)

                if !entry.lyricsLines.isEmpty {
                    lyricsSection
                } else {
                    Text("No Lyrics")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer(minLength: 12)

                PlaybackControlView(isPlaying: entry.isPlaying)
                    .padding(.bottom, 16)
            }
        }
    }

    private var lyricsSection: some View {
        let halfWindow = visibleLineCount / 2
        let startIndex = max(0, entry.highlightedLineIndex - halfWindow)
        let endIndex = min(entry.lyricsLines.count - 1, startIndex + visibleLineCount - 1)
        let adjustedStartIndex = max(0, endIndex - visibleLineCount + 1)

        return VStack(spacing: 8) {
            ForEach(adjustedStartIndex...endIndex, id: \.self) { lineIndex in
                let line = entry.lyricsLines[lineIndex]
                let isHighlighted = (lineIndex == entry.highlightedLineIndex)
                LyricsLineView(
                    line: line,
                    isHighlighted: isHighlighted,
                    showTranslation: entry.showTranslation,
                    translationLanguage: entry.translationLanguage
                )
            }
        }
        .padding(.horizontal, 20)
    }
}
