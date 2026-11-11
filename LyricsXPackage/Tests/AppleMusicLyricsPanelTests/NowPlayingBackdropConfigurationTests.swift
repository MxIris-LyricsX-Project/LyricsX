import CoreGraphics
import Foundation
import MetalKit
import simd
import Testing
@testable import AppleMusicLyricsPanel

struct NowPlayingBackdropConfigurationTests {
    @Test func defaultsMatchMusicsNowPlayingBackdrop() {
        let configuration = AppleMusicLyrics.NowPlayingBackdropConfiguration()

        #expect(configuration.artworkDimension == 128)
        #expect(configuration.canvasDownsampleShift == 2)
        #expect(configuration.artworkTransitionDuration == 0.8)
        #expect(configuration.animationTimeScale == 0.5)
        #expect(configuration.meshSubdivisionLevel == 2)
        #expect(configuration.warpTimingSpeed == 3.5)
        #expect(configuration.pinchMix == 1)
        #expect(configuration.whiteMix == 0.1)
        #expect(configuration.darken(isDarkAppearance: true) == 0.5)
        #expect(configuration.darken(isDarkAppearance: false) == 0.35)
    }

    @Test func environmentFollowsTheWindowOrientation() {
        let configuration = AppleMusicLyrics.NowPlayingBackdropConfiguration()
        let landscape = CGSize(width: 1176, height: 811)
        let portrait = CGSize(width: 600, height: 900)

        #expect(AppleMusicLyrics.NowPlayingBackdropConfiguration.isLandscape(drawableSize: landscape))
        #expect(!AppleMusicLyrics.NowPlayingBackdropConfiguration.isLandscape(drawableSize: portrait))
        #expect(configuration.environment(isLandscape: true) == .init(saturation: 2.4, blurRadiusPoints: 120))
        #expect(configuration.environment(isLandscape: false) == .init(saturation: 2.0, blurRadiusPoints: 85))
        #expect(configuration.meshSegmentCount(isLandscape: true) == 8)
        #expect(configuration.meshSegmentCount(isLandscape: false) == 5)

        let landscapeView = configuration.viewMatrix(drawableSize: landscape)
        #expect(landscapeView.columns.0 == SIMD4(1, 0, 0, 0))
        #expect(abs(landscapeView.columns.1.y - 1176 / 811) < 0.0001)
        let portraitView = configuration.viewMatrix(drawableSize: portrait)
        #expect(abs(portraitView.columns.0.x - 1.5) < 0.0001)
        #expect(portraitView.columns.1 == SIMD4(0, 1, 0, 0))
    }

    @Test func blurSigmaIsThePointRadiusOnTheQuarterCanvas() {
        let configuration = AppleMusicLyrics.NowPlayingBackdropConfiguration()

        // 120 pt × 2 (Retina) ÷ 4 (quarter canvas); Music's 0x25967FA34.
        #expect(configuration.blurSigma(isLandscape: true, backingScaleFactor: 2) == 60)
        #expect(configuration.blurSigma(isLandscape: false, backingScaleFactor: 1) == 21.25)
        #expect(configuration.canvasSize(drawableSize: CGSize(width: 2352, height: 1622)) == (588, 405))
    }

    @Test func rotationInstancesMatchMusicsThreeCopies() {
        let instances = AppleMusicLyrics.NowPlayingBackdropConfiguration().rotationInstances

        #expect(instances.count == 3)
        #expect(instances[0].modelMatrix == simd_float4x4(diagonal: SIMD4(1.4, 1.4, 1, 1)))
        #expect(instances[0].timeScale == 120)
        #expect(instances[0].rotationReferenceInstance == -1)
        #expect(instances[1].modelMatrix.columns.0 == SIMD4(0.7, 0, 0, 0))
        #expect(instances[1].modelMatrix.columns.3 == SIMD4(-0.25, 0.15, 0, 1))
        #expect(instances[1].timeScale == 70)
        #expect(instances[1].rotationReferenceInstance == -1)
        #expect(instances[2].modelMatrix.columns.1 == SIMD4(0, 0.7, 0, 0))
        #expect(instances[2].modelMatrix.columns.3 == SIMD4(0.7, 0.7, 0, 1))
        #expect(instances[2].timeScale == 90)
        #expect(instances[2].rotationReferenceInstance == 0)
    }

    @Test func crossfadeFollowsTheMediaCoreUITimingFunction() {
        let timingFunction = AppleMusicLyrics.NowPlayingBackdropConfiguration().artworkTransitionTimingFunction

        #expect(timingFunction == .init(firstControlPoint: SIMD2(0, 0), secondControlPoint: SIMD2(0.3, 1)))
        #expect(timingFunction.value(at: 0) == 0)
        #expect(timingFunction.value(at: 1) == 1)
        // Solving x(t) = 0.9(1 − t)t² + t³ = 0.5 by hand gives t ≈ 0.7174 and y ≈ 0.806.
        #expect(abs(timingFunction.value(at: 0.5) - 0.806) < 0.01)
        var previousValue: Float = 0
        for step in 1 ... 20 {
            let value = timingFunction.value(at: Float(step) / 20)
            #expect(value >= previousValue)
            previousValue = value
        }
    }

    @Test func backdropTimeRunsAtHalfWallClockSpeed() {
        let configuration = AppleMusicLyrics.NowPlayingBackdropConfiguration()

        #expect(configuration.backdropTime(animationTime: 10) == 5)
        #expect(configuration.meshProgress(backdropTime: 0) == 0.5)
        // sin peaks a quarter period in: time = 3.5 × π / 2.
        #expect(abs(configuration.meshProgress(backdropTime: 3.5 * .pi / 2) - 1) < 0.0001)
    }

    @Test func uniformsMatchTheMetalStructLayout() {
        #expect(MemoryLayout<AppleMusicLyrics.NowPlayingRotationInstanceUniforms>.stride == 80)
        #expect(MemoryLayout<AppleMusicLyrics.NowPlayingRotationInstanceUniforms>.offset(of: \.timeScale) == 64)
        #expect(
            MemoryLayout<AppleMusicLyrics.NowPlayingRotationInstanceUniforms>
                .offset(of: \.rotationReferenceInstance) == 68
        )
        #expect(MemoryLayout<AppleMusicLyrics.NowPlayingColorGradingUniforms>.stride == 32)
        #expect(MemoryLayout<AppleMusicLyrics.NowPlayingBackdropUniforms>.size == 384)
        #expect(MemoryLayout<AppleMusicLyrics.NowPlayingBackdropUniforms>.stride == 384)
        #expect(MemoryLayout<AppleMusicLyrics.NowPlayingBackdropUniforms>.offset(of: \.rotationInstances) == 64)
        #expect(MemoryLayout<AppleMusicLyrics.NowPlayingBackdropUniforms>.offset(of: \.time) == 304)
        #expect(MemoryLayout<AppleMusicLyrics.NowPlayingBackdropUniforms>.offset(of: \.darken) == 328)
        #expect(MemoryLayout<AppleMusicLyrics.NowPlayingBackdropUniforms>.offset(of: \.spectrum) == 336)
        #expect(MemoryLayout<AppleMusicLyrics.NowPlayingBackdropUniforms>.offset(of: \.colorGrading) == 352)
    }

    @Test func eightSegmentPresetsComeFromMediaCoreUI() throws {
        let surfaces = try #require(
            AppleMusicLyrics.ArtworkBackdropMeshPresets.controlPoints(segmentCount: 8, variant: 0)
        )

        #expect(surfaces.source.count == 81)
        #expect(surfaces.destination.count == 81)
        // Row 0 of variant 0's source is the unwarped grid Music typed by hand
        // (0.13 rather than 0.125); its destination row is pushed below the edge.
        #expect(surfaces.source[1] == SIMD2(0.13, 0))
        #expect(surfaces.source[10] == SIMD2(0.13, 0.13))
        #expect(surfaces.destination[0] == SIMD2(-0.2292, -0.0529))
        #expect(surfaces.destination[10] == SIMD2(0.0238, 0.1435))
        #expect(surfaces.destination[40] == SIMD2(0.4836, 0.5344))
        let fourthVariant = try #require(
            AppleMusicLyrics.ArtworkBackdropMeshPresets.controlPoints(segmentCount: 8, variant: 4)
        )
        #expect(fourthVariant.destination[70] == SIMD2(1, 1.0205))
        #expect(AppleMusicLyrics.ArtworkBackdropMeshPresets.controlPoints(segmentCount: 7, variant: 0) == nil)

        let topology = AppleMusicLyrics.ArtworkBackdropMeshTopology(
            baseControlPointCount: 9,
            subdivisionLevel: 2
        )
        #expect(topology.vertexCountPerDimension == 33)
        #expect(topology.vertexCount == 1_089)
        #expect(topology.indexCount == 6_144)
        let vertices = topology.makeVertices(
            sourceControlPoints: surfaces.source,
            destinationControlPoints: surfaces.destination
        )
        #expect(vertices.count == 1_089)
        // Corners stay fixed through subdivision and map to clip space as 2p − 1.
        let corner = try #require(vertices.first { $0.textureCoordinate == SIMD2(0, 0) })
        #expect(corner.clipSpacePosition == SIMD2(-1, -1))
        #expect(abs(corner.destinationClipSpacePosition.x - (2 * -0.2292 - 1)) < 0.0001)
    }

    @Test func fiveSegmentPresetsStillMatchTheMiniPlayerTables() {
        // The five-segment grid is shared between MediaCoreUI and TSLBackdropMetalView;
        // the earlier sparse table recorded these values from Music.i64.
        let firstVariant = AppleMusicLyrics.ArtworkBackdropMeshPresets.controlPoints(variant: 0)
        #expect(firstVariant.source[7] == SIMD2(-0.0933, 0.4))
        #expect(firstVariant.destination[10] == SIMD2(0.8587, 0.2234))
        let secondVariant = AppleMusicLyrics.ArtworkBackdropMeshPresets.controlPoints(segmentCount: 5, variant: 1)
        #expect(secondVariant?.source[7] == SIMD2(0.3265, 0.3839))
        #expect(secondVariant?.destination[7] == SIMD2(0.2437, 0.4392))
    }
}

struct ArtworkBackdropVariantTests {
    private func makeUserDefaults() throws -> UserDefaults {
        let suiteName = "com.JH.LyricsX.ArtworkBackdropVariantTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    @Test func nowPlayingBackdropIsTheDefault() throws {
        let userDefaults = try makeUserDefaults()

        #expect(AppleMusicLyrics.ArtworkBackdropVariant.resolve(from: userDefaults) == .mediaCoreUI26)
    }

    @Test func legacyBackdropIsSelectedByItsRawValue() throws {
        let userDefaults = try makeUserDefaults()
        userDefaults.set("legacyTSL", forKey: AppleMusicLyrics.ArtworkBackdropVariant.userDefaultsKey)

        #expect(AppleMusicLyrics.ArtworkBackdropVariant.resolve(from: userDefaults) == .legacyTSL)
    }

    @Test func unknownValuesFallBackToTheDefault() throws {
        let userDefaults = try makeUserDefaults()
        userDefaults.set("colorfulX", forKey: AppleMusicLyrics.ArtworkBackdropVariant.userDefaultsKey)

        #expect(AppleMusicLyrics.ArtworkBackdropVariant.resolve(from: userDefaults) == .mediaCoreUI26)
    }

    @Test func variantsPrepareArtworkTheWayTheirPipelineSamplesIt() {
        let nowPlaying = AppleMusicLyrics.ArtworkBackdropVariant.mediaCoreUI26
        let legacy = AppleMusicLyrics.ArtworkBackdropVariant.legacyTSL

        #expect(nowPlaying.maximumArtworkDimension == 128)
        #expect(legacy.maximumArtworkDimension == 300)
        #expect(nowPlaying.artworkTextureLoadingOptions[.SRGB] as? Bool == false)
        #expect(nowPlaying.artworkTextureLoadingOptions[.generateMipmaps] == nil)
        #expect(legacy.artworkTextureLoadingOptions[.SRGB] as? Bool == true)
        #expect(legacy.artworkTextureLoadingOptions[.generateMipmaps] as? Bool == true)
    }
}
