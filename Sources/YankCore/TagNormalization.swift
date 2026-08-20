import Foundation

/// Canonicalizes free text into a Yank tag (lowercase, dash-joined, letters/digits only, length-
/// capped). Every producer routes through here so a typed tag and a suggested tag compare equal.
/// Tags stored under older, looser rules are left as-is and stay findable via case-insensitive match.
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
