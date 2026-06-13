import CoreImage
import SwiftUI

@available(macOS 15, *)
extension AppleMusicLyrics {
    struct BackgroundView: View {
        /// A pre-rendered, already-blurred artwork thumbnail. The expensive
        /// Gaussian blur is computed once per track on a small downsampled
        /// image (see `ArtworkBlurRenderer`) instead of live-blurring the
        /// full-resolution artwork across the whole window every frame.
        var blurredArtwork: NSImage?
        var backgroundMode: Int // 0 = artwork blur, 1 = dark, 2 = system

        var body: some View {
            switch backgroundMode {
            case 0:
                artworkBlurBackground
            case 2:
                systemMaterialBackground
            default:
                darkBackground
            }
        }

        @ViewBuilder
        private var artworkBlurBackground: some View {
            if let blurredArtwork {
                // The image is already blurred and saturation-boosted, so this
                // is just a cheap stretch-to-fill of a tiny bitmap. No `.blur`
                // and no `.drawingGroup()` — those forced a full-screen,
                // floating-point CoreImage buffer (~300 MB at 5K) to be
                // re-rendered on every animation tick.
                Image(nsImage: blurredArtwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .overlay(Color.black.opacity(0.4))
                    .clipped()
            } else {
                darkBackground
            }
        }

        private var darkBackground: some View {
            Color.black
        }

        private var systemMaterialBackground: some View {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }
}

// MARK: - Artwork Blur Renderer

/// Produces the blurred backdrop image used by `BackgroundView`.
///
/// The previous implementation applied `.blur(radius: 80).drawingGroup()` to a
/// full-window `Image`. On a Retina display that forced CoreImage to allocate
/// floating-point intermediate buffers the size of the whole window (hundreds
/// of MB at 5K), and the SwiftUI animation loop re-rendered them continuously,
/// making the process footprint oscillate by ~300 MB.
///
/// Blur is low-frequency information, so downsampling the artwork to a small
/// thumbnail first and blurring *that* is visually indistinguishable once the
/// result is scaled back up to fill the window — but the working set shrinks by
/// orders of magnitude and the blur is computed only once per track.
@available(macOS 15, *)
enum ArtworkBlurRenderer {
    // A shared, reusable context. Creating a CIContext per call is expensive;
    // CIContext is documented as thread-safe.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Render a downsampled, saturation-boosted, Gaussian-blurred copy of
    /// `image`. Returns `nil` if the image cannot be decoded.
    ///
    /// - Parameters:
    ///   - image: the source artwork.
    ///   - targetDimension: longest side of the working thumbnail, in pixels.
    ///   - blurRadius: Gaussian blur radius applied to the thumbnail. Tuned to
    ///     visually match the old full-resolution `blur(radius: 80)` once the
    ///     result is stretched to fill the window.
    static func blurredBackground(
        from image: NSImage,
        targetDimension: CGFloat = 240,
        blurRadius: Double = 20
    ) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let source = CIImage(cgImage: cgImage)
        let longestSide = max(source.extent.width, source.extent.height)
        guard longestSide > 0 else { return nil }

        let scale = min(1, targetDimension / longestSide)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let targetExtent = scaled.extent
        guard !targetExtent.isEmpty else { return nil }

        // Mirror the previous `.saturation(1.5)` look.
        let saturated = scaled.applyingFilter(
            "CIColorControls",
            parameters: [kCIInputSaturationKey: 1.5]
        )

        // Clamp before blurring so the blur samples edge pixels instead of
        // transparent ones (which would darken the borders), then crop back.
        let blurred = saturated
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: targetExtent)

        guard let output = context.createCGImage(blurred, from: targetExtent) else {
            return nil
        }
        return NSImage(
            cgImage: output,
            size: NSSize(width: targetExtent.width, height: targetExtent.height)
        )
    }
}
