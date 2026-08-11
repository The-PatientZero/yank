import Foundation

/// The one rule that turns free text into a Yank tag.
///
/// A tag is a single lowercase token: whitespace collapses to a dash, anything that is not a
/// letter, digit, or dash is dropped, leading and trailing dashes are trimmed, and the result is
/// length-capped. Every producer goes through here — the tag field the user types into, the
/// suggestion chips, and the on-device enricher — so a typed tag and a suggested tag are the
/// same string when they mean the same thing, and deduplication between them is exact.
///
/// Tags stored by earlier builds under looser rules are left untouched: they keep decoding and,
/// because matching is case-insensitive, keep being findable. Normalization applies to new input.
public enum TagNormalization {
    /// Longest tag Yank stores. Chosen to stay legible in a chip at the narrowest supported
    /// width rather than to fit any particular storage bound.
    public static let maximumLength = 24

    public static func normalize(_ input: String) -> String {
        let dashed = input
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        let filtered = dashed.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let trimmed = filtered.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(maximumLength))
    }
}
