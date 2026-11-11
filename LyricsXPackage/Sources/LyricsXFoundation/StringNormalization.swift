import Foundation

extension String {
    /// Strips bracketed substrings — half-width `(...)` and `[...]`, full-width
    /// `（...）`, `【...】`, and `［...］` — together with their surrounding
    /// whitespace. Song titles often carry suffix noise like "(feat. X)",
    /// "[Explicit]", or "(Remix)" that hurts lyrics-search recall. Falls back
    /// to the original string when stripping would leave nothing but whitespace.
    public var strippingBrackets: String {
        let pattern = "\\s*(\\([^)]*\\)|（[^）]*）|\\[[^\\]]*\\]|【[^】]*】|［[^］]*］)\\s*"
        guard let regularExpression = try? NSRegularExpression(pattern: pattern) else {
            return self
        }
        let range = NSRange(location: 0, length: (self as NSString).length)
        let stripped = regularExpression.stringByReplacingMatches(
            in: self,
            range: range,
            withTemplate: " "
        )
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? self : trimmed
    }
}
