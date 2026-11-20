import Foundation

/// Which lyrics sources the user has switched off on the Source pane.
///
/// A source switched off is never created for the lyrics search, so neither
/// the automatic search nor the search panel hears from it. Every source is on
/// unless the user switched it off, which is why what gets stored is the
/// switched-off ones: a source a later LyricsKit adds starts out on, and a
/// preference that was never written means "all on".
///
/// The stored form is `LyricsProviders.ServiceID` raw values rather than the
/// display names the priority list stores, because a display name is user
/// interface text and a renamed one would silently switch the source back on.
/// Values this build does not know — written by a newer build — are kept as
/// they are, so switching another source here does not switch that one back
/// on.
public struct LyricsSourceSwitches: Equatable, Sendable {
    /// What the preference stores: the raw values of the switched-off
    /// sources, in the order they were switched off, each once.
    public private(set) var disabledSourceIdentifiers: [String]

    public init(disabledSourceIdentifiers: [String] = []) {
        // A value listed twice would otherwise take two switches back on.
        var seenIdentifiers = Set<String>()
        self.disabledSourceIdentifiers = disabledSourceIdentifiers.filter { seenIdentifiers.insert($0).inserted }
    }

    public func isEnabled(_ service: LyricsProviders.ServiceID) -> Bool {
        !disabledSourceIdentifiers.contains(service.rawValue)
    }

    public mutating func setEnabled(_ isEnabled: Bool, for service: LyricsProviders.ServiceID) {
        disabledSourceIdentifiers.removeAll { $0 == service.rawValue }
        if !isEnabled {
            disabledSourceIdentifiers.append(service.rawValue)
        }
    }
}
