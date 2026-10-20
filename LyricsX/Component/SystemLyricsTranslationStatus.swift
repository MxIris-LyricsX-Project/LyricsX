import Foundation
import LyricsXFoundation

extension SystemTranslationLanguagePair {
    /// "Japanese → Chinese, Simplified", named in the language the app is
    /// shown in rather than the one its region formats with.
    var localizedDescription: String {
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let sourceName = locale.localizedString(forIdentifier: sourceLanguage) ?? sourceLanguage
        let targetName = locale.localizedString(forIdentifier: targetLanguage) ?? targetLanguage
        return String(
            format: NSLocalizedString(
                "%1$@ → %2$@",
                comment: "A translation direction: %1$@ is the language translated from, %2$@ the language translated into."
            ),
            sourceName,
            targetName
        )
    }
}

extension SystemLyricsTranslationError {
    /// What the Lab pane's status line says about it.
    var statusDescription: String {
        switch self {
        case .languagesNotDownloaded(let pair):
            return String(
                format: NSLocalizedString(
                    "The languages for %@ are not downloaded yet.",
                    comment: "Status shown when system lyric translation needs languages this Mac has not downloaded; %@ is a translation direction such as Japanese → Chinese, Simplified."
                ),
                pair.localizedDescription
            )
        case .unsupportedLanguagePair(let pair):
            return String(
                format: NSLocalizedString(
                    "System Translation cannot translate %@.",
                    comment: "Status shown when the system translation framework does not support a language pair; %@ is a translation direction such as Chinese, Traditional → Chinese, Simplified."
                ),
                pair.localizedDescription
            )
        case .unrecognizedLanguage:
            return NSLocalizedString(
                "The language of these lyrics could not be recognized.",
                comment: "Status shown when system lyric translation cannot tell which language the lyrics are in."
            )
        }
    }
}
