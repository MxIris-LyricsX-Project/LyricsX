import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders

extension AppleMusicLyrics {
    struct ArtworkBackdropTextureState {
        let texture: MTLTexture
        let averageLuminosity: Float

        var aspectRatio: Float {
            Float(texture.width) / Float(max(1, texture.height))
        }
    }

    enum ArtworkBackdropPipelineCreationError: Error {
        case unavailableShaderFunction(String)
        case unavailableDrawablePixelFormat
        case unableToCreateMeshVertexBuffer
        case unableToCreateMeshIndexBuffer
        case unableToCreateFallbackTexture
    }

    /// The MiniPlayer large-artwork backdrop (`TSLBackdropMetalView`) as
    /// Music 26.6 ships it: a full-resolution composition of three rotating
    /// artwork copies in linear light, a diagonal-relative Gaussian blur and a
    /// five-segment mesh warp with the dark scrim applied in the final pass.
    /// Kept as `ArtworkBackdropVariant.legacyTSL` for side-by-side comparison.
    final class ArtworkBackdropPipeline: ArtworkBackdropFramePipeline {
        let fallbackTextureState: ArtworkBackdropTextureState
        let drawablePixelFormat: MTLPixelFormat
        let drawableColorSpace: CGColorSpace? = nil
        let clearColor = MTLClearColor(red: 0.05, green: 0.07, blue: 0.1, alpha: 1)

        var artworkTransitionDuration: TimeInterval {
            configuration.artworkTransitionDuration
        }

        private let metalDevice: MTLDevice
        private let configuration: ArtworkGradientConfiguration
        private let compositionPipelineState: MTLRenderPipelineState
        private let finalPipelineState: MTLRenderPipelineState
        private let meshVertexBuffer: MTLBuffer
        private let meshIndexBuffer: MTLBuffer
        private let meshIndexCount: Int
        private var compositionTexture: MTLTexture?
        private var blurredTexture: MTLTexture?
        private var gaussianBlur: MPSImageGaussianBlur?

        init(
            device metalDevice: MTLDevice,
            configuration: ArtworkGradientConfiguration,
            shaderLibrary: MTLLibrary? = nil
        ) throws {
            let shaderLibrary = try shaderLibrary ?? metalDevice.makeDefaultLibrary(bundle: .module)
            let renderingPipeline = try Self.makeRenderingPipeline(
                device: metalDevice,
                shaderLibrary: shaderLibrary,
                preferredPixelFormats: ArtworkBackdropRenderingProfile
                    .preferredDrawablePixelFormats
            )
            self.metalDevice = metalDevice
            self.configuration = configuration
            self.compositionPipelineState = renderingPipeline.compositionPipelineState
            self.finalPipelineState = renderingPipeline.finalPipelineState
            self.drawablePixelFormat = renderingPipeline.pixelFormat

            let meshTopology = ArtworkBackdropMeshTopology(
                baseControlPointCount: configuration.baseMeshControlPointCount,
                subdivisionLevel: configuration.meshSubdivisionLevel
            )
            let meshVertices = meshTopology.makeVertices(
                meshVariant: configuration.meshVariant
                    ?? Int.random(in: 0 ..< ArtworkBackdropMeshPresets.variantCount)
            )
            let meshIndices = meshTopology.makeIndices()
            guard let meshVertexBuffer = Self.makeBuffer(
                from: meshVertices,
                device: metalDevice
            ) else {
                throw ArtworkBackdropPipelineCreationError.unableToCreateMeshVertexBuffer
            }
            guard let meshIndexBuffer = Self.makeBuffer(
                from: meshIndices,
                device: metalDevice
            ) else {
                throw ArtworkBackdropPipelineCreationError.unableToCreateMeshIndexBuffer
            }
            guard let fallbackTexture = Self.makeFallbackTexture(device: metalDevice) else {
                throw ArtworkBackdropPipelineCreationError.unableToCreateFallbackTexture
            }

            self.meshVertexBuffer = meshVertexBuffer
            self.meshIndexBuffer = meshIndexBuffer
            self.meshIndexCount = meshIndices.count
            self.fallbackTextureState = ArtworkBackdropTextureState(
                texture: fallbackTexture,
                averageLuminosity: 0.28
            )
        }

        func drawableSizeWillChange(_ drawableSize: CGSize) {
            compositionTexture = nil
            blurredTexture = nil
            gaussianBlur = nil
        }

        func prepareResources(
            for context: ArtworkBackdropFrameContext
        ) -> ArtworkBackdropResourcePreparation {
            let textureWidth = max(1, Int(context.drawableSize.width.rounded()))
            let textureHeight = max(1, Int(context.drawableSize.height.rounded()))
            if compositionTexture?.width == textureWidth,
               compositionTexture?.height == textureHeight,
               blurredTexture?.width == textureWidth,
               blurredTexture?.height == textureHeight,
               gaussianBlur != nil {
                return .ready
            }

            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: drawablePixelFormat,
                width: textureWidth,
                height: textureHeight,
                mipmapped: false
            )
            textureDescriptor.storageMode = .private
            textureDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            guard let compositionTexture = metalDevice.makeTexture(
                descriptor: textureDescriptor
            ), let blurredTexture = metalDevice.makeTexture(
                descriptor: textureDescriptor
            ) else {
                return .failed
            }
            compositionTexture.label = "Artwork Backdrop Composition Texture"
            blurredTexture.label = "Artwork Backdrop Blurred Texture"

            let textureDiagonal = hypot(Float(textureWidth), Float(textureHeight))
            let blurSigma = max(
                1,
                floor(textureDiagonal * configuration.blurSigmaFraction)
            )
            let gaussianBlur = MPSImageGaussianBlur(
                device: metalDevice,
                sigma: blurSigma
            )
            gaussianBlur.options = ArtworkBackdropRenderingProfile.gaussianBlurOptions
            gaussianBlur.edgeMode = ArtworkBackdropRenderingProfile.gaussianBlurEdgeMode

            self.compositionTexture = compositionTexture
            self.blurredTexture = blurredTexture
            self.gaussianBlur = gaussianBlur
            return .rebuilt
        }

        func encodeOffscreenFrame(
            commandBuffer: MTLCommandBuffer,
            context: ArtworkBackdropFrameContext
        ) -> Bool {
            guard let compositionTexture, let blurredTexture, let gaussianBlur else {
                return false
            }
            guard encodeComposition(
                commandBuffer: commandBuffer,
                destinationTexture: compositionTexture,
                sourceTextureState: context.sourceTextureState,
                destinationTextureState: context.destinationTextureState,
                transitionProgress: context.transitionProgress,
                animationTime: context.animationTime
            ) else {
                return false
            }
            gaussianBlur.encode(
                commandBuffer: commandBuffer,
                sourceTexture: compositionTexture,
                destinationTexture: blurredTexture
            )
            return true
        }

        func encodeFinalFrame(
            commandBuffer: MTLCommandBuffer,
            renderPassDescriptor: MTLRenderPassDescriptor,
            context: ArtworkBackdropFrameContext
        ) -> Bool {
            guard let blurredTexture else { return false }
            return encodeFinalBackdrop(
                commandBuffer: commandBuffer,
                renderPassDescriptor: renderPassDescriptor,
                blurredTexture: blurredTexture,
                animationTime: context.animationTime,
                averageLuminosity: context.sourceTextureState.averageLuminosity
                    + (context.destinationTextureState.averageLuminosity
                        - context.sourceTextureState.averageLuminosity)
                    * context.transitionProgress,
                configuration: configuration
            )
        }

        func encodeComposition(
            commandBuffer: MTLCommandBuffer,
            destinationTexture: MTLTexture,
            sourceTextureState: ArtworkBackdropTextureState,
            destinationTextureState: ArtworkBackdropTextureState,
            transitionProgress: Float,
            animationTime: TimeInterval
        ) -> Bool {
            let renderPassDescriptor = MTLRenderPassDescriptor()
            guard let colorAttachment = renderPassDescriptor.colorAttachments[0] else {
                return false
            }
            colorAttachment.texture = destinationTexture
            colorAttachment.loadAction = .clear
            colorAttachment.storeAction = .store
            colorAttachment.clearColor = MTLClearColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 1
            )
            guard let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor
            ) else {
                return false
            }

            let viewportAspectRatio = Float(destinationTexture.width)
                / Float(max(1, destinationTexture.height))
            var compositionParameters = SIMD4<Float>(
                viewportAspectRatio,
                Float(animationTime),
                transitionProgress,
                1.3
            )

            renderCommandEncoder.label = "Artwork Backdrop Composition Encoder"
            renderCommandEncoder.setRenderPipelineState(compositionPipelineState)
            renderCommandEncoder.setVertexBytes(
                &compositionParameters,
                length: MemoryLayout<SIMD4<Float>>.stride,
                index: 0
            )
            renderCommandEncoder.setFragmentTexture(sourceTextureState.texture, index: 0)
            renderCommandEncoder.setFragmentTexture(destinationTextureState.texture, index: 1)
            renderCommandEncoder.setFragmentBytes(
                &compositionParameters,
                length: MemoryLayout<SIMD4<Float>>.stride,
                index: 0
            )
            renderCommandEncoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: 3
            )
            renderCommandEncoder.endEncoding()
            return true
        }

        func encodeFinalBackdrop(
            commandBuffer: MTLCommandBuffer,
            renderPassDescriptor: MTLRenderPassDescriptor,
            blurredTexture: MTLTexture,
            animationTime: TimeInterval,
            averageLuminosity: Float,
            configuration: ArtworkGradientConfiguration
        ) -> Bool {
            guard let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor
            ) else {
                return false
            }

            var motionParameters = SIMD4<Float>(
                Float(animationTime),
                1.75,
                0.8,
                0
            )
            var appearanceParameters = SIMD4<Float>(
                configuration.saturation,
                configuration.blackScrimOpacity,
                0.02,
                0.995
            )
            var colorRangeParameters = SIMD2<Float>(
                configuration.minimumColorComponent,
                configuration.maximumColorComponent
            )

            renderCommandEncoder.label = "Artwork Backdrop Final Encoder"
            renderCommandEncoder.setRenderPipelineState(finalPipelineState)
            renderCommandEncoder.setVertexBuffer(meshVertexBuffer, offset: 0, index: 0)
            renderCommandEncoder.setVertexBytes(
                &motionParameters,
                length: MemoryLayout<SIMD4<Float>>.stride,
                index: 1
            )
            renderCommandEncoder.setFragmentTexture(blurredTexture, index: 0)
            renderCommandEncoder.setFragmentBytes(
                &appearanceParameters,
                length: MemoryLayout<SIMD4<Float>>.stride,
                index: 0
            )
            renderCommandEncoder.setFragmentBytes(
                &colorRangeParameters,
                length: MemoryLayout<SIMD2<Float>>.stride,
                index: 1
            )
            renderCommandEncoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: meshIndexCount,
                indexType: .uint32,
                indexBuffer: meshIndexBuffer,
                indexBufferOffset: 0
            )
            renderCommandEncoder.endEncoding()
            return true
        }
    }
}

extension AppleMusicLyrics.ArtworkBackdropPipeline {
    fileprivate struct RenderingPipeline {
        let compositionPipelineState: MTLRenderPipelineState
        let finalPipelineState: MTLRenderPipelineState
        let pixelFormat: MTLPixelFormat
    }

    fileprivate static func makeRenderingPipeline(
        device metalDevice: MTLDevice,
        shaderLibrary: MTLLibrary,
        preferredPixelFormats: [MTLPixelFormat]
    ) throws -> RenderingPipeline {
        for pixelFormat in preferredPixelFormats
            where supportsOffscreenTexture(
                pixelFormat: pixelFormat,
                device: metalDevice
            ) {
            do {
                let compositionPipelineState = try makePipelineState(
                    device: metalDevice,
                    shaderLibrary: shaderLibrary,
                    vertexFunctionName: "artworkBackdropCompositionVertex",
                    fragmentFunctionName: "artworkBackdropCompositionFragment",
                    pixelFormat: pixelFormat,
                    label: "Artwork Backdrop Composition Pipeline"
                )
                let finalPipelineState = try makePipelineState(
                    device: metalDevice,
                    shaderLibrary: shaderLibrary,
                    vertexFunctionName: "artworkBackdropMeshVertex",
                    fragmentFunctionName: "artworkBackdropFinalFragment",
                    pixelFormat: pixelFormat,
                    label: "Artwork Backdrop Final Pipeline"
                )
                return RenderingPipeline(
                    compositionPipelineState: compositionPipelineState,
                    finalPipelineState: finalPipelineState,
                    pixelFormat: pixelFormat
                )
            } catch {
                continue
            }
        }

        throw AppleMusicLyrics.ArtworkBackdropPipelineCreationError
            .unavailableDrawablePixelFormat
    }

    fileprivate static func supportsOffscreenTexture(
        pixelFormat: MTLPixelFormat,
        device metalDevice: MTLDevice
    ) -> Bool {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: 1,
            height: 1,
            mipmapped: false
        )
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        return metalDevice.makeTexture(descriptor: textureDescriptor) != nil
    }

    fileprivate static func makePipelineState(
        device metalDevice: MTLDevice,
        shaderLibrary: MTLLibrary,
        vertexFunctionName: String,
        fragmentFunctionName: String,
        pixelFormat: MTLPixelFormat,
        label: String
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunction = shaderLibrary.makeFunction(
            name: vertexFunctionName
        ) else {
            throw AppleMusicLyrics.ArtworkBackdropPipelineCreationError
                .unavailableShaderFunction(vertexFunctionName)
        }
        guard let fragmentFunction = shaderLibrary.makeFunction(
            name: fragmentFunctionName
        ) else {
            throw AppleMusicLyrics.ArtworkBackdropPipelineCreationError
                .unavailableShaderFunction(fragmentFunctionName)
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = label
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    fileprivate static func makeBuffer<Element>(
        from elements: [Element],
        device metalDevice: MTLDevice
    ) -> MTLBuffer? {
        elements.withUnsafeBytes { elementBytes -> MTLBuffer? in
            guard let baseAddress = elementBytes.baseAddress else { return nil }
            return metalDevice.makeBuffer(
                bytes: baseAddress,
                length: elementBytes.count,
                options: .storageModeShared
            )
        }
    }

    fileprivate static func makeFallbackTexture(device metalDevice: MTLDevice) -> MTLTexture? {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: 2,
            height: 2,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = .shaderRead
        guard let texture = metalDevice.makeTexture(descriptor: textureDescriptor) else {
            return nil
        }

        let pixelBytes: [UInt8] = [
            55, 133, 145, 255,
            64, 94, 168, 255,
            125, 79, 158, 255,
            158, 99, 82, 255,
        ]
        pixelBytes.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, 2, 2),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: 8
            )
        }
        texture.label = "Artwork Backdrop Fallback Texture"
        return texture
    }
}
