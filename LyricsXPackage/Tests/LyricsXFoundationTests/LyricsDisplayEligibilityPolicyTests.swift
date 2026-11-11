import Testing
@testable import LyricsXFoundation

private func shouldReplace(
    pinned: Bool = false,
    late: Bool = false,
    displayedIsRecovered: Bool? = false,
    candidateIsRecovered: Bool = false,
    outranks: Bool = true
) -> Bool {
    LyricsDisplayEligibilityPolicy.shouldReplaceDisplayed(
        selectionIsPinned: pinned,
        candidateArrivedAfterPriorityWindow: late,
        displayedIsRecovered: displayedIsRecovered,
        candidateIsRecovered: candidateIsRecovered,
        candidateOutranksDisplayed: outranks
    )
}

@Test
func aBetterResultTakesAnEmptyScreen() {
    #expect(shouldReplace(displayedIsRecovered: nil))
    // Even a result that would lose the comparison wins against nothing.
    #expect(shouldReplace(displayedIsRecovered: nil, outranks: false))
}

@Test
func aBetterResultReplacesAWorseOne() {
    #expect(shouldReplace(outranks: true))
    #expect(!shouldReplace(outranks: false))
}

@Test
func aPinnedSelectionIsNeverReplacedAutomatically() {
    // This is the guarantee that keeps the screen from jumping back off the
    // candidate the user just switched to, two seconds later.
    #expect(!shouldReplace(pinned: true, outranks: true))
    #expect(!shouldReplace(pinned: true, displayedIsRecovered: nil))
    #expect(!shouldReplace(pinned: true, displayedIsRecovered: false, candidateIsRecovered: true))
}

@Test
func aResultArrivingAfterThePriorityWindowNeverTakesTheScreen() {
    #expect(!shouldReplace(late: true, outranks: true))
    #expect(!shouldReplace(late: true, displayedIsRecovered: nil))
    // Not even by being a recovery result, which is otherwise privileged.
    #expect(!shouldReplace(late: true, displayedIsRecovered: false, candidateIsRecovered: true))
}

@Test
func aRecoveredResultSupersedesALocalizedOneRegardlessOfScore() {
    #expect(shouldReplace(displayedIsRecovered: false, candidateIsRecovered: true, outranks: false))
}

@Test
func aLocalizedResultNeverSupersedesARecoveredOne() {
    #expect(!shouldReplace(displayedIsRecovered: true, candidateIsRecovered: false, outranks: true))
}

@Test
func withinOneRecoveryTierTheComparisonDecides() {
    #expect(shouldReplace(displayedIsRecovered: true, candidateIsRecovered: true, outranks: true))
    #expect(!shouldReplace(displayedIsRecovered: true, candidateIsRecovered: true, outranks: false))
    #expect(shouldReplace(displayedIsRecovered: false, candidateIsRecovered: false, outranks: true))
    #expect(!shouldReplace(displayedIsRecovered: false, candidateIsRecovered: false, outranks: false))
}

@Test
func pinningOutranksEveryOtherReason() {
    // Exhaustive: whatever the other inputs say, a pinned selection stands.
    for late in [false, true] {
        for displayedIsRecovered in [nil, false, true] as [Bool?] {
            for candidateIsRecovered in [false, true] {
                for outranks in [false, true] {
                    #expect(!shouldReplace(
                        pinned: true,
                        late: late,
                        displayedIsRecovered: displayedIsRecovered,
                        candidateIsRecovered: candidateIsRecovered,
                        outranks: outranks
                    ))
                }
            }
        }
    }
}
