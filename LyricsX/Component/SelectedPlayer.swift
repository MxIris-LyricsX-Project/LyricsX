import Foundation
import MusicPlayer
import GenericID
import Combine

extension MusicPlayers {
    final class Selected: Agent {
        static let shared = MusicPlayers.Selected()

        private var defaultsObservation: DefaultsObservation?

        private var manualUpdateObservation: AnyCancellable?

        var manualUpdateInterval: TimeInterval = 1.0 {
            didSet {
                scheduleManualUpdate()
            }
        }

        override init() {
            super.init()
            selectPlayer()
            scheduleManualUpdate()
            self.defaultsObservation = defaults.observe(keys: [.preferredPlayerIndex, .useSystemWideNowPlaying, .systemWideNowPlayingAppList]) { [weak self] in
                self?.selectPlayer()
            }
            self.manualUpdateObservation = playbackStateWillChange.sink { [weak self] state in
                // Apple Music can seek while paused without publishing a new
                // position. Keep the existing poll alive until playback stops.
                if state != .stopped {
                    self?.scheduleManualUpdate()
                } else {
                    self?.scheduleCanceller?.cancel()
                }
            }
        }

        private func selectPlayer() {
            let idx = defaults[.preferredPlayerIndex]
            if idx == -1 {
                if defaults[.useSystemWideNowPlaying] {
                    designatedPlayer = MusicPlayers.SystemMedia(allowsApplicationBundleIdentifiers: defaults[.systemWideNowPlayingAppList])
                } else {
                    let players = MusicPlayerName.scriptableCases.compactMap(MusicPlayers.Scriptable.init)
                    designatedPlayer = MusicPlayers.NowPlaying(players: players)
                }
            } else {
                designatedPlayer = MusicPlayerName(index: idx).flatMap(MusicPlayers.Scriptable.init)
            }
        }

        private var scheduleCanceller: Cancellable?
        func scheduleManualUpdate() {
            scheduleCanceller?.cancel()
            guard manualUpdateInterval > 0 else { return }
            let q = DispatchQueue.global()
            let i: DispatchQueue.SchedulerTimeType.Stride = .seconds(manualUpdateInterval)
            scheduleCanceller = q.schedule(after: q.now.advanced(by: i), interval: i, tolerance: i * 0.1, options: nil) { [unowned self] in
                self.designatedPlayer?.updatePlayerState()
            }
        }
    }
}

extension MusicPlayers.Agent {
    /// The bundle identifier of the app the designated player plays its track
    /// in, looking through the agents that only pass another player's events
    /// on; `nil` when no player can be told.
    var currentPlayerBundleIdentifier: String? {
        playerBundleIdentifier(of: designatedPlayer)
    }
}

private func playerBundleIdentifier(of player: MusicPlayerProtocol?) -> String? {
    switch player {
    case let agent as MusicPlayers.Agent:
        return playerBundleIdentifier(of: agent.designatedPlayer)
    case let scriptable as MusicPlayers.Scriptable:
        return scriptable.playerBundleID
    case let systemMedia as MusicPlayers.SystemMedia:
        return systemMedia.playerBundleID
    default:
        return nil
    }
}

extension MusicPlayers.SystemMedia: Then {}
