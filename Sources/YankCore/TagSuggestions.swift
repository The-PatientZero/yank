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
        return allTags.filter { $0.lowercased().hasPrefix(prefix) }
    }

    /// Tags to offer while the user types into a clip's "Add tag" field. The text is normalized
    /// like a stored tag, so no `#` is needed; empty input offers nothing. Matches are
    /// case-insensitive prefixes in the order of `allTags`, minus the tags the clip already has
    /// (compared case-insensitively, since older tags may be stored in other cases).
    static func suggestions(forInput input: String, in allTags: [String], excluding existing: [String]) -> [String] {
        let prefix = TagNormalization.normalize(input)
        guard !prefix.isEmpty else { return [] }
        let taken = Set(existing.map { $0.lowercased() })
        return allTags.filter {
            let lowered = $0.lowercased()
            return lowered.hasPrefix(prefix) && !taken.contains(lowered)
        }
    }

    /// Tag to apply when the user commits a `#tag` search. Exact matches win over
    /// prefix suggestions, matching the established macOS behavior.
    static func completion(searchText: String, in allTags: [String]) -> String? {
        guard searchText.hasPrefix("#") else { return nil }
        let query = String(searchText.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
        let suggestions = allTags.filter { query.isEmpty || $0.lowercased().hasPrefix(query) }
        return allTags.first(where: { $0.lowercased() == query }) ?? suggestions.first
    }
}
