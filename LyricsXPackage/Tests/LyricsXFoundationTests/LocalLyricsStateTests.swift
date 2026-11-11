import Foundation
import Testing
@testable import LyricsXFoundation

private final class ReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private final class ObservedCondition: NSCondition, @unchecked Sendable {
    let waiting = DispatchSemaphore(value: 0)
    override func wait() { waiting.signal(); super.wait() }
}

private func metadata(_ text: String?) -> LocalLyricsState.Metadata {
    LocalLyricsState.Metadata(embeddedText: text, location: .failed)
}

@Suite
struct LocalLyricsStateTests {
    @Test
    func capturingASessionDoesNotDiscardItsRunningRead() throws {
        let state = LocalLyricsState()
        state.activate("old")
        state.activate("new") // Only the track coordinator activates.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = ReadResult()
        DispatchQueue.global().async {
            result.value = state.readMetadata(for: "new", mode: .coalesced, readerAvailable: true, session: state.captureSession(for: "new")!) { _, _, _ in
                entered.signal()
                release.wait()
                return metadata("new embedded")
            }?.embeddedText
            finished.signal()
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 5) == .success)
        _ = state.captureSession(for: "new") // Menu cannot activate a session.
        release.signal()
        try #require(finished.wait(timeout: .now() + 5) == .success)
        #expect(result.value == "new embedded")
        #expect(state.readMetadata(for: "new", mode: .coalesced, readerAvailable: true, session: state.captureSession(for: "new")!) { _, _, _ in
            Issue.record("The shared result should not require another Music read")
            return metadata(nil)
        }?.embeddedText == "new embedded")
    }

    @Test
    func returningToATrackDoesNotAcceptItsPreviousSessionsRead() throws {
        let state = LocalLyricsState()
        state.activate("song")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = ReadResult()
        DispatchQueue.global().async {
            result.value = state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: state.captureSession(for: "song")!) { _, _, _ in
                entered.signal(); release.wait(); return metadata("previous play")
            }?.embeddedText
            finished.signal()
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 5) == .success)
        state.activate("other")
        state.activate("song")
        #expect(state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: state.captureSession(for: "song")!) { _, _, _ in metadata("current play") }?.embeddedText == "current play")
        release.signal()
        try #require(finished.wait(timeout: .now() + 5) == .success)
        #expect(result.value == nil)
        #expect(state.snapshot(for: "song", session: state.captureSession(for: "song")!)?.embeddedText == "current play")
    }

    @Test
    func freshSelectionRetriesWhenAMusicWriteOvertakesItsRead() throws {
        let state = LocalLyricsState()
        state.activate("song")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = ReadResult()
        DispatchQueue.global().async {
            var reads = 0
            result.value = state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: state.captureSession(for: "song")!) { _, _, _ in
                reads += 1
                if reads == 1 { entered.signal(); release.wait(); return metadata("old") }
                return metadata("new")
            }?.embeddedText
            finished.signal()
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 5) == .success)
        let token = try #require(state.beginWrite(for: "song", session: state.captureSession(for: "song")!))
        #expect(state.finishWrite("new", for: "song", token: token))
        release.signal()
        try #require(finished.wait(timeout: .now() + 5) == .success)
        #expect(result.value == "new")
    }

    @Test
    func selectingEmbeddedWhileAWriteIsPendingWaitsForTheCurrentText() throws {
        let condition = ObservedCondition()
        let state = LocalLyricsState(condition: condition)
        state.activate("song")
        let token = try #require(state.beginWrite(for: "song", session: state.captureSession(for: "song")!))
        let finished = DispatchSemaphore(value: 0)
        let result = ReadResult()
        DispatchQueue.global().async {
            result.value = state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: state.captureSession(for: "song")!) { verified, _, _ in
                #expect(verified)
                return metadata("written")
            }?.embeddedText
            finished.signal()
        }
        try #require(condition.waiting.wait(timeout: .now() + 5) == .success)
        #expect(state.finishWrite("written", for: "song", token: token))
        try #require(finished.wait(timeout: .now() + 5) == .success)
        #expect(result.value == "written")
    }

    @Test
    func rejectingLyricsXRemovesTheOnlineResultAndSuppressesTheSavedFile() throws {
        let rejected = try #require(Lyrics("[00:01]Rejected"))
        let selected = try #require(Lyrics("[00:01]Selected"))
        let state = LocalLyricsState()
        state.activate("song")
        state.rememberManagedLyrics(rejected, for: "song", session: state.captureSession(for: "song")!)
        state.rejectLyricsX(for: "song", session: state.captureSession(for: "song")!)
        #expect(state.snapshot(for: "song", session: state.captureSession(for: "song")!)?.managedLyrics == nil)
        #expect(state.snapshot(for: "song", session: state.captureSession(for: "song")!)?.libraryRejected == true)
        state.rememberManagedLyrics(selected, for: "song", session: state.captureSession(for: "song")!)
        #expect(state.snapshot(for: "song", session: state.captureSession(for: "song")!)?.managedLyrics === selected)
        #expect(state.snapshot(for: "song", session: state.captureSession(for: "song")!)?.libraryRejected == false)
    }

    @Test
    func aFailedWriteWakesReadersAndAllowsAnotherMetadataRead() throws {
        let state = LocalLyricsState()
        state.activate("song")
        let token = try #require(state.beginWrite(for: "song", session: state.captureSession(for: "song")!))
        #expect(state.finishWrite(nil, for: "song", token: token))
        #expect(state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: state.captureSession(for: "song")!) { _, _, _ in metadata("still readable") }?.embeddedText == "still readable")
    }

    @Test
    func anOldWriteCannotCompleteAfterAnotherTrackHasStarted() throws {
        let state = LocalLyricsState()
        state.activate("old")
        let token = try #require(state.beginWrite(for: "old", session: state.captureSession(for: "old")!))
        state.activate("new")
        #expect(!state.finishWrite("old text", for: "old", token: token))
        #expect(state.snapshot(for: "new", session: state.captureSession(for: "new")!)?.embeddedText == nil)
    }

    @Test
    func retiredOverrideVerificationWaitsForItsTracksPendingWrite() throws {
        let condition = ObservedCondition()
        let state = LocalLyricsState(condition: condition)
        state.activate("old")
        let session = try #require(state.captureSession(for: "old"))
        state.activate("new")
        let write = try #require(state.beginWrite(for: "old", session: session, access: .verification))
        let result = ReadResult()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result.value = state.readMetadata(for: "old", mode: .fresh, readerAvailable: true, session: session, access: .verification) { verified, _, _ in
                #expect(verified)
                return LocalLyricsState.Metadata(embeddedText: "latest old-track text", location: .failed)
            }?.embeddedText
            finished.signal()
        }
        try #require(condition.waiting.wait(timeout: .now() + 5) == .success)
        #expect(!state.finishWrite("latest old-track text", for: "old", token: write))
        try #require(finished.wait(timeout: .now() + 5) == .success)
        #expect(result.value == "latest old-track text")
        #expect(state.snapshot(for: "new", session: state.captureSession(for: "new")!)?.embeddedText == nil)
    }

    @Test
    func aWriteInvalidatesMetadataBeforeAnOverrideDecisionCanUseIt() throws {
        let state = LocalLyricsState()
        state.activate("song")
        let session = try #require(state.captureSession(for: "song"))
        let old = try #require(state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: session, access: .verification) { _, _, _ in
            LocalLyricsState.Metadata(embeddedText: "old", location: .failed)
        })
        #expect(state.isCurrentMetadata(old, session: session))
        let write = try #require(state.beginWrite(for: "song", session: state.captureSession(for: "song")!))
        #expect(!state.isCurrentMetadata(old, session: session))
        state.finishWrite("new", for: "song", token: write)
        #expect(!state.isCurrentMetadata(old, session: session))
        let latest = try #require(state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: session, access: .verification) { _, _, _ in
            LocalLyricsState.Metadata(embeddedText: "new", location: .failed)
        })
        #expect(state.isCurrentMetadata(latest, session: session))
    }

    @Test
    func freshVerificationKeepsAKnownLocationWhenThePlayerCannotReadIt() throws {
        let state = LocalLyricsState()
        state.activate("song")
        let location = URL(fileURLWithPath: "/Music/Song.m4a")
        let session = try #require(state.captureSession(for: "song"))
        _ = state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: state.captureSession(for: "song")!) { _, _, _ in
            LocalLyricsState.Metadata(embeddedText: "old words", location: .available(location))
        }
        state.activate("next")
        let fresh = try #require(state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: session, access: .verification) { _, _, _ in
            LocalLyricsState.Metadata(embeddedText: "", location: .failed)
        })
        #expect(fresh.fileURL == location)
        #expect(fresh.embeddedText == "")
        #expect(state.isCurrentMetadata(fresh, session: session))
    }

    @Test
    func aSuccessfulMissingLocationClearsTheOldPath() throws {
        let state = LocalLyricsState()
        state.activate("song")
        let location = URL(fileURLWithPath: "/Music/Song.m4a")
        _ = state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: state.captureSession(for: "song")!) { _, _, _ in
            LocalLyricsState.Metadata(embeddedText: "", location: .available(location))
        }
        let missing = try #require(state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: state.captureSession(for: "song")!) { _, _, _ in
            LocalLyricsState.Metadata(embeddedText: "", location: .absent)
        })
        #expect(missing.fileURL == nil)
    }

    @Test
    func joiningAFreshReadSharesTheInFlightResult() throws {
        let condition = ObservedCondition()
        let state = LocalLyricsState(condition: condition)
        state.activate("song")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            _ = state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: state.captureSession(for: "song")!) { _, _, _ in
                entered.signal()
                release.wait()
                return metadata("shared")
            }
            done.leave()
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 5) == .success)
        done.enter()
        DispatchQueue.global().async {
            let result = state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: state.captureSession(for: "song")!) { _, _, _ in
                Issue.record("Joining a read must not issue another Music batch")
                return metadata("duplicate")
            }
            #expect(result?.embeddedText == "shared")
            done.leave()
        }
        try #require(condition.waiting.wait(timeout: .now() + 5) == .success)
        release.signal()
        try #require(done.wait(timeout: .now() + 5) == .success)
    }

    @Test
    func locationCallbackCannotSwitchToAnotherActivationOfTheSameTrack() throws {
        let state = LocalLyricsState()
        let first = try #require(state.activate("A"))
        var callbacks = 0
        let result = state.readMetadata(for: "A", mode: .fresh, readerAvailable: true, session: first,
                                        onLocation: { _ in callbacks += 1 }) { _, bound, report in
            #expect(bound.token == first.token)
            state.activate("B")
            let second = state.activate("A")!
            #expect(second.token != bound.token)
            report(.available(URL(fileURLWithPath: "/old/A.m4a")))
            return metadata("old A")
        }
        #expect(result == nil)
        #expect(callbacks == 0)
        #expect(state.snapshot(for: "A", session: state.captureSession(for: "A")!)?.fileURL == nil)
        #expect(state.snapshot(for: "A", session: state.captureSession(for: "A")!)?.embeddedText == nil)
        let stale = state.readMetadata(for: "A", mode: .fresh, readerAvailable: true, session: first) { _, _, _ in
            Issue.record("A stale captured token must never start its provider")
            return metadata("stale")
        }
        #expect(stale == nil)
    }

    @Test(arguments: [LyricsLocationRead.absent, .failed, .available(URL(fileURLWithPath: "/new/Song.m4a"))])
    func onlyFailedLocationReadsKeepTheKnownPath(outcome: LyricsLocationRead) throws {
        let state = LocalLyricsState()
        state.activate("song")
        let oldURL = URL(fileURLWithPath: "/old/Song.m4a")
        _ = state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: state.captureSession(for: "song")!) { _, _, _ in
            .init(embeddedText: "", location: .available(oldURL))
        }
        let result = try #require(state.readMetadata(for: "song", mode: .fresh, readerAvailable: true, session: state.captureSession(for: "song")!) { _, _, _ in
            .init(embeddedText: "", location: outcome)
        })
        switch outcome {
        case .absent: #expect(result.fileURL == nil)
        case .failed: #expect(result.fileURL == oldURL)
        case .available(let url): #expect(result.fileURL == url)
        }
    }
}
