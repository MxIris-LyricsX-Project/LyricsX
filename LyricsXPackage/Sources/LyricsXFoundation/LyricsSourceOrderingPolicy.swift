import Foundation

/// How two lyrics candidates are ranked against each other.
///
/// Replaces the older "enable source priority ranking" checkbox, whose two
/// states are the first two cases here. Raw values are persisted, so they are
/// part of the preference format and must not be renumbered.
public enum LyricsSourceOrderingMode: Int, Sendable, CaseIterable {
    /// Match quality alone decides; the source list is ignored.
    case qualityOnly = 0
    /// The source list alone decides; quality only separates two candidates
    /// that came from the same source. A barely-matching result from the
    /// top-listed source still beats a perfect match from a lower one.
    case sourceFirst = 1
    /// Match quality decides, except that scores too close to tell apart are
    /// settled by the source list.
    case qualityFirstSourceTieBreak = 2

    /// Unknown raw values fall back to the factory default rather than to nil,
    /// so a preference written by a newer build cannot leave the app with no
    /// ordering at all.
    public init(storedRawValue: Int) {
        self = LyricsSourceOrderingMode(rawValue: storedRawValue) ?? .qualityOnly
    }

    public var usesSourcePriorityOrder: Bool {
        self != .qualityOnly
    }
}

/// The one place that decides which of two lyrics candidates ranks higher.
///
/// Kept free of `UserDefaults` and of `Lyrics` so the ordering can be tested
/// directly — in particular its transitivity, which is the property the whole
/// design hangs on. Two callers rank candidates through this: the automatic
/// search keeps a running maximum, while the search panel and the candidate
/// pool insertion-sort. Those two agree on the winner only if the relation is
/// a strict weak ordering; when it is not, the lyrics that end up on screen
/// stop matching the first row of the search panel, and that mismatch is
/// exactly the symptom this ordering was introduced to stop producing.
public enum LyricsSourceOrderingPolicy {
    /// Scores within this distance count as "the same" for ordering purposes.
    ///
    /// Sized against the real spread of `Lyrics.quality`: a 5-second duration
    /// mismatch moves the score by about 0.019 and a 3-second one by 0.007,
    /// while carrying a translation moves it by 0.05. So this absorbs timing
    /// noise without erasing the translation and word-by-word bonuses.
    public static let qualityTolerance = 0.02

    /// `Int.max` stands for "this source is not in the user's list", which
    /// sorts behind every listed source and ties with every other unlisted one.
    public static let unlistedSourceIndex = Int.max

    public static func hasHigherPriority(
        candidateQuality: Double,
        candidateSourceIndex: Int,
        comparedToQuality: Double,
        comparedToSourceIndex: Int,
        mode: LyricsSourceOrderingMode,
        qualityTolerance: Double = qualityTolerance
    ) -> Bool {
        switch mode {
        case .qualityOnly:
            return normalizedQuality(candidateQuality) > normalizedQuality(comparedToQuality)

        case .sourceFirst:
            if candidateSourceIndex != comparedToSourceIndex {
                return candidateSourceIndex < comparedToSourceIndex
            }
            return normalizedQuality(candidateQuality) > normalizedQuality(comparedToQuality)

        case .qualityFirstSourceTieBreak:
            // Quantised comparison, not `abs(a - b) < tolerance`: the latter is
            // not transitive (a ≈ b and b ≈ c does not give a ≈ c), and a
            // non-transitive relation makes the insertion sort and the running
            // maximum disagree about which candidate won. Rounding both scores
            // onto the same grid reduces the comparison to two integers, so
            // transitivity holds by construction. The price is grid edges:
            // scores straddling a boundary count as different however close
            // they are, and — because `a + tolerance` does not always land a
            // full tolerance away in binary floating point — a nominal
            // one-tolerance gap can occasionally fall just short of a boundary
            // and tie. In exchange one property holds unconditionally: a gap
            // wider than the tolerance always crosses a boundary, so the
            // source list can never overturn a real difference in quality.
            let candidateBucket = qualityBucket(candidateQuality, tolerance: qualityTolerance)
            let comparedToBucket = qualityBucket(comparedToQuality, tolerance: qualityTolerance)
            if candidateBucket != comparedToBucket {
                return candidateBucket > comparedToBucket
            }
            return candidateSourceIndex < comparedToSourceIndex
        }
    }

    /// The source list after the row at `sourceRow` is dragged into the gap
    /// above row `dropRow` — `sources.count` is the gap below the last row —
    /// or `nil` when the list has no such row or gap.
    public static func reorderedSources(_ sources: [String], movingRowAt sourceRow: Int, toDropRow dropRow: Int) -> [String]? {
        guard sources.indices.contains(sourceRow), (0 ... sources.count).contains(dropRow) else { return nil }
        var reorderedSources = sources
        let targetRow = dropRow > sourceRow ? dropRow - 1 : dropRow
        let movedSource = reorderedSources.remove(at: sourceRow)
        reorderedSources.insert(movedSource, at: targetRow)
        return reorderedSources
    }

    public static func qualityBucket(_ quality: Double, tolerance: Double = qualityTolerance) -> Int {
        guard tolerance > 0, tolerance.isFinite else {
            return 0
        }
        let scaledQuality = (normalizedQuality(quality) / tolerance).rounded(.down)
        // `Int(_:)` traps outside `Int`'s range, and the quality arrives from a
        // scorer this module does not own.
        guard scaledQuality > -9_007_199_254_740_992, scaledQuality < 9_007_199_254_740_992 else {
            return scaledQuality < 0 ? Int.min : Int.max
        }
        return Int(scaledQuality)
    }

    /// NaN compares false against everything, which would make the insertion
    /// search fall through and append — silently reducing ordering to arrival
    /// order. Treating it as zero keeps a bug in the upstream scorer from
    /// disabling sorting altogether.
    private static func normalizedQuality(_ quality: Double) -> Double {
        quality.isFinite ? quality : 0
    }
}
