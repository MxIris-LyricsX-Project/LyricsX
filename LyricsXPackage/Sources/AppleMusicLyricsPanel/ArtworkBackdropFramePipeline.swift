import CoreGraphics
import Foundation
import Metal

extension AppleMusicLyrics {
    /// Everything a backdrop pipeline needs to know about the frame it is
    /// about to encode. The renderer fills this in once per `draw(in:)`.
    struct ArtworkBackdropFrameContext {
        let sourceTextureState: ArtworkBackdropTextureState
        let destinationTextureState: ArtworkBackdropTextureState
        /// Linear 0...1 progress of the artwork crossfade; a pipeline applies
        /// its own timing curve on top.
        let transitionProgress: Float
        /// Wall-clock seconds the backdrop has been animating, excluding time
        /// spent paused. A pipeline scales this to its own motion speed.
        let animationTime: TimeInterval
        let drawableSize: CGSize
        let backingScaleFactor: CGFloat
        let isDarkAppearance: Bool
    }

    enum ArtworkBackdropResourcePreparation {
        case ready
        case rebuilt
        case failed
    }

    /// One Apple Music backdrop look, split into the offscreen work the
    /// renderer encodes before it asks `MTKView` for a drawable and the final
    /// pass that lands in it. `ArtworkBackdropRenderer` owns the command queue,
    /// the artwork transition queue, the animation clock and the frame
    /// diagnostics; a pipeline owns its shaders, intermediate textures and
    /// blur kernels.
    protocol ArtworkBackdropFramePipeline: AnyObject {
        var drawablePixelFormat: MTLPixelFormat { get }
        /// Colour space assigned to the backing `CAMetalLayer`; `nil` keeps the
        /// display's own space without colour matching.
        var drawableColorSpace: CGColorSpace? { get }
        var clearColor: MTLClearColor { get }
        var fallbackTextureState: ArtworkBackdropTextureState { get }
        var artworkTransitionDuration: TimeInterval { get }

        func drawableSizeWillChange(_ drawableSize: CGSize)
        /// Rebuilds size-dependent resources when the drawable, backing scale or
        /// orientation changed. Returning `.failed` skips the frame.
        func prepareResources(
            for context: ArtworkBackdropFrameContext
        ) -> ArtworkBackdropResourcePreparation
        func encodeOffscreenFrame(
            commandBuffer: MTLCommandBuffer,
            context: ArtworkBackdropFrameContext
        ) -> Bool
        func encodeFinalFrame(
            commandBuffer: MTLCommandBuffer,
            renderPassDescriptor: MTLRenderPassDescriptor,
            context: ArtworkBackdropFrameContext
        ) -> Bool
    }

    enum ArtworkBackdropDrawableSizing {
        /// Full backing resolution scaled by `scale`, never smaller than one
        /// pixel so Metal is never asked for an empty texture.
        static func pixelSize(
            forNativeBackingSize nativeBackingSize: CGSize,
            scale: CGFloat
        ) -> CGSize {
            guard nativeBackingSize.width > 0,
                  nativeBackingSize.height > 0,
                  scale > 0
            else {
                return CGSize(width: 1, height: 1)
            }

            return CGSize(
                width: max(1, (nativeBackingSize.width * scale).rounded()),
                height: max(1, (nativeBackingSize.height * scale).rounded())
            )
        }
    }
}
