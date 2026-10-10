import AppKit
import Combine
import MusicPlayer

private final class Candidate: MusicPlayerProtocol {
    var name: MusicPlayerName? { nil }
    @Published var currentTrack: MusicTrack?
    @Published var playbackState: PlaybackState = .stopped
    var playbackTime: TimeInterval = 0
    let objectWillChange = ObservableObjectPublisher()
    var currentTrackWillChange: AnyPublisher<MusicTrack?, Never> { $currentTrack.eraseToAnyPublisher() }
    var playbackStateWillChange: AnyPublisher<PlaybackState, Never> { $playbackState.eraseToAnyPublisher() }
    var updates = 0
    var updateHook: (() -> Void)?
    var pendingState: PlaybackState?
    var pendingTrack = "local"
    var commands: [String] = []
    func set(_ state: PlaybackState, track: String? = "track") {
        objectWillChange.send()
        playbackState = state
        currentTrack = track.map { MusicTrack(id: $0, title: $0, album: nil, artist: nil) }
    }
    func resume() { commands.append("resume") }
    func pause() { commands.append("pause") }
    func skipToNextItem() { commands.append("next") }
    func skipToPreviousItem() { commands.append("previous") }
    func updatePlayerState() {
        updates += 1
        updateHook?()
        if let pendingState {
            self.pendingState = nil
            set(pendingState, track: pendingTrack)
        }
    }
}

@main enum AutomaticPlayerProbe {
    static func main() {
        let local = Candidate(), phone = Candidate()
        let automatic = AutomaticPlayer(players: [local, phone], refreshInterval: 0)
        var checks = 0
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1; print("PASS: \(message)")
        }
        check(automatic.designatedPlayer == nil, "no source when every candidate is stopped")
        phone.set(.playing(time: 1), track: "phone"); pump()
        check(automatic.designatedPlayer === phone, "phone is selected from idle")
        check(automatic.currentTrack?.id == "phone", "phone metadata is forwarded")
        automatic.skipToNextItem()
        check(phone.commands == ["next"] && local.commands.isEmpty, "commands route only to selected phone")
        local.set(.playing(time: 2), track: "local"); pump()
        check(automatic.designatedPlayer === phone, "background playback does not steal a playing source")
        phone.set(.paused(time: 1), track: "phone"); pump()
        check(automatic.designatedPlayer === local, "phone pause switches to playing local source")
        local.set(.paused(time: 2), track: "local"); pump()
        check(automatic.designatedPlayer === local, "paused source is retained when no other source is playing")
        phone.set(.playing(time: 3), track: "phone"); pump()
        check(automatic.designatedPlayer === phone, "a nonselected phone can take over a paused local source")
        check(automatic.currentTrack?.id == "phone", "new selected song replaces old source metadata")
        phone.set(.stopped, track: nil); pump()
        check(automatic.designatedPlayer === phone, "phone disconnect does not hand off to a paused local source")
        local.set(.stopped, track: nil); pump()
        check(automatic.designatedPlayer === phone && automatic.currentTrack == nil, "all sources stopping preserves selection and clears metadata")
        local.set(.paused(time: 0), track: nil); pump()
        check(automatic.designatedPlayer === phone, "empty paused candidate cannot displace the selected source")
        phone.set(.playing(time: 4), track: nil); pump()
        check(automatic.designatedPlayer === phone, "playing phone stays selected while new metadata is loading")
        phone.set(.playing(time: 4), track: "next phone song"); pump()
        check(automatic.currentTrack?.id == "next phone song", "late metadata from selected source is forwarded")
        automatic.refreshCandidates()
        pump()
        check(local.updates == 1 && phone.updates == 1, "explicit refresh updates every candidate")
        let local2 = Candidate(), phone2 = Candidate()
        local2.set(.playing(time: 0)); phone2.set(.playing(time: 0))
        let both = AutomaticPlayer(players: [local2, phone2])
        check(both.designatedPlayer === local2, "initial simultaneous playback has deterministic local-first priority")
        local2.set(.stopped, track: nil); pump()
        check(both.designatedPlayer === phone2, "stopped local source falls back to playing phone")
        let onlyPhone = AutomaticPlayer(players: [phone2])
        check(onlyPhone.designatedPlayer === phone2, "phone works when no local system player is available")
        let discoveredLocal = Candidate(), pausedPhone = Candidate()
        pausedPhone.set(.playing(time: 1), track: "phone")
        var discovering: AutomaticPlayer? = AutomaticPlayer(
            players: [discoveredLocal, pausedPhone], refreshInterval: 0.02)
        check(discovering?.designatedPlayer === pausedPhone, "discovery starts with playing phone")
        pausedPhone.set(.paused(time: 1), track: "phone"); pump()
        check(discovering?.designatedPlayer === pausedPhone, "phone pause retains content until a local player starts")
        // No notification until refresh: reproduces a player starting after
        // the selected phone has paused and its playback clock has stopped.
        discoveredLocal.pendingState = .playing(time: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        check(discovering?.designatedPlayer === discoveredLocal, "idle discovery finds local playback after phone pause")
        check(discovering?.currentTrack?.id == "local", "discovered local track replaces phone metadata")
        discovering?.pause()
        check(discoveredLocal.commands == ["pause"] && pausedPhone.commands.isEmpty, "controls follow the newly discovered local player")
        discoveredLocal.set(.paused(time: 2)); pump()
        pausedPhone.pendingState = .playing(time: 3)
        pausedPhone.pendingTrack = "phone resumed"
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        check(discovering?.designatedPlayer === pausedPhone, "idle discovery also allows phone to take over paused Mac")
        weak var releasedSelector = discovering
        discovering = nil
        let updatesBeforeRelease = discoveredLocal.updates
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        check(releasedSelector == nil, "candidate timer does not retain automatic selection")
        check(discoveredLocal.updates == updatesBeforeRelease, "leaving automatic selection cancels candidate polling")
        let silentLocal = Candidate()
        let idle = AutomaticPlayer(players: [silentLocal], refreshInterval: 0.02)
        silentLocal.pendingState = .playing(time: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        check(idle.designatedPlayer === silentLocal, "discovery starts even when no source was initially playing")
        let initiallyPaused = Candidate()
        initiallyPaused.set(.paused(time: 5), track: "paused song")
        let initial = AutomaticPlayer(players: [initiallyPaused], refreshInterval: 0)
        check(initial.designatedPlayer === initiallyPaused && initial.currentTrack?.id == "paused song",
              "initial discovery preserves a paused song")
        let later = Candidate()
        let waiting = AutomaticPlayer(players: [later], refreshInterval: 0)
        later.set(.paused(time: 5), track: "discovered paused song"); pump()
        check(waiting.designatedPlayer === later, "asynchronous initial paused metadata selects a source")
        let slow = Candidate()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var wasMain = true
        slow.updateHook = {
            wasMain = Thread.isMainThread
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        let fast = Candidate()
        fast.pendingState = .playing(time: 2)
        let responsive = AutomaticPlayer(players: [slow, fast], refreshInterval: 0)
        responsive.refreshCandidates()
        check(entered.wait(timeout: .now() + 1) == .success && !wasMain,
              "blocking local player refresh runs off the UI thread")
        for _ in 0..<20 { responsive.refreshCandidates() }
        pump()
        check(responsive.designatedPlayer === fast, "one unresponsive local app does not block discovery of another")
        release.signal(); pump()
        check(slow.updates == 1, "slow candidate refreshes coalesce instead of building a queue")
        let mainOnly = Candidate()
        var mainOnlyWasMain = false
        mainOnly.updateHook = { mainOnlyWasMain = Thread.isMainThread }
        let mainSelector = AutomaticPlayer(players: [mainOnly], mainThreadPlayers: [mainOnly], refreshInterval: 0)
        mainSelector.refreshCandidates()
        check(mainOnlyWasMain, "phone-style main-thread state machines stay on the main thread")
        print("\(checks) automatic source checks passed")
    }
}
