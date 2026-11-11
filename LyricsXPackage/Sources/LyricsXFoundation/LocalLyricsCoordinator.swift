import Combine
import Foundation
import LyricsKit
import MusicPlayer

/// Creates a distinct catalog and its activation capability together.
/// AppController keeps the coordinator private; menu clients cannot obtain an
/// activation capability for that catalog through its public API.
public final class LocalLyricsCoordinator {
    public let catalog: LocalLyricsCatalog
    // Owned by AppController's lyricsDisplay queue, along with activation.
    private var deferredImport: (trackID: String, lyrics: Lyrics)?
    private let activationSubject = PassthroughSubject<LocalLyricsState.Session?, Never>()
    public var activations: AnyPublisher<LocalLyricsState.Session?, Never> { activationSubject.eraseToAnyPublisher() }

    public init(
        embeddedTitle: String, lyricsXTitle: String,
        readMetadata: @escaping (MusicTrack, Bool, (LyricsLocationRead) -> Void) -> LocalLyricsState.Metadata,
        securityDirectory: @escaping (URL) -> URL?
    ) {
        catalog = LocalLyricsCatalog(embeddedTitle: embeddedTitle, lyricsXTitle: lyricsXTitle,
                                    readMetadata: readMetadata, securityDirectory: securityDirectory)
    }

    @discardableResult
    public func activate(_ trackID: String?) -> LocalLyricsState.Session? {
        if deferredImport?.trackID != trackID { deferredImport = nil }
        let session = catalog.state.activate(trackID)
        activationSubject.send(session)
        return session
    }

    /// Preserve an explicit import while the track-change handler is queued.
    public func deferImportUntilActivation(_ lyrics: Lyrics, for trackID: String) {
        deferredImport = (trackID, lyrics)
    }

    public func discardDeferredImport(for trackID: String) {
        if deferredImport?.trackID == trackID { deferredImport = nil }
    }

    public func takeDeferredImport(for session: LocalLyricsState.Session) -> Lyrics? {
        guard catalog.isActive(session) else { return nil }
        defer { deferredImport = nil }
        guard deferredImport?.trackID == session.trackID else { return nil }
        return deferredImport?.lyrics
    }
}
