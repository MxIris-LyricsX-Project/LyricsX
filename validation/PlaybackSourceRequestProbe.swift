import AppKit
import Combine
import MusicPlayer

private final class Query: PlaybackIdentityQuery {
    var receive: ((PlaybackSourceSnapshot?) -> Void)?
    var requests = 0
    var cancellations = 0
    func request(bundleIdentifiers: [String]) { requests += 1 }
    func cancel() { cancellations += 1 }
}

private final class Player: MusicPlayerProtocol {
    var name: MusicPlayerName? { nil }
    var currentTrack: MusicTrack? { nil }
    var playbackState: PlaybackState { .stopped }
    var playbackTime: TimeInterval = 0
    let objectWillChange = ObservableObjectPublisher()
    var currentTrackWillChange: AnyPublisher<MusicTrack?, Never> { Empty().eraseToAnyPublisher() }
    var playbackStateWillChange: AnyPublisher<PlaybackState, Never> { Empty().eraseToAnyPublisher() }
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var updates = 0
    var wasMain = false
    var shouldWait = true
    func updatePlayerState() {
        updates += 1
        wasMain = Thread.isMainThread
        started.signal()
        if shouldWait { _ = release.wait(timeout: .now() + 2) }
    }
    func resume() {}
    func pause() {}
    func skipToNextItem() {}
    func skipToPreviousItem() {}
}

@main private enum PlaybackSourceRequestProbe {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
            count += 1
            print("PASS: \(message)")
        }
        func pump(_ duration: TimeInterval = 0.04) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
        let track = MusicTrack(id: "1", title: "Episode", album: nil, artist: nil)
        let snapshot = PlaybackSourceSnapshot(title: "Episode", artist: nil, album: nil,
                                              bundleIdentifier: "test.player", name: "Player")
        check(snapshot.matches(track), "source identity accepts a title without artist")
        check(!snapshot.matches(MusicTrack(id: "2", title: "Other", album: nil, artist: nil)), "different titles are rejected")
        let song = MusicTrack(id: "3", title: "Episode", album: "Album", artist: "Artist")
        let wrong = PlaybackSourceSnapshot(title: "Episode", artist: "Other", album: "Album", bundleIdentifier: "test", name: nil)
        check(!wrong.matches(song), "contradictory optional metadata is rejected")
        var query: Query? = Query()
        weak var retainedQuery = query
        var request: PlaybackSourceRequest? = PlaybackSourceRequest(query: query!, timeout: 0.08)
        var replies: [PlaybackSourceSnapshot?] = []
        request?.resolve(track: track, bundleIdentifiers: [], isCurrent: { true }) { replies.append($0) }
        query = nil
        check(retainedQuery != nil, "request owner retains the asynchronous adapter")
        retainedQuery?.receive?(snapshot)
        pump()
        check(replies.count == 1 && replies[0]?.bundleIdentifier == "test.player", "late asynchronous reply resolves source")
        check(retainedQuery?.receive == nil, "completed request detaches callback")
        request?.resolve(track: track, bundleIdentifiers: [], isCurrent: { true }) { replies.append($0) }
        let stale = retainedQuery?.receive
        request?.resolve(track: track, bundleIdentifiers: [], isCurrent: { true }) { replies.append($0) }
        stale?(snapshot)
        pump()
        check(replies.count == 1, "superseded callback cannot resolve new request")
        retainedQuery?.receive?(PlaybackSourceSnapshot(title: "Old song", artist: nil, album: nil,
                                                       bundleIdentifier: "test.old", name: nil))
        retainedQuery?.receive?(nil)
        pump(0.01)
        check(replies.count == 1, "unrelated queued reply does not consume the current request")
        retainedQuery?.receive?(snapshot)
        pump()
        check(replies.count == 2, "current replacement request completes")
        request?.resolve(track: track, bundleIdentifiers: [], isCurrent: { false }) { replies.append($0) }
        retainedQuery?.receive?(snapshot)
        pump()
        check(replies.count == 3 && replies.last! == nil, "changed source is not opened")
        request?.resolve(track: track, bundleIdentifiers: [], isCurrent: { true }) { replies.append($0) }
        pump(0.12)
        check(replies.count == 4 && replies.last! == nil, "timeout completes exactly once")
        request?.resolve(track: track, bundleIdentifiers: [], isCurrent: { true }) { replies.append($0) }
        let cancelled = retainedQuery?.receive
        request?.cancel()
        cancelled?(snapshot)
        pump(0.12)
        check(replies.count == 4, "cancelled request delivers neither reply nor timeout")
        request = nil
        check(retainedQuery == nil, "adapter released with its owner")

        let dispatcher = PlaybackCommandDispatcher()
        let slow = Player()
        var refreshed = 0
        dispatcher.refresh(slow) { refreshed += 1 }
        check(slow.started.wait(timeout: .now() + 1) == .success, "refresh entered worker queue")
        check(!slow.wasMain && refreshed == 0, "slow player does not block main thread")
        for _ in 0..<20 { dispatcher.refresh(slow) { refreshed += 1 } }
        slow.release.signal()
        pump()
        check(slow.updates == 1 && refreshed == 1, "repeated refreshes coalesce while source is busy")
        let first = Player(), second = Player()
        first.shouldWait = false
        second.shouldWait = false
        let agent = MusicPlayers.Agent()
        agent.designatedPlayer = first
        var recipients: [ObjectIdentifier] = []
        var completed = 0
        for _ in 0..<3 {
            dispatcher.perform(agent, action: { recipients.append(ObjectIdentifier($0)) }) { completed += 1 }
        }
        agent.designatedPlayer = second
        pump()
        check(completed == 3 && recipients == Array(repeating: ObjectIdentifier(first), count: 3),
              "rapid commands preserve their clicked source and are not dropped")
        check(first.updates == 3 && second.updates == 0 && !first.wasMain, "command refreshes run off main thread")
        print("\(count) source and command checks passed")
    }
}
