import Testing
@testable import LyricsXFoundation

// The Source pane lets the user switch single lyrics sources off. A source
// switched off is never created for the search, so its lyrics stop arriving
// from the automatic search, the search panel and the next-candidate refill.
// What is stored is the list of switched-off sources, so every source —
// including one a later LyricsKit adds — starts out on.

@Test(arguments: LyricsProviders.ServiceID.allCases)
func everySourceIsEnabledByDefault(service: LyricsProviders.ServiceID) {
    #expect(LyricsSourceSwitches().isEnabled(service))
}

@Test
func switchingASourceOffRecordsItsIdentifier() {
    var switches = LyricsSourceSwitches()
    switches.setEnabled(false, for: .kugou)

    #expect(!switches.isEnabled(.kugou))
    #expect(switches.isEnabled(.netease))
    #expect(switches.disabledSourceIdentifiers == ["kugou"])
}

@Test
func switchingASourceBackOnForgetsIt() {
    var switches = LyricsSourceSwitches(disabledSourceIdentifiers: ["kugou", "qq"])
    switches.setEnabled(true, for: .kugou)

    #expect(switches.isEnabled(.kugou))
    #expect(switches.disabledSourceIdentifiers == ["qq"])
}

@Test
func switchingOffTwiceRecordsOnce() {
    var switches = LyricsSourceSwitches()
    switches.setEnabled(false, for: .appleMusic)
    switches.setEnabled(false, for: .appleMusic)

    #expect(switches.disabledSourceIdentifiers == ["appleMusic"])
}

@Test
func duplicateStoredIdentifiersCollapse() {
    var switches = LyricsSourceSwitches(disabledSourceIdentifiers: ["lrclib", "musixmatch", "lrclib"])
    #expect(switches.disabledSourceIdentifiers == ["lrclib", "musixmatch"])

    // One switch back on is enough, however many times the preference listed it.
    switches.setEnabled(true, for: .lrclib)
    #expect(switches.isEnabled(.lrclib))
}

@Test
func identifiersFromANewerBuildSurviveAnotherSwitch() {
    var switches = LyricsSourceSwitches(disabledSourceIdentifiers: ["someFutureSource"])
    #expect(LyricsProviders.ServiceID.allCases.allSatisfy { switches.isEnabled($0) })

    switches.setEnabled(false, for: .qq)
    #expect(switches.disabledSourceIdentifiers == ["someFutureSource", "qq"])
}
