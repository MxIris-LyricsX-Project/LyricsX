import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import simd

extension AppleMusicLyrics {
    enum NowPlayingBackdropPipelineCreationError: Error {
        case unavailableShaderFunction(String)
        case unavailableDrawablePixelFormat
        case unableToCreateQuadVertexBuffer
        case unableToCreateFallbackTexture
    }

    /// Music 26's Now Playing backdrop, `MediaCoreUI.Backdrop.CompositeRenderer`,
    /// rebuilt on public Metal: `TextureBlender` → `RotatingArtworkRenderer` →
    /// `MPSImageGaussianBlur` → `PinchRenderer`.
    ///
    /// 1. The blend pass crossfades the previous and current 128 pixel covers
    ///    into a 128 × 128 half-float texture.
    /// 2. The rotation pass draws three copies of that texture onto a canvas a
    ///    quarter of the drawable's size, cleared to transparent, darkening and
    ///    saturating each copy in gamma space.
    /// 3. The canvas is blurred with a point-sized sigma.
    /// 4. The pinch pass warps the blurred canvas through a subdivided
    ///    `CAMeshTransform`-style grid onto the drawable, unpremultiplies the
    ///    blurred edge, lifts towards white and grades saturated reds and blues.
    final class NowPlayingBackdropPipeline: ArtworkBackdropFramePipeline {
        static let intermediatePixelFormat: MTLPixelFormat = .rgba16Float

        struct QuadVertex {
            var position: SIMD2<Float>
            var textureCoordinate: SIMD2<Float>
        }

        struct MeshBuffers {
            let segmentCount: Int
            let vertexBuffer: MTLBuffer
            let indexBuffer: MTLBuffer
            let indexCount: Int
        }

        let configuration: NowPlayingBackdropConfiguration
        let drawablePixelFormat: MTLPixelFormat
        let drawableColorSpace: CGColorSpace?
        let clearColor: MTLClearColor
        let fallbackTextureState: ArtworkBackdropTextureState
        let meshVariant: Int

        var artworkTransitionDuration: TimeInterval {
            configuration.artworkTransitionDuration
        }

        private let metalDevice: MTLDevice
        private let blendPipelineState: MTLRenderPipelineState
        private let rotationPipelineState: MTLRenderPipelineState
        private let pinchPipelineState: MTLRenderPipelineState
        private let quadVertexBuffer: MTLBuffer
        private var mesh: MeshBuffers?
        private var blendedTexture: MTLTexture?
        private var canvasTexture: MTLTexture?
        private var blurredTexture: MTLTexture?
        private var gaussianBlur: MPSImageGaussianBlur?
        private var preparedBlurSigma: Float = 0
        private var frameUniforms: NowPlayingBackdropUniforms?

        init(
            device metalDevice: MTLDevice,
            configuration: NowPlayingBackdropConfiguration = NowPlayingBackdropConfiguration(),
            shaderLibrary: MTLLibrary? = nil
        ) throws {
            let shaderLibrary = try shaderLibrary ?? metalDevice.makeDefaultLibrary(bundle: .module)
            self.metalDevice = metalDevice
            self.configuration = configuration
            self.drawableColorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)
            self.meshVariant = configuration.meshVariant
                ?? Int.random(in: 0 ..< ArtworkBackdropMeshPresets.variantCount)

            self.blendPipelineState = try Self.makePipelineState(
                device: metalDevice,
                shaderLibrary: shaderLibrary,
                vertexFunctionName: "nowPlayingQuadVertex",
                fragmentFunctionName: "nowPlayingBlendFragment",
                pixelFormat: Self.intermediatePixelFormat,
                label: "Now Playing Backdrop Blend Pipeline"
            )
            self.rotationPipelineState = try Self.makePipelineState(
                device: metalDevice,
                shaderLibrary: shaderLibrary,
                vertexFunctionName: "nowPlayingRotationVertex",
                fragmentFunctionName: "nowPlayingRotationFragment",
                pixelFormat: Self.intermediatePixelFormat,
                label: "Now Playing Backdrop Rotation Pipeline"
            )
            let pinchPipeline = try Self.makePinchPipeline(
                device: metalDevice,
                shaderLibrary: shaderLibrary,
                preferredPixelFormats: ArtworkBackdropRenderingProfile.preferredDrawablePixelFormats
            )
            self.pinchPipelineState = pinchPipeline.pipelineState
            self.drawablePixelFormat = pinchPipeline.pixelFormat

            guard let quadVertexBuffer = Self.makeQuadVertexBuffer(device: metalDevice) else {
                throw NowPlayingBackdropPipelineCreationError.unableToCreateQuadVertexBuffer
            }
            self.quadVertexBuffer = quadVertexBuffer

            guard let fallbackTexture = Self.makeFallbackTexture(
                device: metalDevice,
                color: configuration.fallbackArtworkColor
            ) else {
                throw NowPlayingBackdropPipelineCreationError.unableToCreateFallbackTexture
            }
            let fallbackLuminosity = configuration.fallbackArtworkColor.x * 0.2126
                + configuration.fallbackArtworkColor.y * 0.7152
                + configuration.fallbackArtworkColor.z * 0.0722
            self.fallbackTextureState = ArtworkBackdropTextureState(
                texture: fallbackTexture,
                averageLuminosity: fallbackLuminosity
            )

            // What the placeholder grey becomes after darkening and the white
            // lift, so the first frame and any uncovered drawable match it.
            let processedGray = Double(
                fallbackLuminosity
                    * (1 - configuration.darkAppearanceDarken)
                    * (1 - configuration.whiteMix)
                    + configuration.whiteMix
            )
            self.clearColor = MTLClearColor(
                red: processedGray,
                green: processedGray,
                blue: processedGray,
                alpha: 1
            )
        }

        func drawableSizeWillChange(_ drawableSize: CGSize) {
            canvasTexture = nil
            blurredTexture = nil
            gaussianBlur = nil
        }

        func prepareResources(
            for context: ArtworkBackdropFrameContext
        ) -> ArtworkBackdropResourcePreparation {
            let isLandscape = NowPlayingBackdropConfiguration.isLandscape(
                drawableSize: context.drawableSize
            )
            let canvasSize = configuration.canvasSize(drawableSize: context.drawableSize)
            let blurSigma = configuration.blurSigma(
                isLandscape: isLandscape,
                backingScaleFactor: context.backingScaleFactor
            )
            let meshSegmentCount = configuration.meshSegmentCount(isLandscape: isLandscape)
            var didRebuild = false

            if blendedTexture == nil {
                guard let texture = makeIntermediateTexture(
                    width: configuration.artworkDimension,
                    height: configuration.artworkDimension,
                    label: "Now Playing Backdrop Blended Artwork"
                ) else {
                    return .failed
                }
                blendedTexture = texture
                didRebuild = true
            }

            if canvasTexture?.width != canvasSize.width
                || canvasTexture?.height != canvasSize.height
                || blurredTexture == nil {
                guard let canvasTexture = makeIntermediateTexture(
                    width: canvasSize.width,
                    height: canvasSize.height,
                    label: "Now Playing Backdrop Canvas"
                ), let blurredTexture = makeIntermediateTexture(
                    width: canvasSize.width,
                    height: canvasSize.height,
                    label: "Now Playing Backdrop Blurred Canvas"
                ) else {
                    return .failed
                }
                self.canvasTexture = canvasTexture
                self.blurredTexture = blurredTexture
                didRebuild = true
            }

            if gaussianBlur == nil || preparedBlurSigma != blurSigma {
                let gaussianBlur = MPSImageGaussianBlur(device: metalDevice, sigma: blurSigma)
                gaussianBlur.edgeMode = .zero
                self.gaussianBlur = gaussianBlur
                preparedBlurSigma = blurSigma
                didRebuild = true
            }

            if mesh?.segmentCount != meshSegmentCount {
                guard let mesh = makeMesh(segmentCount: meshSegmentCount) else {
                    return .failed
                }
                self.mesh = mesh
                didRebuild = true
            }

            return didRebuild ? .rebuilt : .ready
        }

        func encodeOffscreenFrame(
            commandBuffer: MTLCommandBuffer,
            context: ArtworkBackdropFrameContext
        ) -> Bool {
            guard let blendedTexture, let canvasTexture, let blurredTexture, let gaussianBlur else {
                return false
            }
            let uniforms = makeUniforms(for: context)
            frameUniforms = uniforms
            guard encodeBlendPass(
                commandBuffer: commandBuffer,
                destinationTexture: blendedTexture,
                previousArtworkTexture: context.sourceTextureState.texture,
                currentArtworkTexture: context.destinationTextureState.texture,
                uniforms: uniforms
            ), encodeRotationPass(
                commandBuffer: commandBuffer,
                destinationTexture: canvasTexture,
                artworkTexture: blendedTexture,
                uniforms: uniforms
            ) else {
                return false
            }
            gaussianBlur.encode(
                commandBuffer: commandBuffer,
                sourceTexture: canvasTexture,
                destinationTexture: blurredTexture
            )
            return true
        }

        func encodeFinalFrame(
            commandBuffer: MTLCommandBuffer,
            renderPassDescriptor: MTLRenderPassDescriptor,
            context: ArtworkBackdropFrameContext
        ) -> Bool {
            guard let blurredTexture, let mesh else { return false }
            let uniforms = frameUniforms ?? makeUniforms(for: context)
            return encodePinchPass(
                commandBuffer: commandBuffer,
                renderPassDescriptor: renderPassDescriptor,
                blurredCanvasTexture: blurredTexture,
                uniforms: uniforms,
                mesh: mesh
            )
        }

        func makeUniforms(for context: ArtworkBackdropFrameContext) -> NowPlayingBackdropUniforms {
            let isLandscape = NowPlayingBackdropConfiguration.isLandscape(
                drawableSize: context.drawableSize
            )
            let environment = configuration.environment(isLandscape: isLandscape)
            let backdropTime = configuration.backdropTime(animationTime: context.animationTime)
            let instances = configuration.rotationInstances.map(NowPlayingRotationInstanceUniforms.init)
            precondition(instances.count == 3, "Music's backdrop rotates exactly three artwork copies")
            return NowPlayingBackdropUniforms(
                viewMatrix: configuration.viewMatrix(drawableSize: context.drawableSize),
                rotationInstances: (instances[0], instances[1], instances[2]),
                time: backdropTime,
                crossfadeProgress: configuration.artworkTransitionTimingFunction.value(
                    at: context.transitionProgress
                ),
                meshProgress: configuration.meshProgress(backdropTime: backdropTime),
                pinchMix: configuration.pinchMix,
                saturation: environment.saturation,
                whiteMix: configuration.whiteMix,
                darken: configuration.darken(isDarkAppearance: context.isDarkAppearance),
                spectrum: .zero,
                colorGrading: NowPlayingColorGradingUniforms(configuration.colorGrading)
            )
        }

        func makeMesh(segmentCount: Int) -> MeshBuffers? {
            guard let surfaces = ArtworkBackdropMeshPresets.controlPoints(
                segmentCount: segmentCount,
                variant: meshVariant
            ) else {
                return nil
            }
            let topology = ArtworkBackdropMeshTopology(
                baseControlPointCount: ArtworkBackdropMeshPresets.controlPointCountPerSide(
                    segmentCount: segmentCount
                ),
                subdivisionLevel: configuration.meshSubdivisionLevel
            )
            let vertices = topology.makeVertices(
                sourceControlPoints: surfaces.source,
                destinationControlPoints: surfaces.destination
            )
            let indices = topology.makeIndices()
            guard let vertexBuffer = Self.makeBuffer(from: vertices, device: metalDevice),
                  let indexBuffer = Self.makeBuffer(from: indices, device: metalDevice)
            else {
                return nil
            }
            vertexBuffer.label = "Now Playing Backdrop Mesh Vertices"
            indexBuffer.label = "Now Playing Backdrop Mesh Indices"
            return MeshBuffers(
                segmentCount: segmentCount,
                vertexBuffer: vertexBuffer,
                indexBuffer: indexBuffer,
                indexCount: indices.count
            )
        }

        func encodeBlendPass(
            commandBuffer: MTLCommandBuffer,
            destinationTexture: MTLTexture,
            previousArtworkTexture: MTLTexture,
            currentArtworkTexture: MTLTexture,
            uniforms: NowPlayingBackdropUniforms
        ) -> Bool {
            let renderPassDescriptor = MTLRenderPassDescriptor()
            guard let colorAttachment = renderPassDescriptor.colorAttachments[0] else {
                return false
            }
            colorAttachment.texture = destinationTexture
            colorAttachment.loadAction = .dontCare
            colorAttachment.storeAction = .store
            guard let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor
            ) else {
                return false
            }

            var uniforms = uniforms
            renderCommandEncoder.label = "Now Playing Backdrop Blend Encoder"
            renderCommandEncoder.setRenderPipelineState(blendPipelineState)
            renderCommandEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            renderCommandEncoder.setFragmentTexture(previousArtworkTexture, index: 0)
            renderCommandEncoder.setFragmentTexture(currentArtworkTexture, index: 1)
            renderCommandEncoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<NowPlayingBackdropUniforms>.stride,
                index: 0
            )
            renderCommandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderCommandEncoder.endEncoding()
            return true
        }

        func encodeRotationPass(
            commandBuffer: MTLCommandBuffer,
            destinationTexture: MTLTexture,
            artworkTexture: MTLTexture,
            uniforms: NowPlayingBackdropUniforms
        ) -> Bool {
            let renderPassDescriptor = MTLRenderPassDescriptor()
            guard let colorAttachment = renderPassDescriptor.colorAttachments[0] else {
                return false
            }
            colorAttachment.texture = destinationTexture
            colorAttachment.loadAction = .clear
            colorAttachment.storeAction = .store
            colorAttachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor
            ) else {
                return false
            }

            var uniforms = uniforms
            renderCommandEncoder.label = "Now Playing Backdrop Rotation Encoder"
            renderCommandEncoder.setRenderPipelineState(rotationPipelineState)
            renderCommandEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            renderCommandEncoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<NowPlayingBackdropUniforms>.stride,
                index: 1
            )
            renderCommandEncoder.setFragmentTexture(artworkTexture, index: 0)
            renderCommandEncoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<NowPlayingBackdropUniforms>.stride,
                index: 0
            )
            renderCommandEncoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: configuration.rotationInstances.count
            )
            renderCommandEncoder.endEncoding()
            return true
        }

        func encodePinchPass(
            commandBuffer: MTLCommandBuffer,
            renderPassDescriptor: MTLRenderPassDescriptor,
            blurredCanvasTexture: MTLTexture,
            uniforms: NowPlayingBackdropUniforms,
            mesh: MeshBuffers
        ) -> Bool {
            guard let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor
            ) else {
                return false
            }

            var uniforms = uniforms
            renderCommandEncoder.label = "Now Playing Backdrop Pinch Encoder"
            renderCommandEncoder.setRenderPipelineState(pinchPipelineState)
            renderCommandEncoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            renderCommandEncoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<NowPlayingBackdropUniforms>.stride,
                index: 1
            )
            renderCommandEncoder.setFragmentTexture(blurredCanvasTexture, index: 0)
            renderCommandEncoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<NowPlayingBackdropUniforms>.stride,
                index: 0
            )
            renderCommandEncoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.indexCount,
                indexType: .uint32,
                indexBuffer: mesh.indexBuffer,
                indexBufferOffset: 0
            )
            renderCommandEncoder.endEncoding()
            return true
        }

        private func makeIntermediateTexture(width: Int, height: Int, label: String) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.intermediatePixelFormat,
                width: max(1, width),
                height: max(1, height),
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            let texture = metalDevice.makeTexture(descriptor: descriptor)
            texture?.label = label
            return texture
        }
    }
}

extension AppleMusicLyrics.NowPlayingBackdropPipeline {
    fileprivate struct PinchPipeline {
        let pipelineState: MTLRenderPipelineState
        let pixelFormat: MTLPixelFormat
    }

    fileprivate static func makePinchPipeline(
        device metalDevice: MTLDevice,
        shaderLibrary: MTLLibrary,
        preferredPixelFormats: [MTLPixelFormat]
    ) throws -> PinchPipeline {
        for pixelFormat in preferredPixelFormats {
            guard let pipelineState = try? makePipelineState(
                device: metalDevice,
                shaderLibrary: shaderLibrary,
                vertexFunctionName: "nowPlayingPinchVertex",
                fragmentFunctionName: "nowPlayingPinchFragment",
                pixelFormat: pixelFormat,
                label: "Now Playing Backdrop Pinch Pipeline"
            ) else {
                continue
            }
            return PinchPipeline(pipelineState: pipelineState, pixelFormat: pixelFormat)
        }
        throw AppleMusicLyrics.NowPlayingBackdropPipelineCreationError.unavailableDrawablePixelFormat
    }

    fileprivate static func makePipelineState(
        device metalDevice: MTLDevice,
        shaderLibrary: MTLLibrary,
        vertexFunctionName: String,
        fragmentFunctionName: String,
        pixelFormat: MTLPixelFormat,
        label: String
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunction = shaderLibrary.makeFunction(name: vertexFunctionName) else {
            throw AppleMusicLyrics.NowPlayingBackdropPipelineCreationError
                .unavailableShaderFunction(vertexFunctionName)
        }
        guard let fragmentFunction = shaderLibrary.makeFunction(name: fragmentFunctionName) else {
            throw AppleMusicLyrics.NowPlayingBackdropPipelineCreationError
                .unavailableShaderFunction(fragmentFunctionName)
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = label
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    /// Music's full-canvas quad, upright: clip-space corners with texture
    /// coordinates whose origin is the top-left corner of the artwork.
    fileprivate static func makeQuadVertexBuffer(device metalDevice: MTLDevice) -> MTLBuffer? {
        let vertices = [
            QuadVertex(position: SIMD2(-1, -1), textureCoordinate: SIMD2(0, 1)),
            QuadVertex(position: SIMD2(-1, 1), textureCoordinate: SIMD2(0, 0)),
            QuadVertex(position: SIMD2(1, -1), textureCoordinate: SIMD2(1, 1)),
            QuadVertex(position: SIMD2(1, 1), textureCoordinate: SIMD2(1, 0)),
        ]
        let buffer = makeBuffer(from: vertices, device: metalDevice)
        buffer?.label = "Now Playing Backdrop Quad"
        return buffer
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

    fileprivate static func makeFallbackTexture(
        device metalDevice: MTLDevice,
        color: SIMD3<Float>
    ) -> MTLTexture? {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = .shaderRead
        guard let texture = metalDevice.makeTexture(descriptor: textureDescriptor) else {
            return nil
        }

        let pixel: [UInt8] = [
            UInt8((min(1, max(0, color.x)) * 255).rounded()),
            UInt8((min(1, max(0, color.y)) * 255).rounded()),
            UInt8((min(1, max(0, color.z)) * 255).rounded()),
            255,
        ]
        let pixelBytes = Array([[UInt8]](repeating: pixel, count: 4).joined())
        pixelBytes.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, 2, 2),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: 8
            )
        }
        texture.label = "Now Playing Backdrop Placeholder Artwork"
        return texture
    }
}
