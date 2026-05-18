import Foundation

extension Comparable {
    func clamped(to limit: ClosedRange<Self>) -> Self {
        return min(max(self, limit.lowerBound), limit.upperBound)
    }

    func clamped(to limit: PartialRangeThrough<Self>) -> Self {
        return min(self, limit.upperBound)
    }

    func clamped(to limit: PartialRangeFrom<Self>) -> Self {
        return max(self, limit.lowerBound)
    }
}

extension Strideable {
    func clamped(to limit: Range<Self>) -> Self {
        guard !limit.isEmpty else {
            preconditionFailure("Range cannot be empty")
        }
        let upperBound = limit.upperBound.advanced(by: -1)
        return min(max(self, limit.lowerBound), upperBound)
    }

    func clamped(to limit: PartialRangeUpTo<Self>) -> Self {
        let upperBound = limit.upperBound.advanced(by: -1)
        return min(self, upperBound)
    }
}

// MARK: - Range

extension NSString {
    var fullRange: NSRange {
        return NSRange(location: 0, length: length)
    }
}

extension String {
    var fullRange: NSRange {
        return NSRange(location: 0, length: utf16.count)
    }
}

extension NSAttributedString {
    var fullRange: NSRange {
        return NSRange(location: 0, length: length)
    }
}

extension CharacterSet {
    static let hiragana = CharacterSet(charactersIn: "\u{3040}" ..< "\u{30a0}")
    static let katakana = CharacterSet(charactersIn: "\u{30a0}" ..< "\u{3100}")
    static let kana = CharacterSet(charactersIn: "\u{3040}" ..< "\u{3100}")
    static let kanji = CharacterSet(charactersIn: "\u{4e00}" ..< "\u{9fc0}")
}

extension String {
    /// Strips bracketed substrings — half-width `(...)` and `[...]`, full-width
    /// `（...）`, `【...】`, and `［...］` — together with their surrounding
    /// whitespace. Song titles often carry suffix noise like "(feat. X)",
    /// "[Explicit]", or "(Remix)" that hurts lyrics-search recall. Falls back
    /// to the original string when stripping would leave nothing but whitespace.
    var strippingBrackets: String {
        let pattern = "\\s*(\\([^)]*\\)|（[^）]*）|\\[[^\\]]*\\]|【[^】]*】|［[^］]*］)\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }
        let range = NSRange(location: 0, length: (self as NSString).length)
        let stripped = regex.stringByReplacingMatches(in: self, range: range, withTemplate: " ")
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? self : trimmed
    }
}
