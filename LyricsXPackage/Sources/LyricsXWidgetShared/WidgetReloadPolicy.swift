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
        /// The player started, paused, stopped or jumped.
        case playbackStateChanged
    }

    /// Collects changes and says when to reload for them.
    public struct Schedule: Sendable {
        /// How long playback has to stay put before a reload. A track change
        /// opens with a pause half a second before the track change itself
        /// arrives, and resuming through the MediaRemote backend reports a
        /// stale position first and the real one up to 0.9 s later.
        public static let playbackSettleInterval: TimeInterval = 1
        /// How long a change to the lyrics waits, so that changes made
        /// together go out in one reload.
        public static let lyricsSettleInterval: TimeInterval = 0.3
        /// How long a track change waits for its lyrics before the widget
        /// shows the track without them.
        public static let lyricsWaitAfterTrackChange: TimeInterval = 2.5
        /// The longest any change waits, however many others keep arriving.
        public static let maximumHold: TimeInterval = 3

        private var firstPendingChangeDate: Date?
        private var lastPlaybackChangeDate: Date?
        private var lastLyricsChangeDate: Date?
        private var trackChangeAwaitingLyricsDate: Date?

        public init() {}

        /// When to reload, or `nil` when nothing has changed since the last
        /// reload.
        public var reloadDate: Date? {
            guard let firstPendingChangeDate else { return nil }
            let settleDates = [
                lastPlaybackChangeDate?.addingTimeInterval(Self.playbackSettleInterval),
                lastLyricsChangeDate?.addingTimeInterval(Self.lyricsSettleInterval),
                trackChangeAwaitingLyricsDate?.addingTimeInterval(Self.lyricsWaitAfterTrackChange),
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
            case .playbackStateChanged:
                lastPlaybackChangeDate = date
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
