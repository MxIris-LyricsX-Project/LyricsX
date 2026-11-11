import Testing
@testable import LyricsXFoundation

@Test
func anUpdateKeepsAIClientsOnTheAIEngine() {
    let engine = LyricsTranslationEnginePolicy.engine(
        storedValue: nil,
        legacyAITranslationEnabled: true,
        isSystemTranslationAvailable: true
    )
    #expect(engine == .ai)
}

@Test
func translationStaysOffForSomeoneWhoNeverTurnedItOn() {
    let engine = LyricsTranslationEnginePolicy.engine(
        storedValue: nil,
        legacyAITranslationEnabled: false,
        isSystemTranslationAvailable: true
    )
    #expect(engine == .off)
}

@Test(arguments: [
    ("off", LyricsTranslationEngine.off),
    ("system", LyricsTranslationEngine.system),
    ("ai", LyricsTranslationEngine.ai),
])
func aChosenEngineOverridesTheOldAISwitch(storedValue: String, expectedEngine: LyricsTranslationEngine) {
    // The old switch is kept in step for a downgrade, but it no longer
    // decides anything once an engine has been chosen.
    let engine = LyricsTranslationEnginePolicy.engine(
        storedValue: storedValue,
        legacyAITranslationEnabled: true,
        isSystemTranslationAvailable: true
    )
    #expect(engine == expectedEngine)
}

@Test
func systemTranslationIsOffOnAMacThatCannotRunIt() {
    let engine = LyricsTranslationEnginePolicy.engine(
        storedValue: "system",
        legacyAITranslationEnabled: false,
        isSystemTranslationAvailable: false
    )
    #expect(engine == .off)
}

@Test
func anUnknownStoredEngineFallsBackToTheOldAISwitch() {
    let engine = LyricsTranslationEnginePolicy.engine(
        storedValue: "a-future-engine",
        legacyAITranslationEnabled: true,
        isSystemTranslationAvailable: true
    )
    #expect(engine == .ai)
}

@Test(arguments: ["", "  "])
func aTargetLanguageNeverSetIsSimplifiedChinese(stored: String) {
    // The default the Lab pane shows as the field's placeholder.
    #expect(AILyricsTranslationPolicy.resolvedTargetLanguage(stored) == "zh-Hans")
}

@Test
func aTargetLanguageThatWasSetIsKept() {
    #expect(AILyricsTranslationPolicy.resolvedTargetLanguage(" ja ") == "ja")
}

@Test(arguments: [
    (LyricsTranslationEngine.off, false),
    (LyricsTranslationEngine.system, false),
    (LyricsTranslationEngine.ai, true),
])
func theOldAISwitchFollowsTheChosenEngine(engine: LyricsTranslationEngine, expectedSwitchState: Bool) {
    // What an older build, which only knows the switch, reads after a downgrade.
    #expect(LyricsTranslationEnginePolicy.legacyAITranslationEnabled(for: engine) == expectedSwitchState)
}
