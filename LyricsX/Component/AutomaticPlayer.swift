import Combine
import Foundation
import MusicPlayer

/// Observe every candidate, including when the currently selected source pauses.
/// Keep the selected source stable unless another source is playing.
final class AutomaticPlayer: MusicPlayers.Agent {
    private let players: [MusicPlayerProtocol]
    private var observations = Set<AnyCancellable>()
    private var refreshObservation: AnyCancellable?
    private let refreshQueues: [ObjectIdentifier: DispatchQueue]
    private let mainThreadPlayers: Set<ObjectIdentifier>
    private var refreshing = Set<ObjectIdentifier>()

    init(players: [MusicPlayerProtocol], mainThreadPlayers: [MusicPlayerProtocol] = [], refreshInterval: TimeInterval = 1) {
        self.players = players
        self.refreshQueues = Dictionary(uniqueKeysWithValues: players.enumerated().map { index, player in
            (ObjectIdentifier(player), DispatchQueue(label: "AutomaticPlayerRefresh.\(index)", qos: .utility))
        })
        self.mainThreadPlayers = Set(mainThreadPlayers.map(ObjectIdentifier.init))
        super.init()
        for player in players {
            player.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.selectPlayer() }
                .store(in: &observations)
        }
        selectPlayer()
        // Discovery belongs to the automatic selector, not the selected
        // player's playback clock. A paused phone must not stop us discovering
        // a local player whose notifications are delayed or unavailable.
        if refreshInterval.isFinite && refreshInterval > 0 {
            let queue = DispatchQueue.main
            let interval: DispatchQueue.SchedulerTimeType.Stride = .seconds(refreshInterval)
            refreshObservation = AnyCancellable(queue.schedule(
                after: queue.now.advanced(by: interval), interval: interval,
                tolerance: interval * 0.1
            ) { [weak self] in
                self?.refreshCandidates()
            })
        }
    }

    private func selectPlayer() {
        let next: MusicPlayerProtocol?
        if (designatedPlayer as? PlaybackTransitionSource)?.isChangingTrack == true {
            // Missing metadata during a skip is not a stopped source. In
            // particular, do not flash a paused local song between phone songs.
            next = designatedPlayer
        } else if designatedPlayer?.playbackState.isPlaying == true
            && (designatedPlayer as? PlaybackTransitionSource)?.isLoadingTrack != true {
            next = designatedPlayer
        } else if let playing = players.first(where: { $0.playbackState.isPlaying && ($0 as? PlaybackTransitionSource)?.isLoadingTrack != true }) {
            next = playing
        } else if designatedPlayer == nil {
            // Initial discovery has no focus to preserve. Keep upstream's ability
            // to display a paused song before anything starts playing.
            next = players.first {
                $0.currentTrack != nil && $0.playbackState != .stopped
                    && ($0 as? PlaybackTransitionSource)?.isLoadingTrack != true
            }
        } else {
            // Paused content is not a reason to transfer selection, including
            // when the current source is empty between tracks or disconnects.
            next = designatedPlayer
        }
        if next !== designatedPlayer { designatedPlayer = next }
    }

    func refreshCandidates() {
        // Candidates deliver their own notifications while idle. An explicit
        // refresh also catches sources that were not previously selected.
        for player in players {
            let identity = ObjectIdentifier(player)
            if mainThreadPlayers.contains(identity) {
                player.updatePlayerState()
                continue
            }
            guard refreshing.insert(identity).inserted else { continue }
            refreshQueues[identity]?.async { [weak self] in
                guard self != nil else { return }
                player.updatePlayerState()
                RunLoop.main.perform(inModes: [.common, .eventTracking]) { [weak self] in
                    self?.refreshing.remove(identity)
                    self?.selectPlayer()
                }
            }
        }
        selectPlayer()
    }
}
