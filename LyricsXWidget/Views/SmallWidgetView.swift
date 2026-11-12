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
                if let coverImage = entry.coverImage {
                    // The accented mode the unfocused desktop uses would
                    // otherwise paint the opaque cover solid white.
                    Image(decorative: coverImage, scale: 1)
                        .resizable()
                        .widgetAccentedRenderingMode(.fullColor)
                        .aspectRatio(contentMode: .fill)
                }

                CoverScrimView()

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
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}
