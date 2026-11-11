import CoreGraphics
import Foundation
import simd

extension AppleMusicLyrics {
    /// The parameters `MediaCoreUI.Backdrop.CompositeRenderer` runs with in
    /// Music 26.6's Now Playing full-window player, fixed to the "exciting"
    /// intensity the lyrics tab selects (`SpectrumAnalysis.intensity == 1`).
    ///
    /// Every default was read out of MediaCoreUI 26.6 (image base
    /// `0x25953e000`): the environment table at `0x25967A234`, the model
    /// matrices at `0x25967A4F8` / `0x259680AAC`, the blur sigma at
    /// `0x25967FA34`, the per-frame tick at `0x25967B980`, the texture loader
    /// at `0x25967FCB0`, and the shader IR of `rotation_*` / `pinch_*` /
    /// `blended_fragment` in the framework's `default.metallib`.
    struct NowPlayingBackdropConfiguration: Sendable {
        struct RotationInstance: Sendable, Equatable {
            let modelMatrix: simd_float4x4
            /// Seconds of backdrop time per full turn.
            let timeScale: Float
            /// Index of the instance whose angle also spins this instance's
            /// view basis around the canvas centre, or -1 to rotate in place.
            let rotationReferenceInstance: Int32
        }

        struct Environment: Sendable, Equatable {
            let saturation: Float
            /// Gaussian blur radius in points on the full drawable; the pipeline
            /// divides it by the canvas downsample before handing it to MPS.
            let blurRadiusPoints: Float
        }

        /// Analytic stand-in for Music's `BackdropLUT` asset, a 32³ colour cube
        /// that is identity on greys, greens, yellows, cyans and magentas and
        /// compresses saturated reds (1, 0, 0 → 0.694, 0.055, 0.059) and blues
        /// (0, 0, 1 → 0.035, 0.035, 0.710). The dominant channel loses
        /// `strength × chroma` while the hue stays within `plateauEnd` of pure
        /// red or blue, fading to nothing by `falloffEnd`; part of the loss spills
        /// into the other two channels and the secondary channel darkens most
        /// halfway between red and yellow (or blue and cyan/magenta). Against the
        /// real cube this reaches a maximum error of 0.040 and a mean of 0.0036.
        struct ColorGrading: Sendable, Equatable {
            var redStrength: Float = 0.306
            var redSpill: Float = 0.18
            var blueStrength: Float = 0.29
            var blueSpill: Float = 0.12
            var plateauEnd: Float = 0.26
            var falloffEnd: Float = 0.77
            var secondaryDarkening: Float = 0.3
            /// 1 applies the approximation, 0 leaves colours ungraded.
            var mix: Float = 1

            init() {}
        }

        /// Longest edge the cover is redrawn to before upload.
        let artworkDimension: Int
        /// The rotating canvas is the drawable shifted right by this many bits
        /// per axis: Music renders at a quarter of the drawable.
        let canvasDownsampleShift: Int
        let drawableScale: CGFloat
        let artworkTransitionDuration: TimeInterval
        let artworkTransitionTimingFunction: CubicBezierTimingFunction
        let artworkAbsenceFallbackDelay: TimeInterval
        /// Music adds 1/60 s of backdrop time per frame while drawing at 30 FPS,
        /// so its motion runs at half wall-clock speed. The panel keeps the
        /// display's own frame rate and scales wall-clock time instead.
        let animationTimeScale: Double
        let meshSubdivisionLevel: Int
        let meshVariant: Int?
        /// `warpTimingSpeed`: the mesh progress is `(sin(time / speed) + 1) / 2`.
        let warpTimingSpeed: Float
        /// 1 keeps the warped surface, 0 the unwarped one zoomed by 1.25.
        let pinchMix: Float
        let whiteMix: Float
        let darkAppearanceDarken: Float
        let lightAppearanceDarken: Float
        let colorGrading: ColorGrading
        let rotationInstances: [RotationInstance]
        let landscapeEnvironment: Environment
        let portraitEnvironment: Environment
        let landscapeMeshSegmentCount: Int
        let portraitMeshSegmentCount: Int
        /// Music paints `systemGray` while no artwork is available.
        let fallbackArtworkColor: SIMD3<Float>

        init(
            artworkDimension: Int = 128,
            canvasDownsampleShift: Int = 2,
            drawableScale: CGFloat = 1,
            artworkTransitionDuration: TimeInterval = 0.8,
            artworkTransitionTimingFunction: CubicBezierTimingFunction = CubicBezierTimingFunction(
                firstControlPoint: SIMD2(0, 0),
                secondControlPoint: SIMD2(0.3, 1)
            ),
            artworkAbsenceFallbackDelay: TimeInterval = 1.2,
            animationTimeScale: Double = 0.5,
            meshSubdivisionLevel: Int = 2,
            meshVariant: Int? = nil,
            warpTimingSpeed: Float = 3.5,
            pinchMix: Float = 1,
            whiteMix: Float = 0.1,
            darkAppearanceDarken: Float = 0.5,
            lightAppearanceDarken: Float = 0.35,
            colorGrading: ColorGrading = ColorGrading(),
            rotationInstances: [RotationInstance] = NowPlayingBackdropConfiguration.musicRotationInstances,
            landscapeEnvironment: Environment = Environment(saturation: 2.4, blurRadiusPoints: 120),
            portraitEnvironment: Environment = Environment(saturation: 2.0, blurRadiusPoints: 85),
            landscapeMeshSegmentCount: Int = 8,
            portraitMeshSegmentCount: Int = 5,
            fallbackArtworkColor: SIMD3<Float> = SIMD3(152, 152, 157) / 255
        ) {
            self.artworkDimension = artworkDimension
            self.canvasDownsampleShift = canvasDownsampleShift
            self.drawableScale = drawableScale
            self.artworkTransitionDuration = artworkTransitionDuration
            self.artworkTransitionTimingFunction = artworkTransitionTimingFunction
            self.artworkAbsenceFallbackDelay = artworkAbsenceFallbackDelay
            self.animationTimeScale = animationTimeScale
            self.meshSubdivisionLevel = meshSubdivisionLevel
            self.meshVariant = meshVariant
            self.warpTimingSpeed = warpTimingSpeed
            self.pinchMix = pinchMix
            self.whiteMix = whiteMix
            self.darkAppearanceDarken = darkAppearanceDarken
            self.lightAppearanceDarken = lightAppearanceDarken
            self.colorGrading = colorGrading
            self.rotationInstances = rotationInstances
            self.landscapeEnvironment = landscapeEnvironment
            self.portraitEnvironment = portraitEnvironment
            self.landscapeMeshSegmentCount = landscapeMeshSegmentCount
            self.portraitMeshSegmentCount = portraitMeshSegmentCount
            self.fallbackArtworkColor = fallbackArtworkColor
        }

        /// Music's three artwork copies: a 1.4× copy turning every 120 s of
        /// backdrop time, a 0.7× copy offset to the upper left turning every
        /// 70 s, and a 0.7× copy in the upper right turning every 90 s whose
        /// view basis also follows the first copy's angle.
        static let musicRotationInstances: [RotationInstance] = [
            RotationInstance(
                modelMatrix: simd_float4x4(diagonal: SIMD4(1.4, 1.4, 1, 1)),
                timeScale: 120,
                rotationReferenceInstance: -1
            ),
            RotationInstance(
                modelMatrix: translationScaleMatrix(translation: SIMD2(-0.25, 0.15), scale: 0.7),
                timeScale: 70,
                rotationReferenceInstance: -1
            ),
            RotationInstance(
                modelMatrix: translationScaleMatrix(translation: SIMD2(0.7, 0.7), scale: 0.7),
                timeScale: 90,
                rotationReferenceInstance: 0
            ),
        ]

        static func isLandscape(drawableSize: CGSize) -> Bool {
            drawableSize.width >= drawableSize.height
        }

        func environment(isLandscape: Bool) -> Environment {
            isLandscape ? landscapeEnvironment : portraitEnvironment
        }

        func meshSegmentCount(isLandscape: Bool) -> Int {
            isLandscape ? landscapeMeshSegmentCount : portraitMeshSegmentCount
        }

        func darken(isDarkAppearance: Bool) -> Float {
            isDarkAppearance ? darkAppearanceDarken : lightAppearanceDarken
        }

        /// Keeps each artwork copy square: landscape stretches y by width /
        /// height, portrait stretches x by height / width.
        func viewMatrix(drawableSize: CGSize) -> simd_float4x4 {
            let width = Float(max(1, drawableSize.width))
            let height = Float(max(1, drawableSize.height))
            if Self.isLandscape(drawableSize: drawableSize) {
                return simd_float4x4(diagonal: SIMD4(1, width / height, 1, 1))
            }
            return simd_float4x4(diagonal: SIMD4(height / width, 1, 1, 1))
        }

        func backdropTime(animationTime: TimeInterval) -> Float {
            Float(animationTime * animationTimeScale)
        }

        func meshProgress(backdropTime: Float) -> Float {
            (sin(backdropTime / warpTimingSpeed) + 1) / 2
        }

        func canvasSize(drawableSize: CGSize) -> (width: Int, height: Int) {
            let drawableWidth = max(1, Int(drawableSize.width.rounded()))
            let drawableHeight = max(1, Int(drawableSize.height.rounded()))
            return (
                max(1, drawableWidth >> canvasDownsampleShift),
                max(1, drawableHeight >> canvasDownsampleShift)
            )
        }

        /// `MPSImageGaussianBlur` sigma on the downsampled canvas:
        /// `blurRadiusPoints × backingScale / canvasDownsample`.
        func blurSigma(isLandscape: Bool, backingScaleFactor: CGFloat) -> Float {
            environment(isLandscape: isLandscape).blurRadiusPoints
                * Float(max(1, backingScaleFactor))
                / Float(1 << canvasDownsampleShift)
        }

        func drawablePixelSize(forNativeBackingSize nativeBackingSize: CGSize) -> CGSize {
            ArtworkBackdropDrawableSizing.pixelSize(
                forNativeBackingSize: nativeBackingSize,
                scale: drawableScale
            )
        }

        private static func translationScaleMatrix(
            translation: SIMD2<Float>,
            scale: Float
        ) -> simd_float4x4 {
            simd_float4x4(
                SIMD4(scale, 0, 0, 0),
                SIMD4(0, scale, 0, 0),
                SIMD4(0, 0, 1, 0),
                SIMD4(translation.x, translation.y, 0, 1)
            )
        }
    }

    /// A `CAMediaTimingFunction`-style cubic Bézier from (0, 0) to (1, 1),
    /// evaluated by solving the horizontal component for the curve parameter.
    struct CubicBezierTimingFunction: Sendable, Equatable {
        let firstControlPoint: SIMD2<Float>
        let secondControlPoint: SIMD2<Float>

        func value(at progress: Float) -> Float {
            let target = min(1, max(0, progress))
            guard target > 0 else { return 0 }
            guard target < 1 else { return 1 }

            var parameter = target
            for _ in 0 ..< 8 {
                let horizontalError = coordinate(
                    firstControlPoint.x,
                    secondControlPoint.x,
                    parameter
                ) - target
                guard abs(horizontalError) > 0.000001 else { break }
                let slope = derivative(firstControlPoint.x, secondControlPoint.x, parameter)
                guard abs(slope) > 0.000001 else { break }
                parameter = min(1, max(0, parameter - horizontalError / slope))
            }

            let remainingError = coordinate(firstControlPoint.x, secondControlPoint.x, parameter) - target
            if abs(remainingError) > 0.0001 {
                var lowerBound: Float = 0
                var upperBound: Float = 1
                for _ in 0 ..< 32 {
                    parameter = (lowerBound + upperBound) / 2
                    if coordinate(firstControlPoint.x, secondControlPoint.x, parameter) < target {
                        lowerBound = parameter
                    } else {
                        upperBound = parameter
                    }
                }
            }
            return coordinate(firstControlPoint.y, secondControlPoint.y, parameter)
        }

        private func coordinate(
            _ firstControl: Float,
            _ secondControl: Float,
            _ parameter: Float
        ) -> Float {
            let remainder = 1 - parameter
            return 3 * remainder * remainder * parameter * firstControl
                + 3 * remainder * parameter * parameter * secondControl
                + parameter * parameter * parameter
        }

        private func derivative(
            _ firstControl: Float,
            _ secondControl: Float,
            _ parameter: Float
        ) -> Float {
            let remainder = 1 - parameter
            return 3 * remainder * remainder * firstControl
                + 6 * remainder * parameter * (secondControl - firstControl)
                + 3 * parameter * parameter * (1 - secondControl)
        }
    }
}
