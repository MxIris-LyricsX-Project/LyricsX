import WidgetKit
import LyricsXWidgetShared

struct LyricsTimelineProvider: AppIntentTimelineProvider {
    private let dataStore: WidgetDataStore

    init() {
        #if DEBUG
        let groupIdentifier = "D5Q73692VW.group.dev.JH.LyricsX"
        #else
        let groupIdentifier = "D5Q73692VW.group.com.JH.LyricsX"
        #endif
        self.dataStore = WidgetDataStore(groupIdentifier: groupIdentifier)
    }

    func placeholder(in context: Context) -> LyricsTimelineEntry {
        LyricsTimelineEntry(
            date: Date(),
            trackTitle: "Song Title",
            artist: "Artist",
            albumName: "Album",
            backgroundColor: CodableColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0),
            coverImageURL: nil,
            lyricsLines: [
                LyricsLineEntry(text: "Lyrics will appear here", translation: nil, startTime: 0, endTime: nil),
            ],
            highlightedLineIndex: 0,
            isPlaying: true,
            showTranslation: false,
            translationLanguage: nil,
            isEmpty: false
        )
    }

    func snapshot(for configuration: LyricsWidgetConfigurationIntent, in context: Context) async -> LyricsTimelineEntry {
        buildCurrentEntry(for: configuration, at: Date())
    }

    func timeline(for configuration: LyricsWidgetConfigurationIntent, in context: Context) async -> Timeline<LyricsTimelineEntry> {
        guard let widgetData = dataStore.read(), widgetData.isPlaying else {
            // Not playing or no data: single static entry
            let entry = buildCurrentEntry(for: configuration, at: Date())
            return Timeline(entries: [entry], policy: .never)
        }

        // Build time-driven entries from lyrics lines
        let coverURL = dataStore.coverURL
        let showTranslation = configuration.showTranslation
        let translationLanguage = configuration.translationLanguage?.id

        var entries: [LyricsTimelineEntry] = []
        let now = Date()

        for (lineIndex, line) in widgetData.lyricsLines.enumerated() {
            // Calculate when this line should be displayed
            let lineOffset = line.startTime - widgetData.playbackPosition
            let entryDate = widgetData.timestamp.addingTimeInterval(lineOffset)

            // Skip entries in the past (except the most recent one)
            if entryDate < now && lineIndex < widgetData.lyricsLines.count - 1 {
                let nextLineOffset = widgetData.lyricsLines[lineIndex + 1].startTime - widgetData.playbackPosition
                let nextEntryDate = widgetData.timestamp.addingTimeInterval(nextLineOffset)
                if nextEntryDate < now {
                    continue
                }
            }

            let entry = LyricsTimelineEntry(
                date: max(entryDate, now),
                trackTitle: widgetData.trackTitle,
                artist: widgetData.artist,
                albumName: widgetData.albumName,
                backgroundColor: widgetData.backgroundColor,
                coverImageURL: coverURL,
                lyricsLines: widgetData.lyricsLines,
                highlightedLineIndex: lineIndex,
                isPlaying: widgetData.isPlaying,
                showTranslation: showTranslation,
                translationLanguage: translationLanguage,
                isEmpty: false
            )
            entries.append(entry)
        }

        if entries.isEmpty {
            let entry = buildCurrentEntry(for: configuration, at: now)
            return Timeline(entries: [entry], policy: .never)
        }

        return Timeline(entries: entries, policy: .never)
    }

    private func buildCurrentEntry(for configuration: LyricsWidgetConfigurationIntent, at date: Date) -> LyricsTimelineEntry {
        guard let widgetData = dataStore.read() else {
            return .empty
        }

        return LyricsTimelineEntry(
            date: date,
            trackTitle: widgetData.trackTitle,
            artist: widgetData.artist,
            albumName: widgetData.albumName,
            backgroundColor: widgetData.backgroundColor,
            coverImageURL: dataStore.coverURL,
            lyricsLines: widgetData.lyricsLines,
            highlightedLineIndex: widgetData.currentLineIndex,
            isPlaying: widgetData.isPlaying,
            showTranslation: configuration.showTranslation,
            translationLanguage: configuration.translationLanguage?.id,
            isEmpty: false
        )
    }
}
