import Foundation

/// When the app asks WidgetKit to rebuild the widget's timeline, and whether a
/// new snapshot needs that at all.
///
/// WidgetKit runs at most one reload the app asks for every five seconds. A
/// request that comes sooner is held until the five seconds are up (chronod
/// logs "Throttling additional refresh request while foreground" and sets a
/// timer for the rest of the window). The app used to ask for a reload the
/// moment anything changed, and a track change is a burst of changes: the
/// player reports the new track as paused, the previous song's lyrics are
/// cleared, playback starts and the new lyrics arrive, all within about two
/// seconds. The first request went through at once and showed the wrong
/// state, the rest waited out the window, and every song opened with five
/// seconds of the wrong lyrics. `Schedule` lets a burst settle and reloads
/// once, with all of it.
public enum WidgetReloadPolicy {
    public enum Change: Equatable, Sendable {
        /// The player moved to another track, whose lyrics are on their way.
        case trackChanged
        /// The lyrics were replaced, or cleared when `hasLyrics` is false.
        case lyricsChanged(hasLyrics: Bool)
        /// The player started, paused, stopped or jumped. `needsSettling` when
        /// the reports that follow may still correct it; see
        /// `playbackChangeNeedsSettling(from:to:trackDuration:)`.
        case playbackStateChanged(needsSettling: Bool)
        /// A setting in the app that changes how every widget shows the
        /// lyrics, such as whether it shows their translation.
        case displaySettingsChanged
    }

    /// Where playback stood at one moment, as the player reported it.
    public struct PlaybackMoment: Equatable, Sendable {
        public let isPlaying: Bool
        public let position: TimeInterval
        public let date: Date

        public init(isPlaying: Bool, position: TimeInterval, date: Date) {
            self.isPlaying = isPlaying
            self.position = position
            self.date = date
        }
    }

    /// How close to either end of the track a report counts as part of a track
    /// change.
    public static let trackBoundaryMargin: TimeInterval = 1.5
    /// How far a report can stray from where playback should be and still
    /// carry on from the report before it.
    public static let playbackContinuityTolerance: TimeInterval = 1

    /// Whether the reports that follow a playback change may still correct it,
    /// so the widget should wait for playback to settle before reloading.
    ///
    /// A plain pause, a resume from where playback paused, or the same report
    /// again needs no waiting. Everything else does:
    /// - a report within `trackBoundaryMargin` of either end of the track,
    ///   which may belong to a track change: the player reports the next track
    ///   as paused half a second before the track change itself arrives;
    /// - a report that does not carry on from the one before, such as a seek,
    ///   or the stale position that resuming through MediaRemote reports first;
    /// - the first report, with nothing to carry on from.
    public static func playbackChangeNeedsSettling(
        from previous: PlaybackMoment?,
        to current: PlaybackMoment,
        trackDuration: TimeInterval?
    ) -> Bool {
        guard let previous else { return true }
        let isNearTrackStart = current.position < trackBoundaryMargin
        let isNearTrackEnd = trackDuration.map { current.position > $0 - trackBoundaryMargin } ?? false
        if isNearTrackStart || isNearTrackEnd {
            return true
        }
        let expectedPosition = previous.isPlaying
            ? previous.position + current.date.timeIntervalSince(previous.date)
            : previous.position
        return abs(current.position - expectedPosition) > playbackContinuityTolerance
    }

    /// Collects changes and says when to reload for them.
    public struct Schedule: Sendable {
        /// How long playback has to stay put after a change that may still be
        /// corrected. A track change opens with a pause half a second before
        /// the track change itself arrives, and resuming through the
        /// MediaRemote backend reports a stale position first and the real one
        /// up to 0.9 s later.
        public static let playbackSettleInterval: TimeInterval = 1
        /// How long a plain pause or resume waits: just long enough to fold in
        /// a second report of the same change.
        public static let plainPlaybackChangeInterval: TimeInterval = 0.15
        /// How long a change to the lyrics waits, so that changes made
        /// together go out in one reload.
        public static let lyricsSettleInterval: TimeInterval = 0.3
        /// How long a track change waits for its lyrics before the widget
        /// shows the track without them.
        public static let lyricsWaitAfterTrackChange: TimeInterval = 2.5
        /// How long a change to a display setting waits, so that a setting
        /// switched off and on again goes out in one reload.
        public static let displaySettingsSettleInterval: TimeInterval = 0.3
        /// The longest any change waits, however many others keep arriving.
        public static let maximumHold: TimeInterval = 3

        private var firstPendingChangeDate: Date?
        private var playbackSettledDate: Date?
        private var lastLyricsChangeDate: Date?
        private var trackChangeAwaitingLyricsDate: Date?
        private var lastDisplaySettingsChangeDate: Date?

        public init() {}

        /// When to reload, or `nil` when nothing has changed since the last
        /// reload.
        public var reloadDate: Date? {
            guard let firstPendingChangeDate else { return nil }
            let settleDates = [
                playbackSettledDate,
                lastLyricsChangeDate?.addingTimeInterval(Self.lyricsSettleInterval),
                trackChangeAwaitingLyricsDate?.addingTimeInterval(Self.lyricsWaitAfterTrackChange),
                lastDisplaySettingsChangeDate?.addingTimeInterval(Self.displaySettingsSettleInterval),
            ].compactMap { $0 }
            let settledDate = settleDates.max() ?? firstPendingChangeDate
            return min(settledDate, firstPendingChangeDate.addingTimeInterval(Self.maximumHold))
        }

        public mutating func note(_ change: Change, at date: Date) {
            if firstPendingChangeDate == nil {
                firstPendingChangeDate = date
            }
            switch change {
            case .trackChanged:
                trackChangeAwaitingLyricsDate = date
            case .lyricsChanged(let hasLyrics):
                lastLyricsChangeDate = date
                if hasLyrics {
                    trackChangeAwaitingLyricsDate = nil
                }
            case .playbackStateChanged(let needsSettling):
                // A plain change never shortens the wait for one still settling.
                let settledDate = date.addingTimeInterval(
                    needsSettling ? Self.playbackSettleInterval : Self.plainPlaybackChangeInterval
                )
                playbackSettledDate = max(playbackSettledDate ?? settledDate, settledDate)
            case .displaySettingsChanged:
                lastDisplaySettingsChangeDate = date
            }
        }

        /// Starts over: everything noted so far has gone out in a reload.
        public mutating func noteReload() {
            self = Schedule()
        }
    }

    /// How far apart two snapshots can put the lyrics and still show the same
    /// line at the same moment, as far as anyone can tell.
    public static let playbackPositionTolerance: TimeInterval = 0.25

    /// Whether a widget built from `current` would show anything a widget
    /// built from `delivered` does not. The app writes a snapshot on every
    /// line change, so most snapshots differ from the one last reloaded only
    /// in when they were taken.
    public static func snapshotNeedsReload(delivered: LyricsWidgetData?, current: LyricsWidgetData) -> Bool {
        guard let delivered else { return true }
        guard delivered.trackTitle == current.trackTitle,
              delivered.artist == current.artist,
              delivered.albumName == current.albumName,
              delivered.backgroundColor == current.backgroundColor,
              delivered.lyricsLines == current.lyricsLines,
              delivered.showsTranslation == current.showsTranslation,
              delivered.availableTranslationLanguages == current.availableTranslationLanguages,
              delivered.isPlaying == current.isPlaying
        else {
            return true
        }
        guard current.isPlaying else {
            // A paused widget shows a single entry, at the current line.
            return delivered.currentLineIndex != current.currentLineIndex
        }
        // A playing widget lays its timeline out from the moment the track
        // was at the start.
        let trackStartDifference = current.trackStartDate.timeIntervalSince(delivered.trackStartDate)
        return abs(trackStartDifference) > playbackPositionTolerance
    }
}

extension LyricsWidgetData {
    /// When the track was at position zero, had it played straight through.
    var trackStartDate: Date {
        timestamp.addingTimeInterval(-playbackPosition)
    }
}
