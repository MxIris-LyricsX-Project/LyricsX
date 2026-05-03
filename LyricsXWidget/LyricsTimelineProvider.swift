import WidgetKit
import LyricsXWidgetShared

struct LyricsTimelineProvider: AppIntentTimelineProvider {
    #if DEBUG
    private static let groupIdentifier = "D5Q73692VW.group.dev.JH.LyricsX"
    #else
    private static let groupIdentifier = "D5Q73692VW.group.com.JH.LyricsX"
    #endif

    /// Empirical compensation for the latency between WidgetKit's
    /// `entry.date` firing and the desktop actually picking up the new
    /// rendered snapshot. We pull every future entry forward by this
    /// much so the visible line transition lands close to the actual
    /// lyric timing instead of trailing it.
    ///
    /// Override at runtime without recompiling:
    ///   defaults write D5Q73692VW.group.com.JH.LyricsX \
    ///       WidgetSchedulingCompensationMs -int 800
    /// (use the `dev.JH.LyricsX` suite for Debug builds)
    /// then nudge the widget (re-add it, or toggle Apple Music) so
    /// WidgetKit pulls a fresh timeline.
    private static let defaultWidgetSchedulingCompensationMs = 600
    private static let compensationOverrideKey = "WidgetSchedulingCompensationMs"

    private static var widgetSchedulingCompensation: TimeInterval {
        let overrideMs = UserDefaults(suiteName: groupIdentifier)?
            .object(forKey: compensationOverrideKey) as? Int
        return TimeInterval(overrideMs ?? defaultWidgetSchedulingCompensationMs) / 1000
    }

    private let dataStore: WidgetDataStore

    init() {
        self.dataStore = WidgetDataStore(groupIdentifier: Self.groupIdentifier)
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
        let schedulingCompensation = Self.widgetSchedulingCompensation

        var entries: [LyricsTimelineEntry] = []
        let now = Date()

        for (lineIndex, line) in widgetData.lyricsLines.enumerated() {
            // Calculate when this line should be displayed.
            // Subtract schedulingCompensation so WidgetKit fires the
            // entry transition early enough that the actual on-screen
            // update lands near `timestamp + lineOffset`.
            let lineOffset = line.startTime - widgetData.playbackPosition
            let entryDate = widgetData.timestamp.addingTimeInterval(lineOffset - schedulingCompensation)

            // Skip entries in the past (except the most recent one)
            if entryDate < now && lineIndex < widgetData.lyricsLines.count - 1 {
                let nextLineOffset = widgetData.lyricsLines[lineIndex + 1].startTime - widgetData.playbackPosition
                let nextEntryDate = widgetData.timestamp.addingTimeInterval(nextLineOffset - schedulingCompensation)
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
