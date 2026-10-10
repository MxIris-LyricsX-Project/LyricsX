import AppKit
import Combine
import MusicPlayer

private final class ProbePlayer: MusicPlayerProtocol {
    var name: MusicPlayerName? = .appleMusic
    var currentTrack: MusicTrack? = MusicTrack(id: "probe", title: "Track", album: "Album", artist: "Artist", duration: 180)
    var playbackState: PlaybackState = .paused(time: 45)
    private var time: TimeInterval = 45
    var seekGate: DispatchSemaphore?
    var playbackTime: TimeInterval {
        get { time }
        set { seekGate?.wait(); time = newValue }
    }
    let objectWillChange = ObservableObjectPublisher()
    var currentTrackWillChange: AnyPublisher<MusicTrack?, Never> { Empty().eraseToAnyPublisher() }
    var playbackStateWillChange: AnyPublisher<PlaybackState, Never> { Empty().eraseToAnyPublisher() }
    var commands: [String] = []
    func resume() { commands.append("play"); playbackState = .playing(time: playbackTime) }
    func pause() { commands.append("pause"); playbackState = .paused(time: playbackTime) }
    func skipToNextItem() { commands.append("next") }
    func skipToPreviousItem() { commands.append("previous") }
    func updatePlayerState() { commands.append("update") }
}

@main private enum PlaybackMenuProbe {
    static func main() {
        _ = NSApplication.shared
        let player = ProbePlayer()
        let view = PlaybackMenuView(player: player, loadArtwork: { _, _, done in done(nil) })
        let buttons = view.subviews.compactMap { $0 as? NSButton }.filter { !$0.isTransparent }
        let slider = view.subviews.compactMap { $0 as? NSSlider }.first!
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            count += 1
            print("PASS: \(name)")
        }
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        func send(_ control: NSControl) {
            check(control.sendAction(control.action!, to: control.target), "control action delivered")
            pump()
        }
        check(buttons.count == 3, "three playback commands")
        check(slider.isEnabled && slider.maxValue == 180 && slider.doubleValue == 45, "duration and elapsed position")
        view.beginTracking()
        pump()
        check(view.isMenuOpen && player.commands.last == "update", "opening refreshes selected player")
        send(buttons[0]); check(player.commands.suffix(2) == ["previous", "update"], "previous routes to selected player")
        send(buttons[1]); check(player.commands.suffix(2) == ["play", "update"], "play routes to selected player")
        send(buttons[1]); check(player.commands.suffix(2) == ["pause", "update"], "pause routes to selected player")
        send(buttons[2]); check(player.commands.suffix(2) == ["next", "update"], "next routes to selected player")
        slider.doubleValue = 100
        send(slider)
        check(player.playbackTime == 100, "seek writes selected player's position")
        player.playbackState = .playing(time: 100)
        view.refresh()
        player.playbackTime = 110
        let trackingDeadline = Date().addingTimeInterval(1.15)
        while Date() < trackingDeadline {
            _ = RunLoop.main.run(mode: .eventTracking, before: trackingDeadline)
        }
        check(slider.doubleValue == 110, "open playing menu refreshes progress")
        view.endTracking()
        player.playbackTime = 120
        RunLoop.main.run(until: Date().addingTimeInterval(1.15))
        check(!view.isMenuOpen && slider.doubleValue == 110, "closed menu stops progress updates")
        player.playbackState = .paused(time: 120)
        view.beginTracking()
        pump()
        player.playbackTime = 130
        RunLoop.main.run(until: Date().addingTimeInterval(1.15))
        check(slider.doubleValue == 120, "paused menu has no progress polling")
        player.objectWillChange.send()
        player.currentTrack = MusicTrack(id: "paused-next", title: "Paused Next", album: nil, artist: nil, duration: 240)
        player.playbackState = .paused(time: 0)
        player.playbackTime = 0
        let pausedChangeDeadline = Date().addingTimeInterval(0.2)
        while Date() < pausedChangeDeadline {
            _ = RunLoop.main.run(mode: .eventTracking, before: pausedChangeDeadline)
        }
        check(slider.maxValue == 240 && slider.doubleValue == 0,
              "paused track notification refreshes in menu tracking mode")
        player.currentTrack?.duration = .nan
        view.refresh()
        check(!slider.isEnabled, "unknown duration disables seeking")
        let before = player.playbackTime
        send(slider)
        check(player.playbackTime == before, "invalid duration cannot write playback position")
        player.currentTrack = nil
        player.playbackState = .stopped
        view.refresh()
        check(view.subviews.compactMap { $0 as? NSButton }.allSatisfy { !$0.isEnabled } && !slider.isEnabled, "empty player disables controls")
        check(PlaybackMenuView.timeString(3661) == "1:01:01", "hour formatting")
        check(PlaybackMenuView.timeString(.infinity) == "0:00" && PlaybackMenuView.timeString(-12) == "0:00", "invalid time formatting")
        view.endTracking()
        check(view.frame.size == NSSize(width: 320, height: 108), "compact card dimensions")
        let delayedPlayer = ProbePlayer()
        let delayedView = PlaybackMenuView(player: delayedPlayer, loadArtwork: { _, _, done in done(nil) })
        let delayedSlider = delayedView.subviews.compactMap { $0 as? NSSlider }.first!
        delayedView.beginTracking()
        pump()
        let seekGate = DispatchSemaphore(value: 0)
        delayedPlayer.seekGate = seekGate
        delayedSlider.doubleValue = 90
        send(delayedSlider)
        delayedView.refresh()
        check(delayedSlider.doubleValue == 90 && delayedPlayer.playbackTime == 45,
              "released drag keeps target while background seek waits")
        delayedSlider.doubleValue = 20
        send(delayedSlider)
        delayedView.refresh()
        check(delayedSlider.doubleValue == 20, "second drag immediately replaces first preview")
        seekGate.signal()
        pump()
        check(delayedSlider.doubleValue == 20 && delayedPlayer.playbackTime == 90,
              "first seek completion cannot clear second drag preview")
        seekGate.signal()
        pump()
        check(delayedSlider.doubleValue == 20 && delayedPlayer.playbackTime == 20,
              "latest completed seek hands progress back to player")
        delayedSlider.doubleValue = 80
        send(delayedSlider)
        delayedPlayer.currentTrack = MusicTrack(id: "different", title: "Different", album: nil, artist: nil, duration: 200)
        delayedView.refresh()
        check(delayedSlider.doubleValue == 20, "new track does not inherit pending drag preview")
        delayedView.endTracking()
        seekGate.signal()
        pump()
        check(!delayedView.isMenuOpen, "late seek completion cannot reopen a closed menu")
        var artworkCallbacks: [(NSImage?) -> Void] = []
        let artworkPlayer = ProbePlayer()
        let artworkView = PlaybackMenuView(player: artworkPlayer, loadArtwork: { _, _, done in artworkCallbacks.append(done) })
        let artworkImageView = artworkView.subviews.compactMap { $0 as? NSImageView }.first!
        artworkView.beginTracking()
        check(artworkCallbacks.count == 1, "missing artwork requests asynchronous fallback")
        artworkView.refresh()
        check(artworkCallbacks.count == 1, "refresh does not duplicate artwork request")
        let firstCover = NSImage(size: NSSize(width: 48, height: 48))
        artworkCallbacks[0](firstCover)
        check(artworkImageView.image === firstCover, "late artwork updates current song")
        artworkPlayer.currentTrack = MusicTrack(id: "next", title: "Next", album: "Album", artist: "Artist", duration: 180)
        artworkView.refresh()
        check(artworkCallbacks.count == 2 && artworkImageView.image !== firstCover, "song change clears previous artwork")
        artworkCallbacks[0](firstCover)
        check(artworkImageView.image !== firstCover, "stale artwork completion cannot overwrite next song")
        let secondCover = NSImage(size: NSSize(width: 48, height: 48))
        artworkCallbacks[1](secondCover)
        check(artworkImageView.image === secondCover, "next song receives its own artwork")
        artworkPlayer.currentTrack = MusicTrack(id: "probe", title: "Track", album: "Album", artist: "Artist", duration: 180)
        artworkView.refresh()
        artworkCallbacks[0](firstCover)
        check(artworkImageView.image !== firstCover, "A-B-A transition rejects the first A request")
        artworkView.endTracking()
        artworkCallbacks[2](firstCover)
        artworkView.beginTracking()
        check(artworkCallbacks.count == 4 && artworkImageView.image !== firstCover,
              "closed-menu artwork reply is ignored and reopening retries")
        artworkCallbacks[3](firstCover)
        artworkPlayer.currentTrack = MusicTrack(id: "next", title: "Next", album: "Album", artist: "Artist", duration: 180)
        artworkView.refresh()
        let nativeCover = NSImage(size: NSSize(width: 48, height: 48))
        artworkPlayer.currentTrack?.artwork = nativeCover
        artworkView.refresh()
        check(artworkImageView.image === nativeCover, "native artwork takes priority over fallback")
        check(PlaybackArtworkLoader.matches(artworkPlayer.currentTrack!, title: " next ", artist: "ARTIST", album: "Album"), "metadata matching tolerates casing and surrounding spaces")
        check(!PlaybackArtworkLoader.matches(artworkPlayer.currentTrack!, title: "Next", artist: "Another artist", album: "Album"), "different artist is rejected")
        check(!PlaybackArtworkLoader.matches(artworkPlayer.currentTrack!, title: "Next", artist: "Artist", album: "Different album"), "different album is rejected")
        artworkView.layoutSubtreeIfNeeded()
        check(artworkImageView.frame.size == NSSize(width: 48, height: 48), "compact cover dimensions")
        check(artworkView.subviews.allSatisfy { artworkView.bounds.contains($0.frame) }, "all controls fit compact card")
        artworkView.endTracking()
        var openedPlayer: MusicPlayerProtocol?
        let linkPlayer = ProbePlayer()
        let linkView = PlaybackMenuView(player: linkPlayer, openPlayer: { openedPlayer = $0 }, loadArtwork: { _, _, done in done(nil) })
        linkView.layoutSubtreeIfNeeded()
        let hotspots = linkView.subviews.compactMap { $0 as? NSButton }.filter { $0.isTransparent }
        check(hotspots.count == 2, "cover and metadata have native click targets")
        send(hotspots[0])
        check(openedPlayer === linkPlayer && linkPlayer.commands.isEmpty, "cover opens selected player without playback commands")
        openedPlayer = nil
        send(hotspots[1])
        check(openedPlayer === linkPlayer, "song and artist area opens selected player")
        let playbackButtons = linkView.subviews.compactMap { $0 as? NSButton }.filter { !$0.isTransparent }
        check(hotspots.allSatisfy { hotspot in playbackButtons.allSatisfy { !hotspot.frame.intersects($0.frame) } }, "open-player hit areas do not overlap playback controls")
        let linkSlider = linkView.subviews.compactMap { $0 as? NSSlider }.first!
        check(playbackButtons.allSatisfy { !linkSlider.frame.intersects($0.frame) }, "playback controls do not overlap the seek slider")
        linkPlayer.currentTrack = nil
        linkView.refresh()
        check(hotspots.allSatisfy { !$0.isEnabled }, "no song disables open-player hit areas")
        let systemPlayer = ProbePlayer()
        systemPlayer.name = nil
        let sourceView = PlaybackMenuView(player: systemPlayer, loadArtwork: { _, _, done in done(nil) })
        var sourceCallbacks: [(String?) -> Void] = []
        var identity = ObjectIdentifier(systemPlayer)
        sourceView.sourceIdentity = { identity }
        sourceView.sourceName = { "Fallback" }
        sourceView.resolveSourceName = { _, done in sourceCallbacks.append(done) }
        let sourceLabel = sourceView.subviews.compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 10 }!
        sourceView.beginTracking()
        check(sourceCallbacks.count == 1, "system source without enum name requests actual app identity")
        sourceCallbacks[0]("Apple Music")
        check(sourceLabel.stringValue == "Apple Music", "system Apple Music displays its resolved name")
        sourceView.refresh()
        check(sourceCallbacks.count == 1 && sourceLabel.stringValue == "Apple Music", "paused/position refresh keeps resolved name without extra queries")
        systemPlayer.currentTrack = MusicTrack(id: "new", title: "New", album: nil, artist: "Artist")
        sourceView.refresh()
        sourceCallbacks[0]("Old App")
        check(sourceLabel.stringValue == "Fallback", "old-song identity cannot overwrite a new song")
        sourceCallbacks[1]("Spotify")
        check(sourceLabel.stringValue == "Spotify", "another system source can display its actual app")
        let otherPlayer = ProbePlayer()
        identity = ObjectIdentifier(otherPlayer)
        sourceView.refresh()
        sourceCallbacks[1]("Old App")
        check(sourceCallbacks.count == 3 && sourceLabel.stringValue == "Fallback", "same song on a different source invalidates old identity")
        sourceView.endTracking()
        sourceCallbacks[2]("Closed Menu")
        check(sourceLabel.stringValue == "Fallback", "closed menu ignores pending app identity")
        sourceView.beginTracking()
        check(sourceCallbacks.count == 4, "reopening retries identity lookup")
        sourceView.endTracking()
        systemPlayer.name = .appleMusic
        sourceView.refresh()
        check(sourceLabel.stringValue == "Apple Music", "direct Apple Music source uses full display name")
        print("\(count) checks passed")
    }
}
