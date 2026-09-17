import CoreGraphics
import Foundation

extension AppleMusicLyrics {
    struct ArtworkGradientConfiguration: Sendable {
        let maximumArtworkDimension: Int
        let drawableScale: CGFloat
        let artworkTransitionDuration: TimeInterval
        let artworkAbsenceFallbackDelay: TimeInterval
        let baseMeshControlPointCount: Int
        let meshSubdivisionLevel: Int
        let meshVariant: Int?
        let blurSigmaFraction: Float
        let saturation: Float
        let blackScrimOpacity: Float
        let minimumColorComponent: Float
        let maximumColorComponent: Float
        let presentationSaturation: Float
        let presentationContrast: Float
        let presentationBrightness: Float

        init(
            maximumArtworkDimension: Int = 300,
            drawableScale: CGFloat = 1,
            artworkTransitionDuration: TimeInterval = 0.5,
            artworkAbsenceFallbackDelay: TimeInterval = 1.2,
            baseMeshControlPointCount: Int = 6,
            meshSubdivisionLevel: Int = 3,
            meshVariant: Int? = nil,
            blurSigmaFraction: Float = 0.045394707,
            saturation: Float = 2,
            blackScrimOpacity: Float = 0.25,
            minimumColorComponent: Float = 0.07,
            maximumColorComponent: Float = 0.97,
            presentationSaturation: Float = 0.6,
            presentationContrast: Float = 0.65,
            presentationBrightness: Float = 0.1
        ) {
            self.maximumArtworkDimension = maximumArtworkDimension
            self.drawableScale = drawableScale
            self.artworkTransitionDuration = artworkTransitionDuration
            self.artworkAbsenceFallbackDelay = artworkAbsenceFallbackDelay
            self.baseMeshControlPointCount = baseMeshControlPointCount
            self.meshSubdivisionLevel = meshSubdivisionLevel
            self.meshVariant = meshVariant
            self.blurSigmaFraction = blurSigmaFraction
            self.saturation = saturation
            self.blackScrimOpacity = blackScrimOpacity
            self.minimumColorComponent = minimumColorComponent
            self.maximumColorComponent = maximumColorComponent
            self.presentationSaturation = presentationSaturation
            self.presentationContrast = presentationContrast
            self.presentationBrightness = presentationBrightness
        }

        func drawablePixelSize(forNativeBackingSize nativeBackingSize: CGSize) -> CGSize {
            guard nativeBackingSize.width > 0,
                  nativeBackingSize.height > 0,
                  drawableScale > 0
            else {
                return CGSize(width: 1, height: 1)
            }

            return CGSize(
                width: max(1, (nativeBackingSize.width * drawableScale).rounded()),
                height: max(1, (nativeBackingSize.height * drawableScale).rounded())
            )
        }
    }

    struct ArtworkGradientRequestState {
        private(set) var currentTrackIdentity: String?
        private(set) var generation: UInt64 = 0
        private(set) var hasSubmittedArtwork = false
        private var hasReceivedTrackIdentity = false

        mutating func observeTrackIdentity(_ trackIdentity: String?) -> Bool {
            guard !hasReceivedTrackIdentity || trackIdentity != currentTrackIdentity else {
                return false
            }

            hasReceivedTrackIdentity = true
            currentTrackIdentity = trackIdentity
            hasSubmittedArtwork = false
            generation &+= 1
            return true
        }

        mutating func beginArtworkRequest() -> UInt64? {
            guard !hasSubmittedArtwork else { return nil }
            hasSubmittedArtwork = true
            generation &+= 1
            return generation
        }

        func acceptsResult(generation: UInt64) -> Bool {
            self.generation == generation
        }
    }

    enum ArtworkGradientRenderingPolicy {
        /// Music draws its Now Playing backdrop at 30 FPS, and the backdrop is a
        /// slow warp over a quarter-resolution canvas — doubling the rate buys no
        /// visible smoothness, it just re-runs the whole blur chain twice as often
        /// and blocks the main thread in `nextDrawable` against the compositor.
        /// The motion itself is wall-clock driven (`ArtworkGradientAnimationClock`
        /// plus `animationTimeScale`), so it runs at the same speed either way.
        static let backdropFramesPerSecond = 30

        static func preferredFramesPerSecond(
            screenMaximumFramesPerSecond: Int?
        ) -> Int {
            guard let screenMaximumFramesPerSecond,
                  screenMaximumFramesPerSecond > 0
            else {
                return backdropFramesPerSecond
            }

            return min(backdropFramesPerSecond, screenMaximumFramesPerSecond)
        }

        static func canRenderFrame(
            isPresentationVisible: Bool,
            isAttachedToWindow: Bool,
            isWindowVisible: Bool,
            isWindowOccluded: Bool,
            isViewHidden: Bool,
            isWindowDragging: Bool,
            isLiveResizing: Bool
        ) -> Bool {
            isPresentationVisible
                && isAttachedToWindow
                && isWindowVisible
                && !isWindowOccluded
                && !isViewHidden
                && !isWindowDragging
                && !isLiveResizing
        }

        static func shouldRenderContinuously(
            isPresentationVisible: Bool,
            isAttachedToWindow: Bool,
            isWindowVisible: Bool,
            isWindowOccluded: Bool,
            isViewHidden: Bool,
            isWindowDragging: Bool,
            isLiveResizing: Bool,
            shouldReduceMotion: Bool
        ) -> Bool {
            canRenderFrame(
                isPresentationVisible: isPresentationVisible,
                isAttachedToWindow: isAttachedToWindow,
                isWindowVisible: isWindowVisible,
                isWindowOccluded: isWindowOccluded,
                isViewHidden: isViewHidden,
                isWindowDragging: isWindowDragging,
                isLiveResizing: isLiveResizing
            ) && !shouldReduceMotion
        }
    }

    struct ArtworkGradientAnimationClock {
        private(set) var accumulatedElapsedTime: TimeInterval = 0
        private var resumeTimestamp: TimeInterval?

        mutating func setPaused(_ shouldPause: Bool, timestamp: TimeInterval) {
            if shouldPause {
                guard let resumeTimestamp else { return }
                accumulatedElapsedTime += max(0, timestamp - resumeTimestamp)
                self.resumeTimestamp = nil
            } else if resumeTimestamp == nil {
                resumeTimestamp = timestamp
            }
        }

        func elapsedTime(at timestamp: TimeInterval) -> TimeInterval {
            guard let resumeTimestamp else { return accumulatedElapsedTime }
            return accumulatedElapsedTime + max(0, timestamp - resumeTimestamp)
        }
    }
}
