import Testing
@testable import LyricsXFoundation

/// One candidate reduced to what the ordering actually looks at.
private struct RankedCandidate {
    var quality: Double
    var sourceIndex: Int
}

private func outranks(
    _ candidate: RankedCandidate,
    _ other: RankedCandidate,
    mode: LyricsSourceOrderingMode
) -> Bool {
    LyricsSourceOrderingPolicy.hasHigherPriority(
        candidateQuality: candidate.quality,
        candidateSourceIndex: candidate.sourceIndex,
        comparedToQuality: other.quality,
        comparedToSourceIndex: other.sourceIndex,
        mode: mode
    )
}

/// What the automatic search does: hold the best result seen so far and swap
/// whenever an arriving one outranks it.
private func runningMaximum(
    of candidates: [RankedCandidate],
    mode: LyricsSourceOrderingMode
) -> RankedCandidate? {
    var best: RankedCandidate?
    for candidate in candidates {
        if best.map({ outranks(candidate, $0, mode: mode) }) ?? true {
            best = candidate
        }
    }
    return best
}

/// What the search panel and the candidate pool do: insert each arrival ahead
/// of the first candidate it outranks.
private func insertionSorted(
    _ candidates: [RankedCandidate],
    mode: LyricsSourceOrderingMode
) -> [RankedCandidate] {
    var sorted: [RankedCandidate] = []
    for candidate in candidates {
        let insertionIndex = sorted.firstIndex { outranks(candidate, $0, mode: mode) } ?? sorted.count
        sorted.insert(candidate, at: insertionIndex)
    }
    return sorted
}

/// Deterministic stand-in for random input — a linear congruential generator,
/// so a failure is reproducible from the seed alone.
private struct RepeatableNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next(upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(upperBound))
    }
}

// MARK: - Per-mode verdicts

@Test
func qualityOnlyIgnoresTheSourceList() {
    let topSourceButWorseMatch = RankedCandidate(quality: 0.50, sourceIndex: 0)
    let bottomSourceButBetterMatch = RankedCandidate(quality: 0.90, sourceIndex: 5)
    #expect(outranks(bottomSourceButBetterMatch, topSourceButWorseMatch, mode: .qualityOnly))
    #expect(!outranks(topSourceButWorseMatch, bottomSourceButBetterMatch, mode: .qualityOnly))
}

@Test
func sourceFirstLetsTheTopSourceWinOnAnyScore() {
    let topSourceButWorseMatch = RankedCandidate(quality: 0.50, sourceIndex: 0)
    let bottomSourceButBetterMatch = RankedCandidate(quality: 0.90, sourceIndex: 5)
    #expect(outranks(topSourceButWorseMatch, bottomSourceButBetterMatch, mode: .sourceFirst))
    #expect(!outranks(bottomSourceButBetterMatch, topSourceButWorseMatch, mode: .sourceFirst))
}

@Test
func sourceFirstFallsBackToQualityWithinOneSource() {
    let betterMatch = RankedCandidate(quality: 0.90, sourceIndex: 2)
    let worseMatch = RankedCandidate(quality: 0.50, sourceIndex: 2)
    #expect(outranks(betterMatch, worseMatch, mode: .sourceFirst))
    #expect(!outranks(worseMatch, betterMatch, mode: .sourceFirst))
}

@Test
func tieBreakModeLetsAClearlyBetterMatchBeatTheTopSource() {
    // The complaint that motivated this mode: a barely-matching result from the
    // user's favourite source was beating a near-perfect one from another.
    let topSourceButWorseMatch = RankedCandidate(quality: 0.50, sourceIndex: 0)
    let bottomSourceButBetterMatch = RankedCandidate(quality: 0.90, sourceIndex: 5)
    #expect(outranks(bottomSourceButBetterMatch, topSourceButWorseMatch, mode: .qualityFirstSourceTieBreak))
    #expect(!outranks(topSourceButWorseMatch, bottomSourceButBetterMatch, mode: .qualityFirstSourceTieBreak))
}

@Test
func tieBreakModeConsultsTheSourceListOnIndistinguishableScores() {
    // Identical scores are the unambiguous case: same bucket, so the list decides.
    let topSource = RankedCandidate(quality: 0.80, sourceIndex: 0)
    let bottomSource = RankedCandidate(quality: 0.80, sourceIndex: 5)
    #expect(outranks(topSource, bottomSource, mode: .qualityFirstSourceTieBreak))
    #expect(!outranks(bottomSource, topSource, mode: .qualityFirstSourceTieBreak))
}

@Test
func anUnlistedSourceSortsBehindEveryListedOne() {
    let listed = RankedCandidate(quality: 0.80, sourceIndex: 3)
    let unlisted = RankedCandidate(
        quality: 0.80,
        sourceIndex: LyricsSourceOrderingPolicy.unlistedSourceIndex
    )
    #expect(outranks(listed, unlisted, mode: .sourceFirst))
    #expect(outranks(listed, unlisted, mode: .qualityFirstSourceTieBreak))
    // Two unlisted sources tie, which leaves arrival order intact.
    #expect(!outranks(unlisted, unlisted, mode: .sourceFirst))
    #expect(!outranks(unlisted, unlisted, mode: .qualityFirstSourceTieBreak))
}

@Test
func anUnknownStoredModeFallsBackToTheFactoryDefault() {
    #expect(LyricsSourceOrderingMode(storedRawValue: 99) == .qualityOnly)
    #expect(LyricsSourceOrderingMode(storedRawValue: -1) == .qualityOnly)
    #expect(LyricsSourceOrderingMode(storedRawValue: 2) == .qualityFirstSourceTieBreak)
}

@Test
func onlyTheQualityOnlyModeSkipsTheSourceList() {
    #expect(!LyricsSourceOrderingMode.qualityOnly.usesSourcePriorityOrder)
    #expect(LyricsSourceOrderingMode.sourceFirst.usesSourcePriorityOrder)
    #expect(LyricsSourceOrderingMode.qualityFirstSourceTieBreak.usesSourcePriorityOrder)
}

// MARK: - The tolerance boundary

@Test
func aGapWiderThanTheToleranceIsAlwaysDecidedByQuality() {
    // The one hard guarantee bucketing buys: a gap that wide cannot fit inside
    // a bucket, so the source list never gets to overturn it. Swept across the
    // whole score range because the grid edges sit at different places for
    // different scores.
    //
    // "Wider than", not "at least": `a + tolerance` is not always `tolerance`
    // away from `a` in binary floating point — `0.12 + 0.02` lands at
    // 0.13999999999999999, a real gap of 0.01999999999999999, which is inside
    // one bucket and correctly counts as a tie. See the test below.
    let tolerance = LyricsSourceOrderingPolicy.qualityTolerance
    for step in 0 ... 500 {
        let lowerQuality = Double(step) * 0.002
        let higherQuality = lowerQuality + tolerance * 1.001
        let betterMatchFromWorstSource = RankedCandidate(
            quality: higherQuality,
            sourceIndex: LyricsSourceOrderingPolicy.unlistedSourceIndex
        )
        let worseMatchFromBestSource = RankedCandidate(quality: lowerQuality, sourceIndex: 0)
        #expect(
            outranks(betterMatchFromWorstSource, worseMatchFromBestSource, mode: .qualityFirstSourceTieBreak),
            "a gap wider than \(tolerance) above \(lowerQuality) should be settled by quality"
        )
    }
}

@Test
func aGapOfExactlyTheToleranceCanStillTie() {
    // Documents the cost of the grid rather than a defect: rounding can leave
    // a nominal one-tolerance gap fractionally short of a bucket boundary, and
    // then the source list decides after all. Pinned to the two cases the sweep
    // above turned up, so a change in the tolerance or in the rounding shows up
    // here instead of silently widening the guarantee.
    for lowerQuality in [0.12, 0.18] {
        let higherQuality = lowerQuality + LyricsSourceOrderingPolicy.qualityTolerance
        #expect(higherQuality - lowerQuality < LyricsSourceOrderingPolicy.qualityTolerance)
        #expect(
            LyricsSourceOrderingPolicy.qualityBucket(lowerQuality)
                == LyricsSourceOrderingPolicy.qualityBucket(higherQuality)
        )
    }
}

@Test
func scoresLandingInTheSameBucketAreTreatedAsEqual() {
    let tolerance = LyricsSourceOrderingPolicy.qualityTolerance
    // 0.80 and 0.8199 share the bucket that starts at 0.80.
    #expect(
        LyricsSourceOrderingPolicy.qualityBucket(0.80, tolerance: tolerance)
            == LyricsSourceOrderingPolicy.qualityBucket(0.8199, tolerance: tolerance)
    )
    // While 0.7999 sits one bucket below, however close it looks.
    #expect(
        LyricsSourceOrderingPolicy.qualityBucket(0.7999, tolerance: tolerance)
            < LyricsSourceOrderingPolicy.qualityBucket(0.80, tolerance: tolerance)
    )
}

@Test
func aNonFiniteScoreIsTreatedAsZeroRatherThanTrapping() {
    #expect(LyricsSourceOrderingPolicy.qualityBucket(.nan) == 0)
    #expect(LyricsSourceOrderingPolicy.qualityBucket(.infinity) == 0)
    #expect(LyricsSourceOrderingPolicy.qualityBucket(-.infinity) == 0)

    // NaN compares false against everything, so left unhandled it would make
    // every insertion fall through and reduce ordering to arrival order.
    let scored = RankedCandidate(quality: 0.5, sourceIndex: 1)
    let unscored = RankedCandidate(quality: .nan, sourceIndex: 1)
    for mode in LyricsSourceOrderingMode.allCases {
        #expect(outranks(scored, unscored, mode: mode))
        #expect(!outranks(unscored, scored, mode: mode))
    }
}

@Test
func aNonPositiveToleranceCollapsesToASingleBucket() {
    // Ordering then degrades to "source list only", which is a defined result;
    // dividing by zero would have produced infinities instead.
    #expect(LyricsSourceOrderingPolicy.qualityBucket(0.9, tolerance: 0) == 0)
    #expect(LyricsSourceOrderingPolicy.qualityBucket(0.1, tolerance: 0) == 0)
}

// MARK: - Transitivity

@Test
func everyModeIsATotalOrderOverRandomCandidates() {
    // The property the whole design hangs on. `abs(a - b) < tolerance` passes
    // the per-mode tests above and fails right here: it admits cycles, and a
    // cycle makes the ordering depend on arrival order.
    for mode in LyricsSourceOrderingMode.allCases {
        for seed in UInt64(1) ... 200 {
            var generator = RepeatableNumberGenerator(seed: seed)
            let candidates = (0 ..< 6).map { _ in
                RankedCandidate(
                    quality: Double(generator.next(upperBound: 101)) * 0.01,
                    sourceIndex: generator.next(upperBound: 4)
                )
            }

            for first in candidates {
                for second in candidates {
                    // Asymmetric: two candidates cannot both outrank each other.
                    #expect(
                        !(outranks(first, second, mode: mode) && outranks(second, first, mode: mode)),
                        "\(mode) seed \(seed): \(first) and \(second) each outrank the other"
                    )
                    for third in candidates {
                        // Transitive, which is what forbids a cycle.
                        if outranks(first, second, mode: mode), outranks(second, third, mode: mode) {
                            #expect(
                                outranks(first, third, mode: mode),
                                "\(mode) seed \(seed): \(first) > \(second) > \(third) but not \(first) > \(third)"
                            )
                        }
                    }
                }
            }
        }
    }
}

@Test
func theRunningMaximumAndTheInsertionSortAgreeOnTheWinner() {
    // The automatic search keeps a running maximum while the search panel and
    // the candidate pool insertion-sort. Disagreement here is exactly the
    // symptom this ordering exists to prevent: lyrics on screen that are not
    // the first row of the panel.
    for mode in LyricsSourceOrderingMode.allCases {
        for seed in UInt64(1) ... 200 {
            var generator = RepeatableNumberGenerator(seed: seed)
            let candidates = (0 ..< 8).map { _ in
                RankedCandidate(
                    quality: Double(generator.next(upperBound: 101)) * 0.01,
                    sourceIndex: generator.next(upperBound: 4)
                )
            }

            let automaticWinner = runningMaximum(of: candidates, mode: mode)
            let panelWinner = insertionSorted(candidates, mode: mode).first
            let automaticDescription = String(describing: automaticWinner)
            let panelDescription = String(describing: panelWinner)
            #expect(
                automaticWinner?.quality == panelWinner?.quality
                    && automaticWinner?.sourceIndex == panelWinner?.sourceIndex,
                "\(mode) seed \(seed): automatic picked \(automaticDescription), panel's first row is \(panelDescription)"
            )
        }
    }
}

// MARK: - Reordering the source list

// The Sources pane reorders its list by drag and drop: a drop names the row it
// moves and the gap it lands in. The row used to come off the drag as plain
// text, which any app can put there, so dragging the text "7" onto the list
// from a text editor crashed the app, and a smaller number moved that row.

private let sourceList = ["NetEase", "QQMusic", "Kugou", "LRCLIB", "Musixmatch"]

@Test
func aSourceDraggedDownLandsInTheGapItWasDroppedIn() {
    // Row 0 dropped in the gap above row 3 ends up after row 2.
    #expect(
        LyricsSourceOrderingPolicy.reorderedSources(sourceList, movingRowAt: 0, toDropRow: 3)
            == ["QQMusic", "Kugou", "NetEase", "LRCLIB", "Musixmatch"]
    )
}

@Test
func aSourceDraggedUpLandsInTheGapItWasDroppedIn() {
    #expect(
        LyricsSourceOrderingPolicy.reorderedSources(sourceList, movingRowAt: 4, toDropRow: 1)
            == ["NetEase", "Musixmatch", "QQMusic", "Kugou", "LRCLIB"]
    )
}

@Test
func aSourceDroppedBelowTheLastRowMovesToTheEnd() {
    #expect(
        LyricsSourceOrderingPolicy.reorderedSources(sourceList, movingRowAt: 1, toDropRow: 5)
            == ["NetEase", "Kugou", "LRCLIB", "Musixmatch", "QQMusic"]
    )
}

@Test(arguments: [2, 3])
func aSourceDroppedNextToItselfStaysWhereItWas(dropRow: Int) {
    #expect(LyricsSourceOrderingPolicy.reorderedSources(sourceList, movingRowAt: 2, toDropRow: dropRow) == sourceList)
}

@Test(arguments: [5, 7, 99, -1])
func aRowTheListDoesNotHaveMovesNothing(sourceRow: Int) {
    #expect(LyricsSourceOrderingPolicy.reorderedSources(sourceList, movingRowAt: sourceRow, toDropRow: 0) == nil)
}

@Test(arguments: [6, -1])
func aGapTheListDoesNotHaveMovesNothing(dropRow: Int) {
    #expect(LyricsSourceOrderingPolicy.reorderedSources(sourceList, movingRowAt: 0, toDropRow: dropRow) == nil)
}
