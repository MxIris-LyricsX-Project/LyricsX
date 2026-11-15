import AppKit
import Foundation
import LyricsXFoundation

// Compares covers against the currently playing track's artwork: to re-rank
// lyrics candidates whose cover visually matches it, and to verify a
// higher-resolution cover before the lyrics panel shows it. How two images are
// fingerprinted and what counts as a match is `ArtworkFingerprint` and
// `ArtworkFingerprintComparison`; what lives here is the playing track's
// reference, the downloads and the per-URL cache.

/// What comparing an image against the playing track's artwork established.
enum ArtworkComparisonOutcome {
    /// The playing track published no artwork, so there is nothing to compare
    /// against — not a rejection.
    case noReference
    case match
    case mismatch
}

actor ArtworkSimilarityScorer {
    static let shared = ArtworkSimilarityScorer()

    private var currentFingerprint: ArtworkFingerprint?
    private var currentTrackId: String?

    private let candidateDownloadLimit = 24
    private var inflightDownloads = 0
    private var cachedFingerprints: [URL: ArtworkFingerprint] = [:]
    private let cacheCapacity = 256

    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                          diskCapacity: 0)
        return URLSession(configuration: configuration)
    }()

    /// Bonus added to a candidate's quality when its artwork matches the
    /// currently playing track.
    static let matchBonus = 0.15

    private init() {}

    // MARK: - Now-Playing side

    func updateNowPlaying(image: NSImage?, trackId: String?) {
        if trackId == nil {
            currentFingerprint = nil
            currentTrackId = nil
            return
        }
        if trackId == currentTrackId {
            return
        }
        currentFingerprint = image.flatMap { Self.fingerprint(image: $0) }
        currentTrackId = trackId
    }

    /// Fills in the reference for a track whose artwork only turned up later.
    /// ScriptingBridge caches an `NSNull` for `artwork` often enough that the
    /// first look at a track comes back empty while the raw AppleEvent bytes are
    /// there for the asking — see `MusicTrack.resolvedArtwork`. Without this the
    /// artwork-bearing players would fall through to the weaker metadata check.
    func supplyNowPlayingIfMissing(image: NSImage, trackIdentifier: String) {
        guard trackIdentifier == currentTrackId, currentFingerprint == nil else { return }
        currentFingerprint = Self.fingerprint(image: image)
    }

    /// Whether an image the caller already holds shows the same cover as the
    /// playing track, with no download involved.
    ///
    /// `noReference` is its own answer rather than a `false`: the caller has to
    /// tell "this is a different cover" (reject it) apart from "there is nothing
    /// to compare against" (fall back to comparing metadata).
    func evaluate(image: NSImage) -> ArtworkComparisonOutcome {
        guard let target = currentFingerprint else {
            return .noReference
        }
        guard let candidate = Self.fingerprint(image: image) else {
            return .mismatch
        }
        return matches(candidate, against: target, describedAs: "in-memory")
            ? .match
            : .mismatch
    }

    // MARK: - Candidate-side scoring

    func matches(artworkURL: URL) async -> Bool {
        guard let target = currentFingerprint else {
            NSLog("[ArtworkMatch] skip url=%@ reason=no-now-playing-fingerprint", artworkURL.absoluteString)
            return false
        }

        let candidate: ArtworkFingerprint
        if let cached = cachedFingerprints[artworkURL] {
            candidate = cached
        } else {
            guard inflightDownloads < candidateDownloadLimit else {
                NSLog("[ArtworkMatch] skip url=%@ reason=throttled inflight=%d", artworkURL.absoluteString, inflightDownloads)
                return false
            }
            inflightDownloads += 1
            defer { inflightDownloads -= 1 }

            guard let computed = await Self.downloadAndFingerprint(url: artworkURL, session: urlSession) else {
                NSLog("[ArtworkMatch] skip url=%@ reason=download-or-fingerprint-failed", artworkURL.absoluteString)
                return false
            }
            if cachedFingerprints.count >= cacheCapacity {
                cachedFingerprints.removeAll(keepingCapacity: true)
            }
            cachedFingerprints[artworkURL] = computed
            candidate = computed
        }

        return matches(candidate, against: target, describedAs: artworkURL.absoluteString)
    }

    private func matches(
        _ candidate: ArtworkFingerprint,
        against target: ArtworkFingerprint,
        describedAs description: String
    ) -> Bool {
        let comparison = candidate.compared(to: target)
        NSLog(
            "[ArtworkMatch] url=%@ hashDist=%d (strong ≤%d, limit ≤%d) chromaDist=%.1f (≤%.0f) -> %@",
            description,
            comparison.hashDistance,
            ArtworkFingerprintComparison.strongHashDistanceThreshold,
            ArtworkFingerprintComparison.hashDistanceThreshold,
            comparison.chrominanceDistance,
            ArtworkFingerprintComparison.chrominanceDistanceThreshold,
            comparison.isMatch ? "MATCH" : "NO-MATCH"
        )
        return comparison.isMatch
    }

    // MARK: - Pipeline

    private static func downloadAndFingerprint(url: URL, session: URLSession) async -> ArtworkFingerprint? {
        do {
            let (data, _) = try await session.data(from: url)
            guard let image = NSImage(data: data) else { return nil }
            return fingerprint(image: image)
        } catch {
            return nil
        }
    }

    private static func fingerprint(image: NSImage) -> ArtworkFingerprint? {
        var imageRect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let cgImage = image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) else {
            return nil
        }
        return ArtworkFingerprint(image: cgImage)
    }
}
