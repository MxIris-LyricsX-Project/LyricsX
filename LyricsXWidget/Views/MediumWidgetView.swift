import SwiftUI
import WidgetKit
import LyricsXWidgetShared

struct MediumWidgetView: View {
    let entry: LyricsTimelineEntry

    var body: some View {
        if entry.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 16) {
                if let coverURL = entry.coverImageURL,
                   let nsImage = NSImage(contentsOf: coverURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 80, height: 80)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
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

                    if !entry.lyricsLines.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            if entry.highlightedLineIndex < entry.lyricsLines.count {
                                let currentLine = entry.lyricsLines[entry.highlightedLineIndex]
                                Text(currentLine.text)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(1)

                                if entry.showTranslation,
                                   let translation = currentLine.translation,
                                   !translation.isEmpty {
                                    Text(translation)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.6))
                                        .lineLimit(1)
                                }
                            }

                            let nextIndex = entry.highlightedLineIndex + 1
                            if nextIndex < entry.lyricsLines.count {
                                Text(entry.lyricsLines[nextIndex].text)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.35))
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }
}
