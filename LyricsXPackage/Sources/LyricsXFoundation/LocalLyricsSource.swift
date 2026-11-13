import Foundation

/// Where a track's lyrics can be read from without a search: the lyrics
/// embedded in the track, or a lyrics file — one beside the track, or the copy
/// in LyricsX's own library.
public enum LocalLyricsSource: Hashable, Sendable {
    case embedded
    case file(URL)

    /// Which of `sources` the lyrics on screen were read from, worked out from
    /// those lyrics alone, so the Local Lyrics menu needs no record of its own
    /// to keep in step with what the automatic lookup, a search or a
    /// translation puts on screen.
    ///
    /// Lyrics read from a file carry its URL. Lyrics with neither a file nor a
    /// service were parsed from the track's embedded text — except imported
    /// lyrics, which have no file until they are saved, and which the import
    /// marks as picked by the user. Lyrics from a search carry their service
    /// and match nothing until they are saved, when they gain a file.
    public static func onScreen(
        localURL: URL?,
        service: String?,
        isUserPicked: Bool,
        among sources: [LocalLyricsSource]
    ) -> LocalLyricsSource? {
        if let localURL {
            let onScreenURL = localURL.standardizedFileURL
            return sources.first {
                guard case .file(let url) = $0 else { return false }
                return url.standardizedFileURL == onScreenURL
            }
        }
        guard service == nil, !isUserPicked, sources.contains(.embedded) else {
            return nil
        }
        return .embedded
    }
}
