import Foundation
import Testing
import Translation
@testable import LyricsXFoundation

// The system translator against the real Translation framework. What a run
// does depends on which languages this Mac has downloaded, so each probe runs
// only on a Mac in the state it is about and skips itself on any other.

/// What this Mac can do with a pair, in a type the test traits can name on
/// any system the package builds for.
private enum LanguagePairState {
    case downloaded
    case notDownloaded
    case unsupported
    case unavailable
}

private func languagePairState(from source: String, to target: String) async -> LanguagePairState {
    guard #available(macOS 26.0, *) else {
        return .unavailable
    }
    switch await LanguageAvailability().status(
        from: Locale.Language(identifier: source),
        to: Locale.Language(identifier: target)
    ) {
    case .installed:
        return .downloaded
    case .supported:
        return .notDownloaded
    case .unsupported:
        return .unsupported
    @unknown default:
        return .unavailable
    }
}

@available(macOS 26.0, *)
@Test(.enabled("Japanese to Simplified Chinese is downloaded") {
    await languagePairState(from: "ja", to: "zh-Hans") == .downloaded
})
func theLinesOfADownloadedPairAreTranslated() async throws {
    let lyrics = try #require(Lyrics("[00:01.000]君の名前を呼んだ\n[00:05.000]夜明けの空に"))
    let result = try await SystemLyricsTranslator().translate(
        lyrics: lyrics,
        lyricsLanguage: "ja",
        targetLanguage: "zh-Hans"
    )
    #expect(result.failure == nil)
    #expect(result.failedLineCount == 0)
    #expect(result.languagePairToDownload == nil)
    #expect(Set(result.translations.keys) == [0, 1])
}

@available(macOS 26.0, *)
@Test(.enabled("Japanese to Simplified Chinese is downloaded") {
    await languagePairState(from: "ja", to: "zh-Hans") == .downloaded
})
func anEnglishLineInAJapaneseSongIsTranslatedWithTheRest() async throws {
    // Why the translator sends a song's every line to one session: the
    // Japanese one reads English too, so it needs no session of its own —
    // and no English download.
    let lyrics = try #require(Lyrics("[00:01.000]君の名前を呼んだ\n[00:05.000]Baby I love you\n[00:09.000]夜明けの空に"))
    let result = try await SystemLyricsTranslator().translate(
        lyrics: lyrics,
        lyricsLanguage: "ja",
        targetLanguage: "zh-Hans"
    )
    #expect(result.failedLineCount == 0)
    #expect(Set(result.translations.keys) == [0, 1, 2])
    #expect(result.translations[1] != "Baby I love you")
}

@available(macOS 26.0, *)
@Test(.enabled("Japanese to Simplified Chinese is downloaded") {
    await languagePairState(from: "ja", to: "zh-Hans") == .downloaded
})
func aLineAlreadyInTheTargetLanguageIsNeitherStoredNorFailed() async throws {
    let lyrics = try #require(Lyrics("[00:01.000]君の名前を呼んだ\n[00:05.000]我们一起走过的路"))
    let result = try await SystemLyricsTranslator().translate(
        lyrics: lyrics,
        lyricsLanguage: "ja",
        targetLanguage: "zh-Hans"
    )
    #expect(result.failedLineCount == 0)
    #expect(Set(result.translations.keys) == [0])
}

@available(macOS 26.0, *)
@Test(.enabled("Korean to Simplified Chinese is supported but not downloaded") {
    await languagePairState(from: "ko", to: "zh-Hans") == .notDownloaded
})
func languagesThatAreNotDownloadedAreOfferedRatherThanTranslated() async throws {
    let lyrics = try #require(Lyrics("[00:01.000]사랑해요\n[00:05.000]너를 기다려"))
    let result = try await SystemLyricsTranslator().translate(
        lyrics: lyrics,
        lyricsLanguage: "ko",
        targetLanguage: "zh-Hans"
    )
    let pair = SystemTranslationLanguagePair(sourceLanguage: "ko", targetLanguage: "zh-Hans")
    #expect(result.translations.isEmpty)
    #expect(result.failedLineCount == 2)
    #expect(result.languagePairToDownload == pair)
    #expect(result.failure as? SystemLyricsTranslationError == .languagesNotDownloaded(pair))
}

@available(macOS 26.0, *)
@Test(.enabled("Traditional to Simplified Chinese is not supported") {
    await languagePairState(from: "zh-Hant", to: "zh-Hans") == .unsupported
})
func aPairTheFrameworkCannotTranslateIsReportedAsSuch() async throws {
    let lyrics = try #require(Lyrics("[00:01.000]我們一起走過的路\n[00:05.000]天亮以前"))
    let result = try await SystemLyricsTranslator().translate(
        lyrics: lyrics,
        lyricsLanguage: "zh-Hant",
        targetLanguage: "zh-Hans"
    )
    let pair = SystemTranslationLanguagePair(sourceLanguage: "zh-Hant", targetLanguage: "zh-Hans")
    #expect(result.translations.isEmpty)
    #expect(result.languagePairToDownload == nil)
    #expect(result.failure as? SystemLyricsTranslationError == .unsupportedLanguagePair(pair))
}
