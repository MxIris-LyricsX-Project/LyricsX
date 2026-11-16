import Foundation
import Testing
@testable import LyricsXFoundation

// MARK: - Asking each source for a larger rendition

/// Apple's image service encodes the rendition size as the whole file name, and
/// what follows the size varies (`bb.jpg`, `bb-60.jpg`), so the rewrite has to
/// carry that suffix over rather than assume one.
@Test
func appleArtworkURLsAreRewrittenToTheRequestedDimensionKeepingTheirSuffix() {
    let searchResultURL = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/a/b/c/source/100x100bb.jpg")!
    #expect(
        HighResolutionArtworkPolicy.upgradedArtworkURL(searchResultURL).absoluteString
            == "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/a/b/c/source/1200x1200bb.jpg"
    )

    let compressedRenditionURL = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/a/b/c/source/100x100bb-60.jpg")!
    #expect(
        HighResolutionArtworkPolicy.upgradedArtworkURL(compressedRenditionURL).absoluteString
            == "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/a/b/c/source/1200x1200bb-60.jpg"
    )
}

/// Asking for less than the source already offers would make the feature worse
/// than doing nothing.
@Test
func artworkURLsAlreadyLargerThanRequestedAreLeftAlone() {
    let originalRenditionURL = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/a/b/c/source/3000x3000bb.jpg")!
    #expect(HighResolutionArtworkPolicy.upgradedArtworkURL(originalRenditionURL) == originalRenditionURL)

    let largeQQMusicURL = URL(string: "https://y.gtimg.cn/music/photo_new/T002R1000x1000M000abcdef.jpg")!
    #expect(HighResolutionArtworkPolicy.upgradedArtworkURL(largeQQMusicURL) == largeQQMusicURL)
}

/// QQ Music carries the size inside a longer name (`T002R800x800M000<album mid>`),
/// so only the size run may change — the album identifier around it must survive.
@Test
func qqMusicArtworkURLsKeepTheirAlbumIdentifierWhenTheSizeIsRaised() {
    let albumCoverURL = URL(string: "https://y.gtimg.cn/music/photo_new/T002R800x800M000abcdef.jpg")!
    #expect(
        HighResolutionArtworkPolicy.upgradedArtworkURL(albumCoverURL).absoluteString
            == "https://y.gtimg.cn/music/photo_new/T002R1000x1000M000abcdef.jpg"
    )
}

/// NetEase resizes through a query item. A URL that already carries one must end
/// up with a single `param`, not two — the CDN honours whichever it sees first.
@Test
func netEaseArtworkURLsGetExactlyOneSizeQueryItem() {
    let plainCoverURL = URL(string: "https://p1.music.126.net/abc/109951165.jpg")!
    #expect(
        HighResolutionArtworkPolicy.upgradedArtworkURL(plainCoverURL).absoluteString
            == "https://p1.music.126.net/abc/109951165.jpg?param=1024y1024"
    )

    let thumbnailCoverURL = URL(string: "https://p1.music.126.net/abc/109951165.jpg?param=300y300")!
    let upgraded = HighResolutionArtworkPolicy.upgradedArtworkURL(thumbnailCoverURL)
    let sizeQueryItems = URLComponents(url: upgraded, resolvingAgainstBaseURL: false)?
        .queryItems?
        .filter { $0.name == "param" }
    #expect(sizeQueryItems?.count == 1)
    #expect(sizeQueryItems?.first?.value == "1024y1024")
}

/// Kugou and Musixmatch have no documented resize convention — LyricsKit already
/// asks them for the largest size they publish — so guessing at one would only
/// produce dead URLs.
@Test
func artworkURLsFromSourcesWithoutAResizeConventionAreLeftAlone() {
    let kugouCoverURL = URL(string: "https://imgessl.kugou.com/stdmusic/480/20190101/cover.jpg")!
    #expect(HighResolutionArtworkPolicy.upgradedArtworkURL(kugouCoverURL) == kugouCoverURL)

    let musixmatchCoverURL = URL(string: "https://s.mxmcdn.net/images-storage/albums/8/1/cover_800x800.jpg")!
    #expect(HighResolutionArtworkPolicy.upgradedArtworkURL(musixmatchCoverURL) == musixmatchCoverURL)
}

@Test
func theITunesSearchURLCarriesTheTrackTermAndDropsAMalformedStorefront() throws {
    let searchURL = HighResolutionArtworkPolicy.iTunesSearchURL(
        title: "Animals",
        artist: "Maroon 5",
        countryCode: "us"
    )
    let queryItems = URLComponents(url: try #require(searchURL), resolvingAgainstBaseURL: false)?.queryItems
    #expect(queryItems?.first { $0.name == "term" }?.value == "Animals Maroon 5")
    #expect(queryItems?.first { $0.name == "entity" }?.value == "song")
    #expect(queryItems?.first { $0.name == "country" }?.value == "US")

    let malformedStorefrontURL = HighResolutionArtworkPolicy.iTunesSearchURL(
        title: "Animals",
        artist: "Maroon 5",
        countryCode: "United States"
    )
    let malformedStorefrontQueryItems = URLComponents(
        url: try #require(malformedStorefrontURL),
        resolvingAgainstBaseURL: false
    )?.queryItems
    #expect(malformedStorefrontQueryItems?.contains { $0.name == "country" } == false)
}

@Test
func aTrackWithNeitherTitleNorArtistHasNothingToSearchFor() {
    #expect(HighResolutionArtworkPolicy.iTunesSearchURL(title: "", artist: nil, countryCode: "US") == nil)
}

// MARK: - Whether a candidate is worth swapping in

/// A candidate that is barely larger buys nothing and still costs a visible
/// swap, so the improvement has to clear a margin rather than merely exist.
@Test
func aCandidateReplacesTheLocalArtworkOnlyWhenItIsSubstantiallyLarger() {
    #expect(
        HighResolutionArtworkPolicy.isWorthReplacing(
            candidateLongestEdge: 700,
            localArtworkLongestEdge: 600
        ) == false
    )
    #expect(
        HighResolutionArtworkPolicy.isWorthReplacing(
            candidateLongestEdge: 720,
            localArtworkLongestEdge: 600
        )
    )
}

/// With no local artwork there is no size to beat, so the candidate is measured
/// against an absolute floor instead.
@Test
func withoutLocalArtworkACandidateOnlyHasToClearTheAbsoluteFloor() {
    #expect(
        HighResolutionArtworkPolicy.isWorthReplacing(
            candidateLongestEdge: 500,
            localArtworkLongestEdge: nil
        ) == false
    )
    #expect(
        HighResolutionArtworkPolicy.isWorthReplacing(
            candidateLongestEdge: 600,
            localArtworkLongestEdge: nil
        )
    )
}

// MARK: - Cache identity

/// The same song reported by two players differs in case, punctuation and
/// accents; keying on the raw strings would miss the cache entry it just wrote.
@Test
func theCacheKeyIgnoresCasePunctuationAndAccents() {
    let playerReported = HighResolutionArtworkPolicy.cacheKey(
        title: "Où Es-Tu?",
        artist: "Céline Dion",
        album: "D'eux"
    )
    let catalogueReported = HighResolutionArtworkPolicy.cacheKey(
        title: "ou es tu",
        artist: "celine dion",
        album: "d eux"
    )
    #expect(playerReported != nil)
    #expect(playerReported == catalogueReported)
}

@Test
func theCacheKeySeparatesDifferentAlbums() {
    let studioAlbumKey = HighResolutionArtworkPolicy.cacheKey(
        title: "Song",
        artist: "Artist",
        album: "Studio Album"
    )
    let liveAlbumKey = HighResolutionArtworkPolicy.cacheKey(
        title: "Song",
        artist: "Artist",
        album: "Live Album"
    )
    #expect(studioAlbumKey != liveAlbumKey)
}

@Test
func aTrackWithoutTitleOrArtistHasNoCacheIdentity() {
    #expect(HighResolutionArtworkPolicy.cacheKey(title: nil, artist: "  ", album: "Album") == nil)
}

// MARK: - The metadata fallback

/// The fallback only runs when the player published no artwork, so it is the
/// only thing standing between the panel and a wrong cover. A catalogue's
/// remaster suffix must not defeat it, and a different recording must.
@Test
func theMetadataFallbackAcceptsABracketedSuffixOnEitherSide() {
    #expect(
        HighResolutionArtworkPolicy.metadataMatches(
            candidateTitle: "Yesterday (Remastered 2009)",
            candidateArtist: "The Beatles",
            candidateDuration: 125,
            trackTitle: "Yesterday",
            trackArtist: "The Beatles",
            trackDuration: 125
        )
    )
}

@Test
func theMetadataFallbackAcceptsExtraFeaturedArtists() {
    #expect(
        HighResolutionArtworkPolicy.metadataMatches(
            candidateTitle: "Moves Like Jagger",
            candidateArtist: "Maroon 5 feat. Christina Aguilera",
            candidateDuration: 201,
            trackTitle: "Moves Like Jagger",
            trackArtist: "Maroon 5",
            trackDuration: 201
        )
    )
}

/// Prefix matching on artists is what admits the featured-artist case above, and
/// it is also what would let an unrelated act through if the boundary were not
/// checked.
@Test
func theMetadataFallbackRejectsAnArtistThatMerelyStartsTheSameWay() {
    #expect(
        HighResolutionArtworkPolicy.metadataMatches(
            candidateTitle: "Hello",
            candidateArtist: "Adelestein",
            candidateDuration: 295,
            trackTitle: "Hello",
            trackArtist: "Adele",
            trackDuration: 295
        ) == false
    )
}

/// Same title, same artist, different recording — a live take or a radio edit.
/// Duration is the only signal that separates them.
@Test
func theMetadataFallbackRejectsARecordingOfADifferentLength() {
    #expect(
        HighResolutionArtworkPolicy.metadataMatches(
            candidateTitle: "Hello",
            candidateArtist: "Adele",
            candidateDuration: 340,
            trackTitle: "Hello",
            trackArtist: "Adele",
            trackDuration: 295
        ) == false
    )
}

/// A player that publishes no artwork often publishes no duration either. That
/// must not by itself sink an otherwise clean title and artist match, or the
/// fallback would never fire for the very players it exists to serve.
@Test
func theMetadataFallbackStillMatchesWhenTheTrackDurationIsUnknown() {
    #expect(
        HighResolutionArtworkPolicy.metadataMatches(
            candidateTitle: "Hello",
            candidateArtist: "Adele",
            candidateDuration: 295,
            trackTitle: "Hello",
            trackArtist: "Adele",
            trackDuration: nil
        )
    )
}

// MARK: - NetEase's catalogue

@Test
func theNetEaseSearchPostsTheTrackTermWithTheHeadersTheEndpointExpects() throws {
    let request = try #require(
        HighResolutionArtworkPolicy.netEaseSearchRequest(title: "心做し", artist: "鹿乃", cookie: nil)
    )
    #expect(request.httpMethod == "POST")
    #expect(request.url?.host == "music.163.com")
    #expect(request.url?.path == "/api/search/pc")
    let requestURL = try #require(request.url)
    let queryItems = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems
    #expect(queryItems?.first { $0.name == "s" }?.value == "心做し 鹿乃")
    #expect(queryItems?.first { $0.name == "type" }?.value == "1")
    #expect(request.value(forHTTPHeaderField: "Referer") == "http://music.163.com/")
    #expect(request.value(forHTTPHeaderField: "User-Agent") != nil)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(request.httpShouldHandleCookies == false)
}

/// The endpoint refuses a request without its session cookie and sets that
/// cookie on the refusal; the retry carries it back.
@Test
func theNetEaseRetryCarriesTheSessionCookieFromTheRefusal() throws {
    let cookie = HighResolutionArtworkPolicy.netEaseSessionCookie(
        fromSetCookieHeader: "NMTID=00O5A6ob8rqyV; Max-Age=315360000; Expires=Wed, 13 Nov 2036 13:47:00 GMT; Path=/"
    )
    #expect(cookie == "NMTID=00O5A6ob8rqyV")

    let retry = try #require(
        HighResolutionArtworkPolicy.netEaseSearchRequest(title: "心做し", artist: "鹿乃", cookie: cookie)
    )
    #expect(retry.value(forHTTPHeaderField: "Cookie") == "NMTID=00O5A6ob8rqyV")
}

@Test
func aMissingOrMalformedSetCookieHeaderGivesNoCookie() {
    #expect(HighResolutionArtworkPolicy.netEaseSessionCookie(fromSetCookieHeader: nil) == nil)
    #expect(HighResolutionArtworkPolicy.netEaseSessionCookie(fromSetCookieHeader: "") == nil)
    #expect(HighResolutionArtworkPolicy.netEaseSessionCookie(fromSetCookieHeader: "Path=/; HttpOnly")
        == "Path=/")
    #expect(HighResolutionArtworkPolicy.netEaseSessionCookie(fromSetCookieHeader: "HttpOnly") == nil)
}

@Test
func aTrackWithNeitherTitleNorArtistIsNotSearchedOnNetEase() {
    #expect(HighResolutionArtworkPolicy.netEaseSearchRequest(title: " ", artist: nil, cookie: nil) == nil)
}

/// Shaped like a real answer: several artists are joined the way the NetEase
/// client shows them, durations are in milliseconds, and a song without a
/// cover is left out rather than failing the whole answer.
@Test
func netEaseSearchResultsBecomeCatalogueEntries() throws {
    let answer = Data("""
    {"result":{"songs":[
      {"name":"心做し","artists":[{"name":"鹿乃"}],"album":{"name":"メリー",
       "picUrl":"http://p1.music.126.net/w5-FU13Owl_VbKfybBwx3A==/2884019003563753.jpg"},"duration":269746},
      {"name":"清空","artists":[{"name":"苏星婕"},{"name":"王忻辰"}],"album":{"name":"清空",
       "picUrl":"http://p1.music.126.net/abc==/109951167814138971.jpg"},"duration":200000},
      {"name":"No Cover","artists":[{"name":"Someone"}],"album":{"name":"Unknown"},"duration":1000}
    ],"songCount":3},"code":200}
    """.utf8)

    let entries = try #require(HighResolutionArtworkPolicy.netEaseSearchEntries(from: answer))
    let firstCoverURL = try #require(
        URL(string: "http://p1.music.126.net/w5-FU13Owl_VbKfybBwx3A==/2884019003563753.jpg")
    )
    let secondCoverURL = try #require(URL(string: "http://p1.music.126.net/abc==/109951167814138971.jpg"))
    #expect(entries == [
        ArtworkCatalogueEntry(
            artworkURL: firstCoverURL,
            title: "心做し",
            artist: "鹿乃",
            duration: 269.746
        ),
        ArtworkCatalogueEntry(
            artworkURL: secondCoverURL,
            title: "清空",
            artist: "苏星婕/王忻辰",
            duration: 200
        ),
    ])
}

/// A refusal is not evidence that the song has no cover there — only a search
/// that ran and found nothing is.
@Test
func aRefusalIsNotAnEmptySearch() {
    let refusal = Data(#"{"code":-462,"data":{"blockText":"绑定手机后，可进行下一步操作哦~"},"message":"请绑定手机后再试哦"}"#.utf8)
    #expect(HighResolutionArtworkPolicy.netEaseSearchEntries(from: refusal) == nil)
    #expect(HighResolutionArtworkPolicy.netEaseSearchEntries(from: Data("<html>".utf8)) == nil)

    let nothingFound = Data(#"{"result":{"songCount":0},"code":200}"#.utf8)
    #expect(HighResolutionArtworkPolicy.netEaseSearchEntries(from: nothingFound) == [])
}
