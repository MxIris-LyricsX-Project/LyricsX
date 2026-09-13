import AppKit
import Combine
import Foundation
import LyricsXFoundation
import MusicPlayer

/// A cover found on the network for a track that is playing now.
struct HighResolutionArtwork {
    let trackIdentifier: String
    let image: NSImage
}

/// One place a cover can come from, together with whatever the source claims the
/// recording is. The claim is what stands in for a fingerprint comparison when
/// the player published no artwork to compare against.
struct ArtworkCandidateSource {
    let url: URL
    let title: String?
    let artist: String?
    let duration: TimeInterval?
}

/// Everything the service needs about the playing track, snapshotted on the main
/// thread by the caller so the actor never reaches back into the player.
struct HighResolutionArtworkRequest {
    let trackIdentifier: String
    let title: String?
    let artist: String?
    let album: String?
    let duration: TimeInterval?
    /// What the player itself published, if anything. Doubles as the reference
    /// the candidates are fingerprinted against and as the size to beat.
    let localArtwork: NSImage?
    /// The cover URL the matched lyrics carried, once lyrics have arrived.
    let lyricsArtwork: ArtworkCandidateSource?
    /// Whether a fruitless search may be remembered. The pass triggered by a
    /// track change must not: the lyrics — and with them a second source — have
    /// not arrived yet, and a miss recorded now would suppress that whole route
    /// on every later replay.
    let mayRecordMiss: Bool
}

/// Finds a higher-resolution copy of the playing track's cover than the music
/// player publishes, and hands it to the Apple Music-style lyrics panel.
///
/// See `Documentations/Evolutions/0015-high-resolution-panel-artwork.md`. The
/// decisions this makes — which URL to ask for, what counts as an improvement,
/// what identifies a song — are `HighResolutionArtworkPolicy`; what lives here is
/// the network, the disk cache and the verification handshake with
/// `ArtworkSimilarityScorer`.
///
/// Nothing here runs unless the panel window is open: the window controller owns
/// the subscriptions that drive it.
@Loggable(subsystem: "com.JH.LyricsX.HighResolutionArtwork", category: "HighResolutionArtwork")
actor HighResolutionArtworkService {
    static let shared = HighResolutionArtworkService()

    private nonisolated let artworkSubject = PassthroughSubject<HighResolutionArtwork, Never>()

    nonisolated var artworkPublisher: AnyPublisher<HighResolutionArtwork, Never> {
        artworkSubject.eraseToAnyPublisher()
    }

    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private let cacheDirectoryURL: URL?

    /// The track every piece of per-track state below belongs to.
    private var currentTrackIdentifier: String?
    /// The longest edge already on screen for that track, so a second pass never
    /// swaps in something no better than what it published itself.
    private var publishedLongestEdge: Int?
    /// What the iTunes search returned for that track, unfiltered. The search
    /// runs once — its results do not change while one song plays — but which of
    /// them are worth downloading is decided again on every pass, because that
    /// depends on whether the player has published artwork yet. Left `nil` when
    /// the search itself failed, so a later pass retries it.
    private var iTunesResults: [ArtworkCandidateSource]?
    /// Covers already downloaded for that track, kept so a later pass can
    /// re-run verification without re-fetching. A later pass can reach a
    /// different verdict than the first: the player often publishes its own
    /// artwork a beat after the track change, which turns the weaker metadata
    /// check into a real fingerprint comparison.
    private var downloadedCandidates: [DownloadedCandidate] = []
    private var hasPrunedCacheDirectory = false

    private init() {
        cacheDirectoryURL = Self.makeCacheDirectory()
    }

    // MARK: - Resolution

    func resolve(_ request: HighResolutionArtworkRequest) async {
        guard defaults[.highResolutionPanelArtworkEnabled] else { return }

        if request.trackIdentifier != currentTrackIdentifier {
            currentTrackIdentifier = request.trackIdentifier
            publishedLongestEdge = nil
            iTunesResults = nil
            downloadedCandidates = []
        }

        guard let cacheKey = HighResolutionArtworkPolicy.cacheKey(
            title: request.title,
            artist: request.artist,
            album: request.album
        ) else {
            return
        }

        // The panel's own artwork lookup falls back to reading the raw
        // AppleEvent bytes when ScriptingBridge hands back a cached `NSNull`, so
        // the track can have artwork that `AppController` never saw and never
        // fingerprinted. Fill that in before anything is compared against it.
        if let localArtwork = request.localArtwork {
            await ArtworkSimilarityScorer.shared.supplyNowPlayingIfMissing(
                image: localArtwork,
                trackIdentifier: request.trackIdentifier
            )
        }

        let localLongestEdge = request.localArtwork?.longestPixelEdge

        if publishedLongestEdge == nil,
           let cachedArtwork = loadCachedArtwork(forKey: cacheKey) {
            // Cached covers were verified before they were written, so this only
            // has to be a size question.
            if HighResolutionArtworkPolicy.isWorthReplacing(
                candidateLongestEdge: cachedArtwork.longestPixelEdge,
                localArtworkLongestEdge: localLongestEdge
            ) {
                publishedLongestEdge = cachedArtwork.longestPixelEdge
                publish(cachedArtwork, for: request.trackIdentifier)
            }
            return
        }

        // One published cover per track is enough; a second pass would spend
        // more requests chasing a marginal size difference nobody can see.
        guard publishedLongestEdge == nil else { return }

        if hasFreshMiss(forKey: cacheKey) { return }

        await downloadPendingCandidates(for: request)

        guard let best = await bestVerifiedCandidate(
            request: request,
            localLongestEdge: localLongestEdge
        ) else {
            recordMissIfAllowed(request, forKey: cacheKey)
            return
        }

        store(best.data, forKey: cacheKey)
        publishedLongestEdge = best.longestEdge
        publish(best.image, for: request.trackIdentifier)
        #log(
            .info,
            """
            Upgraded artwork longestEdge=\(best.longestEdge, privacy: .public) \
            host=\(best.source.url.host ?? "unknown", privacy: .public) \
            wasLongestEdge=\(localLongestEdge ?? 0, privacy: .public)
            """
        )
    }

    private func publish(_ image: NSImage, for trackIdentifier: String) {
        artworkSubject.send(
            HighResolutionArtwork(trackIdentifier: trackIdentifier, image: image)
        )
    }

    // MARK: - Sources

    /// Every source worth trying for this track, asked for its largest rendition.
    private func candidateSources(
        for request: HighResolutionArtworkRequest
    ) async -> [ArtworkCandidateSource] {
        let results: [ArtworkCandidateSource]
        if let iTunesResults {
            results = iTunesResults
        } else if let fetched = await fetchITunesResults(for: request) {
            iTunesResults = fetched
            results = fetched
        } else {
            results = []
        }

        var sources = selectedITunesResults(from: results, request: request)
        if let lyricsArtwork = request.lyricsArtwork {
            sources.append(lyricsArtwork)
        }
        return sources.map { source in
            ArtworkCandidateSource(
                url: HighResolutionArtworkPolicy.upgradedArtworkURL(source.url),
                title: source.title,
                artist: source.artist,
                duration: source.duration
            )
        }
    }

    /// `nil` when the search could not be run or its answer could not be read,
    /// which is a different thing from a search that legitimately found nothing:
    /// only the latter is worth remembering for the rest of the song.
    private func fetchITunesResults(
        for request: HighResolutionArtworkRequest
    ) async -> [ArtworkCandidateSource]? {
        guard let searchURL = HighResolutionArtworkPolicy.iTunesSearchURL(
            title: request.title,
            artist: request.artist,
            countryCode: defaults[.appleMusicStorefront]
        ) else {
            return []
        }
        guard let (data, _) = try? await urlSession.data(from: searchURL),
              let response = try? JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        else {
            return nil
        }
        return response.results.compactMap { result -> ArtworkCandidateSource? in
            guard let artworkURLString = result.artworkUrl100,
                  let artworkURL = URL(string: artworkURLString)
            else {
                return nil
            }
            return ArtworkCandidateSource(
                url: artworkURL,
                title: result.trackName,
                artist: result.artistName,
                duration: result.trackTimeMillis.map { TimeInterval($0) / 1000 }
            )
        }
    }

    /// Which search results to spend a download on. Re-decided every pass: a
    /// result that fails the metadata check is still worth fetching once there
    /// is a local cover to fingerprint it against, and that cover routinely
    /// arrives after the first pass has already run.
    private func selectedITunesResults(
        from results: [ArtworkCandidateSource],
        request: HighResolutionArtworkRequest
    ) -> [ArtworkCandidateSource] {
        let matchingResults = results.filter { source in
            metadataMatches(source, request: request)
        }
        if !matchingResults.isEmpty {
            return Array(matchingResults.prefix(3))
        }
        // Nothing matched on metadata. Downloading anyway is only worth it when
        // there is a local cover to fingerprint against — without one, an
        // unmatched result could never clear verification.
        return request.localArtwork == nil ? [] : Array(results.prefix(2))
    }

    private struct ITunesSearchResponse: Decodable {
        struct Result: Decodable {
            let trackName: String?
            let artistName: String?
            let artworkUrl100: String?
            let trackTimeMillis: Int?
        }

        let results: [Result]
    }

    // MARK: - Verification

    private struct DownloadedCandidate {
        let source: ArtworkCandidateSource
        let image: NSImage
        let data: Data
        let longestEdge: Int
    }

    private func downloadPendingCandidates(for request: HighResolutionArtworkRequest) async {
        let alreadyDownloadedURLs = Set(downloadedCandidates.map(\.source.url))
        let pendingSources = await candidateSources(for: request)
            .filter { !alreadyDownloadedURLs.contains($0.url) }
        guard !pendingSources.isEmpty else { return }

        let fetched = await withTaskGroup(
            of: DownloadedCandidate?.self,
            returning: [DownloadedCandidate].self
        ) { [urlSession] group in
            for source in pendingSources {
                group.addTask {
                    guard let (data, _) = try? await urlSession.data(from: source.url),
                          let image = NSImage(data: data)
                    else {
                        return nil
                    }
                    return DownloadedCandidate(
                        source: source,
                        image: image,
                        data: data,
                        longestEdge: image.longestPixelEdge
                    )
                }
            }
            var candidates: [DownloadedCandidate] = []
            for await candidate in group {
                if let candidate {
                    candidates.append(candidate)
                }
            }
            return candidates
        }

        // The track may have moved on while these were in flight.
        guard request.trackIdentifier == currentTrackIdentifier else { return }
        downloadedCandidates.append(contentsOf: fetched)
    }

    private func bestVerifiedCandidate(
        request: HighResolutionArtworkRequest,
        localLongestEdge: Int?
    ) async -> DownloadedCandidate? {
        var best: DownloadedCandidate?
        for candidate in downloadedCandidates.sorted(by: { $0.longestEdge > $1.longestEdge }) {
            guard candidate.longestEdge > (best?.longestEdge ?? 0) else { continue }
            guard HighResolutionArtworkPolicy.isWorthReplacing(
                candidateLongestEdge: candidate.longestEdge,
                localArtworkLongestEdge: localLongestEdge
            ) else {
                continue
            }
            guard await depictsTheSameCover(candidate, request: request) else { continue }
            best = candidate
        }
        return best
    }

    /// A replacement has to be the *same* cover, or the panel would confidently
    /// show a wrong one — the sharper the picture, the more convincing the
    /// mistake.
    private func depictsTheSameCover(
        _ candidate: DownloadedCandidate,
        request: HighResolutionArtworkRequest
    ) async -> Bool {
        switch await ArtworkSimilarityScorer.shared.evaluate(image: candidate.image) {
        case .match:
            return true
        case .mismatch:
            return false
        case .noReference:
            return metadataMatches(candidate.source, request: request)
        }
    }

    private func metadataMatches(
        _ source: ArtworkCandidateSource,
        request: HighResolutionArtworkRequest
    ) -> Bool {
        HighResolutionArtworkPolicy.metadataMatches(
            candidateTitle: source.title,
            candidateArtist: source.artist,
            candidateDuration: source.duration,
            trackTitle: request.title,
            trackArtist: request.artist,
            trackDuration: request.duration
        )
    }

    // MARK: - Disk cache

    private static func makeCacheDirectory() -> URL? {
        guard let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.JH.LyricsX"
        let directoryURL = cachesURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("HighResolutionArtwork", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }
        return directoryURL
    }

    private func artworkFileURL(forKey key: String) -> URL? {
        cacheDirectoryURL?.appendingPathComponent(key).appendingPathExtension("artwork")
    }

    private func missFileURL(forKey key: String) -> URL? {
        cacheDirectoryURL?.appendingPathComponent(key).appendingPathExtension("miss")
    }

    private func loadCachedArtwork(forKey key: String) -> NSImage? {
        guard let fileURL = artworkFileURL(forKey: key),
              let data = try? Data(contentsOf: fileURL),
              let image = NSImage(data: data)
        else {
            return nil
        }
        // Touch it so pruning drops the covers nobody plays any more first.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
        return image
    }

    private func store(_ data: Data, forKey key: String) {
        guard let fileURL = artworkFileURL(forKey: key) else { return }
        try? data.write(to: fileURL, options: .atomic)
        if let missURL = missFileURL(forKey: key) {
            try? FileManager.default.removeItem(at: missURL)
        }
        pruneCacheDirectoryIfNeeded()
    }

    private func hasFreshMiss(forKey key: String) -> Bool {
        guard let fileURL = missFileURL(forKey: key),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let recordedAt = attributes[.modificationDate] as? Date
        else {
            return false
        }
        guard Date().timeIntervalSince(recordedAt)
            <= HighResolutionArtworkPolicy.negativeResultLifetime else {
            try? FileManager.default.removeItem(at: fileURL)
            return false
        }
        return true
    }

    private func recordMissIfAllowed(
        _ request: HighResolutionArtworkRequest,
        forKey key: String
    ) {
        // A search that could not be run at all — no network, a rejected
        // request — is not evidence that this song has no better cover, and
        // must not be written down as one for a week.
        guard iTunesResults != nil else { return }
        guard request.mayRecordMiss, let fileURL = missFileURL(forKey: key) else { return }
        try? Data().write(to: fileURL, options: .atomic)
        pruneCacheDirectoryIfNeeded()
    }

    private func pruneCacheDirectoryIfNeeded() {
        guard !hasPrunedCacheDirectory, let cacheDirectoryURL else { return }
        hasPrunedCacheDirectory = true
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        guard entries.count > HighResolutionArtworkPolicy.cachedArtworkFileLimit else { return }
        let oldestFirst = entries.sorted { first, second in
            let firstDate = (try? first.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let secondDate = (try? second.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return firstDate < secondDate
        }
        let excessCount = entries.count - HighResolutionArtworkPolicy.cachedArtworkFileLimit
        for fileURL in oldestFirst.prefix(excessCount) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

extension NSImage {
    /// The longest edge in *pixels*. `size` is in points and follows whatever
    /// resolution the source declared — a 1200×1200 JPEG tagged at 144 dpi
    /// reports a 600 pt size — so comparing sizes would rank a large image small.
    var longestPixelEdge: Int {
        let representationEdges = representations.map { max($0.pixelsWide, $0.pixelsHigh) }
        if let largest = representationEdges.max(), largest > 0 {
            return largest
        }
        return Int(max(size.width, size.height).rounded())
    }
}
