import Foundation
import Testing
@testable import LyricsXFoundation

private let searchStartDate = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Test
func aiTranslationWaitsForTheSearchToShowAResultBeforeAnythingIsOnScreen() {
    var window = AutomaticLyricsReplacementWindow()

    window.searchStarted(identifier: UUID(), isAutomatic: true)

    #expect(window.translationStart(at: searchStartDate) == .afterTheSearchShowsAResult)
}

@Test
func aiTranslationStartsOnceThePriorityWindowRunsOut() {
    var window = AutomaticLyricsReplacementWindow()
    let automaticSearch = UUID()
    window.searchStarted(identifier: automaticSearch, isAutomatic: true)

    window.firstResultShown(bySearch: automaticSearch, closingAt: searchStartDate + 5)

    #expect(window.translationStart(at: searchStartDate + 1) == .at(searchStartDate + 5))
    #expect(window.translationStart(at: searchStartDate + 6) == .now)
}

@Test
func aSearchThatOutlivedItsTrackCannotCloseTheNextTracksWindow() {
    var window = AutomaticLyricsReplacementWindow()
    let previousTrackSearch = UUID()
    window.searchStarted(identifier: previousTrackSearch, isAutomatic: true)
    window.reset()
    window.searchStarted(identifier: UUID(), isAutomatic: true)

    window.searchEnded(identifier: previousTrackSearch)

    #expect(window.translationStart(at: searchStartDate) == .afterTheSearchShowsAResult)
}

@Test
func askingForAnotherCandidateBeforeTheFirstResultDoesNotStallAITranslation() {
    // The next-candidate shortcut, pressed before the automatic search shows
    // anything, starts a search of its own. The automatic search keeps
    // running beside it and still reports its first result and its end; were
    // those dropped, AI translation would wait for a result that never comes.
    var window = AutomaticLyricsReplacementWindow()
    let automaticSearch = UUID()
    window.searchStarted(identifier: automaticSearch, isAutomatic: true)
    window.searchStarted(identifier: UUID(), isAutomatic: false)

    window.firstResultShown(bySearch: automaticSearch, closingAt: searchStartDate + 5)
    #expect(window.translationStart(at: searchStartDate + 1) == .at(searchStartDate + 5))

    window.searchEnded(identifier: automaticSearch)
    #expect(window.translationStart(at: searchStartDate + 2) == .now)
}
