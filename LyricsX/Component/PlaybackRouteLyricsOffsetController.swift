import Combine
import CoreAudio
import Foundation
import LyricsXFoundation
import MusicPlayer

/// Follows the playback route — the app the current track plays in and the
/// device the system plays sound through — and the lyrics offset set for it,
/// which `Lyrics.adjustedOffset` adds to the lyrics' own offset and the
/// global one.
final class PlaybackRouteLyricsOffsetController {
    static let shared = PlaybackRouteLyricsOffsetController()

    /// The bundle identifier of the app the current track plays in, or `nil`
    /// when no player can be told. Changes on the main queue.
    @Published private(set) var currentPlayerBundleIdentifier: String?

    /// The device the system plays sound through. Changes on the main queue.
    @Published private(set) var currentOutputDevice: AudioOutputDevice?

    /// Every offset set so far. Changes on the main queue.
    @Published private(set) var offsets: PlaybackRouteLyricsOffsets

    /// Sends on the main queue whenever ``currentRouteOffset`` changes.
    let currentRouteOffsetDidChange = PassthroughSubject<Void, Never>()

    private let currentRouteOffsetLock = NSLock()

    private var lockedCurrentRouteOffset = 0

    private var outputDeviceObserver: SystemDefaultAudioOutputDeviceObserver?

    private var cancelBag = Set<AnyCancellable>()

    private init() {
        currentPlayerBundleIdentifier = Self.playerBundleIdentifier(of: selectedPlayer)
        currentOutputDevice = AudioOutputDevice.systemDefault()
        offsets = PlaybackRouteLyricsOffsets(storedData: defaults[.playbackRouteLyricsOffsets])
        lockedCurrentRouteOffset = offsets.offset(for: currentRoute)

        // The handler runs on the main queue, after this initializer is done.
        outputDeviceObserver = SystemDefaultAudioOutputDeviceObserver(queue: .main) { outputDevice in
            let controller = PlaybackRouteLyricsOffsetController.shared
            if outputDevice != controller.currentOutputDevice {
                controller.currentOutputDevice = outputDevice
            }
            controller.updateCurrentRouteOffset()
        }

        // A new track can play in another app — the system-wide now-playing
        // player follows whichever app plays — and a new designated player
        // republishes its track, so the track covers both.
        selectedPlayer.currentTrackWillChange
            .signal()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                let playerBundleIdentifier = Self.playerBundleIdentifier(of: selectedPlayer)
                if playerBundleIdentifier != currentPlayerBundleIdentifier {
                    currentPlayerBundleIdentifier = playerBundleIdentifier
                }
                updateCurrentRouteOffset()
            }
            .store(in: &cancelBag)

        defaults.publisher(for: [.playbackRouteLyricsOffsets])
            .signal()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                let storedOffsets = PlaybackRouteLyricsOffsets(storedData: defaults[.playbackRouteLyricsOffsets])
                if storedOffsets != offsets {
                    offsets = storedOffsets
                }
                updateCurrentRouteOffset()
            }
            .store(in: &cancelBag)
    }

    /// The route the lyrics play through now, or `nil` while the player or
    /// the output device cannot be told.
    var currentRoute: PlaybackRoute? {
        guard let currentPlayerBundleIdentifier, let currentOutputDevice else { return nil }
        return PlaybackRoute(
            playerBundleIdentifier: currentPlayerBundleIdentifier,
            outputDeviceIdentifier: currentOutputDevice.persistentIdentifier
        )
    }

    /// The offset set for the current route, in milliseconds; 0 when there is
    /// none. Safe to read from any thread: the lyrics displays read it on the
    /// lyrics display queue and on every frame.
    var currentRouteOffset: Int {
        currentRouteOffsetLock.lock()
        defer { currentRouteOffsetLock.unlock() }
        return lockedCurrentRouteOffset
    }

    /// Sets the offset for `route`; 0 removes it. Call on the main queue.
    func setOffset(_ offset: Int, for route: PlaybackRoute, playerName: String, outputDeviceName: String) {
        var newOffsets = offsets
        newOffsets.setOffset(offset, for: route, playerName: playerName, outputDeviceName: outputDeviceName)
        store(newOffsets)
    }

    /// Removes the offset set for `route`. Call on the main queue.
    func removeOffset(for route: PlaybackRoute) {
        var newOffsets = offsets
        newOffsets.removeOffset(for: route)
        store(newOffsets)
    }

    private func store(_ newOffsets: PlaybackRouteLyricsOffsets) {
        guard newOffsets != offsets else { return }
        offsets = newOffsets
        defaults[.playbackRouteLyricsOffsets] = newOffsets.storedData
        updateCurrentRouteOffset()
    }

    private func updateCurrentRouteOffset() {
        let newOffset = offsets.offset(for: currentRoute)
        currentRouteOffsetLock.lock()
        let didChange = newOffset != lockedCurrentRouteOffset
        lockedCurrentRouteOffset = newOffset
        currentRouteOffsetLock.unlock()
        if didChange {
            currentRouteOffsetDidChange.send()
        }
    }

    /// The bundle identifier of the app `player` plays its track in, looking
    /// through the players that only pass another one's events on.
    private static func playerBundleIdentifier(of player: MusicPlayerProtocol?) -> String? {
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
}
