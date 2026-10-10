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
            self.defaultsObservation = defaults.observe(keys: [.preferredPlayerIndex, .useSystemWideNowPlaying, .systemWideNowPlayingAppList, .phoneBluetoothEnabled]) { [weak self] in
                self?.selectPlayer()
            }
            self.manualUpdateObservation = playbackStateWillChange.sink { [weak self] state in
                if state.isPlaying {
                    self?.scheduleManualUpdate()
                } else {
                    self?.scheduleCanceller?.cancel()
                }
            }
        }

        private func selectPlayer() {
            let bluetoothEnabled = defaults[.phoneBluetoothEnabled]
            let preferredIndex = defaults[.preferredPlayerIndex]
            // Keep the saved preference, but use local automatic selection while AVRCP is off.
            let idx = preferredIndex == PhonePlayer.preferenceIndex && !bluetoothEnabled ? -1 : preferredIndex
            PhonePlayer.shared.setEnabled(bluetoothEnabled)
            PhonePlayer.shared.setActive(bluetoothEnabled && (idx == -1 || idx == PhonePlayer.preferenceIndex))
            if idx == PhonePlayer.preferenceIndex {
                designatedPlayer = PhonePlayer.shared
            } else if idx == -1 && !bluetoothEnabled {
                if defaults[.useSystemWideNowPlaying] {
                    designatedPlayer = MusicPlayers.SystemMedia(allowsApplicationBundleIdentifiers: defaults[.systemWideNowPlayingAppList])
                } else {
                    designatedPlayer = MusicPlayers.NowPlaying(players: MusicPlayerName.scriptableCases.compactMap(MusicPlayers.Scriptable.init))
                }
            } else if idx == -1 {
                var players: [MusicPlayerProtocol]
                if defaults[.useSystemWideNowPlaying] {
                    players = MusicPlayers.SystemMedia(allowsApplicationBundleIdentifiers: defaults[.systemWideNowPlayingAppList]).map { [$0] } ?? []
                } else {
                    players = MusicPlayerName.scriptableCases.compactMap(MusicPlayers.Scriptable.init)
                }
                designatedPlayer = AutomaticPlayer(players: players + [PhonePlayer.shared], mainThreadPlayers: [PhonePlayer.shared])
            } else {
                designatedPlayer = MusicPlayerName(index: idx).flatMap(MusicPlayers.Scriptable.init)
            }
            scheduleManualUpdate()
        }

        var activePlayer: MusicPlayerProtocol? {
            var player = designatedPlayer
            var visited = Set<ObjectIdentifier>()
            while let agent = player as? MusicPlayers.Agent {
                guard visited.insert(ObjectIdentifier(agent)).inserted else { return nil }
                player = agent.designatedPlayer
            }
            return player
        }

        private var scheduleCanceller: Cancellable?
        func scheduleManualUpdate() {
            scheduleCanceller?.cancel()
            // AutomaticPlayer keeps discovery alive even when playback pauses.
            // Do not create a second candidate-refresh timer here.
            guard !(designatedPlayer is AutomaticPlayer) else { return }
            guard manualUpdateInterval > 0 else { return }
            let q = designatedPlayer is PhonePlayer ? DispatchQueue.main : DispatchQueue.global()
            let i: DispatchQueue.SchedulerTimeType.Stride = .seconds(manualUpdateInterval)
            scheduleCanceller = q.schedule(after: q.now.advanced(by: i), interval: i, tolerance: i * 0.1, options: nil) { [unowned self] in
                self.designatedPlayer?.updatePlayerState()
            }
        }
    }
}

extension MusicPlayers.SystemMedia: Then {}
