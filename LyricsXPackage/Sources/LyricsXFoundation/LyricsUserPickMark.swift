import Foundation

extension Lyrics.IDTagKey {
    /// Marks a lyrics file as one the user applied by hand, as opposed to one
    /// the automatic search saved on its own. Living in the file rather than in
    /// preferences is the whole point: the mark survives a new machine, a
    /// restored backup and any hand-reorganization of the library.
    ///
    /// Computed rather than stored because `IDTagKey` is not `Sendable`, and a
    /// stored static of a non-`Sendable` type is global mutable state under
    /// strict concurrency. Building one costs a string literal.
    public static var userPick: Lyrics.IDTagKey {
        Lyrics.IDTagKey("lxpick")
    }
}

/// How a hand-applied lyrics file came to be. Recorded as the mark's value for
/// diagnostics only — every reader treats the mark's mere presence as the
/// answer, so adding a case here never changes behaviour.
public enum LyricsUserPickOrigin: String, Sendable, CaseIterable {
    case searchPanel = "search-panel"
    case nextCandidate = "next-candidate"
    case `import`
    case edit
}

extension Lyrics {
    /// The one line a freshly created, still-empty lyrics file starts with, so
    /// that whatever the user types under it is already a hand-made choice.
    ///
    /// A file holding nothing but this line does not parse as lyrics
    /// (`Lyrics.init?` rejects a file with no lyrics lines), so an abandoned
    /// empty file never becomes a candidate.
    public static func userPickMarkLine(origin: LyricsUserPickOrigin) -> String {
        "[\(IDTagKey.userPick.rawValue):\(origin.rawValue)]\n"
    }

    /// Whether this file records a hand-made choice. Any non-empty mark counts:
    /// a value this build does not know about still came from a person.
    public var isUserPicked: Bool {
        idTags[.userPick]?.isEmpty == false
    }

    /// Records that the user applied these lyrics by hand. Re-marking an
    /// already-marked file overwrites the origin, which is by design — the
    /// value describes the most recent deliberate act.
    ///
    /// This only sets the tag; getting the file onto disk is the caller's job.
    /// `needsPersist` lives in the app target, one layer above this one, and
    /// every entry point that marks lyrics is already writing them anyway.
    public func markAsUserPicked(origin: LyricsUserPickOrigin) {
        idTags[.userPick] = origin.rawValue
    }
}
