import Foundation
import MusicPlayer
import WidgetKit
import LyricsXWidgetShared

/// Turns the app's changes into as few widget reloads as it can, each carrying
/// everything that changed. The rules are `WidgetReloadPolicy`'s; this runs
/// them on `DispatchQueue.lyricsDisplay`, where `AppController` writes the
/// widget's snapshot.
@Loggable(subsystem: "com.JH.LyricsX.diagnostics", category: "WidgetReloadCoordinator")
final class WidgetReloadCoordinator {
    /// Writes the snapshot the widget reads and returns it, or `nil` when
    /// nothing is playing and the snapshot was cleared. A playback state
    /// passed in is used instead of the player's. Runs on
    /// `DispatchQueue.lyricsDisplay`.
    private let writeSnapshot: (PlaybackState?) -> LyricsWidgetData?

    private var schedule = WidgetReloadPolicy.Schedule()
    private var scheduledReload: DispatchWorkItem?
    /// The snapshot the widget was last reloaded with.
    private var deliveredSnapshot: LyricsWidgetData?

    init(writeSnapshot: @escaping (PlaybackState?) -> LyricsWidgetData?) {
        self.writeSnapshot = writeSnapshot
    }

    /// Callable from any thread. The change counts from the moment of the call.
    func note(_ change: WidgetReloadPolicy.Change) {
        guard #available(macOS 14, *) else { return }
        let changeDate = Date()
        DispatchQueue.lyricsDisplay.async { [self] in
            schedule.note(change, at: changeDate)
            scheduleReload()
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
        let snapshot = writeSnapshot(nil)
        if let snapshot, !WidgetReloadPolicy.snapshotNeedsReload(delivered: deliveredSnapshot, current: snapshot) {
            #log(.info, "[LXWG][Reload] skipped: the widget already shows this snapshot")
            return
        }
        deliver(snapshot)
    }

    private func deliver(_ snapshot: LyricsWidgetData?) {
        deliveredSnapshot = snapshot
        WidgetCenter.shared.reloadAllTimelines()
        #log(.info, "[LXWG][Reload] reloadAllTimelines (hasSnapshot=\(snapshot != nil, privacy: .public), isPlaying=\(snapshot?.isPlaying ?? false, privacy: .public), lines=\(snapshot?.lyricsLines.count ?? 0, privacy: .public))")
    }
}
