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

    /// Sorted, because `attachmentTags` is a `Set` and its order changes from
    /// one process to the next; an unsorted list would make the fallbacks below
    /// pick a different translation on every launch.
    var translationLanguages: [String] {
        return attachmentTags.compactMap { $0.translationLanguageCode }.sorted()
    }
}

extension Lyrics {
    /// Which translation language to show when the user has not named one, or
    /// nil when the file carries none.
    var displayTranslationLanguage: String? {
        guard let preferredLanguage = defaults[.preferredLyricsTranslationLanguage] else {
            return bestCoveringTranslationLanguage()
        }
        return metadata.translationLanguages.first {
            AILyricsTranslationPolicy.languageIdentifiersMatch($0, preferredLanguage)
        }
    }

    func displayTranslation(for line: LyricsLine) -> String? {
        let preferredLanguage = defaults[.preferredLyricsTranslationLanguage]
        let language: String?
        if let preferredLanguage {
            guard let matchingLanguage = metadata.translationLanguages.first(where: {
                AILyricsTranslationPolicy.languageIdentifiersMatch($0, preferredLanguage)
            }) else {
                return nil
            }
            language = matchingLanguage
        } else {
            language = bestCoveringTranslationLanguage()
        }

        var candidates = language.map { [Optional.some($0)] } ?? []
        if preferredLanguage == nil {
            if metadata.attachmentTags.contains(where: { $0.rawValue.lowercased() == "tr" }) {
                candidates.append(nil)
            }
        }
        guard !candidates.isEmpty else { return nil }
        return line.attachments.translation(languageCodeCandidate: candidates)
    }

    /// The translation language covering the most lines.
    ///
    /// Coverage rather than the alphabetically first code, because the two part
    /// company exactly where it matters: a provider that translated a handful
    /// of lines must not outrank a complete translation merely because `zh-Hans`
    /// sorts before `zh-Hant`. Ties break on the sorted code so the choice is
    /// stable across launches — `attachmentTags` is a `Set`.
    ///
    /// Deliberately independent of the AI target-language setting: that setting
    /// is written whenever the settings sheet is saved, whether or not the user
    /// ever turned the feature on, so keying the display off it would re-language
    /// the lyrics of someone who only opened the sheet once.
    private func bestCoveringTranslationLanguage() -> String? {
        let languages = metadata.translationLanguages
        guard languages.count > 1 else { return languages.first }

        var coverage: [String: Int] = [:]
        for language in languages {
            let candidates: [String?] = [language]
            coverage[language] = lines.reduce(0) { total, line in
                line.attachments.translation(languageCodeCandidate: candidates) == nil
                    ? total
                    : total + 1
            }
        }
        return languages.max { lhs, rhs in
            let lhsCoverage = coverage[lhs] ?? 0
            let rhsCoverage = coverage[rhs] ?? 0
            if lhsCoverage != rhsCoverage {
                return lhsCoverage < rhsCoverage
            }
            // `max(by:)` keeps the element it already holds when this returns
            // false, so calling a larger code "smaller" leaves the smallest on top.
            return lhs > rhs
        } ?? languages.first
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
