import Foundation

/// The history search/filter, shared by the macOS history window and the iOS list so
/// both resolve `@app`, `#tag`, and plain-text queries identically. Pure and testable.
enum ClipQuery {
    /// Filter and order clips for display. An `activeTag` chip ANDs with the search box,
    /// which understands:
    ///   - `@app`  — clips whose source app contains the term (case-insensitive)
    ///   - `#tag`  — clips carrying a tag with that prefix (case-insensitive)
    ///   - text    — clips whose content or OCR text contains the term
    /// Pinned clips float to the top; everything else keeps the input order.
    static func filter(_ items: [ClipboardItem], search: String, activeTag: String?) -> [ClipboardItem] {
        var base = items
        if let activeTag {
            base = base.filter { $0.tags.contains(activeTag) }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if query.hasPrefix("@"), query.count > 1 {
            let app = String(query.dropFirst())
            base = base.filter { $0.sourceApp?.localizedCaseInsensitiveContains(app) ?? false }
        } else if query.hasPrefix("#"), query.count > 1 {
            let tag = String(query.dropFirst()).lowercased()
            base = base.filter { item in item.tags.contains { $0.hasPrefix(tag) } }
        } else if !query.isEmpty, !query.hasPrefix("@"), !query.hasPrefix("#") {
            // A lone "@"/"#" is an in-progress sigil — show everything, don't match the char.
            base = base.filter { $0.matches(query) }
        }
        return base.sorted { $0.isPinned && !$1.isPinned }
    }
}
