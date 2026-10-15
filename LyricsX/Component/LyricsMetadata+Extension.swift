import Foundation
import LyricsXFoundation

extension Lyrics.Metadata.Key {
    static var localURL = Lyrics.Metadata.Key("localURL")
    static var title = Lyrics.Metadata.Key("title")
    static var artist = Lyrics.Metadata.Key("artist")
    static var needsPersist = Lyrics.Metadata.Key("needsPersist")
    static var language = Lyrics.Metadata.Key("language")
}

extension Lyrics.Metadata {
    var localURL: URL? {
        get { return data[.localURL] as? URL }
        set { data[.localURL] = newValue }
    }

    var title: String? {
        get { return data[.title] as? String }
        set { data[.title] = newValue }
    }

    var artist: String? {
        get { return data[.artist] as? String }
        set { data[.artist] = newValue }
    }

    var needsPersist: Bool {
        get { return data[.needsPersist] as? Bool ?? false }
        set { data[.needsPersist] = newValue }
    }

    var language: String? {
        get { return data[.language] as? String }
        set { data[.language] = newValue }
    }

    /// Sorted because `attachmentTags` is a `Set`: without an order, the
    /// "no preferred language" fallbacks below would pick a different
    /// translation on every launch once a file carries more than one language
    /// — a provider's `tr:zh-Hant` against a freshly added `tr:zh-Hans`, for
    /// instance, would leave most lines showing no translation at all.
    var translationLanguages: [String] {
        return attachmentTags.compactMap { $0.translationLanguageCode }.sorted()
    }

    var displayTranslationLanguage: String? {
        let availableLanguages = translationLanguages
        guard let preferredLanguage = defaults[.preferredLyricsTranslationLanguage] else {
            return availableLanguages.first
        }
        return availableLanguages.first {
            AILyricsTranslationPolicy.languageIdentifiersMatch($0, preferredLanguage)
        }
    }

    func displayTranslation(for line: LyricsLine) -> String? {
        let preferredLanguage = defaults[.preferredLyricsTranslationLanguage]
        let language: String?
        if let preferredLanguage {
            guard let matchingLanguage = translationLanguages.first(where: {
                AILyricsTranslationPolicy.languageIdentifiersMatch($0, preferredLanguage)
            }) else {
                return nil
            }
            language = matchingLanguage
        } else {
            language = translationLanguages.first
        }

        var candidates = language.map { [Optional.some($0)] } ?? []
        if preferredLanguage == nil {
            if attachmentTags.contains(where: { $0.rawValue.lowercased() == "tr" }) {
                candidates.append(nil)
            }
        }
        guard !candidates.isEmpty else { return nil }
        return line.attachments.translation(languageCodeCandidate: candidates)
    }
}

extension LyricsLine.Attachments.Tag {
    fileprivate var translationLanguageCode: String? {
        guard rawValue.hasPrefix("tr:") else {
            return nil
        }
        let code = rawValue.dropFirst(3)
        return code.isEmpty ? nil : String(code)
    }
}
