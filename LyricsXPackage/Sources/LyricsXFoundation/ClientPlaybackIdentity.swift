import Foundation

/// The player's identity and metadata are checked together; a matching title
/// from another player is never sufficient to consume NetEase's local state.
public struct ClientPlaybackIdentity: Equatable, Sendable {
    public var sourceBundleIdentifier: String?
    public var title: String?
    public var album: String?
    public var artist: String?
    public var duration: Double?

    public init(sourceBundleIdentifier: String?, title: String?, album: String?, artist: String?, duration: Double?) {
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.title = title
        self.album = album
        self.artist = artist
        self.duration = duration
    }
}
