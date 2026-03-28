import AppIntents
import LyricsXWidgetShared

struct TranslationLanguage: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Translation Language"
    static var defaultQuery = TranslationLanguageQuery()

    var id: String
    var displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

struct TranslationLanguageQuery: EntityQuery {
    private var dataStore: WidgetDataStore {
        #if DEBUG
        let groupIdentifier = "D5Q73692VW.group.dev.JH.LyricsX"
        #else
        let groupIdentifier = "D5Q73692VW.group.com.JH.LyricsX"
        #endif
        return WidgetDataStore(groupIdentifier: groupIdentifier)
    }

    func entities(for identifiers: [String]) async throws -> [TranslationLanguage] {
        let available = availableLanguages()
        return available.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TranslationLanguage] {
        availableLanguages()
    }

    private func availableLanguages() -> [TranslationLanguage] {
        guard let widgetData = dataStore.read() else { return [] }
        return widgetData.availableTranslationLanguages.map { languageCode in
            let displayName = Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode
            return TranslationLanguage(id: languageCode, displayName: displayName)
        }
    }
}
