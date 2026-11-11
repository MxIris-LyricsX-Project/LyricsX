import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalPerformanceShaders
import Testing
@testable import AppleMusicLyricsPanel

@Suite(.serialized)
struct ArtworkBackdropRenderingTests {
    @MainActor
    @Test func metalViewRetainsAppleMusicDefaultColorSpace() throws {
        let renderer = try OffscreenBackdropRenderer()
        let view = try AppleMusicLyrics.ArtworkGradientMetalView(
            frame: .zero,
            device: renderer.device,
            pipeline: renderer.pipeline
        )

        #expect(view.colorspace == nil)
    }

    @Test(arguments: [
        (SIMD4<Float>(1, 0, 0, 1), SIMD3<Float>(0.72634, 0.07, 0.07)),
        (SIMD4<Float>(0, 0, 0, 1), SIMD3<Float>(repeating: 0.07)),
        (SIMD4<Float>(1, 1, 1, 1), SIMD3<Float>(repeating: 0.72634)),
        (SIMD4<Float>(0.4, 0.4, 0.4, 1), SIMD3<Float>(repeating: 0.28)),
        (SIMD4<Float>(0.3, 0.2, 0.1, 1), SIMD3<Float>(0.26575, 0.11575, 0.07)),
    ])
    func finalBackdropKeepsSaturatedArtworkWithinAppleMusicDarkRange(
        artworkColor: SIMD4<Float>,
        expectedColor: SIMD3<Float>
    ) throws {
        let renderer = try OffscreenBackdropRenderer()
        let pixel = try renderer.renderFinalColor(artworkColor)

        // Independent reference: Music's dark pinch_fragment, scrim 0.25,
        // highlight limit 0.995, dark offset 0.02, and channel floor 0.07.
        #expect(abs(pixel.x - expectedColor.x) < 0.005)
        #expect(abs(pixel.y - expectedColor.y) < 0.005)
        #expect(abs(pixel.z - expectedColor.z) < 0.005)
    }

    @Test func compositionRetainsTheThreeOverlappingArtworkRegions() throws {
        let renderer = try OffscreenBackdropRenderer()
        let texture = try renderer.renderComposition(animationTime: 0)

        // A horizontal grayscale ramp samples a different part of the cover
        // in each of Music's three translated quads at time zero.
        let center = try renderer.readPixel(texture, horizontalIndex: 64, verticalIndex: 64)
        let upperRight = try renderer.readPixel(texture, horizontalIndex: 96, verticalIndex: 32)
        let upperLeft = try renderer.readPixel(texture, horizontalIndex: 32, verticalIndex: 32)
        #expect(abs(center.x - 0.979) < 0.01)
        #expect(abs(upperRight.x - 0.755) < 0.01)
        #expect(abs(upperLeft.x - 0.504) < 0.01)
    }

    @Test func artworkRegionsFollowTheIndependentRotationPeriods() throws {
        let renderer = try OffscreenBackdropRenderer()
        let texture = try renderer.renderComposition(animationTime: 7.5)
        let center = try renderer.readPixel(texture, horizontalIndex: 64, verticalIndex: 64)
        let upperRight = try renderer.readPixel(texture, horizontalIndex: 96, verticalIndex: 32)
        let upperLeft = try renderer.readPixel(texture, horizontalIndex: 32, verticalIndex: 32)

        // Reference samples from view * rotation * translation * rotation,
        // with the native 60, 45, and 35 second model periods.
        #expect(abs(center.x - 0.93122) < 0.01)
        #expect(abs(upperRight.x - 0.58838) < 0.01)
        #expect(abs(upperLeft.x - 0.37895) < 0.01)
    }

    @Test func fullBackdropRetainsMutedColorsWhileTheArtworkMoves() throws {
        let renderer = try OffscreenBackdropRenderer()
        let firstFrame = try renderer.renderArtwork(animationTime: 0)
        let laterFrame = try renderer.renderArtwork(animationTime: 5)
        let firstPixels = try renderer.readPixels(firstFrame)
        let laterPixels = try renderer.readPixels(laterFrame)
        var changedPixelCount = 0
        for (firstPixel, laterPixel) in zip(firstPixels, laterPixels) {
            let difference = firstPixel - laterPixel
            if max(abs(difference.x), abs(difference.y), abs(difference.z)) > 0.01 {
                changedPixelCount += 1
            }
        }

        #expect(firstPixels.allSatisfy { pixel in
            min(pixel.x, pixel.y, pixel.z) >= 0.065
                && max(pixel.x, pixel.y, pixel.z) <= 0.732
        })
        #expect(changedPixelCount > firstPixels.count / 10)

        if let outputDirectory = ProcessInfo.processInfo.environment["LYRICSX_BACKDROP_PREVIEW_DIRECTORY"] {
            try renderer.writePreview(firstFrame, directory: outputDirectory, name: "Backdrop-0s.png")
            try renderer.writePreview(laterFrame, directory: outputDirectory, name: "Backdrop-5s.png")
        }
    }
}

private struct OffscreenBackdropRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let shaderLibrary: MTLLibrary
    let pipeline: AppleMusicLyrics.ArtworkBackdropPipeline

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
        self.pipeline = try AppleMusicLyrics.ArtworkBackdropPipeline(
            device: device,
            configuration: .init(meshVariant: 1),
            shaderLibrary: shaderLibrary
        )
    }

    func renderFinalColor(_ color: SIMD4<Float>) throws -> SIMD3<Float> {
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: 1,
            height: 1,
            mipmapped: false
        )
        inputDescriptor.storageMode = .shared
        inputDescriptor.usage = .shaderRead
        let inputTexture = try #require(device.makeTexture(descriptor: inputDescriptor))
        var inputColor = color
        withUnsafeBytes(of: &inputColor) { colorBytes in
            inputTexture.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: colorBytes.baseAddress!,
                bytesPerRow: MemoryLayout<SIMD4<Float>>.stride
            )
        }

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pipeline.drawablePixelFormat,
            width: 8,
            height: 8,
            mipmapped: false
        )
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        let outputTexture = try #require(device.makeTexture(descriptor: outputDescriptor))
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = outputTexture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        let commandBuffer = try #require(commandQueue.makeCommandBuffer())
        try #require(pipeline.encodeFinalBackdrop(
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPass,
            blurredTexture: inputTexture,
            animationTime: 0,
            averageLuminosity: 0.2,
            configuration: .init()
        ))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try #require(commandBuffer.status == .completed, "\(String(describing: commandBuffer.error))")

        return try readPixel(outputTexture, horizontalIndex: 4, verticalIndex: 4)
    }

    func renderComposition(animationTime: TimeInterval) throws -> MTLTexture {
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: 256,
            height: 1,
            mipmapped: false
        )
        inputDescriptor.storageMode = .shared
        inputDescriptor.usage = .shaderRead
        let inputTexture = try #require(device.makeTexture(descriptor: inputDescriptor))
        let colors = (0 ..< 256).map { pixelIndex in
            let component = Float(pixelIndex) / 255
            return SIMD4<Float>(component, component, component, 1)
        }
        colors.withUnsafeBytes { colorBytes in
            inputTexture.replace(
                region: MTLRegionMake2D(0, 0, 256, 1),
                mipmapLevel: 0,
                withBytes: colorBytes.baseAddress!,
                bytesPerRow: colorBytes.count
            )
        }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pipeline.drawablePixelFormat,
            width: 128,
            height: 128,
            mipmapped: false
        )
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        let outputTexture = try #require(device.makeTexture(descriptor: outputDescriptor))
        let textureState = AppleMusicLyrics.ArtworkBackdropTextureState(
            texture: inputTexture,
            averageLuminosity: 0.5
        )
        let commandBuffer = try #require(commandQueue.makeCommandBuffer())
        try #require(pipeline.encodeComposition(
            commandBuffer: commandBuffer,
            destinationTexture: outputTexture,
            sourceTextureState: textureState,
            destinationTextureState: textureState,
            transitionProgress: 0,
            animationTime: animationTime
        ))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try #require(commandBuffer.status == .completed)
        return outputTexture
    }

    func readPixel(
        _ outputTexture: MTLTexture,
        horizontalIndex: Int,
        verticalIndex: Int
    ) throws -> SIMD3<Float> {
        var packedPixel: UInt32 = 0
        outputTexture.getBytes(
            &packedPixel,
            bytesPerRow: 4,
            from: MTLRegionMake2D(horizontalIndex, verticalIndex, 1, 1),
            mipmapLevel: 0
        )
        return try decodePixel(packedPixel, pixelFormat: outputTexture.pixelFormat)
    }

    func renderArtwork(animationTime: TimeInterval) throws -> MTLTexture {
        let artworkDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: 96,
            height: 96,
            mipmapped: false
        )
        artworkDescriptor.storageMode = .shared
        artworkDescriptor.usage = .shaderRead
        let artworkTexture = try #require(device.makeTexture(descriptor: artworkDescriptor))
        var artworkBytes = [UInt8]()
        for verticalIndex in 0 ..< 96 {
            for horizontalIndex in 0 ..< 96 {
                let isLetter = (10 ..< 20).contains(horizontalIndex) && (10 ..< 82).contains(verticalIndex)
                let isArrow = horizontalIndex > 77 && abs(verticalIndex - 46) < horizontalIndex - 77
                artworkBytes.append(contentsOf: isLetter || isArrow ? [244, 244, 244, 255] : [191, 55, 82, 255])
            }
        }
        artworkBytes.withUnsafeBytes { bytes in
            artworkTexture.replace(
                region: MTLRegionMake2D(0, 0, 96, 96),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: 96 * 4
            )
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pipeline.drawablePixelFormat,
            width: 384,
            height: 248,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        let compositionTexture = try #require(device.makeTexture(descriptor: descriptor))
        let blurredTexture = try #require(device.makeTexture(descriptor: descriptor))
        let outputTexture = try #require(device.makeTexture(descriptor: descriptor))
        let commandBuffer = try #require(commandQueue.makeCommandBuffer())
        let textureState = AppleMusicLyrics.ArtworkBackdropTextureState(texture: artworkTexture, averageLuminosity: 0.2)
        try #require(pipeline.encodeComposition(
            commandBuffer: commandBuffer,
            destinationTexture: compositionTexture,
            sourceTextureState: textureState,
            destinationTextureState: textureState,
            transitionProgress: 0,
            animationTime: animationTime
        ))
        let blur = MPSImageGaussianBlur(device: device, sigma: 20)
        blur.options = AppleMusicLyrics.ArtworkBackdropRenderingProfile.gaussianBlurOptions
        blur.edgeMode = AppleMusicLyrics.ArtworkBackdropRenderingProfile.gaussianBlurEdgeMode
        blur.encode(commandBuffer: commandBuffer, sourceTexture: compositionTexture, destinationTexture: blurredTexture)
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = outputTexture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        try #require(pipeline.encodeFinalBackdrop(
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPass,
            blurredTexture: blurredTexture,
            animationTime: animationTime,
            averageLuminosity: 0.2,
            configuration: .init()
        ))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try #require(commandBuffer.status == .completed, "\(String(describing: commandBuffer.error))")
        return outputTexture
    }

    func readPixels(_ texture: MTLTexture) throws -> [SIMD3<Float>] {
        var packedPixels = [UInt32](repeating: 0, count: texture.width * texture.height)
        packedPixels.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        return try packedPixels.map { packedPixel in
            try decodePixel(packedPixel, pixelFormat: texture.pixelFormat)
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

    private func decodePixel(_ packedPixel: UInt32, pixelFormat: MTLPixelFormat) throws -> SIMD3<Float> {
        switch pixelFormat {
        case .bgr10a2Unorm:
            return SIMD3(
                Float((packedPixel >> 20) & 1023),
                Float((packedPixel >> 10) & 1023),
                Float(packedPixel & 1023)
            ) / 1023
        case .bgra8Unorm:
            return SIMD3(
                Float((packedPixel >> 16) & 255),
                Float((packedPixel >> 8) & 255),
                Float(packedPixel & 255)
            ) / 255
        default:
            throw BackdropReadbackError.unsupportedPixelFormat
        }
    }
}

private enum BackdropReadbackError: Error {
    case unsupportedPixelFormat
}
