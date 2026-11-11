import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalPerformanceShaders
import simd
import Testing
@testable import AppleMusicLyricsPanel

@Suite(.serialized)
struct NowPlayingBackdropRenderingTests {
    @Test func rotationPassDarkensAndSaturatesEachCopyInGammaSpace() throws {
        let harness = try NowPlayingBackdropHarness()
        let artworkTexture = try harness.makeSolidTexture(SIMD4(0.8, 0.4, 0.2, 1))

        let canvas = try harness.renderRotationPass(
            artworkTexture: artworkTexture,
            canvasDimension: 128,
            animationTime: 0
        )

        // Hand-computed from Music's rotation_fragment: mix towards black by
        // 0.5 + 0.0075 × instance, then the SVG saturate matrix at 2.4. The
        // lower-right pixel is reached only by the 1.4× first copy; the
        // upper-right pixel is painted last by the third copy.
        let firstCopy = try harness.readPixel(canvas, horizontalIndex: 108, verticalIndex: 108)
        let thirdCopy = try harness.readPixel(canvas, horizontalIndex: 108, verticalIndex: 20)
        expectClose(firstCopy, SIMD3(0.63044, 0.15044, -0.08956), tolerance: 0.005)
        expectClose(thirdCopy, SIMD3(0.61153, 0.14593, -0.08687), tolerance: 0.005)
    }

    @Test func pinchPassUnpremultipliesLiftsAndGradesTheBlurredCanvas() throws {
        let harness = try NowPlayingBackdropHarness()
        let canvas = try harness.makeSolidTexture(SIMD4(0.3, 0.1, 0.05, 0.5))

        let ungraded = try harness.renderPinchPass(canvasTexture: canvas, colorGradingMix: 0)
        let graded = try harness.renderPinchPass(canvasTexture: canvas, colorGradingMix: 1)

        // Unpremultiplied (0.6, 0.2, 0.1) lifted 10 % towards white is
        // (0.64, 0.28, 0.19). The red side of the grading then takes
        // 0.306 × chroma (0.45) off red, spills 18 % of that into green and
        // blue, and darkens green by 0.3 × chroma × 4h(1 − h) at hue 0.2.
        expectClose(ungraded, SIMD3(0.64, 0.28, 0.19), tolerance: 0.004)
        expectClose(graded, SIMD3(0.5023, 0.2806, 0.2148), tolerance: 0.004)
    }

    @Test(arguments: [
        (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0.694, 0.055, 0.059)),
        (SIMD3<Float>(0, 0, 1), SIMD3<Float>(0.035, 0.035, 0.710)),
        (SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0.996, 0)),
        (SIMD3<Float>(1, 1, 0), SIMD3<Float>(0.996, 1, 0)),
        (SIMD3<Float>(0.484, 0.484, 0.484), SIMD3<Float>(0.484, 0.484, 0.484)),
        (SIMD3<Float>(0.484, 0, 0), SIMD3<Float>(0.333, 0.031, 0.027)),
        (SIMD3<Float>(1, 0.258, 0.258), SIMD3<Float>(0.773, 0.302, 0.302)),
        (SIMD3<Float>(0.258, 0.258, 1), SIMD3<Float>(0.286, 0.286, 0.788)),
    ])
    func colorGradingReproducesTheMeasuredBackdropLut(
        input: SIMD3<Float>,
        expected: SIMD3<Float>
    ) throws {
        let harness = try NowPlayingBackdropHarness()
        let canvas = try harness.makeSolidTexture(SIMD4(input.x, input.y, input.z, 1))

        // With no white lift and an opaque canvas the pinch pass is the
        // grading alone; the expected values are samples of Music's BackdropLUT.
        let graded = try harness.renderPinchPass(canvasTexture: canvas, colorGradingMix: 1, whiteMix: 0)

        expectClose(graded, expected, tolerance: 0.012)
    }

    @Test(arguments: [0.0, 20.0])
    func fullFrameLandsInTheNowPlayingToneRange(animationTime: TimeInterval) throws {
        let harness = try NowPlayingBackdropHarness()
        let artworkTexture = try harness.makeArtworkTexture(
            bytes: ArtworkBackdropReferenceFixture.imageBytes,
            dimension: ArtworkBackdropReferenceFixture.dimension
        )

        // The reference window's point size at 1×, so the 120 pt blur covers
        // the same share of the frame as in the screenshot.
        let frame = try harness.renderFrame(
            artworkTexture: artworkTexture,
            drawableSize: CGSize(width: 1176, height: 811),
            animationTime: animationTime
        )
        let statistics = try harness.toneStatistics(of: frame)

        // Measured in the Apple Music half of the 《晴天》 screenshot: luminance
        // p10 / p50 / p90 of 0.134 / 0.175 / 0.336 and saturation p50 / p90 of
        // 0.32 / 0.46. The whole frame is looser than that strip, so the bounds
        // reject the old renderer's crushed shadows (p10 0.070) and doubled
        // saturation (p50 0.59) rather than pin the screenshot.
        #expect(statistics.luminosity10 >= 0.10, "luminance p10 \(statistics.luminosity10)")
        #expect((0.12 ... 0.30).contains(statistics.luminosity50), "luminance p50 \(statistics.luminosity50)")
        #expect(statistics.luminosity90 <= 0.5, "luminance p90 \(statistics.luminosity90)")
        #expect(statistics.saturation50 <= 0.5, "saturation p50 \(statistics.saturation50)")
        #expect(statistics.saturation90 <= 0.75, "saturation p90 \(statistics.saturation90)")
        #expect(statistics.colorSpread90 > 0.03, "colour spread p90 \(statistics.colorSpread90)")

        if let outputDirectory = ProcessInfo.processInfo.environment["LYRICSX_BACKDROP_PREVIEW_DIRECTORY"] {
            try harness.writePreview(frame, directory: outputDirectory, name: "NowPlaying-\(Int(animationTime))s.png")
        }
    }

    @Test func frameResourcesFollowTheDrawableOrientation() throws {
        let harness = try NowPlayingBackdropHarness()
        let artworkTexture = try harness.makeSolidTexture(SIMD4(0.5, 0.5, 0.5, 1))

        let landscapeContext = harness.makeContext(
            artworkTexture: artworkTexture,
            drawableSize: CGSize(width: 800, height: 600),
            animationTime: 0
        )
        #expect(harness.pipeline.prepareResources(for: landscapeContext) == .rebuilt)
        #expect(harness.pipeline.prepareResources(for: landscapeContext) == .ready)
        let landscapeUniforms = harness.pipeline.makeUniforms(for: landscapeContext)
        #expect(landscapeUniforms.saturation == 2.4)

        let portraitContext = harness.makeContext(
            artworkTexture: artworkTexture,
            drawableSize: CGSize(width: 600, height: 800),
            animationTime: 0
        )
        #expect(harness.pipeline.prepareResources(for: portraitContext) == .rebuilt)
        let portraitUniforms = harness.pipeline.makeUniforms(for: portraitContext)
        #expect(portraitUniforms.saturation == 2.0)
        #expect(portraitUniforms.darken == 0.5)
    }

    /// Opt-in diagnostic: `LYRICSX_BACKDROP_PHASE_SWEEP_COVER=/path/to/cover.png`
    /// renders that cover through every mesh preset across a rotation period
    /// and writes the tone statistics next to it, so a single Apple Music
    /// screenshot can be placed inside the range the pipeline actually spans.
    @Test func phaseSweepReportsTheToneRangeOfACover() throws {
        guard let coverPath = ProcessInfo.processInfo.environment["LYRICSX_BACKDROP_PHASE_SWEEP_COVER"] else {
            return
        }
        let harness = try NowPlayingBackdropHarness()
        let artworkTexture = try harness.makeArtworkTexture(contentsOf: coverPath, dimension: 128)
        var report = ["variant\ttime\tlum10\tlum50\tlum90\tsat50\tsat90"]
        for meshVariant in 0 ..< AppleMusicLyrics.ArtworkBackdropMeshPresets.variantCount {
            let pipeline = try harness.makePipeline(meshVariant: meshVariant)
            for animationTime in stride(from: 0.0, through: 240.0, by: 12.0) {
                let frame = try harness.renderFrame(
                    pipeline: pipeline,
                    artworkTexture: artworkTexture,
                    drawableSize: CGSize(width: 1176, height: 811),
                    animationTime: animationTime
                )
                let statistics = try harness.toneStatistics(of: frame)
                report.append(String(
                    format: "%d\t%.0f\t%.3f\t%.3f\t%.3f\t%.2f\t%.2f",
                    meshVariant,
                    animationTime,
                    statistics.luminosity10,
                    statistics.luminosity50,
                    statistics.luminosity90,
                    statistics.saturation50,
                    statistics.saturation90
                ))
            }
        }
        try report.joined(separator: "\n").write(
            toFile: coverPath + ".sweep.tsv",
            atomically: true,
            encoding: .utf8
        )
    }

    @MainActor
    @Test func metalViewAdoptsThePipelineColorSpaceAndClearColor() throws {
        let harness = try NowPlayingBackdropHarness()
        let view = try AppleMusicLyrics.ArtworkGradientMetalView(
            frame: .zero,
            device: harness.device,
            pipeline: harness.pipeline
        )

        #expect(view.colorspace?.name == CGColorSpace.extendedSRGB)
        // The property alone proves nothing: the compositor colour-matches
        // only when the backing CAMetalLayer carries the space.
        let metalLayer = try #require(view.layer as? CAMetalLayer)
        #expect(metalLayer.colorspace?.name == CGColorSpace.extendedSRGB)
        #expect(abs(view.clearColor.red - view.clearColor.green) < 0.0001)
        #expect(view.clearColor.red > 0.3 && view.clearColor.red < 0.45)
    }
}

private func expectClose(
    _ actual: SIMD3<Float>,
    _ expected: SIMD3<Float>,
    tolerance: Float,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let difference = simd_abs(actual - expected)
    #expect(
        difference.max() <= tolerance,
        "actual \(actual) expected \(expected)",
        sourceLocation: sourceLocation
    )
}

private struct NowPlayingBackdropHarness {
    struct ToneStatistics {
        let luminosity10: Float
        let luminosity50: Float
        let luminosity90: Float
        let saturation50: Float
        let saturation90: Float
        let colorSpread90: Float
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let shaderLibrary: MTLLibrary
    let pipeline: AppleMusicLyrics.NowPlayingBackdropPipeline

    init() throws {
        self.device = try #require(MTLCreateSystemDefaultDevice())
        self.commandQueue = try #require(device.makeCommandQueue())
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderSource = try String(
            contentsOf: packageDirectory.appendingPathComponent(
                "Sources/AppleMusicLyricsPanel/ArtworkGradientShaders.metal"
            ),
            encoding: .utf8
        )
        self.shaderLibrary = try device.makeLibrary(source: shaderSource, options: nil)
        self.pipeline = try AppleMusicLyrics.NowPlayingBackdropPipeline(
            device: device,
            configuration: .init(meshVariant: 1),
            shaderLibrary: shaderLibrary
        )
    }

    func makeContext(
        artworkTexture: MTLTexture,
        drawableSize: CGSize,
        animationTime: TimeInterval,
        backingScaleFactor: CGFloat = 1
    ) -> AppleMusicLyrics.ArtworkBackdropFrameContext {
        let textureState = AppleMusicLyrics.ArtworkBackdropTextureState(
            texture: artworkTexture,
            averageLuminosity: 0.3
        )
        return AppleMusicLyrics.ArtworkBackdropFrameContext(
            sourceTextureState: textureState,
            destinationTextureState: textureState,
            transitionProgress: 1,
            animationTime: animationTime,
            drawableSize: drawableSize,
            backingScaleFactor: backingScaleFactor,
            isDarkAppearance: true
        )
    }

    func makeSolidTexture(_ color: SIMD4<Float>) throws -> MTLTexture {
        let texture = try makeTexture(pixelFormat: .rgba32Float, width: 1, height: 1, usage: .shaderRead)
        var pixel = color
        withUnsafeBytes(of: &pixel) { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: MemoryLayout<SIMD4<Float>>.stride
            )
        }
        return texture
    }

    /// Gamma-encoded artwork the way `MTKTextureLoader` delivers it with `SRGB: false`.
    func makeArtworkTexture(bytes: [UInt8], dimension: Int) throws -> MTLTexture {
        let texture = try makeTexture(pixelFormat: .rgba8Unorm, width: dimension, height: dimension, usage: .shaderRead)
        bytes.withUnsafeBytes { rawBytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, dimension, dimension),
                mipmapLevel: 0,
                withBytes: rawBytes.baseAddress!,
                bytesPerRow: dimension * 4
            )
        }
        return texture
    }

    func renderRotationPass(
        artworkTexture: MTLTexture,
        canvasDimension: Int,
        animationTime: TimeInterval
    ) throws -> MTLTexture {
        let canvas = try makeTexture(
            pixelFormat: AppleMusicLyrics.NowPlayingBackdropPipeline.intermediatePixelFormat,
            width: canvasDimension,
            height: canvasDimension,
            usage: [.renderTarget, .shaderRead]
        )
        let context = makeContext(
            artworkTexture: artworkTexture,
            drawableSize: CGSize(width: canvasDimension * 4, height: canvasDimension * 4),
            animationTime: animationTime
        )
        let uniforms = pipeline.makeUniforms(for: context)
        let commandBuffer = try #require(commandQueue.makeCommandBuffer())
        try #require(pipeline.encodeRotationPass(
            commandBuffer: commandBuffer,
            destinationTexture: canvas,
            artworkTexture: artworkTexture,
            uniforms: uniforms
        ))
        try complete(commandBuffer)
        return canvas
    }

    func renderPinchPass(
        canvasTexture: MTLTexture,
        colorGradingMix: Float,
        whiteMix: Float? = nil
    ) throws -> SIMD3<Float> {
        let output = try makeTexture(
            pixelFormat: pipeline.drawablePixelFormat,
            width: 8,
            height: 8,
            usage: [.renderTarget, .shaderRead]
        )
        let context = makeContext(
            artworkTexture: canvasTexture,
            drawableSize: CGSize(width: 32, height: 32),
            animationTime: 0
        )
        var uniforms = pipeline.makeUniforms(for: context)
        uniforms.colorGrading.mix = colorGradingMix
        if let whiteMix {
            uniforms.whiteMix = whiteMix
        }
        let mesh = try #require(pipeline.makeMesh(segmentCount: 8))
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = output
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        let commandBuffer = try #require(commandQueue.makeCommandBuffer())
        try #require(pipeline.encodePinchPass(
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPass,
            blurredCanvasTexture: canvasTexture,
            uniforms: uniforms,
            mesh: mesh
        ))
        try complete(commandBuffer)
        return try readPixel(output, horizontalIndex: 4, verticalIndex: 4)
    }

    func makePipeline(meshVariant: Int) throws -> AppleMusicLyrics.NowPlayingBackdropPipeline {
        try AppleMusicLyrics.NowPlayingBackdropPipeline(
            device: device,
            configuration: .init(meshVariant: meshVariant),
            shaderLibrary: shaderLibrary
        )
    }

    /// A cover file decoded into the gamma-encoded 128 × 128 texture the
    /// panel would upload for it.
    func makeArtworkTexture(contentsOf path: String, dimension: Int) throws -> MTLTexture {
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: dimension * dimension * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: dimension * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
        }
        return try makeArtworkTexture(bytes: bytes, dimension: dimension)
    }

    func renderFrame(
        artworkTexture: MTLTexture,
        drawableSize: CGSize,
        animationTime: TimeInterval
    ) throws -> MTLTexture {
        try renderFrame(
            pipeline: pipeline,
            artworkTexture: artworkTexture,
            drawableSize: drawableSize,
            animationTime: animationTime
        )
    }

    func renderFrame(
        pipeline: AppleMusicLyrics.NowPlayingBackdropPipeline,
        artworkTexture: MTLTexture,
        drawableSize: CGSize,
        animationTime: TimeInterval
    ) throws -> MTLTexture {
        let context = makeContext(
            artworkTexture: artworkTexture,
            drawableSize: drawableSize,
            animationTime: animationTime
        )
        try #require(pipeline.prepareResources(for: context) != .failed)
        let output = try makeTexture(
            pixelFormat: pipeline.drawablePixelFormat,
            width: Int(drawableSize.width),
            height: Int(drawableSize.height),
            usage: [.renderTarget, .shaderRead]
        )
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = output
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = pipeline.clearColor
        renderPass.colorAttachments[0].storeAction = .store
        let commandBuffer = try #require(commandQueue.makeCommandBuffer())
        try #require(pipeline.encodeOffscreenFrame(commandBuffer: commandBuffer, context: context))
        try #require(pipeline.encodeFinalFrame(
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPass,
            context: context
        ))
        try complete(commandBuffer)
        return output
    }

    func toneStatistics(of texture: MTLTexture) throws -> ToneStatistics {
        let pixels = try readPixels(texture)
        var luminosities = [Float]()
        var saturations = [Float]()
        var colorSpreads = [Float]()
        luminosities.reserveCapacity(pixels.count)
        saturations.reserveCapacity(pixels.count)
        colorSpreads.reserveCapacity(pixels.count)
        for pixel in pixels {
            let brightest = max(pixel.x, pixel.y, pixel.z)
            let darkest = min(pixel.x, pixel.y, pixel.z)
            luminosities.append(pixel.x * 0.3 + pixel.y * 0.59 + pixel.z * 0.11)
            saturations.append((brightest - darkest) / max(brightest, 0.00001))
            colorSpreads.append(brightest - darkest)
        }
        luminosities.sort()
        saturations.sort()
        colorSpreads.sort()
        func percentile(_ values: [Float], _ fraction: Double) -> Float {
            values[min(values.count - 1, Int(Double(values.count) * fraction))]
        }
        return ToneStatistics(
            luminosity10: percentile(luminosities, 0.1),
            luminosity50: percentile(luminosities, 0.5),
            luminosity90: percentile(luminosities, 0.9),
            saturation50: percentile(saturations, 0.5),
            saturation90: percentile(saturations, 0.9),
            colorSpread90: percentile(colorSpreads, 0.9)
        )
    }

    func readPixel(_ texture: MTLTexture, horizontalIndex: Int, verticalIndex: Int) throws -> SIMD3<Float> {
        let bytesPerPixel = try bytesPerPixel(of: texture.pixelFormat)
        var pixelBytes = [UInt8](repeating: 0, count: bytesPerPixel)
        pixelBytes.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: bytesPerPixel,
                from: MTLRegionMake2D(horizontalIndex, verticalIndex, 1, 1),
                mipmapLevel: 0
            )
        }
        return try decodePixel(pixelBytes[...], pixelFormat: texture.pixelFormat)
    }

    func readPixels(_ texture: MTLTexture) throws -> [SIMD3<Float>] {
        let bytesPerPixel = try bytesPerPixel(of: texture.pixelFormat)
        var pixelBytes = [UInt8](repeating: 0, count: texture.width * texture.height * bytesPerPixel)
        pixelBytes.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: texture.width * bytesPerPixel,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        return try stride(from: 0, to: pixelBytes.count, by: bytesPerPixel).map { offset in
            try decodePixel(pixelBytes[offset ..< offset + bytesPerPixel], pixelFormat: texture.pixelFormat)
        }
    }

    func writePreview(_ texture: MTLTexture, directory: String, name: String) throws {
        let directoryLocation = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryLocation, withIntermediateDirectories: true)
        let imageBytes = try readPixels(texture).flatMap { pixel in
            [UInt8((pixel.x * 255).rounded()), UInt8((pixel.y * 255).rounded()), UInt8((pixel.z * 255).rounded()), 255]
        }
        let dataProvider = try #require(CGDataProvider(data: Data(imageBytes) as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(
            width: texture.width,
            height: texture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: texture.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(
            directoryLocation.appendingPathComponent(name) as CFURL,
            "public.png" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func makeTexture(
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        usage: MTLTextureUsage
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = usage
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func complete(_ commandBuffer: MTLCommandBuffer) throws {
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try #require(commandBuffer.status == .completed, "\(String(describing: commandBuffer.error))")
    }

    private func bytesPerPixel(of pixelFormat: MTLPixelFormat) throws -> Int {
        switch pixelFormat {
        case .bgr10a2Unorm,
             .bgra8Unorm:
            return 4
        case .rgba16Float:
            return 8
        case .rgba32Float:
            return 16
        default:
            throw NowPlayingReadbackError.unsupportedPixelFormat
        }
    }

    private func decodePixel(_ bytes: ArraySlice<UInt8>, pixelFormat: MTLPixelFormat) throws -> SIMD3<Float> {
        let start = bytes.startIndex
        switch pixelFormat {
        case .bgr10a2Unorm:
            let packed = UInt32(bytes[start]) | UInt32(bytes[start + 1]) << 8
                | UInt32(bytes[start + 2]) << 16 | UInt32(bytes[start + 3]) << 24
            return SIMD3(
                Float((packed >> 20) & 1023),
                Float((packed >> 10) & 1023),
                Float(packed & 1023)
            ) / 1023
        case .bgra8Unorm:
            return SIMD3(Float(bytes[start + 2]), Float(bytes[start + 1]), Float(bytes[start])) / 255
        case .rgba16Float:
            func half(_ offset: Int) -> Float {
                floatFromHalf(UInt16(bytes[start + offset]) | UInt16(bytes[start + offset + 1]) << 8)
            }
            return SIMD3(half(0), half(2), half(4))
        case .rgba32Float:
            func component(_ offset: Int) -> Float {
                var value: UInt32 = 0
                for byteIndex in 0 ..< 4 {
                    value |= UInt32(bytes[start + offset + byteIndex]) << (8 * UInt32(byteIndex))
                }
                return Float(bitPattern: value)
            }
            return SIMD3(component(0), component(4), component(8))
        default:
            throw NowPlayingReadbackError.unsupportedPixelFormat
        }
    }

    private func floatFromHalf(_ bits: UInt16) -> Float {
        let sign: Float = (bits & 0x8000) != 0 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = Float(bits & 0x3FF)
        switch exponent {
        case 0:
            return sign * mantissa / 1024 * pow(2, -14)
        case 31:
            return mantissa == 0 ? sign * .infinity : .nan
        default:
            return sign * (1 + mantissa / 1024) * pow(2, Float(exponent - 15))
        }
    }
}

private enum NowPlayingReadbackError: Error {
    case unsupportedPixelFormat
}
