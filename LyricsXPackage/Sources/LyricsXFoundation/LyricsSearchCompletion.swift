import Foundation

/// How a lyrics search ended.
///
/// A search is cancelled when the track changes or the user rejects the
/// lyrics, and the steps that follow its last result — falling back to the
/// library, writing the lyrics into Music, reporting that nothing else was
/// found — are for a search that ran to its end. `AsyncThrowingStream` ends
/// normally rather than throwing when the task consuming it is cancelled, so
/// the end of the loop cannot tell the two apart. This can.
public enum LyricsSearchCompletion: Equatable, Sendable {
    case finished
    case cancelled

    /// Hands each result of `results` to `handleResult` as it arrives, and
    /// reports whether the search finished or was cancelled.
    @MainActor
    public static func consume<Element>(
        _ results: AsyncThrowingStream<Element, Error>,
        handleResult: (Element) throws -> Void
    ) async throws -> LyricsSearchCompletion {
        for try await result in results {
            // A result still buffered when the task was cancelled belongs to a
            // search nobody wants any more.
            if Task.isCancelled {
                return .cancelled
            }
            try handleResult(result)
        }
        return Task.isCancelled ? .cancelled : .finished
    }
}
