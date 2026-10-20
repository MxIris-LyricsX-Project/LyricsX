import Foundation
import LyricsKit
import NaturalLanguage
import Translation

/// The two languages one translation runs between, as language tags.
public struct SystemTranslationLanguagePair: Hashable, Sendable {
    public let sourceLanguage: String
    public let targetLanguage: String

    public init(sourceLanguage: String, targetLanguage: String) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

public enum SystemLyricsTranslationError: Error, Equatable, Sendable {
    /// Both languages are supported, but this Mac has not downloaded them.
    case languagesNotDownloaded(SystemTranslationLanguagePair)
    /// The Translation framework does not translate between these two.
    case unsupportedLanguagePair(SystemTranslationLanguagePair)
    /// No language could be told for the lines, so there was nothing to
    /// translate them from.
    case unrecognizedLanguage
}

public struct SystemLyricsTranslationResult: Sendable {
    /// Line index → translated text, for every line that came back changed.
    public let translations: [Int: String]
    /// Lines that needed a translation and did not get one. A line that came
    /// back as it went is not one of them.
    public let failedLineCount: Int
    /// Why lines failed. Nil when none did.
    public let failure: (any Error)?
    /// The languages to download when the lyrics' are supported but not on
    /// this Mac; downloading them translates every line this run skipped.
    public let languagePairToDownload: SystemTranslationLanguagePair?

    public init(
        translations: [Int: String],
        failedLineCount: Int,
        failure: (any Error)?,
        languagePairToDownload: SystemTranslationLanguagePair?
    ) {
        self.translations = translations
        self.failedLineCount = failedLineCount
        self.failure = failure
        self.languagePairToDownload = languagePairToDownload
    }
}

public enum SystemLyricsTranslationPolicy {
    /// The text to store for a translated line: trimmed, every run of line
    /// breaks or control characters turned into one space — a lyrics file
    /// keeps a translation on one line — or nil when nothing is left.
    public static func storableTranslation(_ text: String) -> String? {
        var scalars = String.UnicodeScalarView()
        var previousScalarWasBreaking = false
        for scalar in text.unicodeScalars {
            let isBreaking = CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
            if !isBreaking {
                scalars.append(scalar)
            } else if !previousScalarWasBreaking {
                scalars.append(" ")
            }
            previousScalarWasBreaking = isBreaking
        }
        let translation = String(scalars).trimmingCharacters(in: .whitespaces)
        return translation.isEmpty ? nil : translation
    }

    /// Whether `translation` is `sourceText` handed back as it was: a line
    /// already in the target language, or one the models could not read,
    /// such as romanized Japanese. Not worth keeping — bilingual lyrics would
    /// show the line twice — and not a failure either.
    public static func isUnchanged(_ translation: String, from sourceText: String) -> Bool {
        translation == sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Translates lyrics with the Translation framework, on this Mac, using only
/// languages that are already downloaded. Lyrics whose languages are not are
/// reported in `languagePairToDownload` rather than translated: a session
/// made without UI cannot ask for a download.
///
/// Every line goes to one session, from the language the lyrics are in. A
/// line in another language needs no session of its own: on macOS 26.7 a
/// Japanese-to-Chinese session translated "Baby I love you" and a Korean line
/// as well as its Japanese ones, and an English-to-Chinese one the Japanese
/// lines. Picking such lines out would only have asked for a second
/// download.
@available(macOS 26.0, *)
public struct SystemLyricsTranslator: Sendable {
    public init() {}

    /// Translates the lines of `lyrics` that have no translation into
    /// `targetLanguage`. `lyricsLanguage` is the language the lyrics were
    /// recognized as being in, if they were. `lyrics` is only read.
    public func translate(
        lyrics: Lyrics,
        lyricsLanguage: String?,
        targetLanguage: String
    ) async throws -> SystemLyricsTranslationResult {
        guard let targetLanguage = AILyricsTranslationPolicy.normalizedLanguageIdentifier(targetLanguage) else {
            throw AILyricsTranslationError.invalidTargetLanguage
        }
        let lines = AILyricsTranslationPolicy.translationInputLines(lyrics: lyrics, targetLanguage: targetLanguage)
        guard !lines.isEmpty else {
            return SystemLyricsTranslationResult(
                translations: [:],
                failedLineCount: 0,
                failure: nil,
                languagePairToDownload: nil
            )
        }
        guard let sourceLanguage = (lyricsLanguage ?? Self.dominantLanguage(of: lines))
            .flatMap(AILyricsTranslationPolicy.normalizedLanguageIdentifier) else {
            return SystemLyricsTranslationResult(
                translations: [:],
                failedLineCount: lines.count,
                failure: SystemLyricsTranslationError.unrecognizedLanguage,
                languagePairToDownload: nil
            )
        }

        let pair = SystemTranslationLanguagePair(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        let source = Locale.Language(identifier: sourceLanguage)
        let target = Locale.Language(identifier: targetLanguage)
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            break
        case .supported:
            return SystemLyricsTranslationResult(
                translations: [:],
                failedLineCount: lines.count,
                failure: SystemLyricsTranslationError.languagesNotDownloaded(pair),
                languagePairToDownload: pair
            )
        case .unsupported:
            return SystemLyricsTranslationResult(
                translations: [:],
                failedLineCount: lines.count,
                failure: SystemLyricsTranslationError.unsupportedLanguagePair(pair),
                languagePairToDownload: nil
            )
        @unknown default:
            return SystemLyricsTranslationResult(
                translations: [:],
                failedLineCount: lines.count,
                failure: SystemLyricsTranslationError.unsupportedLanguagePair(pair),
                languagePairToDownload: nil
            )
        }

        try Task.checkCancellation()
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            // Apple Intelligence's models where they are available, which
            // carry the tone of a line rather than its words; the framework
            // falls back to the traditional ones on its own.
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .highFidelity)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
        let requests = lines.map { line in
            TranslationSession.Request(sourceText: line.text, clientIdentifier: String(line.index))
        }
        let cancellation = SessionCancellation(session: session)
        let responses = try await withTaskCancellationHandler {
            try await session.translations(from: requests)
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()

        var translations: [Int: String] = [:]
        var answeredLineCount = 0
        for response in responses {
            guard let index = response.clientIdentifier.flatMap({ Int($0) }),
                  let translation = SystemLyricsTranslationPolicy.storableTranslation(response.targetText) else {
                continue
            }
            answeredLineCount += 1
            if !SystemLyricsTranslationPolicy.isUnchanged(translation, from: response.sourceText) {
                translations[index] = translation
            }
        }
        let failedLineCount = lines.count - answeredLineCount
        return SystemLyricsTranslationResult(
            translations: translations,
            failedLineCount: failedLineCount,
            failure: failedLineCount > 0 ? TranslationError.internalError : nil,
            languagePairToDownload: nil
        )
    }

    /// Hands the session to the cancellation handler, which may run on any
    /// thread; `cancel()` is the one thing that touches it there.
    private final class SessionCancellation: @unchecked Sendable {
        private let session: TranslationSession

        init(session: TranslationSession) {
            self.session = session
        }

        func cancel() {
            session.cancel()
        }
    }

    /// The language most of `lines` are in, for lyrics that have not been
    /// told theirs.
    private static func dominantLanguage(of lines: [AILyricsTranslationInputLine]) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.map(\.text).joined(separator: "\n"))
        return recognizer.dominantLanguage?.rawValue
    }
}
