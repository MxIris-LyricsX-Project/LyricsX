import Foundation
import MusicPlayer
import Testing
@testable import LyricsXFoundation

// These concurrent fixtures use immutable tracks and semaphore-only providers.
private final class ConcurrentCatalog: @unchecked Sendable {
    let catalog: LocalLyricsCatalog
    let track: MusicTrack
    init(_ catalog: LocalLyricsCatalog, track: MusicTrack) { self.catalog = catalog; self.track = track }
}

@Suite
struct LocalLyricsCatalogTests {
    private func track(_ id: String = "song", fileURL: URL? = nil, hasScript: Bool = true) -> MusicTrack {
        MusicTrack(id: id, title: "Song", album: nil, artist: "Artist", fileURL: fileURL,
                   originalTrack: hasScript ? NSObject() : nil)
    }

    private func catalog(text: String? = "old") -> LocalLyricsCatalog {
        LocalLyricsCatalog(
            embeddedTitle: "Embedded test title", lyricsXTitle: "Managed test title",
            readMetadata: { track, _, _ in LocalLyricsState.Metadata(embeddedText: text, location: track.fileURL.map(LyricsLocationRead.available) ?? .absent) },
            securityDirectory: { _ in nil }
        )
    }
    @Test
    func aRefreshDeliveredAfterAMusicWriteUsesCurrentText() throws {
        let catalog = catalog()
        let track = track()
        let session = catalog.state.activate(track.id)!
        var results: [[LocalLyricsChoice]] = []
        catalog.discoverChoices(for: track, session: session, libraryFiles: { _ in [] }) { choices, _ in results.append(catalog.reconcile(choices, for: track, session: session)) }
        let old = try #require(results.last)
        #expect(old.first { $0.source == .embedded }?.embeddedContents == "old")
        let token = try #require(catalog.state.beginWrite(for: track.id, session: catalog.state.captureSession(for: track.id)!))
        catalog.state.finishWrite("new", for: track.id, token: token)
        let delivered = catalog.reconcile(old, for: track, session: session)
        #expect(delivered.first { $0.source == .embedded }?.embeddedContents == "new")
    }
    @Test(arguments: [LocalLyricsSource.embedded, .file(URL(fileURLWithPath: "/Music/Song.lrc"))])
    func rejectingAUsersSourcePreservesTheLyricsXOption(source: LocalLyricsSource) throws {
        let catalog = catalog()
        let track = track()
        let online = try #require(Lyrics("[00:01]Online"))
        let session = catalog.state.activate(track.id)!
        catalog.state.rememberManagedLyrics(online, for: track.id, session: catalog.state.captureSession(for: track.id)!)
        catalog.reject(source, session: session)
        #expect(catalog.reconcile([], for: track, session: session).first { $0.source == .lyricsX }?.memoryLyrics === online)
        #expect(catalog.state.snapshot(for: track.id, session: catalog.state.captureSession(for: track.id)!)?.libraryRejected == false)
    }
    @Test
    func rejectingASavedLibraryOptionDoesNotHideItAfterRejectingEmbedded() {
        let catalog = catalog()
        let track = track()
        let session = catalog.state.activate(track.id)!
        let saved = LocalLyricsChoice(sessionToken: session.token, track: track, source: .lyricsX, title: "LyricsX",
                                      lyricsXFileURL: URL(fileURLWithPath: "/LyricsX/Song.lrcx"))
        catalog.reject(.embedded, session: session)
        #expect(catalog.reconcile([saved], for: track, session: session).count == 1)
        catalog.reject(.lyricsX, session: session)
        #expect(catalog.reconcile([saved], for: track, session: session).isEmpty)
    }
    @Test
    func rejectingLyricsXAlsoRemovesAnOldMemoryOption() throws {
        let catalog = catalog()
        let track = track()
        let session = catalog.state.activate(track.id)!
        let online = try #require(Lyrics("[00:01]Online"))
        catalog.state.rememberManagedLyrics(online, for: track.id, session: catalog.state.captureSession(for: track.id)!)
        let old = catalog.reconcile([], for: track, session: session)
        catalog.reject(.lyricsX, session: session)
        #expect(catalog.reconcile(old, for: track, session: session).isEmpty)
        #expect(catalog.state.snapshot(for: track.id, session: catalog.state.captureSession(for: track.id)!)?.managedLyrics == nil)
    }
    @Test
    func noLocationDoesNotProduceADuplicatePartialResult() {
        let catalog = catalog()
        let track = track()
        let session = catalog.state.activate(track.id)!
        var partials = 0
        var finals = 0
        catalog.discoverChoices(for: track, session: session, libraryFiles: { _ in [] }) { _, stage in
            if stage == .cached { partials += 1 } else { finals += 1 }
        }
        #expect(partials == 1)
        #expect(finals == 1)
    }
    @Test
    func discoveryListsBothAdjacentExtensionsAndOnlyOneLyricsXOption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let music = directory.appendingPathComponent("Song.m4a")
        for ext in ["lrc", "lrcx"] {
            try "lyrics".write(to: music.deletingPathExtension().appendingPathExtension(ext), atomically: true, encoding: .utf8)
        }
        let catalog = catalog()
        let track = track(fileURL: music)
        let session = catalog.state.activate(track.id)!
        let online = try #require(Lyrics("[00:01]Online"))
        catalog.state.rememberManagedLyrics(online, for: track.id, session: catalog.state.captureSession(for: track.id)!)
        var final: [LocalLyricsChoice] = []
        catalog.discoverChoices(for: track, session: session, libraryFiles: { _ in
            Issue.record("The online slot should bypass the saved-library lookup")
            return []
        }) { choices, stage in if stage == .complete { final = catalog.reconcile(choices, for: track, session: session) } }
        #expect(final.count == 4)
        #expect(final.filter { $0.source == .lyricsX }.count == 1)
        #expect(final.first { $0.source == .lyricsX }?.memoryLyrics === online)
    }
    @Test
    func importingAfterRejectionRestoresTheManagedSlot() throws {
        let catalog = catalog()
        let track = track()
        let session = catalog.state.activate(track.id)!
        catalog.reject(.lyricsX, session: session)
        let imported = try #require(Lyrics("[00:01]Imported lyrics"))
        #expect(imported.metadata.request == nil && imported.metadata.service == nil)
        catalog.state.rememberManagedLyrics(imported, for: track.id, session: catalog.state.captureSession(for: track.id)!)
        let choices = catalog.reconcile([], for: track, session: session)
        #expect(catalog.state.snapshot(for: track.id, session: catalog.state.captureSession(for: track.id)!)?.libraryRejected == false)
        #expect(choices.count == 1)
        #expect(choices.first?.source == .lyricsX)
        #expect(choices.first?.memoryLyrics === imported)
    }
    @Test
    func embeddedUsesTheTitleProvidedByTheApp() {
        let catalog = catalog()
        let track = track()
        let session = catalog.state.activate(track.id)!
        _ = catalog.metadata(for: track, read: .fresh, session: session)
        #expect(catalog.reconcile([], for: track, session: session).first?.title == "Embedded test title")
    }
    @Test
    func managedOptionUsesTheTitleProvidedByTheApp() throws {
        let catalog = catalog()
        let track = track()
        let session = catalog.state.activate(track.id)!
        catalog.state.rememberManagedLyrics(try #require(Lyrics("[00:01]Imported")), for: track.id, session: catalog.state.captureSession(for: track.id)!)
        #expect(catalog.reconcile([], for: track, session: session).first?.title == "Managed test title")
    }
    @Test(arguments: [false, true])
    func aTrackWithoutScriptingMetadataNeverCallsTheMusicReader(hasURL: Bool) {
        let catalog = LocalLyricsCatalog(
            embeddedTitle: "Embedded", lyricsXTitle: "LyricsX",
            readMetadata: { _, _, _ in
                Issue.record("No scripting metadata is available")
                return LocalLyricsState.Metadata(embeddedText: nil, location: .absent)
            }, securityDirectory: { _ in nil }
        )
        let url = hasURL ? URL(fileURLWithPath: "/Music/Song.m4a") : nil
        let track = track(fileURL: url, hasScript: false)
        let session = catalog.state.activate(track.id)!
        catalog.discoverChoices(for: track, session: session, libraryFiles: { _ in [] }) { _, _ in }
        #expect(catalog.metadata(for: track, read: .fresh, session: session)?.embeddedText == nil)
        #expect(catalog.state.snapshot(for: track.id, session: catalog.state.captureSession(for: track.id)!)?.fileURL == url)
    }
    @Test
    func embeddedAndLocationAreLoadedAsOneSharedMetadataBatch() {
        var reads = 0
        let location = URL(fileURLWithPath: "/Music/Song.m4a")
        let catalog = LocalLyricsCatalog(
            embeddedTitle: "Embedded", lyricsXTitle: "LyricsX",
            readMetadata: { _, _, _ in
                reads += 1
                return LocalLyricsState.Metadata(embeddedText: "words", location: .available(location))
            }, securityDirectory: { _ in nil }
        )
        let track = track()
        let session = catalog.state.activate(track.id)!
        let first = catalog.metadata(for: track, read: .coalesced, session: session)
        let second = catalog.metadata(for: track, read: .coalesced, session: session)
        #expect(first?.embeddedText == "words" && first?.fileURL == location)
        #expect(second?.fileURL == location)
        catalog.discoverChoices(for: track, session: session, libraryFiles: { _ in [] }) { _, _ in }
        #expect(reads == 2)
    }
    @Test
    func menuFileResultsDoNotWaitForTheLyricsPartOfARunningBatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Song.m4a")
        let lyricsURL = directory.appendingPathComponent("Song.lrc")
        try "[00:01]words".write(to: lyricsURL, atomically: true, encoding: .utf8)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseLocation = DispatchSemaphore(value: 0)
        let cachedPublished = DispatchSemaphore(value: 0)
        let releaseLyrics = DispatchSemaphore(value: 0)
        let filesPublished = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        let catalog = LocalLyricsCatalog(
            embeddedTitle: "Embedded", lyricsXTitle: "LyricsX",
            readMetadata: { _, _, reportLocation in
                readStarted.signal()
                #expect(releaseLocation.wait(timeout: .now() + 5) == .success)
                reportLocation(.available(location))
                #expect(releaseLyrics.wait(timeout: .now() + 5) == .success)
                return LocalLyricsState.Metadata(embeddedText: "words", location: .available(location))
            }, securityDirectory: { _ in nil }
        )
        let fixture = ConcurrentCatalog(catalog, track: track())
        let session = catalog.state.activate(fixture.track.id)!
        completed.enter()
        DispatchQueue.global().async {
            _ = fixture.catalog.metadata(for: fixture.track, read: .coalesced, session: session)
            completed.leave()
        }
        defer { releaseLocation.signal(); releaseLyrics.signal() }
        try #require(readStarted.wait(timeout: .now() + 5) == .success)
        completed.enter()
        DispatchQueue.global().async {
            fixture.catalog.discoverChoices(for: fixture.track, session: session, libraryFiles: { _ in [] }) { choices, stage in
                if stage == .cached { cachedPublished.signal() }
                if stage == .location, choices.contains(where: { $0.source == .file(lyricsURL) }) { filesPublished.signal() }
            }
            completed.leave()
        }
        try #require(cachedPublished.wait(timeout: .now() + 5) == .success)
        releaseLocation.signal()
        try #require(filesPublished.wait(timeout: .now() + 5) == .success)
        releaseLyrics.signal()
        try #require(completed.wait(timeout: .now() + 5) == .success)
    }

    @Test
    func refreshingTheSameTrackReplacesMovedOrMissingSiblingChoices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let x = directory.appendingPathComponent("X/Song.m4a")
        let y = directory.appendingPathComponent("Y/Song.m4a")
        for url in [x, y] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "words".write(to: url.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
        }
        var currentURL: URL? = x
        let catalog = LocalLyricsCatalog(
            embeddedTitle: "Embedded", lyricsXTitle: "LyricsX",
            readMetadata: { _, _, report in
                report(currentURL.map(LyricsLocationRead.available) ?? .absent)
                return LocalLyricsState.Metadata(embeddedText: "", location: currentURL.map(LyricsLocationRead.available) ?? .absent)
            }, securityDirectory: { _ in nil }
        )
        let track = track()
        let session = catalog.state.activate(track.id)!
        var files: [LocalLyricsSource] = []
        func refresh() {
            catalog.discoverChoices(for: track, session: session, libraryFiles: { _ in [] }) { choices, stage in
                if stage != .cached {
                    let expected = currentURL?.deletingPathExtension().appendingPathExtension("lrc")
                    let actual = choices.compactMap { choice -> URL? in
                        if case .file(let url) = choice.source { return url }; return nil
                    }
                    #expect(actual == expected.map { [$0] } ?? [])
                }
                if stage == .complete { files = choices.map(\.source) }
            }
        }
        refresh()
        #expect(files.contains(.file(x.deletingPathExtension().appendingPathExtension("lrc"))))
        currentURL = y
        refresh()
        #expect(files.contains(.file(y.deletingPathExtension().appendingPathExtension("lrc"))))
        currentURL = nil
        refresh()
        #expect(!files.contains { if case .file = $0 { return true }; return false })
    }

    @Test
    func aFailedFirstReadKeepsTheExplicitTrackLocationButAbsenceClearsIt() throws {
        let url = URL(fileURLWithPath: "/Music/Song.m4a")
        var outcome = LyricsLocationRead.failed
        let catalog = LocalLyricsCatalog(
            embeddedTitle: "Embedded", lyricsXTitle: "LyricsX",
            readMetadata: { _, _, _ in .init(embeddedText: "", location: outcome) },
            securityDirectory: { _ in nil }
        )
        let track = track(fileURL: url)
        let session = try #require(catalog.state.activate(track.id))
        #expect(catalog.metadata(for: track, read: .fresh, session: session)?.fileURL == url)
        outcome = .absent
        #expect(catalog.metadata(for: track, read: .fresh, session: session)?.fileURL == nil)
        outcome = .failed
        #expect(catalog.metadata(for: track, read: .fresh, session: session)?.fileURL == nil)
    }


    @Test
    func staleSessionCannotChangeTheManagedSlotOrStartAnOrdinaryWrite() throws {
        let coordinator = LocalLyricsCoordinator(
            embeddedTitle: "Embedded", lyricsXTitle: "LyricsX",
            readMetadata: { _, _, _ in .init(embeddedText: nil, location: .absent) },
            securityDirectory: { _ in nil }
        )
        let catalog = coordinator.catalog
        let first = try #require(coordinator.activate("A"))
        coordinator.activate("B")
        let current = try #require(coordinator.activate("A"))
        let selected = try #require(Lyrics("[00:01]Current"))
        let stale = try #require(Lyrics("[00:01]Stale"))
        #expect(catalog.rememberManagedLyrics(selected, session: current))
        #expect(!catalog.rememberManagedLyrics(stale, session: first))
        catalog.reject(.lyricsX, session: first)
        #expect(catalog.snapshot(for: first) == nil)
        #expect(catalog.beginWrite(session: first) == nil)
        #expect(catalog.snapshot(for: current)?.managedLyrics === selected)
        #expect(catalog.snapshot(for: current)?.libraryRejected == false)
        let write = try #require(catalog.beginWrite(session: first, access: .verification))
        #expect(!catalog.finishWrite("Old A", token: write))
        #expect(catalog.snapshot(for: current)?.embeddedText == nil)
    }

    @Test
    func discoveryAlwaysCompletesWhenItsSessionIsRetiredBeforeOrDuringTheRead() throws {
        var coordinator: LocalLyricsCoordinator!
        coordinator = LocalLyricsCoordinator(
            embeddedTitle: "Embedded", lyricsXTitle: "LyricsX",
            readMetadata: { _, _, _ in
                coordinator.activate("B")
                return .init(embeddedText: "Old A", location: .absent)
            }, securityDirectory: { _ in nil }
        )
        defer { coordinator = nil }
        let catalog = coordinator.catalog
        let track = track("A")
        let session = try #require(coordinator.activate(track.id))
        var stages: [LocalLyricsRefreshStage] = []
        catalog.discoverChoices(for: track, session: session, libraryFiles: { _ in [] }) { _, stage in stages.append(stage) }
        #expect(stages.last == .cancelled)
        #expect(stages.filter { $0 == .cancelled }.count == 1)
        #expect(!stages.contains(.complete))
        stages = []
        catalog.discoverChoices(for: track, session: session, libraryFiles: { _ in [] }) { _, stage in stages.append(stage) }
        #expect(stages == [.cancelled])
    }

}
