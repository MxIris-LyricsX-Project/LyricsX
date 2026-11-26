import Foundation

extension LyricsProviders.ServiceID {
    /// The lyrics source run by the company behind the music app with
    /// `bundleIdentifier` — QQ Music's for QQ Music — or `nil` when LyricsX
    /// searches no source of that app's.
    ///
    /// Matched on the identifier's dot-separated components, ignoring case,
    /// so the Mac and the iPad builds of one player map alike
    /// (`com.tencent.QQMusicMac`, `com.tencent.QQMusic`) while another app
    /// from the same company does not (`com.tencent.xinWeChat`). Matching a
    /// substring instead would also take in any app whose name merely
    /// contains one of these words.
    public init?(playerBundleIdentifier bundleIdentifier: String) {
        let components = bundleIdentifier.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3, components[0] == "com" else { return nil }
        switch (components[1], components[2]) {
        case ("tencent", let product) where product.hasPrefix("qqmusic"):
            self = .qq
        case ("netease", "163music"), ("netease", "cloudmusic"):
            self = .netease
        case ("kugou", _):
            self = .kugou
        case ("apple", "music") where components.count == 3:
            // Exactly the app: an extension or a helper of Music is not where
            // a track plays.
            self = .appleMusic
        default:
            return nil
        }
    }
}

/// Lyrics from the source run by the app the track plays in — QQ Music's
/// lyrics while QQ Music plays — score higher, because that app times its
/// lyrics against the very recording it is playing, while another source's
/// lyrics of the same title may come from another version of the song.
public enum PlayerLyricsSourcePolicy {
    /// Added to the match score of lyrics from the playing app's own source.
    ///
    /// Enough to outweigh one of LyricsKit's 0.05 feature bonuses (a
    /// translation, inline time tags) plus a small duration difference, so the
    /// playing app's copy of the right song comes first; it only ties a copy
    /// that has both features when its own has neither. Far short of the 0.3
    /// or more a wrong title or artist costs, so it never lifts another song
    /// above the right one.
    public static let matchBonus = 0.1

    /// Whether lyrics that `service` found — a provider's name as
    /// `Lyrics.Metadata.service` records it — come from the lyrics source of
    /// the app with `playerBundleIdentifier`.
    ///
    /// `false` when either is missing: lyrics read from a file have no
    /// service, and a player that cannot be told has no source of its own.
    public static func lyricsService(
        _ service: String?,
        belongsToPlayerWithBundleIdentifier playerBundleIdentifier: String?
    ) -> Bool {
        guard let service, let playerBundleIdentifier,
              let playerSource = LyricsProviders.ServiceID(playerBundleIdentifier: playerBundleIdentifier) else {
            return false
        }
        return playerSource.displayName == service
    }
}
