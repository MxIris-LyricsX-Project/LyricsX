import CoreGraphics
import Foundation

/// A compact signature of a cover's picture, for telling whether two images show
/// the same cover whatever their size or encoding.
///
/// The decision is driven primarily by a 64-bit dHash (difference hash) of the
/// image *structure*, with a colour check that only intervenes in an ambiguous
/// band — see `ArtworkFingerprintComparison`.
///
/// Why chrominance and not absolute RGB? The now-playing image is decoded and
/// colour-managed by the system; a candidate is a CDN JPEG. The two routinely
/// differ in overall *brightness* (gamma, colour-profile conversion, JPEG
/// quality) while depicting the identical cover. Comparing luma-independent
/// chrominance (YCbCr Cb/Cr) cancels an additive brightness offset by
/// construction, because the colour-difference weights sum to zero.
///
/// Sampling resolutions:
///   - dHash compares the cells of the classic 9×8 luminance grid (64-bit
///     hash), but each cell is the *average* of an 8×8 block of a 72×64
///     rendering rather than whatever drawing straight into 9×8 lands on.
///     Drawn straight in, detail finer than a cell folds into the cells by an
///     amount that depends on the source's size, so a 1000-pixel cover and its
///     100-pixel thumbnail — a streaming app's compressed Now Playing image —
///     disagreed on cells close in brightness: 9–14 bits on real NetEase covers,
///     against 0–5 once averaged.
///   - The average colour samples a 32×32 grid (1024 px) so JPEG quantisation,
///     padding and different CDN crops average out instead of skewing the
///     chrominance — at 9×8 a single pixel is ~1.4% of the mean, an order of
///     magnitude noisier.
public struct ArtworkFingerprint: Hashable, Sendable {
    public let differenceHash: UInt64
    public let averageRed: UInt8
    public let averageGreen: UInt8
    public let averageBlue: UInt8

    public init(differenceHash: UInt64, averageRed: UInt8, averageGreen: UInt8, averageBlue: UInt8) {
        self.differenceHash = differenceHash
        self.averageRed = averageRed
        self.averageGreen = averageGreen
        self.averageBlue = averageBlue
    }

    /// `nil` when the image cannot be drawn into an sRGB bitmap.
    public init?(image: CGImage) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let differenceHash = Self.differenceHash(of: image, colorSpace: colorSpace),
              let averageColor = Self.averageColor(of: image, colorSpace: colorSpace)
        else {
            return nil
        }
        self.init(
            differenceHash: differenceHash,
            averageRed: averageColor.red,
            averageGreen: averageColor.green,
            averageBlue: averageColor.blue
        )
    }

    /// How this fingerprint compares with `reference` — the playing track's cover.
    public func compared(to reference: ArtworkFingerprint) -> ArtworkFingerprintComparison {
        ArtworkFingerprintComparison(
            hashDistance: (differenceHash ^ reference.differenceHash).nonzeroBitCount,
            chrominanceDistance: chrominanceDistance(to: reference)
        )
    }

    // MARK: - Pipeline

    private struct AverageColor {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private static let bytesPerPixel = 4
    private static let hashGridWidth = 9
    private static let hashGridHeight = 8
    /// Rendered pixels averaged into each hash cell, along each edge.
    private static let pixelsPerHashCellEdge = 8

    /// Renders `image` into a freshly allocated sRGB premultiplied bitmap of
    /// `width`×`height` and hands `body` its bytes, which are valid for the
    /// duration of the call only.
    private static func withRenderedBitmap<Result>(
        of image: CGImage,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace,
        interpolationQuality: CGInterpolationQuality,
        body: (UnsafePointer<UInt8>) -> Result
    ) -> Result? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.interpolationQuality = interpolationQuality
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        return body(data.assumingMemoryBound(to: UInt8.self))
    }

    /// Rec. 601 luma in integer math, scaled by 1000.
    private static func scaledLuma(_ bytes: UnsafePointer<UInt8>, pixelIndex: Int) -> Int {
        let red = Int(bytes[pixelIndex * bytesPerPixel]) * 299
        let green = Int(bytes[pixelIndex * bytesPerPixel + 1]) * 587
        let blue = Int(bytes[pixelIndex * bytesPerPixel + 2]) * 114
        return red + green + blue
    }

    private static func differenceHash(of image: CGImage, colorSpace: CGColorSpace) -> UInt64? {
        let width = hashGridWidth * pixelsPerHashCellEdge
        let height = hashGridHeight * pixelsPerHashCellEdge
        return withRenderedBitmap(
            of: image,
            width: width,
            height: height,
            colorSpace: colorSpace,
            interpolationQuality: .high
        ) { bytes in
            // Summed rather than averaged: every cell holds the same number of
            // pixels, so the sums order exactly as the averages would.
            var cellLuminance = [Int](repeating: 0, count: hashGridWidth * hashGridHeight)
            for row in 0 ..< height {
                for column in 0 ..< width {
                    let cellIndex = (row / pixelsPerHashCellEdge) * hashGridWidth + column / pixelsPerHashCellEdge
                    cellLuminance[cellIndex] += scaledLuma(bytes, pixelIndex: row * width + column)
                }
            }
            var hash: UInt64 = 0
            for row in 0 ..< hashGridHeight {
                let rowStart = row * hashGridWidth
                for column in 0 ..< hashGridWidth - 1 {
                    hash <<= 1
                    if cellLuminance[rowStart + column] > cellLuminance[rowStart + column + 1] {
                        hash |= 1
                    }
                }
            }
            return hash
        }
    }

    private static func averageColor(of image: CGImage, colorSpace: CGColorSpace) -> AverageColor? {
        let width = 32
        let height = 32
        return withRenderedBitmap(
            of: image,
            width: width,
            height: height,
            colorSpace: colorSpace,
            interpolationQuality: .medium
        ) { bytes in
            let pixelCount = width * height
            var redSum = 0
            var greenSum = 0
            var blueSum = 0
            for pixelIndex in 0 ..< pixelCount {
                redSum += Int(bytes[pixelIndex * bytesPerPixel])
                greenSum += Int(bytes[pixelIndex * bytesPerPixel + 1])
                blueSum += Int(bytes[pixelIndex * bytesPerPixel + 2])
            }
            return AverageColor(
                red: UInt8(redSum / pixelCount),
                green: UInt8(greenSum / pixelCount),
                blue: UInt8(blueSum / pixelCount)
            )
        }
    }

    /// Euclidean distance between the two fingerprints' average colours in the
    /// luma-independent (Cb, Cr) chrominance plane. A brightness difference
    /// between a system-decoded now-playing image and a CDN JPEG of the same
    /// cover largely cancels here — Cb/Cr weights sum to zero, so a uniform
    /// luma offset drops out — while a genuinely different palette does not.
    private func chrominanceDistance(to other: ArtworkFingerprint) -> Double {
        let ownChrominance = chrominance
        let otherChrominance = other.chrominance
        let blueDifference = ownChrominance.blueDifference - otherChrominance.blueDifference
        let redDifference = ownChrominance.redDifference - otherChrominance.redDifference
        return (blueDifference * blueDifference + redDifference * redDifference).squareRoot()
    }

    private var chrominance: (blueDifference: Double, redDifference: Double) {
        let red = Double(averageRed)
        let green = Double(averageGreen)
        let blue = Double(averageBlue)
        // Rec. 601 luma; Cb/Cr are the colour-difference components.
        let luma = 0.299 * red + 0.587 * green + 0.114 * blue
        return (blue - luma, red - luma)
    }
}

/// What comparing two artwork fingerprints established.
///
///   1. dHash within `strongHashDistanceThreshold` bits — the structures are,
///      to a ~10^-14 false-match probability, the same image. Accepted outright,
///      so a brightness or encoding shift on a genuine match cannot veto it.
///      dHash works on luminance and is therefore colour-blind, so a template
///      cover recoloured per release could in principle land here; in practice
///      that requires near-identical brightness structure, which is rare enough
///      that the strong band is safe to wave through.
///   2. dHash within `hashDistanceThreshold` but past the strong threshold — the
///      "ambiguous band". Here the two artworks must also share a chrominance
///      signature, which rejects "same layout, different palette" template
///      collisions while still admitting the same cover re-encoded at a
///      different brightness.
///   3. Past `hashDistanceThreshold` the structures differ enough that it is
///      never called a match (~85% of bits must agree).
public struct ArtworkFingerprintComparison: Hashable, Sendable {
    public static let strongHashDistanceThreshold = 4
    public static let hashDistanceThreshold = 10
    /// Euclidean distance in the (Cb, Cr) plane, each component spanning roughly
    /// ±128. Loose enough to tolerate re-encoding and gentle remasters, tight
    /// enough to reject a recoloured template.
    public static let chrominanceDistanceThreshold = 30.0

    /// Bits that differ between the two difference hashes.
    public let hashDistance: Int
    public let chrominanceDistance: Double

    public var isStrongMatch: Bool {
        hashDistance <= Self.strongHashDistanceThreshold
    }

    public var isMatch: Bool {
        guard hashDistance <= Self.hashDistanceThreshold else { return false }
        return isStrongMatch || chrominanceDistance <= Self.chrominanceDistanceThreshold
    }
}
