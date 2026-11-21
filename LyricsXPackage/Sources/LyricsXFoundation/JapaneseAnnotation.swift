import Foundation

/// Where the desktop lyrics put Japanese annotations — furigana over kanji and
/// romaji under Japanese words — in one line of lyrics.
public enum JapaneseAnnotationScope: Hashable {
    /// Nothing in the line is annotated.
    case noJapanese
    /// The line as a whole reads as Japanese, so all of it is annotated.
    case wholeLine
    /// The line reads as another language; only these runs of it, UTF-16
    /// ranges in the line, are annotated.
    case japaneseRuns([NSRange])

    /// The whole line when the system reads it as Japanese. Otherwise each
    /// run of kanji and kana that reads as Japanese on its own and holds a
    /// Japanese word: some hiragana, or two katakana in a row.
    ///
    /// English-heavy lines with Japanese in them often read as another
    /// language as a whole (止まらない in "Oh darling darling 止まらない
    /// dance"), so their runs are judged one by one. One kana is no evidence
    /// by itself: Chinese lyrics borrow の (在那个夏天の风里, which reads as
    /// Chinese), and kaomoji are made of single katakana (ヽ(・∀・)ノ).
    public init(line: String) {
        if Self.dominantLanguage(of: line) == "ja" {
            self = .wholeLine
            return
        }
        let text = line as NSString
        let runs = Self.japaneseScriptRun
            .matches(in: line, range: NSRange(location: 0, length: text.length))
            .map(\.range)
            .filter { range in
                let run = text.substring(with: range)
                return Self.dominantLanguage(of: run) == "ja"
                    && run.range(of: Self.japaneseWordEvidence, options: .regularExpression) != nil
            }
        self = runs.isEmpty ? .noJapanese : .japaneseRuns(runs)
    }

    /// The UTF-16 ranges of `line` to annotate.
    public func ranges(in line: String) -> [NSRange] {
        switch self {
        case .noJapanese:
            return []
        case .wholeLine:
            return [NSRange(location: 0, length: (line as NSString).length)]
        case let .japaneseRuns(runs):
            return runs
        }
    }

    /// A run of kanji and kana, with the marks and the long-vowel sign that
    /// sit inside Japanese words.
    private static let japaneseScriptRun = try! NSRegularExpression(pattern: #"[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{M}ー]+"#)

    private static let japaneseWordEvidence = #"\p{sc=Hiragana}|\p{sc=Katakana}{2}"#

    private static func dominantLanguage(of text: String) -> String? {
        let length = (text as NSString).length
        guard length > 0 else { return nil }
        return CFStringTokenizerCopyBestStringLanguage(text as CFString, CFRange(location: 0, length: length)) as String?
    }
}

/// A reading placed over part of a word: `range` is a UTF-16 range in the word.
public struct FuriganaSpan: Hashable {
    public var reading: String
    public var range: NSRange

    public init(reading: String, range: NSRange) {
        self.reading = reading
        self.range = range
    }
}

/// How the reading of a word spreads over its kanji, for the furigana the
/// desktop lyrics generate when the lyrics bring none of their own.
public enum FuriganaAlignment {
    /// The characters read as kanji: every CJK ideograph block — the unified
    /// block, its extensions and the compatibility ideographs (山﨑's 﨑) —
    /// and the marks that stand for a kanji reading rather than for their
    /// own sound: 々 (時々), 〆 (〆切) and the small ヵ and ヶ (ヶ月, 関ヶ原).
    public static let kanjiCharacters: CharacterSet = {
        var characters = CharacterSet(charactersIn: "\u{3400}" ... "\u{4DBF}")
        characters.insert(charactersIn: "\u{4E00}" ... "\u{9FFF}")
        characters.insert(charactersIn: "\u{F900}" ... "\u{FAFF}")
        characters.insert(charactersIn: "\u{20000}" ... "\u{323AF}")
        characters.insert(charactersIn: "々〆ヵヶ")
        return characters
    }()

    /// Whether `character` is read as part of a kanji run rather than written
    /// out in kana.
    public static func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: kanjiCharacters.contains)
    }

    /// The furigana for the kanji runs of `token`, given the reading of the
    /// whole token in hiragana.
    ///
    /// Kana already written in the token anchor the reading, so each kanji run
    /// gets the part of it between them (日の出, ひので → 日 ひ, 出 で);
    /// contiguous kanji share one span. A token with no consistent alignment,
    /// or with more than one, gets none rather than a guess.
    public static func spans(token: String, reading: String) -> [FuriganaSpan] {
        guard !token.isEmpty, !reading.isEmpty, token != reading else { return [] }

        struct Segment {
            let range: NSRange
            let isKanji: Bool
            let literal: [Character]
        }
        struct Position: Hashable {
            let segment: Int
            let reading: Int
        }
        func normalizedKana(_ text: String) -> [Character] {
            let hiragana = text.applyingTransform(.hiraganaToKatakana, reverse: true) ?? text
            return Array(hiragana.precomposedStringWithCanonicalMapping)
        }

        let characters = Array(token)
        let indices = Array(token.indices) + [token.endIndex]
        var segments: [Segment] = []
        var start = 0
        while start < characters.count {
            let kanji = isKanji(characters[start])
            var end = start + 1
            while end < characters.count, isKanji(characters[end]) == kanji { end += 1 }
            let range = NSRange(indices[start] ..< indices[end], in: token)
            let literal = kanji ? [] : normalizedKana(String(characters[start ..< end]))
            segments.append(Segment(range: range, isKanji: kanji, literal: literal))
            start = end
        }

        let kana = normalizedKana(reading)
        var minimumRemaining = Array(repeating: 0, count: segments.count + 1)
        for index in segments.indices.reversed() {
            minimumRemaining[index] = minimumRemaining[index + 1] + (segments[index].isKanji ? 1 : segments[index].literal.count)
        }

        // Each kanji run consumes at least one kana. Count at most two
        // complete alignments, so repeated anchors are not guessed.
        var memo: [Position: Int] = [:]
        func alignmentCount(_ index: Int, _ cursor: Int) -> Int {
            let position = Position(segment: index, reading: cursor)
            if let cached = memo[position] { return cached }
            var count = 0
            if index == segments.count {
                count = cursor == kana.count ? 1 : 0
            } else if kana.count - cursor >= minimumRemaining[index] {
                let segment = segments[index]
                if segment.isKanji {
                    let last = kana.count - minimumRemaining[index + 1]
                    for end in (cursor + 1) ... last {
                        count = min(2, count + alignmentCount(index + 1, end))
                        if count == 2 { break }
                    }
                } else {
                    let end = cursor + segment.literal.count
                    if kana[cursor ..< end].elementsEqual(segment.literal) {
                        count = alignmentCount(index + 1, end)
                    }
                }
            }
            memo[position] = count
            return count
        }
        guard alignmentCount(0, 0) == 1 else { return [] }

        var spans: [FuriganaSpan] = []
        var cursor = 0
        for (index, segment) in segments.enumerated() {
            if !segment.isKanji {
                cursor += segment.literal.count
                continue
            }
            let last = kana.count - minimumRemaining[index + 1]
            guard let end = ((cursor + 1) ... last).first(where: { alignmentCount(index + 1, $0) == 1 }) else {
                return []
            }
            spans.append(FuriganaSpan(reading: String(kana[cursor ..< end]), range: segment.range))
            cursor = end
        }
        return spans
    }
}
