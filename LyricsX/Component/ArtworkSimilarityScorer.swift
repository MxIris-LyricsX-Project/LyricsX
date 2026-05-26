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
//   2. Their 24-bit average RGB (one byte per channel) is within ~30/255 on
//      every channel — i.e. the overall *colour mood* is the same. This
//      second gate rejects "same layout, different palette" false matches.
// 9×8 was kept as the working size for both the dHash bit grid and the
// colour average; the average is noisy at that resolution but the threshold
// is loose enough (30/255) to tolerate it.

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
    //     rejects "same template, recoloured" hits.
    private let dHashDistanceThreshold = 10
    private let perChannelColorDelta = 30

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
            return false
        }

        let candidate: ArtworkFingerprint
        if let cached = cachedFingerprints[artworkURL] {
            candidate = cached
        } else {
            guard inflightDownloads < candidateDownloadLimit else {
                return false
            }
            inflightDownloads += 1
            defer { inflightDownloads -= 1 }

            guard let computed = await Self.downloadAndFingerprint(url: artworkURL, session: urlSession) else {
                return false
            }
            if cachedFingerprints.count >= cacheCapacity {
                cachedFingerprints.removeAll(keepingCapacity: true)
            }
            cachedFingerprints[artworkURL] = computed
            candidate = computed
        }

        let hashDistance = Self.hammingDistance(target.dHash, candidate.dHash)
        guard hashDistance <= dHashDistanceThreshold else { return false }

        let deltaR = abs(Int(target.avgR) - Int(candidate.avgR))
        let deltaG = abs(Int(target.avgG) - Int(candidate.avgG))
        let deltaB = abs(Int(target.avgB) - Int(candidate.avgB))
        return deltaR <= perChannelColorDelta
            && deltaG <= perChannelColorDelta
            && deltaB <= perChannelColorDelta
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
        // Render to a 9×8 sRGB bitmap. One pass over the 72 pixels yields
        // both the per-pixel luminance (for dHash) and the RGB sums (for the
        // average colour gate).
        let width = 9
        let height = 8

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
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

        var imageRect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let cgImage = image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        let pixelCount = width * height
        var luminance = [UInt8](repeating: 0, count: pixelCount)
        var sumR = 0
        var sumG = 0
        var sumB = 0

        for index in 0..<pixelCount {
            let r = Int(bytes[index * bytesPerPixel])
            let g = Int(bytes[index * bytesPerPixel + 1])
            let b = Int(bytes[index * bytesPerPixel + 2])
            // Rec. 601 luma in integer math.
            let luma = (r * 299 + g * 587 + b * 114) / 1000
            luminance[index] = UInt8(min(255, luma))
            sumR += r
            sumG += g
            sumB += b
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

        return ArtworkFingerprint(
            dHash: hash,
            avgR: UInt8(sumR / pixelCount),
            avgG: UInt8(sumG / pixelCount),
            avgB: UInt8(sumB / pixelCount)
        )
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
