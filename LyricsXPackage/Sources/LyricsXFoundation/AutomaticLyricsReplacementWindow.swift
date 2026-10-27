import Foundation

/// Whether the automatic lyrics search may still replace the lyrics on screen,
/// and until when.
///
/// The search for a newly playing track puts its first result on screen at
/// once and then keeps a priority window open, during which a better result
/// may still take the screen. AI translation is paid for, so it waits for
/// that window to close rather than translate lyrics about to be replaced.
///
/// The window belongs to the automatic search that opened it, and events from
/// any other search are ignored: a search that outlives its track must not
/// cut short the wait the next track's search set up.
public struct AutomaticLyricsReplacementWindow: Equatable, Sendable {
    /// When a translation of the lyrics on screen may start.
    public enum TranslationStart: Equatable, Sendable {
        /// Nothing can replace the lyrics on screen any more.
        case now
        /// A better result may still take the screen until then.
        case at(Date)
        /// The search has shown nothing yet. Ask again when it does, or when
        /// it ends.
        case afterTheSearchShowsAResult
    }

    private enum Phase: Equatable, Sendable {
        case closed
        case awaitingFirstResult
        case open(closingDate: Date)
    }

    private var phase: Phase = .closed
    private var searchIdentifier: UUID?

    public init() {}

    /// A search has started. `isAutomatic` is true for the search LyricsX runs
    /// by itself for a newly playing track, and false for one the user asked
    /// for: the search that fetches more candidates for the next-candidate
    /// shortcut.
    public mutating func searchStarted(identifier: UUID, isAutomatic: Bool) {
        // A search the user asked for neither opens the window nor takes it
        // over. Its pick is the user's own choice, and the automatic search it
        // runs beside still reports its first result and its end; taking the
        // window over would drop those reports and leave it waiting for good.
        guard isAutomatic else { return }
        searchIdentifier = identifier
        phase = .awaitingFirstResult
    }

    /// The first result of the search `identifier` is on screen, and better
    /// ones may replace it until `closingDate`.
    public mutating func firstResultShown(bySearch identifier: UUID, closingAt closingDate: Date) {
        guard identifier == searchIdentifier else { return }
        phase = .open(closingDate: closingDate)
    }

    /// The search `identifier` has ended, failed or been cancelled, so nothing
    /// it returns can reach the screen any more.
    public mutating func searchEnded(identifier: UUID) {
        guard identifier == searchIdentifier else { return }
        phase = .closed
    }

    /// The track changed. Its search, if it gets one, opens a window of its own.
    public mutating func reset() {
        phase = .closed
        searchIdentifier = nil
    }

    public func translationStart(at now: Date) -> TranslationStart {
        switch phase {
        case .closed:
            return .now
        case .awaitingFirstResult:
            return .afterTheSearchShowsAResult
        case .open(let closingDate):
            return closingDate > now ? .at(closingDate) : .now
        }
    }
}
