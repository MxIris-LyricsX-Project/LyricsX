import Foundation
import QuartzCore

extension AppleMusicLyrics {
    /// A `CASpringAnimation` described the way Apple Music describes one.
    ///
    /// For its period-based curves, Music's `sub_1001662D4` derives coefficients
    /// from a **period** and a damping ratio:
    ///
    /// ```
    /// mass      = 1
    /// stiffness = mass * (2π / period)²
    /// damping   = dampingRatio * 2 * √(stiffness * mass)
    /// ```
    ///
    /// It then builds a throwaway `CASpringAnimation`, reads `settlingDuration`
    /// off it, and keeps that alongside the coefficients — which is what lets it
    /// schedule follow-up work for when the spring has come to rest. We do the
    /// same, so `settlingDuration` is Core Animation's own answer rather than an
    /// approximation of it.
    struct SpringTimingParameters {
        let mass: CGFloat
        let stiffness: CGFloat
        let damping: CGFloat
        let initialVelocity: CGFloat
        /// How long Core Animation thinks this spring takes to settle.
        let settlingDuration: TimeInterval

        init(dampingRatio: CGFloat, period: TimeInterval) {
            let mass: CGFloat = 1
            // A non-positive period would make the spring infinitely stiff; clamp
            // to something short rather than producing a NaN nobody can trace.
            let safePeriod = period > 0 ? period : 0.01
            let angularFrequency = 2 * CGFloat.pi / CGFloat(safePeriod)
            let stiffness = mass * angularFrequency * angularFrequency

            self.mass = mass
            self.stiffness = stiffness
            self.damping = dampingRatio * 2 * (stiffness * mass).squareRoot()
            self.initialVelocity = 0

            let probe = CASpringAnimation()
            probe.mass = mass
            probe.stiffness = stiffness
            probe.damping = damping
            self.settlingDuration = probe.settlingDuration
        }

        init(mass: CGFloat, stiffness: CGFloat, damping: CGFloat, initialVelocity: CGFloat = 0) {
            self.mass = mass
            self.stiffness = stiffness
            self.damping = damping
            self.initialVelocity = initialVelocity

            let probe = CASpringAnimation()
            probe.mass = mass
            probe.stiffness = stiffness
            probe.damping = damping
            probe.initialVelocity = initialVelocity
            self.settlingDuration = probe.settlingDuration
        }

        func makeAnimation(keyPath: String) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = mass
            animation.stiffness = stiffness
            animation.damping = damping
            animation.initialVelocity = initialVelocity
            animation.duration = settlingDuration
            return animation
        }
    }
}
