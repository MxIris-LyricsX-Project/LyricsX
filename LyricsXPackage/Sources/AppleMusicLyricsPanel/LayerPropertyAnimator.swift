import AppKit
import QuartzCore

extension AppleMusicLyrics {
    /// Apple Music's `LayerPropertyAnimator`, ported.
    ///
    /// You hand it some layers and a timing — a spring, or a cubic curve —
    /// register closures that mutate those layers however you like, then
    /// `run(afterDelay:)`. It snapshots the animatable properties before and
    /// after your closures, and emits one animation per property that actually
    /// changed.
    ///
    /// Why this shape rather than writing the animations by hand: the call sites
    /// get to say *what the layer should look like* (`frame = ...`,
    /// `affineTransform = ...`) instead of *which key paths to animate*, and the
    /// stagger falls out of `beginTime` — one scheduled animation per glyph,
    /// no timer and no per-frame work. That is the whole reason Music's ripple is
    /// smooth: after the batch is scheduled the CPU is done, and the render
    /// server interpolates every glyph on its own clock.
    ///
    /// Recovered from `sub_100162270` (init), `sub_100162B3C` (run) and the call
    /// sites in `sub_10018B2B4` / `sub_1001678FC` / `sub_100169874`.
    final class LayerPropertyAnimator {
        /// The properties Music's animator diffs, and the key paths they animate
        /// through. `frame` is not animatable itself — Core Animation expresses it
        /// as `position` plus `bounds`, and `affineTransform` as `transform`.
        private enum AnimatedProperty: CaseIterable {
            case position
            case bounds
            case transform
            case opacity
            case shadowOpacity
            case backgroundColor

            var keyPath: String {
                switch self {
                case .position: return "position"
                case .bounds: return "bounds"
                case .transform: return "transform"
                case .opacity: return "opacity"
                case .shadowOpacity: return "shadowOpacity"
                case .backgroundColor: return "backgroundColor"
                }
            }

            /// Animation key, so a re-run replaces the in-flight animation for the
            /// same property instead of stacking a second one on top of it.
            var animationKey: String {
                "AppleMusicLyrics.\(keyPath)"
            }
        }

        /// One layer's animatable state at a point in time.
        private struct Snapshot {
            let position: CGPoint
            let bounds: CGRect
            let transform: CATransform3D
            let opacity: Float
            let shadowOpacity: Float
            let backgroundColor: CGColor?

            init(of layer: CALayer) {
                self.position = layer.position
                self.bounds = layer.bounds
                self.transform = layer.transform
                self.opacity = layer.opacity
                self.shadowOpacity = layer.shadowOpacity
                self.backgroundColor = layer.backgroundColor
            }

            func value(for property: AnimatedProperty) -> Any? {
                switch property {
                case .position: return NSValue(point: position)
                case .bounds: return NSValue(rect: bounds)
                case .transform: return NSValue(caTransform3D: transform)
                case .opacity: return opacity
                case .shadowOpacity: return shadowOpacity
                case .backgroundColor: return backgroundColor
                }
            }

            func differs(from other: Snapshot, in property: AnimatedProperty) -> Bool {
                switch property {
                case .position: return position != other.position
                case .bounds: return bounds != other.bounds
                case .transform: return !CATransform3DEqualToTransform(transform, other.transform)
                case .opacity: return opacity != other.opacity
                case .shadowOpacity: return shadowOpacity != other.shadowOpacity
                case .backgroundColor:
                    guard let backgroundColor, let otherColor = other.backgroundColor else {
                        return (backgroundColor == nil) != (other.backgroundColor == nil)
                    }
                    return backgroundColor != otherColor
                }
            }
        }

        private let layers: [CALayer]
        private let timing: any LayerAnimationTiming
        private var changes: [() -> Void] = []
        private var completions: [() -> Void] = []

        init(layers: [CALayer], timing: any LayerAnimationTiming) {
            self.layers = layers
            self.timing = timing
        }

        func addChange(_ change: @escaping () -> Void) {
            changes.append(change)
        }

        func addCompletion(_ completion: @escaping () -> Void) {
            completions.append(completion)
        }

        /// Apply the registered changes and animate into them, starting `delay`
        /// from now.
        ///
        /// The changes themselves are applied with actions disabled, so the model
        /// tree jumps straight to its final state and the animation we add on top
        /// is the only thing anyone sees. `fillMode = .both` is what makes the
        /// stagger work: a glyph whose `beginTime` has not arrived yet keeps
        /// showing its *old* value rather than snapping to the new one.
        func run(afterDelay delay: TimeInterval = 0) {
            // What changed is decided from the model, which is what the closures
            // write; where it animates from is read off the screen. Animating from
            // the model would skip whatever a previous batch still has in flight,
            // since the model already holds that batch's destination. Diffing the
            // screen, though, would also pick up a property another animator set
            // a moment ago in this same turn — its animation is not committed yet,
            // so the screen still shows the old value — and replace that animation
            // with one on this timing. A pressed line runs two animators over the
            // same two layers, one for opacity and one for the transform
            // (`sub_10019D630`), so that is not hypothetical.
            let modelBefore = layers.map(Snapshot.init(of:))
            let visibleBefore = layers.map { Snapshot(of: $0.presentation() ?? $0) }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for change in changes {
                change()
            }
            CATransaction.commit()

            let after = layers.map(Snapshot.init(of:))
            let beginTime = CACurrentMediaTime() + delay

            for (index, layer) in layers.enumerated() {
                addAnimations(
                    to: layer,
                    changedFrom: modelBefore[index],
                    visibleFrom: visibleBefore[index],
                    to: after[index],
                    beginTime: beginTime
                )
            }

            scheduleCompletions(afterDelay: delay)
        }

        private func addAnimations(
            to layer: CALayer,
            changedFrom modelBefore: Snapshot,
            visibleFrom visibleBefore: Snapshot,
            to after: Snapshot,
            beginTime: CFTimeInterval
        ) {
            for property in AnimatedProperty.allCases where after.differs(from: modelBefore, in: property) {
                let animation = timing.makePropertyAnimation(keyPath: property.keyPath)
                animation.fromValue = visibleBefore.value(for: property)
                animation.toValue = after.value(for: property)
                animation.beginTime = beginTime
                animation.fillMode = .both
                animation.isRemovedOnCompletion = true
                animation.preferredFrameRateRange = LyricsSpecs.preferredFrameRateRange
                layer.add(animation, forKey: property.animationKey)
            }
        }

        private func scheduleCompletions(afterDelay delay: TimeInterval) {
            guard !completions.isEmpty else { return }
            let pending = completions
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + timing.totalDuration) {
                for completion in pending {
                    completion()
                }
            }
        }

        /// Drop every animation this type could have added, on every layer given.
        /// Used when a line is recycled mid-ripple, so the next song does not
        /// inherit half-finished springs.
        static func removeAllAnimations(from layer: CALayer) {
            for property in AnimatedProperty.allCases {
                layer.removeAnimation(forKey: property.animationKey)
            }
        }
    }
}
