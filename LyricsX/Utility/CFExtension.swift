import Foundation
import SwiftCF

// MARK: - CFStringTokenizer

extension NSString {
    var dominantLanguage: String? {
        return CFStringTokenizer.bestLanguage(for: .from(self))?.asSwift()
    }
}

extension CFStringTokenizer {
    func currentFuriganaAnnotations(in string: NSString) -> [(NSString, NSRange)] {
        let range = currentTokenRange()
        let tokenStr = string.substring(with: range.asNS)
        guard tokenStr.unicodeScalars.contains(where: CharacterSet.kanji.contains),
              let latin = currentTokenAttribute(.latinTranscription)?.asNS(),
              let hiragana = latin.applyingTransform(.latinToHiragana, reverse: false) else {
            return []
        }
        return automaticFuriganaAnnotations(in: tokenStr, reading: hiragana, offset: range.location)
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
    func normalizedKana(_ text: String) -> [Character] {
        let hiragana = text.applyingTransform(.hiraganaToKatakana, reverse: true) ?? text
        return Array(hiragana.precomposedStringWithCanonicalMapping)
    }
    func isKanji(_ character: Character) -> Bool {
        return character.unicodeScalars.contains(where: CharacterSet.kanji.contains) || character == "々"
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
