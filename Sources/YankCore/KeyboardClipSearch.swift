import Foundation

/// Pure keyboard-extension search/index helper.
///
/// The extension renders only text clips. It scans the store's items directly and normalizes
/// lazily during the scan — stopping at the result limit — so the memory-constrained keyboard
/// never holds a second copy of the history's text (the store already holds it once).
enum KeyboardClipSearch {
    /// Live, insertable text clips, order preserved. Used to decide whether the keyboard has
    /// anything to show before building the search UI.
    static func insertableItems(from items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { !$0.isDeleted && $0.textContent != nil }
    }

    static func results(
        from items: [ClipboardItem],
        query: String,
        emptyLimit: Int,
        searchLimit: Int
    ) -> [ClipboardItem] {
        let normalizedQuery = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let limit = max(0, normalizedQuery.isEmpty ? emptyLimit : searchLimit)
        guard limit > 0 else { return [] }

        let insertable = items.lazy.filter { !$0.isDeleted && $0.textContent != nil }
        if normalizedQuery.isEmpty {
            return Array(insertable.prefix(limit))
        }
        return Array(
            insertable
                .filter { normalize($0.textContent ?? "").contains(normalizedQuery) }
                .prefix(limit)
        )
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
