import WidgetKit
import SwiftUI
import LyricsXWidgetShared

@main
struct LyricsXWidgetBundle: WidgetBundle {
    var body: some Widget {
        LyricsWidget()
    }
}

struct LyricsWidget: Widget {
    let kind = "com.JH.LyricsX.LyricsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: LyricsWidgetConfigurationIntent.self,
            provider: LyricsTimelineProvider()
        ) { entry in
            LyricsWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: entry.backgroundColor?.gradientColors ?? Color.defaultGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        #if DEBUG
        .configurationDisplayName("LyricsX (DEBUG)")
        .description("[DEBUG BUILD] Display current song lyrics")
        #else
        .configurationDisplayName("LyricsX")
        .description("Display current song lyrics")
        #endif
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct LyricsWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    let entry: LyricsTimelineEntry

    var body: some View {
        contentView
            .modifier(DebugBuildBadge())
    }

    @ViewBuilder
    private var contentView: some View {
        switch widgetFamily {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        case .systemExtraLarge:
            ExtraLargeWidgetView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}

/// Visible-only-in-Debug marker so we can tell at a glance which widget
/// instance on the desktop is running the Debug build (`dev.JH.LyricsX`)
/// vs. the installed Release build (`com.JH.LyricsX`). Remove the
/// modifier call in `LyricsWidgetEntryView.body` when no longer needed.
private struct DebugBuildBadge: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        content.overlay(alignment: .topTrailing) {
            Text("DEBUG")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.red.opacity(0.85), in: Capsule())
                .padding(6)
        }
        #else
        content
        #endif
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    LyricsWidget()
} timeline: {
    LyricsTimelineEntry(
        date: Date(),
        trackTitle: "Bohemian Rhapsody",
        artist: "Queen",
        albumName: "A Night at the Opera",
        backgroundColor: CodableColor(red: 0.15, green: 0.1, blue: 0.25, alpha: 1.0),
        coverImageURL: nil,
        lyricsLines: [],
        highlightedLineIndex: 0,
        isPlaying: true,
        showTranslation: false,
        translationLanguage: nil,
        isEmpty: false
    )
}

#Preview("Large", as: .systemLarge) {
    LyricsWidget()
} timeline: {
    LyricsTimelineEntry(
        date: Date(),
        trackTitle: "Bohemian Rhapsody",
        artist: "Queen",
        albumName: "A Night at the Opera",
        backgroundColor: CodableColor(red: 0.15, green: 0.1, blue: 0.25, alpha: 1.0),
        coverImageURL: nil,
        lyricsLines: [
            LyricsLineEntry(text: "Is this the real life?", translation: nil, startTime: 0, endTime: 5),
            LyricsLineEntry(text: "Is this just fantasy?", translation: nil, startTime: 5, endTime: 10),
            LyricsLineEntry(text: "Caught in a landslide", translation: nil, startTime: 10, endTime: 15),
            LyricsLineEntry(text: "No escape from reality", translation: nil, startTime: 15, endTime: 20),
            LyricsLineEntry(text: "Open your eyes", translation: nil, startTime: 20, endTime: 25),
            LyricsLineEntry(text: "Look up to the skies and see", translation: nil, startTime: 25, endTime: 30),
            LyricsLineEntry(text: "I'm just a poor boy", translation: nil, startTime: 30, endTime: 35),
        ],
        highlightedLineIndex: 3,
        isPlaying: true,
        showTranslation: false,
        translationLanguage: nil,
        isEmpty: false
    )
}
