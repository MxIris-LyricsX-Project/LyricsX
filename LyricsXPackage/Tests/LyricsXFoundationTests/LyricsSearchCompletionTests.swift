import Testing
@testable import LyricsXFoundation

@Test @MainActor
func aSearchCancelledMidwayReportsThatItWasCancelled() async throws {
    let (results, resultContinuation) = AsyncThrowingStream<Int, Error>.makeStream()
    let (firstResultHandled, firstResultHandledContinuation) = AsyncStream<Void>.makeStream()

    let search = Task { @MainActor in
        try await LyricsSearchCompletion.consume(results) { _ in
            firstResultHandledContinuation.yield()
        }
    }
    resultContinuation.yield(1)
    for await _ in firstResultHandled {
        break
    }
    search.cancel()

    #expect(try await search.value == .cancelled)
}

@Test @MainActor
func aSearchThatRunsToItsEndReportsThatItFinished() async throws {
    let (results, resultContinuation) = AsyncThrowingStream<Int, Error>.makeStream()
    resultContinuation.yield(1)
    resultContinuation.yield(2)
    resultContinuation.finish()

    var handledResults: [Int] = []
    let completion = try await LyricsSearchCompletion.consume(results) { handledResults.append($0) }

    #expect(completion == .finished)
    #expect(handledResults == [1, 2])
}
