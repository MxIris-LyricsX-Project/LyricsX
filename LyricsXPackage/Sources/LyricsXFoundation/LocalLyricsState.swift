import Foundation
import LyricsKit

public enum LyricsMetadataRead: Sendable { case coalesced, fresh }
public enum LyricsSessionAccess: Sendable { case active, verification }

public enum LyricsLocationRead: Equatable, Sendable {
    case available(URL)
    case absent
    case failed
}

/// The coordinator owns activation. Readers can only capture an existing token.
/// The condition protects state; managed Lyrics mutations belong to lyricsDisplay.
public final class LocalLyricsState: @unchecked Sendable {
    public struct Metadata {
        public let embeddedText: String?
        public let location: LyricsLocationRead
        public fileprivate(set) var fileURL: URL?
        fileprivate var identity: UUID?
        fileprivate var revision: Int?

        public init(embeddedText: String?, location: LyricsLocationRead) {
            self.embeddedText = embeddedText
            self.location = location
            if case .available(let url) = location { fileURL = url }
        }
    }

    public struct Snapshot {
        public let embeddedText: String?
        public let fileURL: URL?
        public let location: LyricsLocationRead?
        public let managedLyrics: Lyrics?
        public let libraryRejected: Bool
    }

    public struct Session: Equatable, @unchecked Sendable {
        fileprivate let context: Track
        fileprivate let owner: UUID
        public var token: UUID { context.identity }
        public var trackID: String { context.id }
        public static func == (lhs: Self, rhs: Self) -> Bool { lhs.owner == rhs.owner && lhs.token == rhs.token }
    }

    public struct WriteToken: Equatable, @unchecked Sendable {
        fileprivate let context: Track
        fileprivate let write: UUID
        fileprivate let owner: UUID
        var trackID: String { context.id }
        public static func == (lhs: Self, rhs: Self) -> Bool { lhs.context === rhs.context && lhs.write == rhs.write }
    }

    fileprivate struct Observer {
        let access: LyricsSessionAccess
        let callback: (LyricsLocationRead) -> Void
    }

    fileprivate final class Track {
        let id: String
        let identity = UUID()
        var embeddedText: String?
        var fileURL: URL?
        var location: LyricsLocationRead?
        var managedLyrics: Lyrics?
        var libraryRejected = false
        var verifiedWrite = false
        var lastRead: Date?
        var readerAvailable: Bool?
        var completedReads = 0
        var reading = false
        var writing: UUID?
        var revision = 0
        var emittedLocation: (revision: Int, result: LyricsLocationRead)?
        var observers: [UUID: Observer] = [:]

        init(id: String) { self.id = id }
        func apply(_ location: LyricsLocationRead) {
            self.location = location
            switch location {
            case .available(let url): fileURL = url
            case .absent: fileURL = nil
            case .failed: break
            }
        }
        func stamp(_ metadata: Metadata) -> Metadata {
            var result = metadata
            result.fileURL = fileURL
            result.identity = identity
            result.revision = revision
            return result
        }
        var cachedMetadata: Metadata? {
            location.map { stamp(Metadata(embeddedText: embeddedText, location: $0)) }
        }
    }

    private let owner = UUID()
    private let condition: NSCondition
    private var track: Track?

    init() { condition = NSCondition() }
    init(condition: NSCondition) { self.condition = condition }

    @discardableResult
    func activate(_ trackID: String?) -> Session? {
        condition.lock()
        defer { condition.unlock() }
        track = trackID.map { Track(id: $0) }
        condition.broadcast()
        return track.map { Session(context: $0, owner: owner) }
    }

    func captureSession(for trackID: String) -> Session? {
        condition.lock()
        defer { condition.unlock() }
        guard let track, track.id == trackID else { return nil }
        return Session(context: track, owner: owner)
    }

    func isActive(_ session: Session) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return session.owner == owner && track === session.context
    }

    func snapshot(for trackID: String, session: Session) -> Snapshot? {
        condition.lock()
        defer { condition.unlock() }
        guard let track, track.id == trackID,
              session.owner == owner && session.context === track else { return nil }
        return Snapshot(embeddedText: track.embeddedText, fileURL: track.fileURL, location: track.location,
                        managedLyrics: track.managedLyrics, libraryRejected: track.libraryRejected)
    }

    @discardableResult
    func rememberManagedLyrics(_ lyrics: Lyrics, for trackID: String, session: Session) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard track?.id == trackID, session.owner == owner && session.context === track else { return false }
        track?.managedLyrics = lyrics
        track?.libraryRejected = false
        return true
    }

    func rejectLyricsX(for trackID: String, session: Session) {
        condition.lock()
        defer { condition.unlock() }
        guard track?.id == trackID, session.owner == owner && session.context === track else { return }
        track?.managedLyrics = nil
        track?.libraryRejected = true
    }

    func beginWrite(for trackID: String, session: Session, access: LyricsSessionAccess = .active) -> WriteToken? {
        condition.lock()
        defer { condition.unlock() }
        let context = session.context
        guard session.owner == owner, context.id == trackID,
              access == .verification || track === context else { return nil }
        let token = WriteToken(context: context, write: UUID(), owner: owner)
        context.writing = token.write
        context.revision += 1
        return token
    }

    @discardableResult
    func finishWrite(_ contents: String?, for trackID: String, token: WriteToken) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let context = token.context
        guard token.owner == owner, context.id == trackID, context.writing == token.write else { return false }
        context.writing = nil
        context.revision += 1
        context.lastRead = nil
        if let contents { context.embeddedText = contents; context.verifiedWrite = true }
        condition.broadcast()
        return track === context
    }

    func isCurrentMetadata(_ metadata: Metadata, session: Session) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let context = session.context
        return session.owner == owner && metadata.identity == context.identity && metadata.revision == context.revision
            && context.writing == nil && metadata.fileURL == context.fileURL
    }

    private func publish(_ result: LyricsLocationRead, context: Track, revision: Int) {
        condition.lock()
        guard context.reading, context.revision == revision else { condition.unlock(); return }
        if let previous = context.emittedLocation, previous.revision == revision, previous.result == result {
            condition.unlock()
            return
        }
        context.apply(result)
        context.emittedLocation = (revision, result)
        let callbacks = context.observers.values.filter { $0.access == .verification || track === context }.map(\.callback)
        condition.unlock()
        callbacks.forEach { $0(result) }
    }

    /// The session and publication closure are bound to one context under the
    /// lock. Joining readers receive a running job's early location without
    /// waiting for its lyrics. Only verification may use a retired context.
    func readMetadata(
        for trackID: String,
        mode: LyricsMetadataRead,
        readerAvailable: Bool,
        session: Session,
        initialFileURL: URL? = nil,
        access: LyricsSessionAccess = .active,
        onLocation: ((LyricsLocationRead) -> Void)? = nil,
        reader: (_ useVerifiedReader: Bool, _ session: Session, _ reportLocation: (LyricsLocationRead) -> Void) -> Metadata
    ) -> Metadata? {
        condition.lock()
        let context = session.context
        guard session.owner == owner, context.id == trackID,
              access == .verification || track === context else { condition.unlock(); return nil }
        let boundSession = Session(context: context, owner: owner)
        if context.location == nil, context.fileURL == nil { context.fileURL = initialFileURL }
        let initialReadCount = context.completedReads
        let observerID = UUID()
        defer { context.observers.removeValue(forKey: observerID); condition.unlock() }
        if let onLocation {
            context.observers[observerID] = Observer(access: access, callback: onLocation)
            if context.reading, let emitted = context.emittedLocation, emitted.revision == context.revision {
                condition.unlock()
                onLocation(emitted.result)
                condition.lock()
            }
        }
        while true {
            guard access == .verification || track === context else { return nil }
            if context.reading || context.writing != nil { condition.wait(); continue }
            if mode == .coalesced || context.completedReads > initialReadCount,
               context.readerAvailable == readerAvailable,
               let lastRead = context.lastRead, Date().timeIntervalSince(lastRead) < 1,
               let cached = context.cachedMetadata {
                if let onLocation { condition.unlock(); onLocation(cached.location); condition.lock() }
                guard access == .verification || track === context else { return nil }
                guard cached.revision == context.revision, context.writing == nil else { continue }
                return cached
            }
            let revision = context.revision
            let verified = context.verifiedWrite
            context.reading = true
            context.emittedLocation = nil
            condition.unlock()
            let fresh = reader(verified, boundSession) { result in self.publish(result, context: context, revision: revision) }
            publish(fresh.location, context: context, revision: revision)
            condition.lock()
            context.reading = false
            condition.broadcast()
            guard access == .verification || track === context else { return nil }
            guard context.revision == revision else { continue }
            context.apply(fresh.location)
            if let text = fresh.embeddedText { context.embeddedText = text }
            context.completedReads += 1
            context.lastRead = Date()
            context.readerAvailable = readerAvailable
            return mode == .fresh ? context.stamp(fresh) : context.cachedMetadata
        }
    }
}
