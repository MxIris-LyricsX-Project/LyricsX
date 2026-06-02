import AppKit
import CoreGraphics
import Foundation

// Re-ranks lyrics candidates whose cover artwork visually matches the
// currently playing track. Two artworks count as the same if both:
//   1. Their 64-bit dHash (difference hash) is within Hamming distance 10 —
//      i.e. the *shape/structure* of the image is the same up to scaling and
//      compression. dHash alone is colour-blind because it works on
//      luminance, which means template covers recoloured per release would
//      collide.
//   2. Their 24-bit average RGB (one byte per channel) is within ~45/255 on
//      every channel — i.e. the overall *colour mood* is the same. This
//      second gate rejects "same layout, different palette" false matches.
// The two gates use *different* sampling resolutions:
//   - dHash uses the classic 9×8 luminance grid (72 px, 64 bit hash).
//   - The average colour samples a 32×32 grid (1024 px). At 9×8 a single
//      pixel is ~1.4% of the mean, so noise from JPEG quantisation, padding
//      or different CDN crops easily pushed the per-channel mean past 30/255
//      between two visually-identical sources; 32×32 cuts that noise floor
//      by an order of magnitude and lets us keep the colour gate strict
//      enough to reject recoloured templates.

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

    // Matching thresholds. Tuned so:
    //   - dHash slack admits the same image at different resolutions /
    //     compression (~85% bits in common).
    //   - colour slack admits typical CDN re-encoding & gentle remasters but
    //     rejects "same template, recoloured" hits. 45/255 ≈ 18% — looser
    //     than before, but paired with the 32×32 sampling grid the false-
    //     positive risk is no worse than the old 30/255 at 9×8.
    private let dHashDistanceThreshold = 10
    private let perChannelColorDelta = 45

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
        let deltaR = abs(Int(target.avgR) - Int(candidate.avgR))
        let deltaG = abs(Int(target.avgG) - Int(candidate.avgG))
        let deltaB = abs(Int(target.avgB) - Int(candidate.avgB))
        let hashOK = hashDistance <= dHashDistanceThreshold
        let colorOK = deltaR <= perChannelColorDelta
            && deltaG <= perChannelColorDelta
            && deltaB <= perChannelColorDelta
        let matched = hashOK && colorOK
        NSLog("[ArtworkMatch] url=%@ hashDist=%d (≤%d:%@) ΔR=%d ΔG=%d ΔB=%d (≤%d:%@) -> %@",
              artworkURL.absoluteString,
              hashDistance, dHashDistanceThreshold, hashOK ? "OK" : "FAIL",
              deltaR, deltaG, deltaB, perChannelColorDelta, colorOK ? "OK" : "FAIL",
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
}

struct ArtworkFingerprint: Hashable, Sendable {
    let dHash: UInt64
    let avgR: UInt8
    let avgG: UInt8
    let avgB: UInt8
}
