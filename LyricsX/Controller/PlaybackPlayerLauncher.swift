import AppKit
import MediaRemoteAdapter
import MusicPlayer

/// Separate instances for menu labels and opening apps: closing the menu must
/// cancel its label query without cancelling a click that opens the source app.
final class PlaybackPlayerLauncher {
    private let request = PlaybackSourceRequest(query: MediaRemoteIdentityQuery())

    func cancel() { request.cancel() }

    func resolve(_ player: MusicPlayerProtocol, completion: @escaping (PlaybackSourceSnapshot?) -> Void) {
        request.cancel()
        guard let source = PlaybackCommandDispatcher.source(of: player) else { completion(nil); return }
        if let scriptable = source as? MusicPlayers.Scriptable {
            completion(PlaybackSourceSnapshot(title: player.currentTrack?.title, artist: player.currentTrack?.artist,
                                              album: player.currentTrack?.album, bundleIdentifier: scriptable.playerBundleID,
                                              name: player.name?.rawValue))
            return
        }
        guard let system = source as? MusicPlayers.SystemMedia, let expected = player.currentTrack else {
            completion(nil)
            return
        }
        let key = PlaybackArtworkLoader.key(for: expected, source: player.name)
        request.resolve(track: expected, bundleIdentifiers: system.allowsApplicationBundleIdentifiers, isCurrent: { [weak player, weak source] in
            guard let player, let source, PlaybackCommandDispatcher.source(of: player) === source,
                  let track = player.currentTrack else { return false }
            return PlaybackArtworkLoader.key(for: track, source: player.name) == key
        }, completion: completion)
    }

    func resolveName(_ player: MusicPlayerProtocol, completion: @escaping (String?) -> Void) {
        resolve(player) { snapshot in
            guard let snapshot else { completion(nil); return }
            if snapshot.bundleIdentifier == "com.apple.Music" { completion("Apple Music"); return }
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: snapshot.bundleIdentifier).first?.localizedName
            completion(name ?? snapshot.name)
        }
    }

    func open(_ player: MusicPlayerProtocol) {
        resolve(player) { snapshot in
            guard let snapshot, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: snapshot.bundleIdentifier) else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        }
    }
}
