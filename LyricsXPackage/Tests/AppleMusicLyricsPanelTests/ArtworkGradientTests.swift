import CoreGraphics
import Foundation
import MetalKit
import MetalPerformanceShaders
import Testing
@testable import AppleMusicLyricsPanel

struct ArtworkGradientConfigurationTests {
    @Test func defaultsKeepRenderingWorkBounded() {
        let configuration = AppleMusicLyrics.ArtworkGradientConfiguration()

        #expect(configuration.maximumArtworkDimension == 300)
        #expect(configuration.drawableScale == 1)
        #expect(configuration.artworkTransitionDuration == 0.5)
        #expect(configuration.baseMeshControlPointCount == 6)
        #expect(configuration.meshSubdivisionLevel == 3)
    }

    @Test func drawableSizeUsesTheFullNativeBackingSize() {
        let configuration = AppleMusicLyrics.ArtworkGradientConfiguration()

        let drawablePixelSize = configuration.drawablePixelSize(
            forNativeBackingSize: CGSize(width: 2000, height: 1200)
        )

        #expect(drawablePixelSize == CGSize(width: 2000, height: 1200))
    }

    @Test func drawableSizeNeverCreatesAZeroSizedMetalTexture() {
        let configuration = AppleMusicLyrics.ArtworkGradientConfiguration()

        let drawablePixelSize = configuration.drawablePixelSize(
            forNativeBackingSize: .zero
        )

        #expect(drawablePixelSize == CGSize(width: 1, height: 1))
    }

    @Test func meshTopologyMatchesTheAppleMusicShapedSubdivision() {
        let configuration = AppleMusicLyrics.ArtworkGradientConfiguration()
        let meshTopology = AppleMusicLyrics.ArtworkBackdropMeshTopology(
            baseControlPointCount: configuration.baseMeshControlPointCount,
            subdivisionLevel: configuration.meshSubdivisionLevel
        )

        #expect(meshTopology.vertexCountPerDimension == 41)
        #expect(meshTopology.vertexCount == 1_681)
        #expect(meshTopology.indexCount == 9_600)
    }

    @Test func meshSubdivisionRetainsAppleMusicControlSurfaceCurvature() throws {
        let meshTopology = AppleMusicLyrics.ArtworkBackdropMeshTopology(
            baseControlPointCount: 6,
            subdivisionLevel: 3
        )
        let vertices = meshTopology.makeVertices()
        let controlPoint = try #require(vertices.first { vertex in
            abs(vertex.textureCoordinate.x - 0.2) < 0.00001
                && abs(vertex.textureCoordinate.y - 0.2) < 0.00001
        })
        // Music's second preset after CAMeshTransform subdividedMesh:3.
        #expect(abs(controlPoint.clipSpacePosition.x - -0.48579174) < 0.00002)
        #expect(abs(controlPoint.clipSpacePosition.y - -0.43396914) < 0.00002)
    }

    @Test(arguments: [
        (0, SIMD2<Float>(0.2, 1), SIMD2<Float>(0.00656875, 1.14418435), SIMD2<Float>(0.00656875, 1.14418435)),
        (0, SIMD2<Float>(0.325, 0.475), SIMD2<Float>(-0.36648244, 0.09934746), SIMD2<Float>(-0.35348713, 0.20821613)),
        (1, SIMD2<Float>(0.775, 0.675), SIMD2<Float>(0.79725677, 0.38115561), SIMD2<Float>(0.80704927, 0.37944725)),
        (2, SIMD2<Float>(0.6, 0), SIMD2<Float>(0.45270625, -1.15425313), SIMD2<Float>(0.45270625, -1.15425313)),
        (4, SIMD2<Float>(0.2, 0.2), SIMD2<Float>(-0.62434840, -0.62834156), SIMD2<Float>(-0.66586816, -0.60243762)),
    ])
    func meshPresetsRetainTheirCurvedBoundariesAndDestinationSurfaces(
        meshVariant: Int,
        textureCoordinate: SIMD2<Float>,
        sourcePosition: SIMD2<Float>,
        destinationPosition: SIMD2<Float>
    ) throws {
        let vertices = AppleMusicLyrics.ArtworkBackdropMeshTopology(
            baseControlPointCount: 6,
            subdivisionLevel: 3
        ).makeVertices(meshVariant: meshVariant)
        let vertex = try #require(vertices.first { vertex in
            abs(vertex.textureCoordinate.x - textureCoordinate.x) < 0.00001
                && abs(vertex.textureCoordinate.y - textureCoordinate.y) < 0.00001
        })
        // Samples from Music's control tables refined by CAMeshTransform.
        #expect(abs(vertex.clipSpacePosition.x - sourcePosition.x) < 0.00002)
        #expect(abs(vertex.clipSpacePosition.y - sourcePosition.y) < 0.00002)
        #expect(abs(vertex.destinationClipSpacePosition.x - destinationPosition.x) < 0.00002)
        #expect(abs(vertex.destinationClipSpacePosition.y - destinationPosition.y) < 0.00002)
    }
}

struct ArtworkGradientRequestStateTests {
    @Test func artworkIsSubmittedOncePerTrackAndStaleResultsAreRejected() throws {
        var requestState = AppleMusicLyrics.ArtworkGradientRequestState()

        let observedFirstTrack = requestState.observeTrackIdentity("first-track")
        #expect(observedFirstTrack)
        let firstGenerationCandidate = requestState.beginArtworkRequest()
        let firstGeneration = try #require(firstGenerationCandidate)
        let repeatedGenerationCandidate = requestState.beginArtworkRequest()
        #expect(repeatedGenerationCandidate == nil)
        #expect(requestState.acceptsResult(generation: firstGeneration))

        let observedSecondTrack = requestState.observeTrackIdentity("second-track")
        #expect(observedSecondTrack)
        #expect(!requestState.acceptsResult(generation: firstGeneration))
        let secondGenerationCandidate = requestState.beginArtworkRequest()
        let secondGeneration = try #require(secondGenerationCandidate)

        #expect(secondGeneration > firstGeneration)
        #expect(requestState.acceptsResult(generation: secondGeneration))
    }

    @Test func repeatedTrackIdentityDoesNotInvalidateTheCurrentTexture() {
        var requestState = AppleMusicLyrics.ArtworkGradientRequestState()

        let observedInitialTrack = requestState.observeTrackIdentity("same-track")
        let observedRepeatedTrack = requestState.observeTrackIdentity("same-track")

        #expect(observedInitialTrack)
        #expect(!observedRepeatedTrack)
    }
}

struct ArtworkBackdropImageProcessorTests {
    @Test func artworkPreparationPreservesAspectRatioAndBoundsTheLongestEdge() throws {
        let coreGraphicsImage = try #require(Self.makeSplitColorArtworkImage())

        let preparedArtwork = try #require(
            AppleMusicLyrics.ArtworkBackdropImageProcessor.prepare(
                coreGraphicsImage,
                maximumDimension: 300
            )
        )

        #expect(preparedArtwork.image.width == 300)
        #expect(preparedArtwork.image.height == 150)
        #expect((0 ... 1).contains(preparedArtwork.averageLuminosity))
    }

    private static func makeSplitColorArtworkImage() -> CGImage? {
        let imageWidth = 320
        let imageHeight = 160
        let bytesPerPixel = 4
        let bytesPerRow = imageWidth * bytesPerPixel
        var pixelBytes = [UInt8](repeating: 0, count: bytesPerRow * imageHeight)

        for verticalPixelIndex in 0 ..< imageHeight {
            for horizontalPixelIndex in 0 ..< imageWidth {
                let pixelByteIndex = verticalPixelIndex * bytesPerRow
                    + horizontalPixelIndex * bytesPerPixel
                if horizontalPixelIndex < imageWidth / 2 {
                    pixelBytes[pixelByteIndex] = 230
                    pixelBytes[pixelByteIndex + 1] = 42
                    pixelBytes[pixelByteIndex + 2] = 58
                } else {
                    pixelBytes[pixelByteIndex] = 35
                    pixelBytes[pixelByteIndex + 1] = 78
                    pixelBytes[pixelByteIndex + 2] = 230
                }
                pixelBytes[pixelByteIndex + 3] = 255
            }
        }

        guard let dataProvider = CGDataProvider(data: Data(pixelBytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }
        return CGImage(
            width: imageWidth,
            height: imageHeight,
            bitsPerComponent: 8,
            bitsPerPixel: bytesPerPixel * 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big
                .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

struct ArtworkGradientRenderingPolicyTests {
    /// Music's own backdrop runs at 30 FPS. A faster screen must not pull the
    /// backdrop up with it — the blur chain is re-encoded every frame, so the
    /// rate is a cost, not a quality knob.
    @Test func frameRateMatchesMusicAndNeverExceedsTheScreen() {
        #expect(
            AppleMusicLyrics.ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: nil
            ) == 30
        )
        #expect(
            AppleMusicLyrics.ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: 0
            ) == 30
        )
        #expect(
            AppleMusicLyrics.ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: 60
            ) == 30
        )
        #expect(
            AppleMusicLyrics.ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: 120
            ) == 30
        )
        // A display slower than Music's rate still caps the backdrop: asking for
        // 30 on a 24 Hz screen only queues frames the compositor cannot show.
        #expect(
            AppleMusicLyrics.ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: 24
            ) == 24
        )
    }

    @Test func visibleStationaryWindowRendersContinuously() {
        let shouldRenderContinuously = AppleMusicLyrics.ArtworkGradientRenderingPolicy.shouldRenderContinuously(
            isPresentationVisible: true,
            isAttachedToWindow: true,
            isWindowVisible: true,
            isWindowOccluded: false,
            isViewHidden: false,
            isWindowDragging: false,
            isLiveResizing: false,
            shouldReduceMotion: false
        )

        #expect(shouldRenderContinuously)
    }

    @Test(arguments: [
        (false, true, true, false, false, false, false, false),
        (true, false, true, false, false, false, false, false),
        (true, true, false, false, false, false, false, false),
        (true, true, true, true, false, false, false, false),
        (true, true, true, false, true, false, false, false),
        (true, true, true, false, false, true, false, false),
        (true, true, true, false, false, false, true, false),
        (true, true, true, false, false, false, false, true),
    ])
    func unavailableOrMotionRestrictedStatesPauseContinuousRendering(
        isPresentationVisible: Bool,
        isAttachedToWindow: Bool,
        isWindowVisible: Bool,
        isWindowOccluded: Bool,
        isViewHidden: Bool,
        isWindowDragging: Bool,
        isLiveResizing: Bool,
        shouldReduceMotion: Bool
    ) {
        let shouldRenderContinuously = AppleMusicLyrics.ArtworkGradientRenderingPolicy.shouldRenderContinuously(
            isPresentationVisible: isPresentationVisible,
            isAttachedToWindow: isAttachedToWindow,
            isWindowVisible: isWindowVisible,
            isWindowOccluded: isWindowOccluded,
            isViewHidden: isViewHidden,
            isWindowDragging: isWindowDragging,
            isLiveResizing: isLiveResizing,
            shouldReduceMotion: shouldReduceMotion
        )

        #expect(!shouldRenderContinuously)
    }
}

struct ArtworkRenderingArchitectureTests {
    @Test
    func continuousRendererUsesMetalKitDisplayPacing() {
        let renderingViewType: Any.Type = AppleMusicLyrics.ArtworkGradientMetalView.self

        #expect(renderingViewType is MTKView.Type)
    }

    @Test
    func renderingProfilePrefersAppleMusicPixelFormatsAndBlurBehavior() {
        #expect(
            AppleMusicLyrics.ArtworkBackdropRenderingProfile.preferredDrawablePixelFormats
                == [.bgr10a2Unorm, .bgra8Unorm]
        )
        #expect(
            AppleMusicLyrics.ArtworkBackdropRenderingProfile.gaussianBlurOptions
                == [.allowReducedPrecision, .disableInternalTiling]
        )
        #expect(
            AppleMusicLyrics.ArtworkBackdropRenderingProfile.gaussianBlurEdgeMode
                == .zero
        )
    }
}

struct ArtworkGradientAnimationClockTests {
    @Test func pausedWallClockTimeDoesNotAdvanceTheGradient() {
        var animationClock = AppleMusicLyrics.ArtworkGradientAnimationClock()

        animationClock.setPaused(false, timestamp: 10)
        #expect(animationClock.elapsedTime(at: 12) == 2)
        animationClock.setPaused(true, timestamp: 12)
        #expect(animationClock.elapsedTime(at: 50) == 2)
        animationClock.setPaused(false, timestamp: 50)
        #expect(animationClock.elapsedTime(at: 51.5) == 3.5)
    }
}
