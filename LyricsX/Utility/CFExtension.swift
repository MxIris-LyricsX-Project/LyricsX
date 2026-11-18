import Foundation
import SwiftCF

// MARK: - CFStringTokenizer

extension NSString {
    var dominantLanguage: String? {
        return CFStringTokenizer.bestLanguage(for: .from(self))?.asSwift()
    }
}

extension CFStringTokenizer {
    func currentFuriganaToken(in string: NSString) -> JapaneseFuriganaToken {
        let range = currentTokenRange().asNS
        let text = string.substring(with: range)
        return JapaneseFuriganaToken(text: text, range: range) {
            currentTokenAttribute(.latinTranscription)?.asNS().applyingTransform(.latinToHiragana, reverse: false)
        }
    }

    func currentRomanjiAnnotation(in string: NSString) -> (NSString, NSRange)? {
        let range = currentTokenRange()
        let tokenStr = string.substring(with: range.asNS)

        let japaneseChars = CharacterSet.kanji
            .union(.hiragana)
            .union(.katakana)

        guard tokenStr.unicodeScalars.contains(where: japaneseChars.contains),
              let latin = currentTokenAttribute(.latinTranscription)?.asNS() else {
            return nil
        }

        let romanji = latin as NSString
        return (romanji, range.asNS)
    }
}

struct JapaneseFuriganaToken {
    let range: NSRange
    let text: String
    private let containsKanji: Bool
    private let hiragana: String?

    init(text: String, range: NSRange, hiragana: () -> String?) {
        self.text = text
        self.range = range
        containsKanji = text.unicodeScalars.contains(where: { $0.properties.isIdeographic })
        let reading = containsKanji ? hiragana() : nil
        self.hiragana = reading?.isEmpty == false ? reading : nil
    }

    static func annotations(for tokens: [Self]) -> [(NSString, NSRange)] {
        return tokens.indices.flatMap { index -> [(NSString, NSRange)] in
            let token = tokens[index]
            guard token.containsKanji else { return [] }
            let text = token.text
            if let reading = token.hiragana {
                return automaticFuriganaAnnotations(in: text, reading: reading, offset: token.range.location)
            }
            guard let first = text.first, let reading = JapaneseOkuriganaReadings.bundled.reading(
                for: first, suffix: String(text.dropFirst()), tokens: tokens, after: index
            ) else { return [] }
            return [(reading as NSString, NSRange(location: token.range.location, length: String(first).utf16.count))]
        }
    }
}

/// KANJIDIC2 kun readings indexed by kanji and the kana written after it.
struct JapaneseOkuriganaReadings {
    static let bundled: Self = {
        let contents = Bundle.main.url(forResource: "JapaneseOkurigana", withExtension: "tsv")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return Self(contents ?? "")
    }()

    private let forms: [Character: [String: Set<String>]]

    init(_ contents: String) {
        var forms: [Character: [String: Set<String>]] = [:]
        for line in contents.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            guard columns.count == 3, columns[0].count == 1, let glyph = columns[0].first else { continue }
            forms[glyph, default: [:]][String(columns[1]), default: []].insert(String(columns[2]))
        }
        self.forms = forms
    }

    func reading(
        for glyph: Character, suffix: String, tokens: [JapaneseFuriganaToken], after index: Int
    ) -> String? {
        guard let candidates = forms[glyph] else { return nil }

        // Only consider dictionary forms ending at an actual token boundary.
        // The tokenizer may split the okurigana off; collect adjacent kana
        // tokens only, and never cross another kanji or a separator.
        var suffix = normalizedKana(suffix)
        var cursor = index
        var readings: Set<String> = []
        while candidates.keys.contains(where: { $0.hasPrefix(suffix) }) {
            if let stems = candidates[suffix] {
                readings.formUnion(stems)
                if readings.count > 1 { return nil }
            }
            guard cursor + 1 < tokens.count else { break }
            let next = tokens[cursor + 1]
            guard next.range.location == NSMaxRange(tokens[cursor].range),
                  next.text.unicodeScalars.allSatisfy(CharacterSet.kana.contains) else { break }
            suffix += normalizedKana(next.text)
            cursor += 1
        }
        return readings.first
    }
}

private func normalizedKana(_ text: String) -> String {
    let hiragana = text.applyingTransform(.hiraganaToKatakana, reverse: true) ?? text
    return hiragana.precomposedStringWithCanonicalMapping
}

private func automaticFuriganaAnnotations(in token: String, reading: String, offset: Int) -> [(NSString, NSRange)] {
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
    func isKanji(_ character: Character) -> Bool {
        return character.unicodeScalars.contains(where: { $0.properties.isIdeographic }) || character == "々"
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
        let literal = kanji ? [] : Array(normalizedKana(String(characters[start ..< end])))
        segments.append(Segment(range: range, isKanji: kanji, literal: literal))
        start = end
    }

    let kana = Array(normalizedKana(reading))
    var minimumRemaining = Array(repeating: 0, count: segments.count + 1)
    for index in segments.indices.reversed() {
        minimumRemaining[index] = minimumRemaining[index + 1] + (segments[index].isKanji ? 1 : segments[index].literal.count)
    }

    // Kana already written in the token anchors its reading. Each kanji run
    // consumes at least one kana; contiguous kanji remain a single ruby span.
    // Count at most two complete alignments so repeated anchors are not guessed.
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

    var annotations: [(NSString, NSRange)] = []
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
        let range = NSRange(location: offset + segment.range.location, length: segment.range.length)
        annotations.append((String(kana[cursor ..< end]) as NSString, range))
        cursor = end
    }
    return annotations
}
