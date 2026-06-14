import Foundation

@available(macOS 15, *)
extension AppleMusicLyrics {
    /// Tracks whether the lyrics view auto-follows playback or has been
    /// "delegated" to the user (scrolled away), with a countdown back to
    /// following. Plain AppKit-friendly class (no SwiftUI/@Observable); UI
    /// refreshes via the `onChange` callback.
    final class InteractionStateModel {
        enum State: Equatable {
            case following
            case intermediate
            case countingDown
            case isolated
        }

        private(set) var state: State = .following {
            didSet { onChange?() }
        }

        var delegationProgress: Double = 0 {
            didSet { onChange?() }
        }

        /// Fired on any state / progress change.
        var onChange: (() -> Void)?

        var isFollowing: Bool {
            state == .following
        }

        var isDelegated: Bool {
            state != .following
        }

        private var intermediateTask: Task<Void, Never>?
        private var countdownTask: Task<Void, Never>?

        private let countDownDelay: TimeInterval = 1.0
        private let countDownDuration: TimeInterval = 3.0

        func userDidScroll() {
            guard state != .isolated else { return }
            cancelTimers()
            state = .intermediate
            delegationProgress = 0
            intermediateTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.countDownDelay ?? 1.0))
                guard !Task.isCancelled else { return }
                self?.startCountdown()
            }
        }

        func toggleIsolation() {
            cancelTimers()
            state = state == .isolated ? .following : .isolated
            delegationProgress = 0
        }

        func returnToFollowing() {
            cancelTimers()
            state = .following
            delegationProgress = 0
        }

        private func startCountdown() {
            state = .countingDown
            delegationProgress = 0
            countdownTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let steps = 60
                let stepDuration = self.countDownDuration / Double(steps)
                for step in 1 ... steps {
                    try? await Task.sleep(for: .seconds(stepDuration))
                    guard !Task.isCancelled else { return }
                    self.delegationProgress = Double(step) / Double(steps)
                }
                self.state = .following
                self.delegationProgress = 0
            }
        }

        private func cancelTimers() {
            intermediateTask?.cancel()
            intermediateTask = nil
            countdownTask?.cancel()
            countdownTask = nil
        }
    }
}
