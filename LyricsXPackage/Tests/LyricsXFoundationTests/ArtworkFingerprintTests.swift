import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LyricsXFoundation

// MARK: - The same cover at very different sizes

/// NetEase Cloud Music hands system Now Playing a heavily compressed 100-pixel
/// JPEG, and the lyrics panel verifies a large copy against it before showing
/// the copy. Drawn straight into the 9×8 hash grid, detail finer than a grid
/// cell is not averaged away but folds into the cells — by a different amount
/// at 1000 pixels than at 100 — so the same cover landed 9–14 bits away from
/// its own thumbnail, past the limit of 10, and the sharp copy was thrown away
/// as a different cover.
@Test(arguments: [1000, 500, 200])
func aCoverAndItsHundredPixelThumbnailShareAFingerprint(catalogueEdge: Int) throws {
    let cover = SyntheticCover.overlappingWaves
    let catalogueCopy = try #require(ArtworkFingerprint(image: cover.downsampled(toEdge: catalogueEdge).image()))
    let thumbnail = try #require(
        ArtworkFingerprint(image: cover.downsampled(toEdge: 100).image().compressedAsJPEG(quality: 0.5))
    )

    let comparison = catalogueCopy.compared(to: thumbnail)
    #expect(
        comparison.isStrongMatch,
        "a \(catalogueEdge)-pixel copy is \(comparison.hashDistance) bits from its own thumbnail"
    )
}

/// Averaging before hashing must not blur different covers into one.
@Test
func differentCoversStayApartAtEitherSize() throws {
    let waves = try #require(ArtworkFingerprint(image: SyntheticCover.overlappingWaves.image()))
    let spotlight = try #require(
        ArtworkFingerprint(image: SyntheticCover.spotlight.downsampled(toEdge: 100).image())
    )

    let comparison = waves.compared(to: spotlight)
    #expect(comparison.hashDistance > ArtworkFingerprintComparison.hashDistanceThreshold)
    #expect(!comparison.isMatch)
}

// MARK: - The decision bands

@Test
func theStrongBandMatchesWhateverTheColour() {
    let comparison = ArtworkFingerprintComparison(hashDistance: 4, chrominanceDistance: 90)
    #expect(comparison.isStrongMatch)
    #expect(comparison.isMatch)
}

@Test
func theAmbiguousBandNeedsTheColoursToAgree() {
    #expect(ArtworkFingerprintComparison(hashDistance: 10, chrominanceDistance: 30).isMatch)
    #expect(!ArtworkFingerprintComparison(hashDistance: 10, chrominanceDistance: 31).isMatch)
}

@Test
func pastTheLimitNothingMatches() {
    #expect(!ArtworkFingerprintComparison(hashDistance: 11, chrominanceDistance: 0).isMatch)
}

// MARK: - Synthetic covers

/// A cover drawn from a luminance field plus per-pixel film grain. Smaller
/// renditions are exact box averages of the full-size pixels — what a CDN's
/// resize produces.
private struct SyntheticCover {
    static let fullEdge = 1000

    let edge: Int
    /// RGBA, 8 bits per channel, row-major from the top-left corner.
    let pixels: [UInt8]

    /// Three crossing waves, one of them finer than a cell of the hash grid —
    /// the kind of detail a real cover's texture and edges carry.
    static let overlappingWaves = SyntheticCover(seed: 0x5EED) { horizontal, vertical in
        128
            + 30 * sin(2 * .pi * (3.3 * horizontal + 1.1 * vertical) + 0.7)
            + 25 * sin(2 * .pi * (-2.2 * horizontal + 4.1 * vertical) + 2.1)
            + 20 * sin(2 * .pi * (6.5 * horizontal + 2.7 * vertical) + 4.0)
    }

    /// A bright patch off to one side over a dark ground.
    static let spotlight = SyntheticCover(seed: 0xC0FFEE) { horizontal, vertical in
        let distance = hypot(horizontal - 0.7, vertical - 0.35)
        return 50 + 150 * exp(-distance * distance / 0.05)
    }

    private init(edge: Int, pixels: [UInt8]) {
        self.edge = edge
        self.pixels = pixels
    }

    private init(seed: UInt64, luminance: (Double, Double) -> Double) {
        let edge = Self.fullEdge
        var randomNumberGenerator = SplitMixRandomNumberGenerator(state: seed)
        var pixels = [UInt8](repeating: 255, count: edge * edge * 4)
        for row in 0 ..< edge {
            for column in 0 ..< edge {
                let base = luminance(Double(column) / Double(edge), Double(row) / Double(edge))
                let grain = Double.random(in: -40 ... 40, using: &randomNumberGenerator)
                let level = min(255, max(0, base + grain))
                let pixelOffset = (row * edge + column) * 4
                // A warm tint, so the chrominance check sees a real colour.
                pixels[pixelOffset] = UInt8(min(255, level * 1.1))
                pixels[pixelOffset + 1] = UInt8(level)
                pixels[pixelOffset + 2] = UInt8(level * 0.8)
            }
        }
        self.init(edge: edge, pixels: pixels)
    }

    func downsampled(toEdge targetEdge: Int) -> SyntheticCover {
        precondition(edge % targetEdge == 0, "box averaging needs a whole number of pixels per block")
        let blockEdge = edge / targetEdge
        var downsampledPixels = [UInt8](repeating: 255, count: targetEdge * targetEdge * 4)
        for targetRow in 0 ..< targetEdge {
            for targetColumn in 0 ..< targetEdge {
                var channelSums = [0, 0, 0]
                for row in targetRow * blockEdge ..< (targetRow + 1) * blockEdge {
                    for column in targetColumn * blockEdge ..< (targetColumn + 1) * blockEdge {
                        let pixelOffset = (row * edge + column) * 4
                        for channel in 0 ..< 3 {
                            channelSums[channel] += Int(pixels[pixelOffset + channel])
                        }
                    }
                }
                let targetOffset = (targetRow * targetEdge + targetColumn) * 4
                for channel in 0 ..< 3 {
                    downsampledPixels[targetOffset + channel] = UInt8(channelSums[channel] / (blockEdge * blockEdge))
                }
            }
        }
        return SyntheticCover(edge: targetEdge, pixels: downsampledPixels)
    }

    func image() -> CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: edge,
            height: edge,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: edge * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }
}

extension CGImage {
    /// Encodes and decodes again as a lossy JPEG, the way a streaming app hands
    /// over its thumbnail.
    fileprivate func compressedAsJPEG(quality: Double) -> CGImage {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination,
            self,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        CGImageDestinationFinalize(destination)
        let source = CGImageSourceCreateWithData(data, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }
}

/// SplitMix64: a fixed seed gives the same grain on every run and machine.
private struct SplitMixRandomNumberGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
