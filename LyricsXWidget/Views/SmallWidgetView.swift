import SwiftUI
import WidgetKit
import LyricsXWidgetShared

struct SmallWidgetView: View {
    let entry: LyricsTimelineEntry

    var body: some View {
        if entry.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(gradientBackground)
        } else {
            ZStack(alignment: .bottomLeading) {
                if let coverURL = entry.coverImageURL,
                   let nsImage = NSImage(contentsOf: coverURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 20)
                        .overlay(Color.black.opacity(0.4))
                } else {
                    gradientBackground
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.trackTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(entry.artist)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .padding(12)
            }
        }
    }

    private var gradientBackground: some View {
        LinearGradient(
            colors: entry.backgroundColor?.gradientColors ?? Color.defaultGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
