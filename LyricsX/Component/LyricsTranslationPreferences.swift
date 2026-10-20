import Foundation
import GenericID
import LyricsXFoundation

/// Whether this Mac can run system translation: the Translation framework's
/// session for contexts without UI, `init(installedSource:target:)`, is public
/// from macOS 26.
var isSystemLyricsTranslationAvailable: Bool {
    if #available(macOS 26.0, *) {
        return true
    }
    return false
}

extension UserDefaults {
    /// The engine that translates lyrics. Setting it also sets the AI switch
    /// it replaced, which builds from before the engine choice still read.
    var lyricsTranslationEngine: LyricsTranslationEngine {
        get {
            return LyricsTranslationEnginePolicy.engine(
                storedValue: self[.lyricsTranslationEngine],
                legacyAITranslationEnabled: self[.aiLyricsTranslationEnabled],
                isSystemTranslationAvailable: isSystemLyricsTranslationAvailable
            )
        }
        set {
            self[.lyricsTranslationEngine] = newValue.rawValue
            self[.aiLyricsTranslationEnabled] = LyricsTranslationEnginePolicy.legacyAITranslationEnabled(for: newValue)
        }
    }

    /// The language either engine translates into, with the default filled in.
    var resolvedLyricsTranslationTargetLanguage: String {
        return AILyricsTranslationPolicy.resolvedTargetLanguage(self[.lyricsTranslationTargetLanguage])
    }
}
