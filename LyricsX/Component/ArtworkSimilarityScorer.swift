import AppKit
import CoreGraphics
import Foundation

// Re-ranks lyrics candidates whose cover artwork visually matches the
// currently playing track. The decision is driven primarily by a 64-bit dHash
// (difference hash) of the image *structure*, with a colour check that only
// intervenes in an ambiguous band:
//
//   1. dHash within `strongHashDistanceThreshold` bits — the structures are,
//      to a ~10^-14 false-match probability, the same image. Accept outright.
//      dHash works on luminance and is therefore colour-blind, so a template
//      cover recoloured per release could in principle land here; in practice
//      that requires near-identical brightness structure, which is rare enough
//      that the strong band is safe to wave through.
//   2. dHash within `dHashDistanceThreshold` but past the strong threshold —
//      the "ambiguous band". Here we additionally require the two artworks to
//      share a *chrominance* (hue/saturation) signature, which rejects the
//      "same layout, different palette" template collisions while still
//      admitting the same cover re-encoded at a different brightness.
//
// Why chrominance and not absolute RGB? The now-playing image is decoded and
// colour-managed by the system; the candidate is a CDN JPEG. The two routinely
// differ in overall *brightness* (gamma, colour-profile conversion, JPEG
// quality) while depicting the identical cover. The previous gate compared the
// absolute average RGB on every channel with an L∞ threshold, so a uniform
// brightness shift — which leaves the actual hue untouched — moved all three
// channels together past the threshold and wrongly rejected real matches.
// Comparing luma-independent chrominance (YCbCr Cb/Cr) cancels an additive
// brightness offset by construction, because the colour-difference weights sum
// to zero.
//
// Sampling resolutions:
//   - dHash uses the classic 9×8 luminance grid (72 px, 64-bit hash).
//   - The average colour samples a 32×32 grid (1024 px) so JPEG quantisation,
//      padding and different CDN crops average out instead of skewing the
//      chrominance — at 9×8 a single pixel is ~1.4% of the mean, an order of
//      magnitude noisier.

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

    // Matching thresholds.
    //   - dHashDistanceThreshold: the outer bound. Past this the structures
    //     differ enough that we never call it a match (~85% of bits must
    //     agree). Admits the same image at different resolutions / compression.
    //   - strongHashDistanceThreshold: at or under this the structures are
    //     essentially identical (random collision ~10^-14), so we accept
    //     without the colour check — that is what stops a brightness/encoding
    //     shift on a genuine match from being vetoed.
    //   - chrominanceDistanceThreshold: Euclidean distance in the (Cb, Cr)
    //     chrominance plane (each component spans roughly ±128). Only consulted
    //     in the ambiguous band. Loose enough to tolerate re-encoding & gentle
    //     remasters, tight enough to reject a recoloured template. Tune against
    //     the chromaDist values logged below.
    private let dHashDistanceThreshold = 10
    private let strongHashDistanceThreshold = 4
    private let chrominanceDistanceThreshold = 30.0

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

        let hashDistance = Self.hammingDistance(target.dHash, candidate.dHash)
        guard hashDistance <= dHashDistanceThreshold else {
            NSLog("[ArtworkMatch] url=%@ hashDist=%d (>%d) -> NO-MATCH",
                  artworkURL.absoluteString, hashDistance, dHashDistanceThreshold)
            return false
        }

        // Strong structural match: accept without consulting colour, so a
        // brightness/encoding shift on a genuine match cannot veto it.
        if hashDistance <= strongHashDistanceThreshold {
            NSLog("[ArtworkMatch] url=%@ hashDist=%d (≤%d strong) -> MATCH",
                  artworkURL.absoluteString, hashDistance, strongHashDistanceThreshold)
            return true
        }

        // Ambiguous band: require a matching chrominance signature to reject
        // "same template, recoloured" collisions, ignoring overall brightness.
        let chrominanceDistance = Self.chrominanceDistance(target, candidate)
        let matched = chrominanceDistance <= chrominanceDistanceThreshold
        NSLog("[ArtworkMatch] url=%@ hashDist=%d (≤%d) chromaDist=%.1f (≤%.0f:%@) -> %@",
              artworkURL.absoluteString,
              hashDistance, dHashDistanceThreshold,
              chrominanceDistance, chrominanceDistanceThreshold, matched ? "OK" : "FAIL",
              matched ? "MATCH" : "NO-MATCH")
        return matched
    }

    // MARK: - Pipeline (pure helpers)

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
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var imageRect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let cgImage = image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) else {
            return nil
        }

        guard let dHash = computeDHash(cgImage: cgImage, colorSpace: colorSpace) else { return nil }
        guard let averageColor = computeAverageColor(cgImage: cgImage, colorSpace: colorSpace) else { return nil }

        return ArtworkFingerprint(
            dHash: dHash,
            avgR: averageColor.r,
            avgG: averageColor.g,
            avgB: averageColor.b
        )
    }

    // Render `cgImage` into a freshly allocated sRGB premultiplied bitmap of
    // size width×height. The closure runs with a pointer to the raw bytes,
    // which is valid for the duration of the call only.
    private static func withRenderedBitmap<T>(
        cgImage: CGImage,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace,
        body: (UnsafePointer<UInt8>) -> T
    ) -> T? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        return body(data.assumingMemoryBound(to: UInt8.self))
    }

    private static func computeDHash(cgImage: CGImage, colorSpace: CGColorSpace) -> UInt64? {
        let width = 9
        let height = 8
        let bytesPerPixel = 4
        return withRenderedBitmap(cgImage: cgImage, width: width, height: height, colorSpace: colorSpace) { bytes in
            let pixelCount = width * height
            var luminance = [UInt8](repeating: 0, count: pixelCount)
            for index in 0..<pixelCount {
                let r = Int(bytes[index * bytesPerPixel])
                let g = Int(bytes[index * bytesPerPixel + 1])
                let b = Int(bytes[index * bytesPerPixel + 2])
                // Rec. 601 luma in integer math.
                let luma = (r * 299 + g * 587 + b * 114) / 1000
                luminance[index] = UInt8(min(255, luma))
            }
            var hash: UInt64 = 0
            for row in 0..<height {
                let rowStart = row * width
                for column in 0..<(width - 1) {
                    let left = luminance[rowStart + column]
                    let right = luminance[rowStart + column + 1]
                    hash <<= 1
                    if left > right {
                        hash |= 1
                    }
                }
            }
            return hash
        }
    }

    private static func computeAverageColor(cgImage: CGImage, colorSpace: CGColorSpace) -> (r: UInt8, g: UInt8, b: UInt8)? {
        // 32×32 (1024 px) — see file-level comment for the rationale behind
        // sampling at a higher resolution than dHash.
        let width = 32
        let height = 32
        let bytesPerPixel = 4
        return withRenderedBitmap(cgImage: cgImage, width: width, height: height, colorSpace: colorSpace) { bytes in
            let pixelCount = width * height
            var sumR = 0
            var sumG = 0
            var sumB = 0
            for index in 0..<pixelCount {
                sumR += Int(bytes[index * bytesPerPixel])
                sumG += Int(bytes[index * bytesPerPixel + 1])
                sumB += Int(bytes[index * bytesPerPixel + 2])
            }
            return (
                r: UInt8(sumR / pixelCount),
                g: UInt8(sumG / pixelCount),
                b: UInt8(sumB / pixelCount)
            )
        }
    }

    private static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    /// Euclidean distance between the two fingerprints' average colours in the
    /// luma-independent (Cb, Cr) chrominance plane. A brightness difference
    /// between a system-decoded now-playing image and a CDN JPEG of the same
    /// cover largely cancels here — Cb/Cr weights sum to zero, so a uniform
    /// luma offset drops out — while a genuinely different palette does not.
    private static func chrominanceDistance(_ first: ArtworkFingerprint, _ second: ArtworkFingerprint) -> Double {
        func chrominance(_ fingerprint: ArtworkFingerprint) -> (cb: Double, cr: Double) {
            let red = Double(fingerprint.avgR)
            let green = Double(fingerprint.avgG)
            let blue = Double(fingerprint.avgB)
            // Rec. 601 luma; Cb/Cr are the colour-difference components.
            let luma = 0.299 * red + 0.587 * green + 0.114 * blue
            return (cb: blue - luma, cr: red - luma)
        }
        let firstChrominance = chrominance(first)
        let secondChrominance = chrominance(second)
        let deltaCb = firstChrominance.cb - secondChrominance.cb
        let deltaCr = firstChrominance.cr - secondChrominance.cr
        return (deltaCb * deltaCb + deltaCr * deltaCr).squareRoot()
    }
}

struct ArtworkFingerprint: Hashable, Sendable {
    let dHash: UInt64
    let avgR: UInt8
    let avgG: UInt8
    let avgB: UInt8
}
