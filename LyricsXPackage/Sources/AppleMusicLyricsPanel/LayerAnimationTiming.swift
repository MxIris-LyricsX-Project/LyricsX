import Foundation
import QuartzCore

extension AppleMusicLyrics {
    /// How a `LayerPropertyAnimator` batch travels to its new values.
    ///
    /// Music's own animator takes either kind: almost everything rides a
    /// spring, but a pressed line fades its highlight in and out along fixed
    /// cubic curves (`sub_10019D630`), and the line filters run on one too.
    protocol LayerAnimationTiming {
        /// How long until the animation has finished, so follow-up work can be
        /// scheduled for when it has.
        var totalDuration: TimeInterval { get }

        /// A configured animation for `keyPath`; the caller fills in the values
        /// and the start time.
        func makePropertyAnimation(keyPath: String) -> CABasicAnimation
    }

    /// A fixed-duration animation along a cubic Bézier curve, given the way
    /// Music's disassembly gives it: a duration and the curve's two inner
    /// control points.
    struct CubicTimingParameters: LayerAnimationTiming {
        let duration: TimeInterval
        let controlPoint1: CGPoint
        let controlPoint2: CGPoint

        var totalDuration: TimeInterval {
            duration
        }

        var timingFunction: CAMediaTimingFunction {
            CAMediaTimingFunction(
                controlPoints: Float(controlPoint1.x),
                Float(controlPoint1.y),
                Float(controlPoint2.x),
                Float(controlPoint2.y)
            )
        }

        func makePropertyAnimation(keyPath: String) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.timingFunction = timingFunction
            return animation
        }
    }
}

extension AppleMusicLyrics.SpringTimingParameters: AppleMusicLyrics.LayerAnimationTiming {
    var totalDuration: TimeInterval {
        settlingDuration
    }

    func makePropertyAnimation(keyPath: String) -> CABasicAnimation {
        makeAnimation(keyPath: keyPath)
    }
}
