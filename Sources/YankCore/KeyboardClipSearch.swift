import Foundation

/// Pure keyboard-extension search/index helper.
///
/// The extension renders only text clips. Building entries once per store snapshot keeps
/// per-keystroke work to a bounded scan over normalized strings instead of rebuilding
/// display metadata and re-checking clip eligibility each time.
enum KeyboardClipSearch {
    struct Entry: Equatable, Sendable {
        var item: ClipboardItem
        var normalizedText: String
    }

    static func entries(from items: [ClipboardItem]) -> [Entry] {
        items.compactMap { item in
            guard !item.isDeleted, let text = item.textContent else { return nil }
            return Entry(item: item, normalizedText: normalize(text))
        }
    }

    static func results(
        from entries: [Entry],
        query: String,
        emptyLimit: Int,
        searchLimit: Int
    ) -> [ClipboardItem] {
        let normalizedQuery = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let limit = max(0, normalizedQuery.isEmpty ? emptyLimit : searchLimit)
        guard limit > 0 else { return [] }

        if normalizedQuery.isEmpty {
            return Array(entries.lazy.map(\.item).prefix(limit))
        }
        return Array(
            entries.lazy
                .filter { $0.normalizedText.contains(normalizedQuery) }
                .map(\.item)
                .prefix(limit)
        )
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
