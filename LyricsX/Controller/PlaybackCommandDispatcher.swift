import Foundation
import MusicPlayer

/// Capture the concrete source on the UI thread, then serialize potentially
/// blocking Apple events off it. Frequent refresh requests never build a backlog.
final class PlaybackCommandDispatcher {
    private let queue = DispatchQueue(label: "PlaybackMenuCommands", qos: .userInitiated)
    private var refreshing = Set<ObjectIdentifier>()

    static func source(of player: MusicPlayerProtocol) -> MusicPlayerProtocol? {
        var source = player
        var visited = Set<ObjectIdentifier>()
        while let agent = source as? MusicPlayers.Agent {
            guard visited.insert(ObjectIdentifier(agent)).inserted, let next = agent.designatedPlayer else { return nil }
            source = next
        }
        return source
    }

    func refresh(_ player: MusicPlayerProtocol, completion: @escaping () -> Void) {
        guard let source = Self.source(of: player) else { return }
        let identity = ObjectIdentifier(source)
        guard refreshing.insert(identity).inserted else { return }
        queue.async { [weak self] in
            guard self != nil else { return }
            source.updatePlayerState()
            RunLoop.main.perform(inModes: [.common, .eventTracking]) { [weak self] in
                self?.refreshing.remove(identity)
                completion()
            }
        }
    }

    func perform(_ player: MusicPlayerProtocol, action: @escaping (MusicPlayerProtocol) -> Void,
                 completion: @escaping () -> Void) {
        guard let source = Self.source(of: player) else { return }
        queue.async {
            action(source)
            source.updatePlayerState()
            RunLoop.main.perform(inModes: [.common, .eventTracking], block: completion)
        }
    }
}
