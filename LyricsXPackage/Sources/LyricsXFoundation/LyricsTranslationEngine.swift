import Foundation

/// What translates the lines a lyrics file has no translation for. One at a
/// time, so every translation a song gains comes from the same engine.
public enum LyricsTranslationEngine: String, CaseIterable, Sendable {
    case off
    /// The Translation framework, on this Mac. Needs macOS 26.
    case system
    /// An OpenAI-compatible chat-completions endpoint.
    case ai
}

public enum LyricsTranslationEnginePolicy {
    /// The engine the stored preference selects.
    ///
    /// The engine choice replaced an on/off switch for AI translation. Until
    /// an engine has been chosen, that switch decides, so an update leaves
    /// someone who had AI translation on with AI translation on.
    public static func engine(
        storedValue: String?,
        legacyAITranslationEnabled: Bool,
        isSystemTranslationAvailable: Bool
    ) -> LyricsTranslationEngine {
        let engine = storedValue.flatMap(LyricsTranslationEngine.init(rawValue:))
            ?? (legacyAITranslationEnabled ? .ai : .off)
        if engine == .system, !isSystemTranslationAvailable {
            return .off
        }
        return engine
    }

    /// The old switch's value for `engine`, kept in step so that a build from
    /// before the engine choice, which reads only the switch, still runs AI
    /// translation exactly when it was the chosen engine.
    public static func legacyAITranslationEnabled(for engine: LyricsTranslationEngine) -> Bool {
        engine == .ai
    }
}
