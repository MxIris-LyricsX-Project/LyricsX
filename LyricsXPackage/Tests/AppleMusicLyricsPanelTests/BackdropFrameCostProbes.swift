import CoreGraphics
import Foundation
import Metal
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

/// How much of a frame each backdrop pipeline costs on the GPU, measured
/// offscreen at the drawable size a full-screen panel really gets. This is
/// the number the lyrics tree has to share the GPU with: the 2026-09-06
/// stutter report showed the Metal view's main-thread drawable wait sitting
/// at 13–15 ms of a 16.7 ms frame, and this probe tells whether that wait is
/// the GPU genuinely working that long or only presentation back-pressure.
///
/// Every frame's GPU interval comes from the command buffer's own
/// `gpuStartTime` / `gpuEndTime`, so the CPU encode and the wait for a
/// drawable are not in it. The table is printed for every run; the budget
/// assertion only bites when `LYRICSX_BACKDROP_GPU_BUDGET_MILLISECONDS` names
/// a number, because absolute GPU time is a property of the machine.
@Suite(.serialized)
struct BackdropFrameCostProbes {
    private static let recordedDrawableSize = CGSize(width: 2354, height: 1626)
    private static let sampledFrameCount = 60

    private struct FrameCost {
        let gpuMilliseconds: Double
        let encodeMilliseconds: Double
    }

    private struct CostSummary: CustomStringConvertible {
        let variant: AppleMusicLyrics.ArtworkBackdropVariant
        let medianGPU: Double
        let maximumGPU: Double
        let medianEncode: Double

        var description: String {
            String(
                format: "%@ gpu median %.2f ms max %.2f ms, cpu encode median %.2f ms",
                variant.rawValue, medianGPU, maximumGPU, medianEncode
            )
        }
    }

    @Test func eachBackdropVariantReportsItsGPUCostAtTheRecordedSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let commandQueue = try #require(device.makeCommandQueue())
        let shaderLibrary = try Self.makeShaderLibrary(device: device)

        var summaries: [CostSummary] = []
        for variant in [AppleMusicLyrics.ArtworkBackdropVariant.mediaCoreUI26, .legacyTSL] {
            let pipeline = try variant.makePipeline(device: device, shaderLibrary: shaderLibrary)
            let artwork = try Self.makeSyntheticArtwork(
                device: device,
                dimension: variant.maximumArtworkDimension
            )
            let costs = try Self.measure(
                pipeline: pipeline,
                artwork: artwork,
                commandQueue: commandQueue,
                device: device
            )
            let gpuTimes = costs.map(\.gpuMilliseconds).sorted()
            let encodeTimes = costs.map(\.encodeMilliseconds).sorted()
            summaries.append(CostSummary(
                variant: variant,
                medianGPU: gpuTimes[gpuTimes.count / 2],
                maximumGPU: gpuTimes[gpuTimes.count - 1],
                medianEncode: encodeTimes[encodeTimes.count / 2]
            ))
        }

        let report = summaries.map(\.description).joined(separator: "\n")
        print("Backdrop frame cost at \(Int(Self.recordedDrawableSize.width))×\(Int(Self.recordedDrawableSize.height)):\n\(report)")

        if let budgetText = ProcessInfo.processInfo.environment["LYRICSX_BACKDROP_GPU_BUDGET_MILLISECONDS"],
           let budget = Double(budgetText) {
            for summary in summaries {
                #expect(
                    summary.medianGPU <= budget,
                    "\(summary.variant.rawValue) spends \(summary.medianGPU) ms of GPU per frame, over the \(budget) ms budget"
                )
            }
        }
    }

    // MARK: Harness

    private static func measure(
        pipeline: any AppleMusicLyrics.ArtworkBackdropFramePipeline,
        artwork: MTLTexture,
        commandQueue: MTLCommandQueue,
        device: MTLDevice
    ) throws -> [FrameCost] {
        let textureState = AppleMusicLyrics.ArtworkBackdropTextureState(texture: artwork, averageLuminosity: 0.3)
        let output = try makeTexture(
            device: device,
            pixelFormat: pipeline.drawablePixelFormat,
            width: Int(recordedDrawableSize.width),
            height: Int(recordedDrawableSize.height)
        )
        var costs: [FrameCost] = []
        // One warm-up frame absorbs resource creation and pipeline compilation.
        for frameIndex in 0 ... sampledFrameCount {
            let context = AppleMusicLyrics.ArtworkBackdropFrameContext(
                sourceTextureState: textureState,
                destinationTextureState: textureState,
                transitionProgress: 1,
                animationTime: Double(frameIndex) / 60,
                drawableSize: recordedDrawableSize,
                backingScaleFactor: 2,
                isDarkAppearance: true
            )
            try #require(pipeline.prepareResources(for: context) != .failed)
            let renderPass = MTLRenderPassDescriptor()
            renderPass.colorAttachments[0].texture = output
            renderPass.colorAttachments[0].loadAction = .clear
            renderPass.colorAttachments[0].clearColor = pipeline.clearColor
            renderPass.colorAttachments[0].storeAction = .store

            let encodeStart = CACurrentMediaTime()
            let commandBuffer = try #require(commandQueue.makeCommandBuffer())
            try #require(pipeline.encodeOffscreenFrame(commandBuffer: commandBuffer, context: context))
            try #require(pipeline.encodeFinalFrame(
                commandBuffer: commandBuffer,
                renderPassDescriptor: renderPass,
                context: context
            ))
            commandBuffer.commit()
            let encodeMilliseconds = (CACurrentMediaTime() - encodeStart) * 1000
            commandBuffer.waitUntilCompleted()
            try #require(commandBuffer.status == .completed, "\(String(describing: commandBuffer.error))")
            guard frameIndex > 0 else { continue }
            costs.append(FrameCost(
                gpuMilliseconds: (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000,
                encodeMilliseconds: encodeMilliseconds
            ))
        }
        return costs
    }

    private static func makeShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderSource = try String(
            contentsOf: packageDirectory.appendingPathComponent("Sources/AppleMusicLyricsPanel/ArtworkGradientShaders.metal"),
            encoding: .utf8
        )
        return try device.makeLibrary(source: shaderSource, options: nil)
    }

    /// A cover-like texture: two colour fields with a soft diagonal boundary,
    /// so the blur and the grading have real gradients to chew on.
    private static func makeSyntheticArtwork(device: MTLDevice, dimension: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: dimension,
            height: dimension,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8](repeating: 255, count: dimension * dimension * 4)
        for verticalIndex in 0 ..< dimension {
            for horizontalIndex in 0 ..< dimension {
                let mix = Double(horizontalIndex + verticalIndex) / Double(2 * dimension)
                let offset = (verticalIndex * dimension + horizontalIndex) * 4
                bytes[offset] = UInt8(40 + 180 * mix)
                bytes[offset + 1] = UInt8(90 + 60 * (1 - mix))
                bytes[offset + 2] = UInt8(200 - 150 * mix)
            }
        }
        bytes.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, dimension, dimension),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: dimension * 4
            )
        }
        return texture
    }

    private static func makeTexture(device: MTLDevice, pixelFormat: MTLPixelFormat, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        return try #require(device.makeTexture(descriptor: descriptor))
    }
}
