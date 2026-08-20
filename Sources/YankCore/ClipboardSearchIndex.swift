import Foundation

/// Compact keyword index for file-backed text clips. Large clip bodies stay in blob files, so
/// this stores bounded, normalized whole-word coverage captured once — letting keyword search
/// find file-backed clips without reading every blob on each keystroke.
enum ClipboardSearchIndex {
    private static let separator = "\u{1F}"
    private static let minimumTokenLength = 2
    private static let maximumTokenLength = 64
    private static let maximumTokens = 8_192
    private static let tokenCharacters = CharacterSet.alphanumerics

    static func make(for text: String) -> String? {
        let tokens = tokenize(text, maximumTokens: maximumTokens)
        guard !tokens.isEmpty else { return nil }
        return separator + tokens.sorted().joined(separator: separator) + separator
    }

    static func matches(_ index: String?, query: String) -> Bool {
        guard let index else { return false }
        let queryTokens = tokenize(query, maximumTokens: maximumTokens)
        guard !queryTokens.isEmpty else { return false }
        return queryTokens.allSatisfy { index.contains(separator + $0 + separator) }
    }

    private static func tokenize(_ text: String, maximumTokens: Int) -> Set<String> {
        var tokens = Set<String>()
        var current = String()
        current.reserveCapacity(maximumTokenLength)

        func flushToken() {
            guard current.count >= minimumTokenLength else {
                current.removeAll(keepingCapacity: true)
                return
            }
            tokens.insert(current)
            current.removeAll(keepingCapacity: true)
        }

        for scalar in text.lowercased().unicodeScalars {
            if tokenCharacters.contains(scalar) {
                if current.count < maximumTokenLength {
                    current.unicodeScalars.append(scalar)
                }
            } else {
                flushToken()
                if tokens.count >= maximumTokens { break }
            }
        }
        if tokens.count < maximumTokens {
            flushToken()
        }
        return tokens
    }
}
