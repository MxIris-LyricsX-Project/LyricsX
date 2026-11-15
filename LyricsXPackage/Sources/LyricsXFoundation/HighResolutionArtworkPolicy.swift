import CryptoKit
import Foundation

/// Decides whether a network copy of the current track's cover is worth putting
/// on screen in place of the one the music player handed over, and how to ask
/// each source for its largest rendition.
///
/// The artwork a player publishes is small: system-wide Now Playing carries
/// whatever thumbnail the source application compressed into
/// `kMRMediaRemoteNowPlayingInfoArtworkData` (routinely 300–600 pixels), which
/// the lyrics panel then stretches across a cover view that reaches roughly
/// 1400 pixels when the window is full screen.
///
/// Everything in here is pure — URL rewriting, the replacement comparison, cache
/// keys and the metadata fallback check — so the whole decision surface is
/// testable without a network, a disk or a player. Downloading, caching and
/// fingerprinting live in the app.
public enum HighResolutionArtworkPolicy {
    /// How much larger a candidate's longest edge has to be before it replaces
    /// the artwork already on screen. A near-tie is not worth the visible swap.
    public static let minimumUpscaleFactor: Double = 1.2

    /// Some players publish no artwork at all, so there is nothing to beat. A
    /// candidate then only has to clear an absolute floor — below this it would
    /// be no sharper than what the panel already fails to show.
    public static let minimumDimensionWithoutLocalArtwork = 600

    /// Asked of Apple's image service. The originals reach 100000×100000 (which
    /// really means "unresized", often several megabytes); 1200 already covers a
    /// full-screen cover view on a 5K display.
    public static let requestedAppleArtworkDimension = 1200

    /// QQ Music serves its covers at `T002R<w>x<h>M000<album mid>.jpg`; 1000 is
    /// the largest rendition it reliably has.
    public static let requestedQQMusicArtworkDimension = 1000

    /// NetEase resizes on request through the `param` query item.
    public static let requestedNetEaseArtworkDimension = 1024

    public static let iTunesSearchResultLimit = 5

    public static let netEaseSearchResultLimit = 5

    /// How far a candidate's duration may sit from the playing track's before
    /// the two are considered different recordings.
    public static let durationTolerance: TimeInterval = 3

    /// A track with no high-resolution cover anywhere would otherwise be
    /// re-searched on every replay, so a miss is remembered — but not forever,
    /// because catalogues do gain covers.
    public static let negativeResultLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Cached covers are pruned oldest-first past this count.
    public static let cachedArtworkFileLimit = 300

    // MARK: - Replacement

    /// Whether a candidate is enough of an improvement to swap in.
    ///
    /// This is a size question only — that the candidate depicts the *same*
    /// cover is established separately, by fingerprint when the player gave us
    /// something to compare against and by `metadataMatches` when it did not.
    public static func isWorthReplacing(
        candidateLongestEdge: Int,
        localArtworkLongestEdge: Int?
    ) -> Bool {
        guard candidateLongestEdge > 0 else {
            return false
        }
        guard let localArtworkLongestEdge, localArtworkLongestEdge > 0 else {
            return candidateLongestEdge >= minimumDimensionWithoutLocalArtwork
        }
        return Double(candidateLongestEdge)
            >= Double(localArtworkLongestEdge) * minimumUpscaleFactor
    }

    // MARK: - Sources

    public static func iTunesSearchURL(
        title: String?,
        artist: String?,
        countryCode: String?
    ) -> URL? {
        guard let searchTerm = searchTerm(title: title, artist: artist) else {
            return nil
        }
        var components = URLComponents(string: "https://itunes.apple.com/search")
        var queryItems = [
            URLQueryItem(name: "term", value: searchTerm),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(iTunesSearchResultLimit)),
        ]
        if let storefrontCountryCode = storefrontCountryCode(countryCode) {
            queryItems.append(URLQueryItem(name: "country", value: storefrontCountryCode))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    /// NetEase Cloud Music's catalogue, searched by title and artist. It is the
    /// catalogue the NetEase client itself plays from, so it knows the Chinese
    /// releases and Japanese doujin tracks the iTunes Store usually does not —
    /// and the client hands Now Playing only a 100-pixel cover.
    ///
    /// The endpoint is the one LyricsKit's NetEase lyrics source searches. It
    /// refuses a request without the `NMTID` session cookie (code -462) and sets
    /// the cookie on that refusal, so a caller without one sends the request
    /// again with `cookie` taken from `netEaseSessionCookie(fromSetCookieHeader:)`.
    public static func netEaseSearchRequest(
        title: String?,
        artist: String?,
        cookie: String?
    ) -> URLRequest? {
        guard let searchTerm = searchTerm(title: title, artist: artist) else {
            return nil
        }
        var components = URLComponents(string: "http://music.163.com/api/search/pc")
        components?.queryItems = [
            URLQueryItem(name: "s", value: searchTerm),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: String(netEaseSearchResultLimit)),
            URLQueryItem(name: "type", value: "1"),
        ]
        guard let url = components?.url else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("http://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(netEaseUserAgent, forHTTPHeaderField: "User-Agent")
        // The cookie is managed by hand, so whether a request carries one never
        // depends on what a cookie store happens to hold.
        request.httpShouldHandleCookies = false
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    /// The `name=value` pair a `Set-Cookie` header opens with — the part a
    /// following request sends back.
    public static func netEaseSessionCookie(fromSetCookieHeader setCookieHeader: String?) -> String? {
        guard let pair = setCookieHeader?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespaces),
            pair.contains("=")
        else {
            return nil
        }
        return pair
    }

    /// The songs a NetEase search returned, each with its album cover. `nil`
    /// when the answer is not a search result at all — a refusal such as the
    /// cookie challenge, or something unreadable — which is a different thing
    /// from a search that found nothing (`[]`): only the latter says this song
    /// has no cover there.
    public static func netEaseSearchEntries(from data: Data) -> [ArtworkCatalogueEntry]? {
        guard let response = try? JSONDecoder().decode(NetEaseSearchResponse.self, from: data),
              response.code == 200
        else {
            return nil
        }
        return (response.result?.songs ?? []).compactMap { song in
            guard let pictureURLString = song.album?.picUrl,
                  let pictureURL = URL(string: pictureURLString)
            else {
                return nil
            }
            let artistNames = (song.artists ?? []).compactMap(\.name).filter { !$0.isEmpty }
            return ArtworkCatalogueEntry(
                artworkURL: pictureURL,
                title: song.name,
                artist: artistNames.isEmpty ? nil : artistNames.joined(separator: "/"),
                duration: song.duration.map { TimeInterval($0) / 1000 }
            )
        }
    }

    private static let netEaseUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Safari/605.1.15"

    private struct NetEaseSearchResponse: Decodable {
        struct Result: Decodable {
            let songs: [Song]?
        }

        struct Song: Decodable {
            struct Artist: Decodable {
                let name: String?
            }

            struct Album: Decodable {
                let picUrl: String?
            }

            let name: String?
            let artists: [Artist]?
            let album: Album?
            /// Milliseconds.
            let duration: Int?
        }

        let code: Int
        let result: Result?
    }

    private static func searchTerm(title: String?, artist: String?) -> String? {
        let searchTerm = [title, artist]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return searchTerm.isEmpty ? nil : searchTerm
    }

    /// Rewrites a cover URL to ask its host for a larger rendition. Hosts we
    /// have no documented resize convention for (Kugou, Musixmatch) come back
    /// untouched — they already hand out the biggest size they offer.
    public static func upgradedArtworkURL(_ artworkURL: URL) -> URL {
        upgradedAppleArtworkURL(artworkURL)
            ?? upgradedQQMusicArtworkURL(artworkURL)
            ?? upgradedNetEaseArtworkURL(artworkURL)
            ?? artworkURL
    }

    /// `…/source/100x100bb.jpg` → `…/source/1200x1200bb.jpg`. The suffix after
    /// the dimensions varies (`bb.jpg`, `bb-60.jpg`, `bf.png`), so it is carried
    /// over rather than assumed.
    private static func upgradedAppleArtworkURL(_ artworkURL: URL) -> URL? {
        guard artworkURL.host?.hasSuffix("mzstatic.com") == true else {
            return nil
        }
        let renditionName = artworkURL.lastPathComponent
        guard let dimensions = firstDimensionToken(in: renditionName),
              dimensions.range.lowerBound == renditionName.startIndex,
              max(dimensions.width, dimensions.height) < requestedAppleArtworkDimension
        else {
            return nil
        }
        return artworkURL.deletingLastPathComponent().appendingPathComponent(
            renditionName.replacingCharacters(
                in: dimensions.range,
                with: squareDimensionToken(requestedAppleArtworkDimension)
            )
        )
    }

    private static func upgradedQQMusicArtworkURL(_ artworkURL: URL) -> URL? {
        guard artworkURL.host?.contains("gtimg") == true else {
            return nil
        }
        let renditionName = artworkURL.lastPathComponent
        guard let dimensions = firstDimensionToken(in: renditionName),
              max(dimensions.width, dimensions.height) < requestedQQMusicArtworkDimension
        else {
            return nil
        }
        return artworkURL.deletingLastPathComponent().appendingPathComponent(
            renditionName.replacingCharacters(
                in: dimensions.range,
                with: squareDimensionToken(requestedQQMusicArtworkDimension)
            )
        )
    }

    private static func upgradedNetEaseArtworkURL(_ artworkURL: URL) -> URL? {
        guard artworkURL.host?.hasSuffix("music.126.net") == true else {
            return nil
        }
        var components = URLComponents(url: artworkURL, resolvingAgainstBaseURL: false)
        let requestedSize = "\(requestedNetEaseArtworkDimension)y\(requestedNetEaseArtworkDimension)"
        var queryItems = (components?.queryItems ?? []).filter { $0.name != "param" }
        queryItems.append(URLQueryItem(name: "param", value: requestedSize))
        components?.queryItems = queryItems
        return components?.url
    }

    private struct DimensionToken {
        let width: Int
        let height: Int
        let range: Range<String.Index>
    }

    /// Finds the first `<digits>x<digits>` run in a file name. Both hosts encode
    /// the rendition size that way — Apple as the whole name (`100x100bb.jpg`),
    /// QQ Music inside it (`T002R800x800M000<album mid>.jpg`) — and neither has a
    /// documented format beyond that, so this stays a scan rather than a pattern
    /// that would also have to be kept in step with their naming.
    private static func firstDimensionToken(in name: String) -> DimensionToken? {
        var index = name.startIndex
        while index < name.endIndex {
            guard name[index].isNumber else {
                index = name.index(after: index)
                continue
            }
            let widthStart = index
            var cursor = index
            while cursor < name.endIndex, name[cursor].isNumber {
                cursor = name.index(after: cursor)
            }
            guard cursor < name.endIndex, name[cursor] == "x" else {
                index = cursor
                continue
            }
            let heightStart = name.index(after: cursor)
            var heightEnd = heightStart
            while heightEnd < name.endIndex, name[heightEnd].isNumber {
                heightEnd = name.index(after: heightEnd)
            }
            guard heightEnd > heightStart,
                  let width = Int(name[widthStart ..< cursor]),
                  let height = Int(name[heightStart ..< heightEnd])
            else {
                index = heightEnd
                continue
            }
            return DimensionToken(width: width, height: height, range: widthStart ..< heightEnd)
        }
        return nil
    }

    private static func squareDimensionToken(_ dimension: Int) -> String {
        "\(dimension)x\(dimension)"
    }

    // MARK: - Cache key

    /// Keyed on the song rather than on `MusicTrack.id`, which is assigned by
    /// whichever player is in front: the same song played through a different
    /// player carries a different identifier and would miss its own cache entry.
    public static func cacheKey(title: String?, artist: String?, album: String?) -> String? {
        let normalizedTitle = normalized(title ?? "")
        let normalizedArtist = normalized(artist ?? "")
        guard !normalizedTitle.isEmpty || !normalizedArtist.isEmpty else {
            return nil
        }
        let identity = [normalizedTitle, normalizedArtist, normalized(album ?? "")]
            .joined(separator: "|")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Metadata fallback

    /// The check that stands in for a fingerprint comparison when the player
    /// published no artwork at all: there is nothing to compare against, so the
    /// candidate has to prove itself on title, artist and duration instead.
    public static func metadataMatches(
        candidateTitle: String?,
        candidateArtist: String?,
        candidateDuration: TimeInterval?,
        trackTitle: String?,
        trackArtist: String?,
        trackDuration: TimeInterval?
    ) -> Bool {
        guard let trackTitle, let trackArtist, let candidateTitle, let candidateArtist else {
            return false
        }
        guard titlesMatch(candidateTitle, trackTitle),
              artistsMatch(candidateArtist, trackArtist)
        else {
            return false
        }
        if let trackDuration, trackDuration > 0,
           let candidateDuration, candidateDuration > 0 {
            guard abs(trackDuration - candidateDuration) <= durationTolerance else {
                return false
            }
        }
        return true
    }

    /// Titles match outright, or match once both sides lose their bracketed
    /// suffixes — a catalogue's "Song (Remastered 2011)" is the same recording
    /// as a player's "Song" often enough that requiring equality would throw
    /// away most matches, while containment alone would accept "Love" for
    /// "Love Story".
    private static func titlesMatch(_ candidateTitle: String, _ trackTitle: String) -> Bool {
        let normalizedCandidate = normalized(candidateTitle)
        let normalizedTrack = normalized(trackTitle)
        guard !normalizedCandidate.isEmpty, !normalizedTrack.isEmpty else {
            return false
        }
        if normalizedCandidate == normalizedTrack {
            return true
        }
        return normalized(candidateTitle.strippingBrackets)
            == normalized(trackTitle.strippingBrackets)
    }

    /// Artists match outright, or one side merely carries additional credits
    /// ("Maroon 5" versus "Maroon 5 feat. Christina Aguilera"). The extra part
    /// has to start on a word boundary, so "Adele" never matches "Adelestein".
    private static func artistsMatch(_ candidateArtist: String, _ trackArtist: String) -> Bool {
        let normalizedCandidate = normalized(candidateArtist)
        let normalizedTrack = normalized(trackArtist)
        guard !normalizedCandidate.isEmpty, !normalizedTrack.isEmpty else {
            return false
        }
        if normalizedCandidate == normalizedTrack {
            return true
        }
        return normalizedCandidate.hasPrefix(normalizedTrack + " ")
            || normalizedTrack.hasPrefix(normalizedCandidate + " ")
    }

    // MARK: - Normalisation

    /// Case, accents, half/full width and punctuation all differ freely between
    /// what a player reports and what a catalogue stores, and none of them
    /// change which song is meant.
    public static func normalized(_ text: String) -> String {
        let folded = text.folding(
            options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
            locale: nil
        )
        let separated = folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " " as Character
        }
        return String(separated)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func storefrontCountryCode(_ countryCode: String?) -> String? {
        guard let countryCode else {
            return nil
        }
        let trimmed = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 2,
              trimmed.allSatisfy({ $0.isLetter })
        else {
            return nil
        }
        return trimmed
    }
}

/// One song a catalogue search returned, reduced to what choosing its cover
/// needs: where the cover is, and what the catalogue says the recording is.
public struct ArtworkCatalogueEntry: Equatable, Sendable {
    public let artworkURL: URL
    public let title: String?
    public let artist: String?
    public let duration: TimeInterval?

    public init(artworkURL: URL, title: String?, artist: String?, duration: TimeInterval?) {
        self.artworkURL = artworkURL
        self.title = title
        self.artist = artist
        self.duration = duration
    }
}
