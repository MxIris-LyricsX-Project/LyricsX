/// Decides whether an arriving search result may take over the screen.
///
/// Entering the candidate pool and taking the screen are separate questions:
/// every result that survives the search filters is a candidate the user may
/// switch onto by hand, while only some of them are allowed to replace what is
/// already being read. This policy answers the second question alone.
public enum LyricsDisplayEligibilityPolicy {
    /// - Parameters:
    ///   - selectionIsPinned: the user picked a candidate by hand, so nothing
    ///     may move the screen on its own.
    ///   - candidateArrivedAfterPriorityWindow: the result reached us after the
    ///     window for late swaps closed. It still belongs in the pool, but by
    ///     then the user has been reading the displayed lyrics for seconds.
    ///   - displayedIsRecovered: whether the lyrics currently on screen came
    ///     from name recovery, or `nil` when nothing is displayed yet.
    ///   - candidateIsRecovered: whether the arriving result came from name
    ///     recovery. Recovery re-searches with the track's native-script name,
    ///     so its results supersede localized-name ones outright — and are
    ///     never superseded by them, whatever the quality scores say.
    ///   - candidateOutranksDisplayed: the quality/source comparison between
    ///     the two, consulted only within the same recovery tier.
    public static func shouldReplaceDisplayed(
        selectionIsPinned: Bool,
        candidateArrivedAfterPriorityWindow: Bool,
        displayedIsRecovered: Bool?,
        candidateIsRecovered: Bool,
        candidateOutranksDisplayed: Bool
    ) -> Bool {
        if selectionIsPinned {
            return false
        }
        if candidateArrivedAfterPriorityWindow {
            return false
        }
        guard let displayedIsRecovered else {
            // Nothing on screen: anything that got this far is an improvement.
            return true
        }
        if candidateIsRecovered != displayedIsRecovered {
            return candidateIsRecovered
        }
        return candidateOutranksDisplayed
    }
}
