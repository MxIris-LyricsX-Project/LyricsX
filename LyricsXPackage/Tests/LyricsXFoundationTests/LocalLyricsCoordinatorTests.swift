import Combine
import Foundation
import Testing
@testable import LyricsXFoundation

@Suite
struct LocalLyricsCoordinatorTests {
    @Test
    func activationResumesAWaitingRefreshOnceAndUsesANewTokenOnEveryReturn() throws {
        let coordinator = LocalLyricsCoordinator(
            embeddedTitle: "Embedded", lyricsXTitle: "LyricsX",
            readMetadata: { _, _, _ in .init(embeddedText: nil, location: .absent) },
            securityDirectory: { _ in nil }
        )
        let catalog = coordinator.catalog
        var refresh = LocalLyricsRefreshState()
        var refreshes = 0
        refresh.waitForActivation()
        let waitingGeneration = refresh.generation
        #expect(catalog.captureSession(for: "A") == nil)
        #expect(catalog.captureSession(for: "A") == nil)
        #expect(refresh.lastCompleted == nil)
        let subscription = coordinator.activations.sink { session in
            guard let session, refresh.receiveActivation(session.token) else { return }
            #expect(catalog.isActive(session))
            refreshes += 1
            _ = refresh.begin()
        }
        defer { subscription.cancel() }
        let first = try #require(coordinator.activate("A"))
        #expect(refreshes == 1)
        #expect(refresh.sessionToken == first.token)
        let acceptsWaiting = refresh.accept(.complete, generation: waitingGeneration)
        #expect(!acceptsWaiting)
        let duplicate = refresh.receiveActivation(first.token)
        #expect(!duplicate)
        #expect(catalog.captureSession(for: "A") == first)
        #expect(refreshes == 1)
        coordinator.activate("B")
        let second = try #require(coordinator.activate("A"))
        #expect(first.token != second.token)
        #expect(!catalog.isActive(first))
        #expect(catalog.isActive(second))
        #expect(refreshes == 3)
    }
    private func coordinator() -> LocalLyricsCoordinator {
        LocalLyricsCoordinator(
            embeddedTitle: "Embedded", lyricsXTitle: "LyricsX",
            readMetadata: { _, _, _ in .init(embeddedText: nil, location: .absent) },
            securityDirectory: { _ in nil }
        )
    }

    @Test
    func anImportBeforeActivationIsRetainedWithoutCreatingASession() throws {
        let owner = coordinator()
        let first = try #require(Lyrics("[00:01]First import"))
        let latest = try #require(Lyrics("[00:01]Latest import"))
        owner.deferImportUntilActivation(first, for: "A")
        owner.deferImportUntilActivation(latest, for: "A")
        #expect(owner.catalog.captureSession(for: "A") == nil)
        let session = try #require(owner.activate("A"))
        let imported = try #require(owner.takeDeferredImport(for: session))
        #expect(imported === latest)
        #expect(owner.catalog.rememberManagedLyrics(imported, session: session))
        #expect(owner.catalog.snapshot(for: session)?.managedLyrics === latest)
        #expect(owner.takeDeferredImport(for: session) == nil)
    }

    @Test
    func rejectionBeforeActivationDiscardsTheDeferredImport() throws {
        let owner = coordinator()
        owner.deferImportUntilActivation(try #require(Lyrics("[00:01]Import")), for: "A")
        owner.discardDeferredImport(for: "A")
        let session = try #require(owner.activate("A"))
        #expect(owner.takeDeferredImport(for: session) == nil)
        #expect(owner.catalog.snapshot(for: session)?.managedLyrics == nil)
    }

    @Test(arguments: [false, true])
    func leavingTheTrackDiscardsItsDeferredImport(stopped: Bool) throws {
        let owner = coordinator()
        owner.deferImportUntilActivation(try #require(Lyrics("[00:01]Import")), for: "A")
        owner.activate(stopped ? nil : "B")
        let session = try #require(owner.activate("A"))
        #expect(owner.takeDeferredImport(for: session) == nil)
    }

    @Test
    func aRetiredSessionCannotConsumeANewerDeferredImport() throws {
        let owner = coordinator()
        let old = try #require(owner.activate("A"))
        owner.activate("B")
        let imported = try #require(Lyrics("[00:01]New import"))
        owner.deferImportUntilActivation(imported, for: "A")
        #expect(owner.takeDeferredImport(for: old) == nil)
        let current = try #require(owner.activate("A"))
        #expect(owner.takeDeferredImport(for: current) === imported)
    }

}
