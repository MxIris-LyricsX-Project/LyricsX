import Foundation
import Testing
@testable import LyricsXWidgetShared

// WidgetKit runs at most one reload the app asks for every five seconds and
// holds the rest until the five seconds are up, so a reload spent on a change
// that is still under way leaves the widget wrong for the rest of the window.

@Suite("Widget reload policy")
struct WidgetReloadPolicyTests {
    @Test("a track change reloads once, after its lyrics have arrived")
    func trackChangeReloadsOnceWithItsLyrics() throws {
        // Shaped on a track change chronod logged on 2026-10-18. The player
        // first reported the new track as paused, with the previous song's
        // lyrics still loaded; they were cleared half a second later, playback
        // started, and the new lyrics arrived within two seconds. The app
        // reloaded at the first of these, and the widget showed the previous
        // song's lyrics, paused, until the five seconds were up.
        let reloads = reloadTimes(for: [
            (0, .playbackStateChanged(needsSettling: true)),
            (0.494, .trackChanged),
            (0.494, .lyricsChanged(hasLyrics: false)),
            (1.007, .playbackStateChanged(needsSettling: true)),
            (1.821, .lyricsChanged(hasLyrics: true)),
        ])

        #expect(reloads.count == 1)
        let reload = try #require(reloads.first)
        #expect(reload >= 1.821)
        #expect(reload <= 3)
    }

    @Test("a track that gets no lyrics still reloads once the wait for them is over")
    func trackWithoutLyricsReloadsAfterTheWait() {
        let reloads = reloadTimes(for: [
            (0, .trackChanged),
            (0, .lyricsChanged(hasLyrics: false)),
        ])

        #expect(reloads == [2.5])
    }

    @Test("lyrics replaced in two steps reload once, shortly after the second")
    func lyricsReplacedInTwoStepsReloadOnce() throws {
        // Switching to another lyrics candidate clears the current lyrics
        // before the new ones are set.
        let reloads = reloadTimes(for: [
            (0, .lyricsChanged(hasLyrics: false)),
            (0.1, .lyricsChanged(hasLyrics: true)),
        ])

        #expect(reloads.count == 1)
        let reload = try #require(reloads.first)
        #expect(abs(reload - 0.4) < 0.001)
    }

    @Test("a display setting change reloads the widget once, shortly after")
    func displaySettingChangeReloadsShortlyAfter() {
        // Every widget takes its settings from the app, so switching one in
        // the app's preferences is the only way to change what they show.
        let reloads = reloadTimes(for: [(0, .displaySettingsChanged)])

        #expect(reloads == [0.3])
    }

    @Test("a playback change that may still be corrected waits past the track change that may follow it")
    func unsettledPlaybackChangeWaitsForTheTrackChange() throws {
        // The track change in the first test arrived half a second after the
        // pause that opened it.
        let reloads = reloadTimes(for: [(0, .playbackStateChanged(needsSettling: true))])

        #expect(reloads.count == 1)
        let reload = try #require(reloads.first)
        #expect(reload > 0.5)
        #expect(reload <= 1)
    }

    @Test("a plain pause or resume reaches the widget almost at once")
    func settledPlaybackChangeReloadsAlmostAtOnce() throws {
        let reloads = reloadTimes(for: [(0, .playbackStateChanged(needsSettling: false))])

        #expect(reloads.count == 1)
        let reload = try #require(reloads.first)
        #expect(reload <= 0.2)
    }

    @Test("a plain change does not cut short a change that is still settling")
    func settledChangeKeepsTheEarlierWait() throws {
        let reloads = reloadTimes(for: [
            (0, .playbackStateChanged(needsSettling: true)),
            (0.2, .playbackStateChanged(needsSettling: false)),
        ])

        #expect(reloads.count == 1)
        let reload = try #require(reloads.first)
        #expect(reload >= 1)
    }

    @Test("changes that keep coming hold the reload for three seconds at most")
    func changesThatKeepComingAreHeldThreeSecondsAtMost() {
        let changes = stride(from: 0.0, through: 4.5, by: 0.5).map { seconds in
            (seconds: seconds, change: WidgetReloadPolicy.Change.playbackStateChanged(needsSettling: true))
        }

        let reloads = reloadTimes(for: changes)

        #expect(reloads.first == 3)
    }

    @Test("a snapshot taken later in the same playback needs no reload")
    func laterSnapshotOfTheSamePlaybackNeedsNoReload() {
        // The app writes a snapshot on every line change. One taken twelve
        // seconds later, twelve seconds further into the track, lays out the
        // same timeline.
        let delivered = snapshot(takenAt: 100, position: 30)
        let later = snapshot(takenAt: 112, position: 42.1)

        #expect(!WidgetReloadPolicy.snapshotNeedsReload(delivered: delivered, current: later))
    }

    @Test("a change the widget would show needs a reload", arguments: VisibleChange.allCases)
    func visibleChangeNeedsReload(_ change: VisibleChange) {
        #expect(WidgetReloadPolicy.snapshotNeedsReload(delivered: change.delivered, current: change.current))
    }

    @Test("a plain pause or resume needs no settling", arguments: PlaybackReport.plainChanges)
    func plainPlaybackChangeNeedsNoSettling(_ report: PlaybackReport) {
        #expect(!WidgetReloadPolicy.playbackChangeNeedsSettling(
            from: report.previous,
            to: report.current,
            trackDuration: report.trackDuration
        ))
    }

    @Test("a report that the next ones may still correct needs settling", arguments: PlaybackReport.correctableChanges)
    func correctablePlaybackChangeNeedsSettling(_ report: PlaybackReport) {
        #expect(WidgetReloadPolicy.playbackChangeNeedsSettling(
            from: report.previous,
            to: report.current,
            trackDuration: report.trackDuration
        ))
    }
}

/// A playback report and the one before it, positions in seconds into a
/// 240-second track, dates in seconds from the start.
struct PlaybackReport: CustomTestStringConvertible, Sendable {
    let name: String
    let previous: WidgetReloadPolicy.PlaybackMoment?
    let current: WidgetReloadPolicy.PlaybackMoment
    let trackDuration: TimeInterval? = 240

    var testDescription: String {
        name
    }

    static let plainChanges = [
        PlaybackReport(name: "pausing mid-track", previous: playing(at: 90, on: 0), current: paused(at: 95, on: 5)),
        PlaybackReport(name: "resuming where it paused", previous: paused(at: 95, on: 5), current: playing(at: 95.2, on: 20)),
        PlaybackReport(name: "reporting the same pause again", previous: paused(at: 95, on: 5), current: paused(at: 95, on: 5.1)),
    ]

    static let correctableChanges = [
        PlaybackReport(name: "the first report", previous: nil, current: paused(at: 95, on: 0)),
        // The player reports the next track as paused before the track change.
        PlaybackReport(name: "a pause at the start of a track", previous: playing(at: 230, on: 0), current: paused(at: 0.155, on: 10.4)),
        PlaybackReport(name: "a pause at the end of the track", previous: playing(at: 238, on: 0), current: paused(at: 239.5, on: 1.5)),
        // Resuming through MediaRemote first reports a position seconds off.
        PlaybackReport(name: "a resume reporting a stale position", previous: paused(at: 95, on: 5), current: playing(at: 88, on: 20)),
        PlaybackReport(name: "a seek while playing", previous: playing(at: 60, on: 0), current: playing(at: 120, on: 1)),
    ]

    private static func playing(at position: TimeInterval, on seconds: TimeInterval) -> WidgetReloadPolicy.PlaybackMoment {
        WidgetReloadPolicy.PlaybackMoment(isPlaying: true, position: position, date: Date(timeIntervalSinceReferenceDate: seconds))
    }

    private static func paused(at position: TimeInterval, on seconds: TimeInterval) -> WidgetReloadPolicy.PlaybackMoment {
        WidgetReloadPolicy.PlaybackMoment(isPlaying: false, position: position, date: Date(timeIntervalSinceReferenceDate: seconds))
    }
}

enum VisibleChange: CaseIterable {
    case seek
    case pause
    case newLyrics
    case newTrack
    case translationShown
    case nothingDeliveredYet

    var delivered: LyricsWidgetData? {
        switch self {
        case .nothingDeliveredYet:
            nil
        default:
            snapshot(takenAt: 100, position: 30)
        }
    }

    var current: LyricsWidgetData {
        switch self {
        case .seek:
            snapshot(takenAt: 101, position: 61)
        case .pause:
            snapshot(takenAt: 101, position: 31, isPlaying: false)
        case .newLyrics:
            snapshot(takenAt: 101, position: 31, lines: ["Another first line", "Another second line"])
        case .newTrack:
            snapshot(takenAt: 101, position: 31, title: "Another Song")
        case .translationShown:
            snapshot(takenAt: 101, position: 31, showsTranslation: true)
        case .nothingDeliveredYet:
            snapshot(takenAt: 101, position: 31)
        }
    }
}

private func snapshot(
    takenAt seconds: TimeInterval,
    position: TimeInterval,
    isPlaying: Bool = true,
    title: String = "Song",
    lines: [String] = ["First line", "Second line"],
    showsTranslation: Bool = false
) -> LyricsWidgetData {
    LyricsWidgetData(
        trackTitle: title,
        artist: "Artist",
        albumName: "Album",
        backgroundColor: CodableColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
        lyricsLines: lines.enumerated().map { lineIndex, text in
            LyricsLineEntry(text: text, translation: "Translation \(lineIndex)", startTime: TimeInterval(lineIndex * 20), endTime: nil)
        },
        currentLineIndex: 1,
        isPlaying: isPlaying,
        timestamp: Date(timeIntervalSinceReferenceDate: seconds),
        playbackPosition: position,
        showsTranslation: showsTranslation
    )
}

/// Feeds `changes` to a schedule the way the app does, each at its moment, with
/// any reload that falls due before the next change happening first. Returns
/// when the reloads happened, in seconds from the start.
private func reloadTimes(for changes: [(seconds: TimeInterval, change: WidgetReloadPolicy.Change)]) -> [TimeInterval] {
    let origin = Date(timeIntervalSinceReferenceDate: 0)
    var schedule = WidgetReloadPolicy.Schedule()
    var reloadTimes: [TimeInterval] = []

    func reloadWhatFallsDue(by date: Date?) {
        while let reloadDate = schedule.reloadDate, date.map({ reloadDate <= $0 }) ?? true {
            reloadTimes.append(reloadDate.timeIntervalSince(origin))
            schedule.noteReload()
        }
    }

    for (seconds, change) in changes {
        let changeDate = origin.addingTimeInterval(seconds)
        reloadWhatFallsDue(by: changeDate)
        schedule.note(change, at: changeDate)
    }
    reloadWhatFallsDue(by: nil)
    return reloadTimes
}
