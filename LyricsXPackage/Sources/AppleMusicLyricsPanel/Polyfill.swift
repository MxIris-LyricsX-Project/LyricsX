import Foundation

extension Task where Success == Never, Failure == Never {
    /// Back-deployable seconds-based sleep that mirrors the macOS 13+
    /// `Task.sleep(for:)` ergonomics while delegating to the older
    /// `Task.sleep(nanoseconds:)` so it works on macOS 11/12.
    static func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
    }
}
