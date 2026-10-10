import Foundation

/// Phone covers have no reference image. Resolve catalogue language differences
/// without guessing that an unrelated English title or artist is an alias.
enum PhoneArtworkMetadata {
    static func simplified(_ text: String?) -> String? {
        text.map { $0.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? $0 }
    }

    static func fallbackCountry(title: String?, artist: String?, configuredCountry: String?) -> String? {
        guard configuredCountry?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "tw" else { return nil }
        let text = (title ?? "") + (artist ?? "")
        guard text.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) }) else { return nil }
        return "tw"
    }
}
