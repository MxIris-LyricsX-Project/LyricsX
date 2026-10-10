import AppKit
import MusicPlayer

struct PlaybackSourceSnapshot {
    let title: String?
    let artist: String?
    let album: String?
    let bundleIdentifier: String
    let name: String?

    func matches(_ track: MusicTrack) -> Bool {
        func normalized(_ value: String?) -> String {
            (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        // A source can legitimately omit artist/album (for example, a podcast).
        // Require a title and reject contradictory optional metadata.
        guard !normalized(track.title).isEmpty, normalized(track.title) == normalized(title) else { return false }
        for (expected, actual) in [(track.artist, artist), (track.album, album)] {
            if !normalized(expected).isEmpty && !normalized(actual).isEmpty,
               normalized(expected) != normalized(actual) { return false }
        }
        return !bundleIdentifier.isEmpty
    }
}

protocol PlaybackIdentityQuery: AnyObject {
    var receive: ((PlaybackSourceSnapshot?) -> Void)? { get set }
    func request(bundleIdentifiers: [String])
    func cancel()
}

/// Main-thread owner for a one-shot query. The adapter must remain alive through
/// both the asynchronous reply and its asynchronous process teardown.
final class PlaybackSourceRequest {
    private let query: PlaybackIdentityQuery
    private let timeout: TimeInterval
    private var generation = 0
    private var deadline: Timer?

    init(query: PlaybackIdentityQuery, timeout: TimeInterval = 3) {
        self.query = query
        self.timeout = timeout
    }

    deinit {
        deadline?.invalidate()
        query.receive = nil
        query.cancel()
    }

    func cancel() {
        generation += 1
        deadline?.invalidate()
        deadline = nil
        query.receive = nil
        query.cancel()
    }

    func resolve(track: MusicTrack, bundleIdentifiers: [String], isCurrent: @escaping () -> Bool,
                 completion: @escaping (PlaybackSourceSnapshot?) -> Void) {
        cancel()
        let request = generation
        query.receive = { [weak self] snapshot in
            RunLoop.main.perform(inModes: [.common, .eventTracking]) {
                guard let self, self.generation == request else { return }
                guard isCurrent() else {
                    self.cancel()
                    completion(nil)
                    return
                }
                // A cancelled adapter query may already have queued a reply.
                // Do not let an unrelated/empty snapshot consume this request;
                // the current reply can still arrive before the deadline.
                guard let snapshot, snapshot.matches(track) else { return }
                self.cancel()
                completion(snapshot)
            }
        }
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self, self.generation == request else { return }
            self.cancel()
            completion(nil)
        }
        deadline = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        query.request(bundleIdentifiers: bundleIdentifiers)
    }
}
