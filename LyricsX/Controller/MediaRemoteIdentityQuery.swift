import AppKit
import MediaRemoteAdapter

/// Retained by PlaybackSourceRequest, rather than scoped to a single click.
final class MediaRemoteIdentityQuery: PlaybackIdentityQuery {
    private let controller = MediaController()
    var receive: ((PlaybackSourceSnapshot?) -> Void)?

    func request(bundleIdentifiers: [String]) {
        controller.bundleIdentifiers = bundleIdentifiers
        let callback = receive
        controller.onTrackInfoReceived = { info, _ in
            guard let info, let bundleID = info.parentApplicationBundleIdentifier ?? info.bundleIdentifier else {
                callback?(nil)
                return
            }
            var title = info.title, artist = info.artist
            // Apply the same recovery as SystemMedia only to iOS-on-Mac apps.
            // An em dash in a native player's song title is ordinary metadata.
            let app = info.processIdentifier.flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
            if MediaController.isiOSAppOnMac(runningApp: app) {
                for field in [info.title, info.artist] {
                    if let field, let range = field.range(of: " — ") {
                        let recoveredTitle = String(field[..<range.lowerBound])
                        let recoveredArtist = String(field[range.upperBound...])
                        guard !recoveredTitle.isEmpty && !recoveredArtist.isEmpty else { continue }
                        title = recoveredTitle
                        artist = recoveredArtist
                        break
                    }
                }
            }
            callback?(PlaybackSourceSnapshot(title: title, artist: artist, album: info.album,
                                              bundleIdentifier: bundleID, name: info.applicationName))
        }
        controller.updatePlayerState()
    }

    func cancel() {
        controller.onTrackInfoReceived = nil
        controller.stopListening()
    }
}
