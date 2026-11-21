import Foundation
import LyricsXFoundation
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
        guard tokenStr.unicodeScalars.contains(where: FuriganaAlignment.kanjiCharacters.contains),
              let latin = currentTokenAttribute(.latinTranscription)?.asNS(),
              let hiragana = latin.applyingTransform(.latinToHiragana, reverse: false) else {
            return []
        }
        return FuriganaAlignment.spans(token: tokenStr, reading: hiragana).map { span in
            (span.reading as NSString, NSRange(location: range.location + span.range.location, length: span.range.length))
        }
    }

    func currentRomanjiAnnotation(in string: NSString) -> (NSString, NSRange)? {
        let range = currentTokenRange()
        let tokenStr = string.substring(with: range.asNS)

        let japaneseChars = FuriganaAlignment.kanjiCharacters
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
