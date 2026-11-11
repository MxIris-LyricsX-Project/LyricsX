/// An ordered pool of interchangeable candidates, plus the one currently in use.
///
/// Members stay sorted by a caller-supplied priority relation, so the
/// highest-priority candidate sits at index 0 — the same relation the manual
/// search panel orders its result list by.
///
/// The selection is stored as an index but behaves as if it were a reference:
/// an insertion landing at or above the selected position shifts the index
/// along with it. Without that correction a late high-priority arrival would
/// silently slide the selection onto a neighbouring candidate, and the next
/// `advanceSelection()` would hand back a candidate the user had already seen.
public struct PriorityOrderedCandidatePool<Candidate: AnyObject> {
    public private(set) var candidates: [Candidate] = []

    public private(set) var selectedIndex: Int?

    private let hasHigherPriority: (Candidate, Candidate) -> Bool

    public init(hasHigherPriority: @escaping (Candidate, Candidate) -> Bool) {
        self.hasHigherPriority = hasHigherPriority
    }

    public var count: Int {
        candidates.count
    }

    public var isEmpty: Bool {
        candidates.isEmpty
    }

    public var selectedCandidate: Candidate? {
        guard let selectedIndex, candidates.indices.contains(selectedIndex) else {
            return nil
        }
        return candidates[selectedIndex]
    }

    public func contains(where predicate: (Candidate) -> Bool) -> Bool {
        candidates.contains(where: predicate)
    }

    /// Inserts `candidate` at its priority-ordered position, returning that position.
    @discardableResult
    public mutating func insert(_ candidate: Candidate) -> Int {
        let insertionIndex = insertionIndex(for: candidate, in: candidates)
        candidates.insert(candidate, at: insertionIndex)
        if let currentSelectedIndex = selectedIndex, insertionIndex <= currentSelectedIndex {
            selectedIndex = currentSelectedIndex + 1
        }
        return insertionIndex
    }

    /// Points the selection at `candidate`, if the pool holds that exact object.
    @discardableResult
    public mutating func selectCandidate(identicalTo candidate: Candidate) -> Bool {
        guard let index = candidates.firstIndex(where: { $0 === candidate }) else {
            return false
        }
        selectedIndex = index
        return true
    }

    /// Moves the selection one step down the pool, wrapping around at the end.
    ///
    /// Returns the newly selected candidate, or `nil` when the pool is empty.
    @discardableResult
    public mutating func advanceSelection() -> Candidate? {
        guard !candidates.isEmpty else {
            return nil
        }
        let nextIndex = selectedIndex.map { ($0 + 1) % candidates.count } ?? 0
        selectedIndex = nextIndex
        return candidates[nextIndex]
    }

    /// Re-sorts the pool after a member's priority changed underneath it — an
    /// artwork-similarity bonus landing, for one — keeping the selection on the
    /// same object.
    public mutating func resort() {
        let previouslySelected = selectedCandidate
        candidates = reordered(candidates)
        selectedIndex = previouslySelected.flatMap { selected in
            candidates.firstIndex { $0 === selected }
        }
    }

    /// Replaces the whole pool, ordering it by the same relation, and selects
    /// `candidateToSelect` when it is among the new members.
    public mutating func replaceAll(with newCandidates: [Candidate], selecting candidateToSelect: Candidate?) {
        candidates = reordered(newCandidates)
        selectedIndex = nil
        if let candidateToSelect {
            selectCandidate(identicalTo: candidateToSelect)
        }
    }

    public mutating func removeAll() {
        candidates = []
        selectedIndex = nil
    }

    /// Replays insertion order rather than calling `sort`: candidates of equal
    /// priority must keep their relative arrival order, which sorting over a
    /// strict-weak relation does not guarantee.
    private func reordered(_ unorderedCandidates: [Candidate]) -> [Candidate] {
        var orderedCandidates: [Candidate] = []
        for candidate in unorderedCandidates {
            orderedCandidates.insert(candidate, at: insertionIndex(for: candidate, in: orderedCandidates))
        }
        return orderedCandidates
    }

    private func insertionIndex(for candidate: Candidate, in orderedCandidates: [Candidate]) -> Int {
        orderedCandidates.firstIndex { hasHigherPriority(candidate, $0) } ?? orderedCandidates.endIndex
    }
}
