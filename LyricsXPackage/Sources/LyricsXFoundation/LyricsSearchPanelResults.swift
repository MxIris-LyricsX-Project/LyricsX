import Foundation

/// What the search panel holds: the track its search ran for, the results
/// ranked best first, and the row the user selected.
///
/// Results keep arriving after the user has selected one, and each is ranked
/// into place. The table keeps a selected row index across a reload, so a
/// better result inserted above the selection would otherwise move it onto a
/// result the user never previewed — the one "Use" would then save.
public struct LyricsSearchPanelResults<Result: AnyObject> {
    /// The track the search ran for, or nil when nothing was playing.
    public let trackIdentifier: String?
    public private(set) var results: [Result] = []
    public private(set) var selectedIndex: Int?

    public init(trackIdentifier: String?) {
        self.trackIdentifier = trackIdentifier
    }

    public var selectedResult: Result? {
        guard let selectedIndex, results.indices.contains(selectedIndex) else {
            return nil
        }
        return results[selectedIndex]
    }

    /// Ranks `result` in ahead of the first result it outranks, keeping
    /// arrival order among results that rank alike.
    public mutating func insert(_ result: Result, outranks: (Result, Result) -> Bool) {
        let insertionIndex = results.firstIndex(where: { outranks(result, $0) }) ?? results.endIndex
        results.insert(result, at: insertionIndex)
        if let selectedIndex, insertionIndex <= selectedIndex {
            self.selectedIndex = selectedIndex + 1
        }
    }

    /// Ranks every result again after a score changed, keeping the selected
    /// result selected.
    public mutating func rerank(outranks: (Result, Result) -> Bool) {
        let selectedResult = selectedResult
        var rerankedResults: [Result] = []
        for result in results {
            let insertionIndex = rerankedResults.firstIndex(where: { outranks(result, $0) }) ?? rerankedResults.endIndex
            rerankedResults.insert(result, at: insertionIndex)
        }
        results = rerankedResults
        selectedIndex = selectedResult.flatMap { selectedResult in
            results.firstIndex(where: { $0 === selectedResult })
        }
    }

    public mutating func select(at index: Int?) {
        guard let index, results.indices.contains(index) else {
            selectedIndex = nil
            return
        }
        selectedIndex = index
    }

    /// What applying the selected result means while `currentTrackIdentifier`
    /// plays.
    public func application(whilePlaying currentTrackIdentifier: String?) -> LyricsResultsApplication {
        LyricsResultsApplication(resultsFoundFor: trackIdentifier, whilePlaying: currentTrackIdentifier)
    }
}

/// Where lyrics the user picks from a set of results belong.
public enum LyricsResultsApplication: Equatable, Sendable {
    /// The results were found for the track playing now, so the pick goes on
    /// screen.
    case currentTrack
    /// Another track plays now. The pick belongs to the track the results
    /// were found for, and to no other.
    case originalTrackOnly

    public init(resultsFoundFor originalTrackIdentifier: String?, whilePlaying currentTrackIdentifier: String?) {
        guard let originalTrackIdentifier else {
            // A search typed in with nothing playing was not for any track.
            self = .currentTrack
            return
        }
        self = originalTrackIdentifier == currentTrackIdentifier ? .currentTrack : .originalTrackOnly
    }
}
