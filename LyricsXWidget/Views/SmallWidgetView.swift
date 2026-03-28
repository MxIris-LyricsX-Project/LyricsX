import SwiftUI
import WidgetKit
import LyricsXWidgetShared

struct SmallWidgetView: View {
    let entry: LyricsTimelineEntry

    var body: some View {
        if entry.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .bottomLeading) {
                if let coverURL = entry.coverImageURL,
                   let nsImage = NSImage(contentsOf: coverURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 20)
                        .overlay(Color.black.opacity(0.4))
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
}
