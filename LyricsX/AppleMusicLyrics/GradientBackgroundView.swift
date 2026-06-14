import AppKit
import CoreGraphics
import ColorfulX

@available(macOS 15, *)
extension AppleMusicLyrics {
    /// Metal-rendered animated multicolor gradient background (ColorfulX),
    /// driven by the current artwork's dominant colors. Pure AppKit — no SwiftUI.
    final class GradientBackgroundView: NSView {
        private let gradientView = AnimatedMulticolorGradientView()
        private let darkOverlay = NSView()
        /// Track identity the current palette was computed for, so colors are
        /// re-extracted only on track change.
        private var paletteTrackID: String?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            setup()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Purely decorative — pass all clicks through to the draggable root view
        /// behind it (so dragging the gradient moves the window).
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        private func setup() {
            gradientView.translatesAutoresizingMaskIntoConstraints = false
            gradientView.speed = 0.55          // slow ambient drift
            gradientView.noise = 2             // a touch of grain; high noise reads as muddy
            gradientView.bias = 0.003
            gradientView.transitionSpeed = 2.0 // spring crossfade on track change
            gradientView.setColors(ColorfulPreset.aurora, animated: false)
            addSubview(gradientView)

            // Darken just enough for text contrast (lighter than before so the
            // vivid artwork palette stays rich).
            darkOverlay.translatesAutoresizingMaskIntoConstraints = false
            darkOverlay.wantsLayer = true
            darkOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.34).cgColor
            addSubview(darkOverlay)

            NSLayoutConstraint.activate([
                gradientView.topAnchor.constraint(equalTo: topAnchor),
                gradientView.bottomAnchor.constraint(equalTo: bottomAnchor),
                gradientView.leadingAnchor.constraint(equalTo: leadingAnchor),
                gradientView.trailingAnchor.constraint(equalTo: trailingAnchor),
                darkOverlay.topAnchor.constraint(equalTo: topAnchor),
                darkOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
                darkOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                darkOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        /// Update the palette from the current artwork. Colors are extracted at
        /// most once per track; ColorfulX spring-crossfades to the new palette.
        func update(artwork: NSImage?, trackID: String?) {
            guard trackID != paletteTrackID else { return }
            paletteTrackID = trackID

            if let artwork, let colors = ArtworkColorExtractor.dominantColors(from: artwork), !colors.isEmpty {
                gradientView.setColors(colors, animated: true)
            } else {
                gradientView.setColors(ColorfulPreset.aurora, animated: true)
            }
        }
    }
}

// MARK: - Artwork Dominant Color Extraction

/// Extracts a small palette of dominant colors from album artwork via
/// downsampling + k-means, for driving the ColorfulX gradient.
@available(macOS 15, *)
enum ArtworkColorExtractor {
    /// Returns up to `count` vivid dominant colors (ColorfulX renders up to 8
    /// stops). Raw album-art clusters skew dark and desaturated, which reads as a
    /// muddy gradient — so each cluster's saturation is boosted and very dark
    /// colors are lifted, and the palette is ranked by vividness × weight.
    static func dominantColors(from image: NSImage, sampleDimension: Int = 44, count: Int = 5) -> [NSColor]? {
        guard let pixels = downsampledPixels(from: image, dimension: sampleDimension), !pixels.isEmpty else {
            return nil
        }
        let clusters = kMeans(pixels: pixels, clusterCount: 8, iterations: 10)

        struct Candidate {
            let color: NSColor
            let weight: Int
            let saturation: CGFloat
        }
        let candidates: [Candidate] = clusters.map { cluster in
            let (hue, saturation, brightness) = rgbToHSB(cluster.center)
            // Boost saturation to bring out accent hues, but KEEP the artwork's
            // own brightness (only lift true black) so the dark, moody character
            // is preserved instead of washing out to a flat mid-gray.
            let boostedSaturation = min(1, saturation * 1.5 + 0.05)
            let keptBrightness = min(0.95, max(0.16, brightness))
            let color = NSColor(hue: hue, saturation: boostedSaturation, brightness: keptBrightness, alpha: 1)
            return Candidate(color: color, weight: cluster.weight, saturation: boostedSaturation)
        }

        let minimumAccentWeight = max(1, pixels.count / 50)
        var pickedIndices: [Int] = []

        // Mood: the most dominant clusters (these carry the dark base tones).
        for index in candidates.indices.sorted(by: { candidates[$0].weight > candidates[$1].weight }) {
            if pickedIndices.count >= 3 { break }
            pickedIndices.append(index)
        }
        // Accents: the most saturated clusters with non-trivial coverage, so a
        // small-but-important warm/cool accent in the artwork still shows up.
        for index in candidates.indices.sorted(by: { candidates[$0].saturation > candidates[$1].saturation }) {
            if pickedIndices.count >= count { break }
            if candidates[index].weight >= minimumAccentWeight, !pickedIndices.contains(index) {
                pickedIndices.append(index)
            }
        }

        let palette = pickedIndices.map { candidates[$0].color }
        return palette.isEmpty ? nil : palette
    }

    private static func rgbToHSB(_ rgb: RGB) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let maximum = max(rgb.r, rgb.g, rgb.b)
        let minimum = min(rgb.r, rgb.g, rgb.b)
        let delta = maximum - minimum
        let brightness = maximum
        let saturation = maximum <= 0 ? 0 : delta / maximum
        var hue: CGFloat = 0
        if delta > 0 {
            if maximum == rgb.r {
                hue = (rgb.g - rgb.b) / delta
            } else if maximum == rgb.g {
                hue = 2 + (rgb.b - rgb.r) / delta
            } else {
                hue = 4 + (rgb.r - rgb.g) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, saturation, brightness)
    }

    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
    }

    private struct Cluster {
        var center: RGB
        var weight: Int
    }

    /// Render the artwork into a small RGBA8 bitmap and read its pixels.
    private static func downsampledPixels(from image: NSImage, dimension: Int) -> [RGB]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = dimension
        let height = dimension
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &raw,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var pixels: [RGB] = []
        pixels.reserveCapacity(width * height)
        for index in stride(from: 0, to: raw.count, by: 4) {
            let alpha = CGFloat(raw[index + 3]) / 255
            guard alpha > 0.1 else { continue }
            pixels.append(RGB(
                r: CGFloat(raw[index]) / 255,
                g: CGFloat(raw[index + 1]) / 255,
                b: CGFloat(raw[index + 2]) / 255
            ))
        }
        return pixels
    }

    /// Lightweight k-means over the sampled pixels. Seeds are spread across the
    /// pixel list so the initial centers are reasonably distinct.
    private static func kMeans(pixels: [RGB], clusterCount: Int, iterations: Int) -> [Cluster] {
        let k = min(clusterCount, pixels.count)
        guard k > 0 else { return [] }

        var centers: [RGB] = (0 ..< k).map { pixels[$0 * pixels.count / k] }
        var assignments = [Int](repeating: 0, count: pixels.count)

        for _ in 0 ..< iterations {
            // Assign each pixel to its nearest center.
            for (pixelIndex, pixel) in pixels.enumerated() {
                var bestDistance = CGFloat.greatestFiniteMagnitude
                var bestCenter = 0
                for (centerIndex, center) in centers.enumerated() {
                    let distance = squaredDistance(pixel, center)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestCenter = centerIndex
                    }
                }
                assignments[pixelIndex] = bestCenter
            }

            // Recompute centers as the mean of their assigned pixels.
            var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: k)
            var counts = [Int](repeating: 0, count: k)
            for (pixelIndex, pixel) in pixels.enumerated() {
                let cluster = assignments[pixelIndex]
                sums[cluster].r += pixel.r
                sums[cluster].g += pixel.g
                sums[cluster].b += pixel.b
                counts[cluster] += 1
            }
            for clusterIndex in 0 ..< k where counts[clusterIndex] > 0 {
                let total = CGFloat(counts[clusterIndex])
                centers[clusterIndex] = RGB(
                    r: sums[clusterIndex].r / total,
                    g: sums[clusterIndex].g / total,
                    b: sums[clusterIndex].b / total
                )
            }
        }

        var weights = [Int](repeating: 0, count: k)
        for cluster in assignments {
            weights[cluster] += 1
        }
        return (0 ..< k).map { Cluster(center: centers[$0], weight: weights[$0]) }
    }

    private static func squaredDistance(_ lhs: RGB, _ rhs: RGB) -> CGFloat {
        let deltaR = lhs.r - rhs.r
        let deltaG = lhs.g - rhs.g
        let deltaB = lhs.b - rhs.b
        return deltaR * deltaR + deltaG * deltaG + deltaB * deltaB
    }
}
