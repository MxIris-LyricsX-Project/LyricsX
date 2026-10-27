import Testing
@testable import LyricsXFoundation

private final class SearchResult {
    let score: Int

    init(score: Int) {
        self.score = score
    }
}

private func outranks(_ candidate: SearchResult, _ existing: SearchResult) -> Bool {
    candidate.score > existing.score
}

@Test
func aBetterResultArrivingAboveTheSelectionKeepsThePreviewedResultSelected() {
    var panelResults = LyricsSearchPanelResults<SearchResult>(trackIdentifier: "track")
    let previewedResult = SearchResult(score: 5)
    panelResults.insert(previewedResult, outranks: outranks)
    panelResults.select(at: 0)

    panelResults.insert(SearchResult(score: 9), outranks: outranks)

    #expect(panelResults.selectedResult === previewedResult)
    #expect(panelResults.selectedIndex == 1)
}

@Test
func aWorseResultArrivingBelowTheSelectionLeavesTheSelectionInPlace() {
    var panelResults = LyricsSearchPanelResults<SearchResult>(trackIdentifier: "track")
    let previewedResult = SearchResult(score: 5)
    panelResults.insert(previewedResult, outranks: outranks)
    panelResults.select(at: 0)

    panelResults.insert(SearchResult(score: 1), outranks: outranks)

    #expect(panelResults.selectedResult === previewedResult)
    #expect(panelResults.selectedIndex == 0)
}

@Test
func rerankingAfterAScoreChangeKeepsThePreviewedResultSelected() {
    var panelResults = LyricsSearchPanelResults<SearchResult>(trackIdentifier: "track")
    let previewedResult = SearchResult(score: 5)
    panelResults.insert(previewedResult, outranks: outranks)
    panelResults.insert(SearchResult(score: 3), outranks: outranks)
    panelResults.select(at: 0)

    panelResults.insert(SearchResult(score: 7), outranks: outranks)
    panelResults.rerank(outranks: outranks)

    #expect(panelResults.selectedResult === previewedResult)
}

@Test
func usingAResultAfterTheTrackChangedKeepsItForTheTrackItWasFoundFor() {
    let panelResults = LyricsSearchPanelResults<SearchResult>(trackIdentifier: "first track")

    #expect(panelResults.application(whilePlaying: "first track") == .currentTrack)
    #expect(panelResults.application(whilePlaying: "second track") == .originalTrackOnly)
    #expect(panelResults.application(whilePlaying: nil) == .originalTrackOnly)
}

@Test
func aSearchTypedInWithNothingPlayingAppliesToWhateverPlaysNow() {
    let panelResults = LyricsSearchPanelResults<SearchResult>(trackIdentifier: nil)

    #expect(panelResults.application(whilePlaying: "track") == .currentTrack)
}
