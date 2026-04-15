import SwiftUI

@available(macOS 15, *)
extension AppleMusicLyrics {
    struct ProgressDotsView: View {
        var progress: Double // 0.0 ... 1.0

        @State private var isBreathing = false

        private let dotSize: CGFloat = 6
        private let dotSpacing: CGFloat = 8

        var body: some View {
            HStack(spacing: dotSpacing) {
                dot(activationThreshold: 0.33)
                dot(activationThreshold: 0.66)
                dot(activationThreshold: 0.90)
            }
            .onAppear {
                isBreathing = true
            }
        }

        @ViewBuilder
        private func dot(activationThreshold: Double) -> some View {
            let isActive = progress >= activationThreshold
            Circle()
                .fill(Color.white.opacity(isActive ? 0.8 : 0.3))
                .frame(width: dotSize, height: dotSize)
                .scaleEffect(isActive && isBreathing ? 1.25 : 1.0)
                .animation(
                    isActive
                        ? .smooth(duration: 1.5).repeatForever(autoreverses: true)
                        : .smooth(duration: 0.3),
                    value: isBreathing
                )
                .animation(.smooth(duration: 0.3), value: isActive)
        }
    }
}
