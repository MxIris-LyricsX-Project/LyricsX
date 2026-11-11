import Testing
@testable import LyricsXFoundation

private final class ScoredCandidate {
    let name: String
    var score: Int

    init(_ name: String, score: Int) {
        self.name = name
        self.score = score
    }
}

private func makePool() -> PriorityOrderedCandidatePool<ScoredCandidate> {
    PriorityOrderedCandidatePool { newCandidate, existingCandidate in
        newCandidate.score > existingCandidate.score
    }
}

@Test
func poolKeepsMembersOrderedByPriorityAndArrivalOrderWithinATie() {
    var pool = makePool()
    pool.insert(ScoredCandidate("first-of-fifty", score: 50))
    pool.insert(ScoredCandidate("ninety", score: 90))
    pool.insert(ScoredCandidate("second-of-fifty", score: 50))
    pool.insert(ScoredCandidate("ten", score: 10))

    #expect(pool.candidates.map(\.name) == ["ninety", "first-of-fifty", "second-of-fifty", "ten"])
}

@Test
func insertingAboveTheSelectionKeepsTheSelectionOnTheSameCandidate() {
    var pool = makePool()
    let chosen = ScoredCandidate("chosen", score: 50)
    pool.insert(ScoredCandidate("high", score: 90))
    pool.insert(chosen)
    pool.selectCandidate(identicalTo: chosen)
    #expect(pool.selectedIndex == 1)

    // A late arrival outranking both lands at index 0 and pushes the selection down.
    pool.insert(ScoredCandidate("higher", score: 99))

    #expect(pool.selectedIndex == 2)
    #expect(pool.selectedCandidate === chosen)
}

@Test
func insertingBelowTheSelectionLeavesTheSelectionIndexAlone() {
    var pool = makePool()
    let chosen = ScoredCandidate("chosen", score: 90)
    pool.insert(chosen)
    pool.insert(ScoredCandidate("low", score: 50))
    pool.selectCandidate(identicalTo: chosen)
    #expect(pool.selectedIndex == 0)

    pool.insert(ScoredCandidate("lower", score: 10))

    #expect(pool.selectedIndex == 0)
    #expect(pool.selectedCandidate === chosen)
}

@Test
func advancingWrapsAroundTheEndOfThePool() {
    var pool = makePool()
    pool.insert(ScoredCandidate("high", score: 90))
    pool.insert(ScoredCandidate("middle", score: 50))
    pool.insert(ScoredCandidate("low", score: 10))
    pool.selectCandidate(identicalTo: pool.candidates[0])

    #expect(pool.advanceSelection()?.name == "middle")
    #expect(pool.advanceSelection()?.name == "low")
    #expect(pool.advanceSelection()?.name == "high")
}

@Test
func advancingWithoutAPriorSelectionStartsAtTheTop() {
    var pool = makePool()
    pool.insert(ScoredCandidate("high", score: 90))
    pool.insert(ScoredCandidate("low", score: 10))

    #expect(pool.selectedIndex == nil)
    #expect(pool.advanceSelection()?.name == "high")
}

@Test
func advancingAnEmptyPoolYieldsNothing() {
    var pool = makePool()
    #expect(pool.advanceSelection() == nil)
    #expect(pool.selectedCandidate == nil)
}

@Test
func resortingAfterAScoreChangeKeepsTheSelectionOnTheSameCandidate() {
    var pool = makePool()
    let chosen = ScoredCandidate("chosen", score: 50)
    let riser = ScoredCandidate("riser", score: 10)
    pool.insert(ScoredCandidate("high", score: 90))
    pool.insert(chosen)
    pool.insert(riser)
    pool.selectCandidate(identicalTo: chosen)
    #expect(pool.selectedIndex == 1)

    // An artwork bonus lands and lifts the last candidate to the top.
    riser.score = 99
    pool.resort()

    #expect(pool.candidates.map(\.name) == ["riser", "high", "chosen"])
    #expect(pool.selectedCandidate === chosen)
    #expect(pool.selectedIndex == 2)
}

@Test
func replacingThePoolReordersAndRelocatesTheSelection() {
    var pool = makePool()
    pool.insert(ScoredCandidate("stale", score: 90))

    let chosen = ScoredCandidate("chosen", score: 50)
    pool.replaceAll(
        with: [ScoredCandidate("low", score: 10), chosen, ScoredCandidate("high", score: 90)],
        selecting: chosen
    )

    #expect(pool.candidates.map(\.name) == ["high", "chosen", "low"])
    #expect(pool.selectedIndex == 1)
    #expect(pool.selectedCandidate === chosen)
}

@Test
func replacingThePoolWithACandidateItDoesNotHoldClearsTheSelection() {
    var pool = makePool()
    pool.replaceAll(with: [ScoredCandidate("only", score: 10)], selecting: ScoredCandidate("stranger", score: 90))

    #expect(pool.selectedIndex == nil)
    #expect(pool.selectedCandidate == nil)
}

@Test
func removingEverythingClearsTheSelectionToo() {
    var pool = makePool()
    let chosen = ScoredCandidate("chosen", score: 50)
    pool.insert(chosen)
    pool.selectCandidate(identicalTo: chosen)

    pool.removeAll()

    #expect(pool.isEmpty)
    #expect(pool.selectedIndex == nil)
    #expect(pool.selectedCandidate == nil)
}
