import Foundation
import LyricsKit
import MusicPlayer

public final class LocalLyricsCatalog {
    let state = LocalLyricsState()
    private let embeddedTitle: String
    private let lyricsXTitle: String
    private let readMetadata: (MusicTrack, Bool, (LyricsLocationRead) -> Void) -> LocalLyricsState.Metadata
    private let securityDirectory: (URL) -> URL?

    init(
        embeddedTitle: String, lyricsXTitle: String,
        readMetadata: @escaping (MusicTrack, Bool, (LyricsLocationRead) -> Void) -> LocalLyricsState.Metadata,
        securityDirectory: @escaping (URL) -> URL?
    ) {
        self.embeddedTitle = embeddedTitle
        self.lyricsXTitle = lyricsXTitle
        self.readMetadata = readMetadata
        self.securityDirectory = securityDirectory
    }

    public func captureSession(for trackID: String) -> LocalLyricsState.Session? { state.captureSession(for: trackID) }
    public func isActive(_ session: LocalLyricsState.Session) -> Bool { state.isActive(session) }

    public func snapshot(for session: LocalLyricsState.Session) -> LocalLyricsState.Snapshot? {
        state.snapshot(for: session.trackID, session: session)
    }

    @discardableResult
    public func rememberManagedLyrics(_ lyrics: Lyrics, session: LocalLyricsState.Session) -> Bool {
        state.rememberManagedLyrics(lyrics, for: session.trackID, session: session)
    }

    public func reject(_ source: LocalLyricsSource?, session: LocalLyricsState.Session) {
        if source == .lyricsX { state.rejectLyricsX(for: session.trackID, session: session) }
    }

    public func beginWrite(session: LocalLyricsState.Session, access: LyricsSessionAccess = .active) -> LocalLyricsState.WriteToken? {
        state.beginWrite(for: session.trackID, session: session, access: access)
    }

    @discardableResult
    public func finishWrite(_ contents: String?, token: LocalLyricsState.WriteToken) -> Bool {
        state.finishWrite(contents, for: token.trackID, token: token)
    }

    public func isCurrentMetadata(_ metadata: LocalLyricsState.Metadata, session: LocalLyricsState.Session) -> Bool {
        state.isCurrentMetadata(metadata, session: session)
    }

    public func metadata(
        for track: MusicTrack, read: LyricsMetadataRead, session: LocalLyricsState.Session,
        access: LyricsSessionAccess = .active, onLocation: ((LyricsLocationRead) -> Void)? = nil
    ) -> LocalLyricsState.Metadata? {
        state.readMetadata(for: track.id, mode: read, readerAvailable: track.originalTrack != nil,
                           session: session, initialFileURL: track.fileURL, access: access, onLocation: onLocation) { verified, _, report in
            guard track.originalTrack != nil else {
                let location = track.fileURL.map(LyricsLocationRead.available) ?? .absent
                report(location)
                return LocalLyricsState.Metadata(embeddedText: nil, location: location)
            }
            return readMetadata(track, verified, report)
        }
    }

    /// Called once on UI delivery. Both file choices and state belong to this
    /// exact token, so A→B→A cannot turn an old A result into a new A result.
    public func reconcile(_ choices: [LocalLyricsChoice], for track: MusicTrack, session: LocalLyricsState.Session) -> [LocalLyricsChoice] {
        guard let snapshot = state.snapshot(for: track.id, session: session) else { return [] }
        var result = choices.filter { $0.sessionToken == session.token }
        if snapshot.location != nil {
            let siblings = snapshot.fileURL.map { music in ["lrc", "lrcx"].map { music.deletingPathExtension().appendingPathExtension($0) } } ?? []
            result.removeAll { if case .file(let url) = $0.source { return !siblings.contains(url) }; return false }
        }
        if let text = snapshot.embeddedText {
            result.removeAll { $0.source == .embedded }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.insert(LocalLyricsChoice(sessionToken: session.token, track: track, source: .embedded,
                                               title: embeddedTitle, embeddedContents: text), at: 0)
            }
        }
        if let lyrics = snapshot.managedLyrics {
            result.removeAll { $0.source == .lyricsX }
            result.append(lyricsXChoice(for: track, session: session, memoryLyrics: lyrics))
        } else if snapshot.libraryRejected {
            result.removeAll { $0.source == .lyricsX }
        }
        return result
    }

    /// Only the metadata provider reads Music. A request-local serial delivery
    /// queue builds file choices while that provider is still reading lyrics.
    /// Returning drains all deliveries; each completion replaces the prior batch.
    public func discoverChoices(
        for track: MusicTrack, session: LocalLyricsState.Session,
        libraryFiles: @escaping (MusicTrack) -> [URL],
        completion: @escaping ([LocalLyricsChoice], LocalLyricsRefreshStage) -> Void
    ) {
        guard isActive(session) else { completion([], .cancelled); return }
        let snapshot = state.snapshot(for: track.id, session: session)
        let initialURL = snapshot?.location == nil ? track.fileURL : snapshot?.fileURL
        let job = Discovery(catalog: self, track: track, session: session,
                            libraryFiles: libraryFiles, completion: completion)
        job.enqueue(.cached, fileURL: initialURL)
        let metadata = metadata(for: track, read: .fresh, session: session) { _ in
            let location = self.state.snapshot(for: track.id, session: session)?.fileURL
            if location != initialURL { job.enqueue(.location, fileURL: location) }
        }
        if let metadata { job.enqueue(.complete, fileURL: metadata.fileURL) }
        else { job.enqueue(.cancelled, fileURL: nil) }
        job.drain()
    }

    private func choices(for track: MusicTrack, session: LocalLyricsState.Session, libraryChoice: () -> LocalLyricsChoice?) -> [LocalLyricsChoice] {
        var choices: [LocalLyricsChoice] = []
        if let musicFileURL = track.fileURL {
            for ext in ["lrc", "lrcx"] {
                let url = musicFileURL.deletingPathExtension().appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: url.path) {
                    choices.append(LocalLyricsChoice(sessionToken: session.token, track: track, source: .file(url), title: url.lastPathComponent))
                }
            }
        }
        if let snapshot = state.snapshot(for: track.id, session: session), snapshot.managedLyrics == nil, !snapshot.libraryRejected,
           let libraryChoice = libraryChoice() { choices.append(libraryChoice) }
        return choices
    }

    private func libraryLyricsChoice(for track: MusicTrack, session: LocalLyricsState.Session, files: () -> [URL]) -> LocalLyricsChoice? {
        let candidates = files()
        guard let first = candidates.first else { return nil }
        return try? withSecurityScopedAccess(to: securityDirectory(first)) {
            guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
            return lyricsXChoice(for: track, session: session, fileURL: file)
        }
    }

    private func lyricsXChoice(for track: MusicTrack, session: LocalLyricsState.Session, fileURL: URL? = nil, memoryLyrics: Lyrics? = nil) -> LocalLyricsChoice {
        LocalLyricsChoice(sessionToken: session.token, track: track, source: .lyricsX, title: lyricsXTitle,
                          lyricsXFileURL: fileURL, memoryLyrics: memoryLyrics)
    }

    /// All mutable request data and callbacks are confined to queue. Providers
    /// run on the caller's lookup queue; only immutable inputs cross queues.
    private final class Discovery: @unchecked Sendable {
        let catalog: LocalLyricsCatalog
        let track: MusicTrack
        let session: LocalLyricsState.Session
        let libraryFiles: (MusicTrack) -> [URL]
        let completion: ([LocalLyricsChoice], LocalLyricsRefreshStage) -> Void
        let queue = DispatchQueue(label: "LocalLyricsDelivery")
        lazy var libraryChoice = catalog.libraryLyricsChoice(for: track, session: session) { self.libraryFiles(self.track) }

        init(catalog: LocalLyricsCatalog, track: MusicTrack, session: LocalLyricsState.Session,
             libraryFiles: @escaping (MusicTrack) -> [URL], completion: @escaping ([LocalLyricsChoice], LocalLyricsRefreshStage) -> Void) {
            self.catalog = catalog
            self.track = track
            self.session = session
            self.libraryFiles = libraryFiles
            self.completion = completion
        }

        func enqueue(_ stage: LocalLyricsRefreshStage, fileURL: URL?) {
            queue.async { [self] in
                if stage == .cancelled || (stage == .complete && !catalog.isActive(session)) {
                    completion([], .cancelled)
                    return
                }
                guard catalog.isActive(session) else { return }
                var locatedTrack = track
                locatedTrack.fileURL = fileURL
                let choices = catalog.choices(for: locatedTrack, session: session) { self.libraryChoice }
                completion(choices, stage)
            }
        }
        func drain() { queue.sync {} }
    }
}
