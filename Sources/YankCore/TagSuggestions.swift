import Foundation

/// Tag autocomplete: which tags to suggest for a search query. Shared by the macOS
/// history search and the iOS tag bar so both complete `#tag` identically. Pure.
enum TagSuggestions {
    /// Tags matching a search query. A `#`-prefixed query narrows by case-insensitive
    /// prefix; anything else — including a bare `#` or empty text — returns all tags.
    /// Input order is preserved.
    static func matching(searchText: String, in allTags: [String]) -> [String] {
        guard searchText.hasPrefix("#") else { return allTags }
        let prefix = String(searchText.dropFirst()).lowercased()
        guard !prefix.isEmpty else { return allTags }
        return allTags.filter { $0.hasPrefix(prefix) }
    }

    /// Tag to apply when the user commits a `#tag` search. Exact matches win over
    /// prefix suggestions, matching the established macOS behavior.
    static func completion(searchText: String, in allTags: [String]) -> String? {
        guard searchText.hasPrefix("#") else { return nil }
        let query = String(searchText.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
        let suggestions = allTags.filter { query.isEmpty || $0.hasPrefix(query) }
        return allTags.first(where: { $0 == query }) ?? suggestions.first
    }
}
