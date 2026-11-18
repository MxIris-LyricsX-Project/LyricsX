import Foundation

/// Where the check of the Apple Music `media-user-token` stands.
///
/// `AppController` runs the check whenever it rebuilds the lyrics sources
/// and publishes this value; the Lab pane shows it under the token field.
/// The Apple Music lyrics source is in the search only while the check has
/// found the token authorized.
public enum AppleMusicTokenCheck: Hashable, Sendable {
    /// No token is entered; Apple Music lyrics are off.
    case noToken
    /// A check is on its way to amp-api.
    case checking
    /// amp-api answered, or the check gave up.
    case finished(LyricsProviders.AppleMusicAuthorizationStatus)

    /// Whether the Apple Music lyrics source goes into the search.
    public var includesAppleMusicLyrics: Bool {
        if case .finished(.authorized) = self { return true }
        return false
    }

    /// The storefront's region in `locale`'s language — "日本" for `"jp"` in
    /// Simplified Chinese — or the identifier itself when `locale` has no
    /// name for it.
    public static func regionName(forStorefront storefront: String, locale: Locale = .current) -> String {
        locale.localizedString(forRegionCode: storefront.uppercased()) ?? storefront
    }
}
