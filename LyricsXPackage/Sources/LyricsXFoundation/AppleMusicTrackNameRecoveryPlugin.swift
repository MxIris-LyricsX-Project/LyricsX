import Foundation
import LyricsKit

extension LyricsSearchRequest {
    /// Whether the search is for a track playing in Music — whichever player
    /// source reported it: the Apple Music player, or the system-wide now
    /// playing source while Music is the app playing. Apple Music name
    /// recovery runs for these searches only.
    ///
    /// Kept in `userInfo` under the key LyricsKit reserves for it,
    /// `AppleMusicNameRecoveryPlugin.appleMusicTrackUserInfoKey`.
    public var isForAppleMusicTrack: Bool {
        get {
            userInfo[AppleMusicNameRecoveryPlugin.appleMusicTrackUserInfoKey] == "1"
        }
        set {
            userInfo[AppleMusicNameRecoveryPlugin.appleMusicTrackUserInfoKey] = newValue ? "1" : nil
        }
    }
}

/// Apple Music name recovery for the searches made for a track playing in
/// Music, those whose ``LyricsSearchRequest/isForAppleMusicTrack`` is set.
///
/// `AppleMusicNameRecoveryPlugin` recovers a name for whatever request it is
/// given, so on its own it has to be mounted and unmounted as the player
/// changes. That rebuilds the provider group asynchronously, and the first
/// track after a switch to Music is often searched with the old group,
/// without the plugin. This plugin stays mounted while the switch is on and
/// decides per search instead.
public struct AppleMusicTrackNameRecoveryPlugin: LyricsSearchRequestPlugin {
    private let nameRecovery: any LyricsSearchRequestPlugin

    /// - Parameter nameRecovery: The recovery to run for Apple Music tracks.
    public init(nameRecovery: any LyricsSearchRequestPlugin = AppleMusicNameRecoveryPlugin()) {
        self.nameRecovery = nameRecovery
    }

    public func additionalRequests(for request: LyricsSearchRequest) async -> [LyricsSearchRequest] {
        guard request.isForAppleMusicTrack else {
            return []
        }
        return await nameRecovery.additionalRequests(for: request)
    }
}
