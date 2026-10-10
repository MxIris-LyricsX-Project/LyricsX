import AppKit
import ApplicationServices
import MusicPlayer
import ScriptingBridge

/// Fetch artwork omitted by the system Now Playing snapshot without blocking menu tracking.
final class PlaybackArtworkLoader {
    static let shared = PlaybackArtworkLoader()
    private let queue = DispatchQueue(label: "PlaybackArtwork", qos: .utility)
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 8 }

    static func key(for track: MusicTrack, source: MusicPlayerName?) -> String {
        [source?.rawValue ?? "", track.id, track.title ?? "", track.artist ?? "", track.album ?? ""].joined(separator: "\u{1f}")
    }

    func load(_ track: MusicTrack, source: MusicPlayerName?, completion: @escaping (NSImage?) -> Void) {
        let key = Self.key(for: track, source: source) as NSString
        if let image = cache.object(forKey: key) { completion(image); return }
        queue.async { [weak self] in
            guard let self = self else { return }
            if source == nil || source == .appleMusic,
               let object = self.currentTrack(in: "com.apple.Music", matching: track),
               let items = object.value(forKey: "artworks") as? NSArray,
               let first = items.firstObject as? SBObject,
               let image = first.value(forKey: "data") as? NSImage {
                self.finish(image, key: key, completion: completion)
                return
            }
            if source == nil || source == .spotify,
               let object = self.currentTrack(in: "com.spotify.client", matching: track),
               let value = object.value(forKey: "artworkUrl") as? String,
               let url = URL(string: value), url.scheme == "https" {
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                URLSession.shared.dataTask(with: request) { data, response, _ in
                    let image: NSImage?
                    if let response = response as? HTTPURLResponse, response.statusCode == 200,
                       let data = data, data.count <= 10 * 1024 * 1024 {
                        image = NSImage(data: data)
                    } else { image = nil }
                    self.finish(image, key: key, completion: completion)
                }.resume()
                return
            }
            self.finish(nil, key: key, completion: completion)
        }
    }

    private func currentTrack(in bundleID: String, matching expected: MusicTrack) -> SBObject? {
        // Do not launch another player or request a new Automation permission for a cover.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false,
              hasAutomationPermission(for: bundleID),
              let app = SBApplication(bundleIdentifier: bundleID), app.isRunning else { return nil }
        app.timeout = 120 // Apple-event ticks: two seconds, on the utility queue.
        guard let track = app.value(forKey: "currentTrack") as? SBObject,
              Self.matches(expected, title: track.value(forKey: "name") as? String,
                           artist: track.value(forKey: "artist") as? String,
                           album: track.value(forKey: "album") as? String) else { return nil }
        return track
    }

    static func matches(_ track: MusicTrack, title: String?, artist: String?, album: String?) -> Bool {
        func normalized(_ value: String?) -> String {
            (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let expectedTitle = normalized(track.title)
        let expectedArtist = normalized(track.artist)
        guard !expectedTitle.isEmpty, !expectedArtist.isEmpty,
              expectedTitle == normalized(title), expectedArtist == normalized(artist) else { return false }
        let expectedAlbum = normalized(track.album)
        return expectedAlbum.isEmpty || expectedAlbum == normalized(album)
    }

    private func hasAutomationPermission(for bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let result = bytes.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &target) }
        guard result == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) == noErr
    }

    private func finish(_ image: NSImage?, key: NSString, completion: @escaping (NSImage?) -> Void) {
        let image = image.map(Self.thumbnail)
        if let image = image { cache.setObject(image, forKey: key) }
        RunLoop.main.perform(inModes: [.common, .eventTracking]) { completion(image) }
    }

    private static func thumbnail(_ image: NSImage) -> NSImage {
        guard let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let scale = min(1, 144 / CGFloat(max(original.width, original.height)))
        let width = max(1, Int(CGFloat(original.width) * scale))
        let height = max(1, Int(CGFloat(original.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { return image }
        return NSImage(cgImage: result, size: NSSize(width: width, height: height))
    }
}
