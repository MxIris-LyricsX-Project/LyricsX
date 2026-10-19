import Foundation
@preconcurrency import MusicPlayer
import WidgetKit
import LyricsXWidgetShared

/// Turns the app's changes into as few widget reloads as it can, each carrying
/// everything that changed. The rules are `WidgetReloadPolicy`'s; this runs
/// them on `DispatchQueue.lyricsDisplay`, where `AppController` writes the
/// widget's snapshot.
///
/// `@unchecked Sendable` because every stored property is read and written on
/// `DispatchQueue.lyricsDisplay` only, which is serial.
@Loggable(subsystem: "com.JH.LyricsX.diagnostics", category: "WidgetReloadCoordinator")
final class WidgetReloadCoordinator: @unchecked Sendable {
    /// Writes the snapshot the widget reads and returns it, or `nil` when
    /// nothing is playing and the snapshot was cleared. A playback state
    /// passed in is used instead of the player's. Runs on
    /// `DispatchQueue.lyricsDisplay`.
    private let writeSnapshot: (PlaybackState?) -> LyricsWidgetData?

    private var schedule = WidgetReloadPolicy.Schedule()
    private var scheduledReload: DispatchWorkItem?
    /// The snapshot the widget was last reloaded with.
    private var deliveredSnapshot: LyricsWidgetData?
    /// Whether the changes waiting for the next reload include a track change.
    private var pendingChangesIncludeTrackChange = false
    /// Widget skip buttons waiting for their track change to reach the snapshot.
    private var trackChangeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// The player's last report, to tell a plain pause or resume from a report
    /// the next ones may still correct.
    private var previousPlaybackMoment: WidgetReloadPolicy.PlaybackMoment?

    init(writeSnapshot: @escaping (PlaybackState?) -> LyricsWidgetData?) {
        self.writeSnapshot = writeSnapshot
    }

    /// Callable from any thread. The change counts from the moment of the call.
    func note(_ change: WidgetReloadPolicy.Change) {
        guard #available(macOS 14, *) else { return }
        let changeDate = Date()
        DispatchQueue.lyricsDisplay.async { [self] in
            schedule.note(change, at: changeDate)
            if change == .trackChanged {
                pendingChangesIncludeTrackChange = true
            }
            scheduleReload()
        }
    }

    /// A playback report from the player. Callable from any thread, as the
    /// report arrives: a playing position is only meaningful at its moment.
    func notePlaybackState(isPlaying: Bool, position: TimeInterval, trackDuration: TimeInterval?) {
        guard #available(macOS 14, *) else { return }
        let moment = WidgetReloadPolicy.PlaybackMoment(isPlaying: isPlaying, position: position, date: Date())
        DispatchQueue.lyricsDisplay.async { [self] in
            let needsSettling = WidgetReloadPolicy.playbackChangeNeedsSettling(
                from: previousPlaybackMoment,
                to: moment,
                trackDuration: trackDuration
            )
            previousPlaybackMoment = moment
            #log(.info, "[LXWG][Reload] playback report (isPlaying=\(isPlaying, privacy: .public), position=\(position, privacy: .public), needsSettling=\(needsSettling, privacy: .public))")
            schedule.note(.playbackStateChanged(needsSettling: needsSettling), at: moment.date)
            scheduleReload()
        }
    }

    // WidgetKit reloads the widget whose button was pressed when the button's
    // intent returns, and reads the snapshot then. These two return once the
    // snapshot shows what the button did. They also reload every widget, for
    // the other sizes on the desktop: Apple does not say whether the reload
    // after an intent covers them.

    /// For the play/pause button: writes the state the player was just asked
    /// for, ahead of the player reporting it.
    func deliverPlaybackToggle(expectedPlaybackState: PlaybackState) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.lyricsDisplay.async { [self] in
                deliver(writeSnapshot(expectedPlaybackState))
                // Compare with what the player reports once it settles, and
                // reload if it did not do what the button asked.
                schedule.note(.playbackStateChanged(needsSettling: true), at: Date())
                scheduleReload()
                continuation.resume()
            }
        }
    }

    /// For the skip buttons: waits until the next track and its lyrics are
    /// in the snapshot, or `timeout` if no track change comes.
    func waitForTrackChangeDelivery(timeout: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.lyricsDisplay.async { [self] in
                let waiterIdentifier = UUID()
                trackChangeWaiters[waiterIdentifier] = continuation
                DispatchQueue.lyricsDisplay.asyncAfter(deadline: .now() + timeout) { [self] in
                    trackChangeWaiters.removeValue(forKey: waiterIdentifier)?.resume()
                }
            }
        }
    }

    private func scheduleReload() {
        scheduledReload?.cancel()
        scheduledReload = nil
        guard let reloadDate = schedule.reloadDate else { return }
        let reload = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        scheduledReload = reload
        DispatchQueue.lyricsDisplay.asyncAfter(deadline: .now() + max(reloadDate.timeIntervalSinceNow, 0), execute: reload)
    }

    private func reload() {
        scheduledReload = nil
        schedule.noteReload()
        let includesTrackChange = pendingChangesIncludeTrackChange
        pendingChangesIncludeTrackChange = false
        let snapshot = writeSnapshot(nil)
        if let snapshot, !WidgetReloadPolicy.snapshotNeedsReload(delivered: deliveredSnapshot, current: snapshot) {
            #log(.info, "[LXWG][Reload] skipped: the widget already shows this snapshot")
        } else {
            deliver(snapshot)
        }
        if includesTrackChange {
            let waiters = trackChangeWaiters.values
            trackChangeWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func deliver(_ snapshot: LyricsWidgetData?) {
        deliveredSnapshot = snapshot
        WidgetCenter.shared.reloadAllTimelines()
        #log(.info, "[LXWG][Reload] reloadAllTimelines (hasSnapshot=\(snapshot != nil, privacy: .public), isPlaying=\(snapshot?.isPlaying ?? false, privacy: .public), lines=\(snapshot?.lyricsLines.count ?? 0, privacy: .public))")
    }
}
