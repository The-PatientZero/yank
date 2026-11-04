import Foundation

/// Memoises one `ClipQuery.filter` result. Both platforms re-read the filtered list several
/// times per render (list, header count, sectioning, selection summaries), so without this
/// every render recomputes the same filter/sort. The store invalidates it when `items` changes.
public struct ClipFilterCache {
    private var query: String?
    private var tag: String?
    private var result: [ClipboardItem] = []

    /// Creates an empty cache.
    public init() {}

    /// The cached result for this query, or nil when the cache is empty or holds another query.
    public func result(query: String, tag: String?) -> [ClipboardItem]? {
        guard self.query == query, self.tag == tag else { return nil }
        return result
    }

    /// Remembers `result` as the answer for this search and tag.
    public mutating func store(_ result: [ClipboardItem], query: String, tag: String?) {
        self.query = query
        self.tag = tag
        self.result = result
    }

    /// The filtered list for this search and tag: the cached result when it matches, otherwise
    /// the items not waiting out their undo window, filtered and stored. Both stores call this
    /// from `filteredItems`; they invalidate the cache whenever `items` or the pending delete change.
    mutating func filtered(
        _ items: [ClipboardItem],
        pending: PendingDeletion?,
        search: String,
        activeTag: String?
    ) -> [ClipboardItem] {
        if let cached = result(query: search, tag: activeTag) { return cached }
        let visible = PendingDeletePolicy.visibleItems(items, pending: pending)
        let filtered = ClipQuery.filter(visible, search: search, activeTag: activeTag)
        store(filtered, query: search, tag: activeTag)
        return filtered
    }

    /// Forgets the stored result.
    public mutating func invalidate() {
        query = nil
        tag = nil
        result = []
    }
}
