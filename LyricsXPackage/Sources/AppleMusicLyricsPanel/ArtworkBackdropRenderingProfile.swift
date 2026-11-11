import Metal
import MetalPerformanceShaders

extension AppleMusicLyrics {
    enum ArtworkBackdropRenderingProfile {
        static let preferredDrawablePixelFormats: [MTLPixelFormat] = [
            .bgr10a2Unorm,
            .bgra8Unorm,
        ]

        static let gaussianBlurOptions: MPSKernelOptions = [
            .allowReducedPrecision,
            .disableInternalTiling,
        ]

        static let gaussianBlurEdgeMode: MPSImageEdgeMode = .zero
    }
}
