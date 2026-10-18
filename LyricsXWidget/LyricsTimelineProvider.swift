import ImageIO
import WidgetKit
import LyricsXWidgetShared

/// Builds every widget's timeline from the snapshot the app writes.
///
/// The widget has no settings of its own, on purpose: anything it can show
/// two ways, such as translations, follows a setting in the app that comes in
/// the snapshot. WidgetKit splits a reload the app asks for into one request
/// per widget configuration and runs one every five seconds, so each widget
/// edited into a configuration of its own put the others five seconds behind.
/// Documentations/Internal/DesktopWidget.md has the measurements.
@Loggable(subsystem: "com.JH.LyricsX.diagnostics", category: "LyricsTimelineProvider")
struct LyricsTimelineProvider: TimelineProvider {
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
    /// On macOS 27.2 (2026-10-18) NotificationCenter switched to each entry
    /// a median 0.78 s after its date: 36 line changes per widget size, nine
    /// in ten between 0.22 s and 1.24 s. 0.8 s centres the line change on
    /// the lyric. The spread is beyond any compensation: the host fires on
    /// timers the system coalesces, often onto the next whole second.
    ///
    /// Override at runtime without recompiling, in the app group's
    /// preferences inside its container, the file the widget reads its
    /// snapshot from (a plain `defaults write <group>` writes to
    /// ~/Library/Preferences, which the sandboxed widget never reads):
    ///   defaults write ~/Library/Group\ Containers/D5Q73692VW.group.com.JH.LyricsX/Library/Preferences/D5Q73692VW.group.com.JH.LyricsX \
    ///       WidgetSchedulingCompensationMs -int 900
    /// (use the `dev.JH.LyricsX` group for Debug builds)
    /// then nudge the widget (re-add it, or toggle Apple Music) so
    /// WidgetKit pulls a fresh timeline.
    private static let defaultWidgetSchedulingCompensationMs = 800
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
            coverImage: nil,
            lyricsLines: [
                LyricsLineEntry(text: "Lyrics will appear here", translation: nil, startTime: 0, endTime: nil),
            ],
            highlightedLineIndex: 0,
            isPlaying: true,
            showsTranslation: false,
            isEmpty: false
        )
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (LyricsTimelineEntry) -> Void) {
        let entry = buildCurrentEntry(at: Date())
        #log(.info, "[LXWG][Provider] snapshot returned (isEmpty=\(entry.isEmpty, privacy: .public), isPlaying=\(entry.isPlaying, privacy: .public), highlight=\(entry.highlightedLineIndex, privacy: .public))")
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<LyricsTimelineEntry>) -> Void) {
        completion(makeTimeline())
    }

    private func makeTimeline() -> Timeline<LyricsTimelineEntry> {
        let snapshot = dataStore.read()
        #log(.info, "[LXWG][Provider] getTimeline(in:) called (hasData=\(snapshot != nil, privacy: .public), isPlaying=\(snapshot?.isPlaying ?? false, privacy: .public), playbackPosition=\(snapshot?.playbackPosition ?? -1, privacy: .public), lineIndex=\(snapshot?.currentLineIndex ?? -1, privacy: .public), lines=\(snapshot?.lyricsLines.count ?? 0, privacy: .public))")

        guard let widgetData = snapshot, widgetData.isPlaying else {
            // Not playing or no data: single static entry
            let entry = buildCurrentEntry(at: Date())
            #log(.info, "[LXWG][Provider] static branch → 1 entry (reason=\(snapshot == nil ? "noData" : "paused", privacy: .public))")
            return Timeline(entries: [entry], policy: .never)
        }

        // Build time-driven entries from lyrics lines
        let coverImage = loadCoverImage()
        let schedulingCompensation = Self.widgetSchedulingCompensation

        var entries: [LyricsTimelineEntry] = []
        let now = Date()

        // Only generate entries that fall inside a rolling window. With
        // `policy: .after(refreshDate)` below, WidgetKit re-asks for a
        // fresh timeline before the window ends — that keeps the widget's
        // displayed line continuously re-anchored to the current
        // (timestamp, playbackPosition), so accumulated drift between
        // WidgetKit's scheduler clock and actual playback can't grow
        // past the window length. Empirically a 60s window keeps the
        // visible line within a frame of the live track without
        // spending excessive WidgetKit refresh budget.
        //
        // The refresh comes `refreshLeadTime` before the window ends, so the
        // old timeline still has lines while the new one is made. chronod
        // asks for it about 4 s after the refresh date and renders it for
        // 1–2 s more; refreshing at the window's very end left the widget on
        // the last line for that long, once a minute (2026-10-18: the large
        // widget changed no line from 19:43:10 to 19:43:17).
        let timelineWindow: TimeInterval = 60
        let refreshLeadTime: TimeInterval = 15
        let windowEnd = now.addingTimeInterval(timelineWindow)
        let refreshDate = windowEnd.addingTimeInterval(-refreshLeadTime)

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
                coverImage: coverImage,
                lyricsLines: widgetData.lyricsLines,
                highlightedLineIndex: lineIndex,
                isPlaying: widgetData.isPlaying,
                showsTranslation: widgetData.showsTranslation,
                isEmpty: false
            )
            entries.append(entry)
        }

        if entries.isEmpty {
            let entry = buildCurrentEntry(at: now)
            #log(.info, "[LXWG][Provider] dynamic branch produced 0 entries → fallback static (1 entry, refresh after window)")
            return Timeline(entries: [entry], policy: .after(refreshDate))
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
        return Timeline(entries: entries, policy: .after(refreshDate))
    }

    /// The album cover the app wrote, decoded once for a whole timeline. Every
    /// entry used to read and decode the file again as it was rendered, and a
    /// reload renders every entry of every widget size before any of them
    /// shows.
    private func loadCoverImage() -> CGImage? {
        guard let coverURL = dataStore.coverURL,
              let imageSource = CGImageSourceCreateWithURL(coverURL as CFURL, nil)
        else {
            return nil
        }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(imageSource, 0, options)
    }

    private func buildCurrentEntry(at date: Date) -> LyricsTimelineEntry {
        guard let widgetData = dataStore.read() else {
            return .empty
        }

        return LyricsTimelineEntry(
            date: date,
            trackTitle: widgetData.trackTitle,
            artist: widgetData.artist,
            albumName: widgetData.albumName,
            backgroundColor: widgetData.backgroundColor,
            coverImage: loadCoverImage(),
            lyricsLines: widgetData.lyricsLines,
            highlightedLineIndex: widgetData.currentLineIndex,
            isPlaying: widgetData.isPlaying,
            showsTranslation: widgetData.showsTranslation,
            isEmpty: false
        )
    }
}
