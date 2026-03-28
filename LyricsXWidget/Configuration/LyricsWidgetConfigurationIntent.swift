import AppIntents
import WidgetKit

struct LyricsWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "LyricsX Widget"
    static var description: IntentDescription = "Display current song lyrics"

    @Parameter(title: "Show Translation", default: false)
    var showTranslation: Bool

    @Parameter(title: "Translation Language")
    var translationLanguage: TranslationLanguage?
}
