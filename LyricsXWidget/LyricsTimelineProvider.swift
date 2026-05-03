import WidgetKit
import LyricsXWidgetShared

@Loggable(subsystem: "com.JH.LyricsX.diagnostics", category: "LyricsTimelineProvider")
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
        let entry = buildCurrentEntry(for: configuration, at: Date())
        #log(.info, "[LXWG][Provider] snapshot returned (isEmpty=\(entry.isEmpty, privacy: .public), isPlaying=\(entry.isPlaying, privacy: .public), highlight=\(entry.highlightedLineIndex, privacy: .public))")
        return entry
    }

    func timeline(for configuration: LyricsWidgetConfigurationIntent, in context: Context) async -> Timeline<LyricsTimelineEntry> {
        let snapshot = dataStore.read()
        #log(.info, "[LXWG][Provider] timeline(for:) called (hasData=\(snapshot != nil, privacy: .public), isPlaying=\(snapshot?.isPlaying ?? false, privacy: .public), playbackPosition=\(snapshot?.playbackPosition ?? -1, privacy: .public), lineIndex=\(snapshot?.currentLineIndex ?? -1, privacy: .public), lines=\(snapshot?.lyricsLines.count ?? 0, privacy: .public))")

        guard let widgetData = snapshot, widgetData.isPlaying else {
            // Not playing or no data: single static entry
            let entry = buildCurrentEntry(for: configuration, at: Date())
            #log(.info, "[LXWG][Provider] static branch → 1 entry (reason=\(snapshot == nil ? "noData" : "paused", privacy: .public))")
            return Timeline(entries: [entry], policy: .never)
        }

        // Build time-driven entries from lyrics lines
        let coverURL = dataStore.coverURL
        let showTranslation = configuration.showTranslation
        let translationLanguage = configuration.translationLanguage?.id
        let schedulingCompensation = Self.widgetSchedulingCompensation

        var entries: [LyricsTimelineEntry] = []
        let now = Date()

        // Only generate entries that fall inside a rolling window. With
        // `policy: .after(windowEnd)` below, WidgetKit re-asks for a
        // fresh timeline at the window's end — that keeps the widget's
        // displayed line continuously re-anchored to the current
        // (timestamp, playbackPosition), so accumulated drift between
        // WidgetKit's scheduler clock and actual playback can't grow
        // past the window length. Empirically a 60s window keeps the
        // visible line within a frame of the live track without
        // spending excessive WidgetKit refresh budget.
        let timelineWindow: TimeInterval = 60
        let windowEnd = now.addingTimeInterval(timelineWindow)

        for (lineIndex, line) in widgetData.lyricsLines.enumerated() {
            // Calculate when this line should be displayed.
            // Subtract schedulingCompensation so WidgetKit fires the
            // entry transition early enough that the actual on-screen
            // update lands near `timestamp + lineOffset`.
            let lineOffset = line.startTime - widgetData.playbackPosition
            let entryDate = widgetData.timestamp.addingTimeInterval(lineOffset - schedulingCompensation)

            // Stop once we leave the rolling window — anything further
            // out will be regenerated from a more accurate baseline at
            // the next refetch.
            if entryDate > windowEnd {
                break
            }

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
            #log(.info, "[LXWG][Provider] dynamic branch produced 0 entries → fallback static (1 entry, refresh after window)")
            return Timeline(entries: [entry], policy: .after(windowEnd))
        }

        // Drop entries whose visible window would be too short to render.
        // LRC files frequently contain adjacent lines with near-identical
        // startTimes (chorus repeats, dual-language tracks split into two
        // lines, or just timestamp typos) — observed gaps as small as
        // 20ms. WidgetKit's scheduler + the SwiftUI rendering pipeline
        // can't honor sub-frame transitions, so the line ends up
        // appearing "skipped" to the user. We keep the later of any two
        // entries within `minDisplayDuration` so the visible line is the
        // one that actually has time to display.
        let minDisplayDuration: TimeInterval = 0.4
        let originalCount = entries.count
        var filtered: [LyricsTimelineEntry] = []
        filtered.reserveCapacity(entries.count)
        for index in 0..<entries.count {
            if index + 1 < entries.count {
                let gap = entries[index + 1].date.timeIntervalSince(entries[index].date)
                if gap < minDisplayDuration {
                    continue
                }
            }
            filtered.append(entries[index])
        }
        let droppedCount = originalCount - filtered.count
        entries = filtered

        let firstDate = entries.first?.date.timeIntervalSince(now) ?? 0
        let lastDate = entries.last?.date.timeIntervalSince(now) ?? 0
        let preview = entries.prefix(8).map { entry in
            String(format: "@+%.2fs#%d", entry.date.timeIntervalSince(now), entry.highlightedLineIndex)
        }.joined(separator: " ")
        #log(.info, "[LXWG][Provider] dynamic branch → \(entries.count, privacy: .public) entries (dropped=\(droppedCount, privacy: .public) sub-\(minDisplayDuration, privacy: .public)s, window=\(timelineWindow, privacy: .public)s), first=+\(firstDate, privacy: .public)s last=+\(lastDate, privacy: .public)s, compensation=\(schedulingCompensation, privacy: .public)s, preview=\(preview, privacy: .public)")
        return Timeline(entries: entries, policy: .after(windowEnd))
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
