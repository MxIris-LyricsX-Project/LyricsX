import Foundation
import Testing
@testable import LyricsXFoundation

@Suite
struct LocalLyricsRefreshStateTests {
    @Test
    func failedMusicVerificationInvalidatesAnAlreadyRunningRefresh() {
        var refresh = LocalLyricsRefreshState()
        let old = refresh.begin()
        refresh.invalidate()
        let replacement = refresh.begin()
        let acceptedOld = refresh.accept(.complete, generation: old)
        #expect(!acceptedOld)
        #expect(refresh.inFlight)
        #expect(refresh.lastCompleted == nil)
        let acceptedReplacement = refresh.accept(.complete, generation: replacement)
        #expect(acceptedReplacement)
        #expect(!refresh.inFlight)
    }
    @Test
    func cancelledRefreshStopsLoadingWithoutCachingAbsence() {
        var refresh = LocalLyricsRefreshState()
        let cancelled = refresh.begin()
        let accepted = refresh.accept(.cancelled, generation: cancelled)
        #expect(accepted)
        #expect(!refresh.inFlight)
        #expect(refresh.lastCompleted == nil)
        let stale = refresh.accept(.complete, generation: cancelled)
        #expect(!stale)
        let replacement = refresh.begin()
        #expect(refresh.inFlight)
        let completed = refresh.accept(.complete, generation: replacement)
        #expect(completed)
        #expect(refresh.lastCompleted != nil)
    }

    @Test
    func waitingForActivationDoesNotCacheAbsenceOrRestartTheWait() {
        var refresh = LocalLyricsRefreshState()
        refresh.waitForActivation()
        let waiting = refresh.generation
        refresh.waitForActivation()
        #expect(refresh.generation == waiting)
        #expect(refresh.phase == .waitingForActivation)
        #expect(refresh.lastCompleted == nil)
        #expect(refresh.inFlight)
        let token = UUID()
        let resumed = refresh.receiveActivation(token)
        #expect(resumed)
        #expect(refresh.phase == .idle)
        let lookup = refresh.begin()
        #expect(refresh.phase == .loading)
        let completed = refresh.accept(.complete, generation: lookup)
        #expect(completed)
        let duplicate = refresh.receiveActivation(token)
        #expect(!duplicate)
        #expect(refresh.phase == .idle)
        #expect(refresh.lastCompleted != nil)
    }

    @Test
    func staleCancellationCannotStopItsReplacement() {
        var refresh = LocalLyricsRefreshState()
        let old = refresh.begin()
        refresh.invalidate()
        let replacement = refresh.begin()
        let cancelled = refresh.accept(.cancelled, generation: old)
        #expect(!cancelled)
        #expect(refresh.phase == .loading)
        let completed = refresh.accept(.complete, generation: replacement)
        #expect(completed)
        #expect(refresh.phase == .idle)
    }

    @Test
    func aValidSessionResumesWaitingEvenWhenItsTokenHasNotChanged() {
        var refresh = LocalLyricsRefreshState()
        let token = UUID()
        refresh.receiveActivation(token)
        refresh.waitForActivation()
        let waiting = refresh.generation
        let resumed = refresh.receiveActivation(token)
        #expect(resumed)
        #expect(refresh.phase == .idle)
        #expect(!refresh.inFlight)
        #expect(refresh.generation != waiting)
        let generation = refresh.begin()
        let completed = refresh.accept(.complete, generation: generation)
        #expect(completed)
        #expect(refresh.lastCompleted != nil)
    }

}
