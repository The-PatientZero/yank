import Foundation

/// Memoises one `ClipQuery.filter` result. Both platforms re-read the filtered list several
/// times per render (list, header count, sectioning, selection summaries), so without this
/// every render recomputes the same filter/sort. The store invalidates it when `items` changes.
public struct ClipFilterCache {
    private var query: String?
    private var tag: String?
    private var result: [ClipboardItem] = []

    public init() {}

    /// The cached result for this query, or nil when the cache is empty or holds another query.
    public func result(query: String, tag: String?) -> [ClipboardItem]? {
        guard self.query == query, self.tag == tag else { return nil }
        return result
    }

    public mutating func store(_ result: [ClipboardItem], query: String, tag: String?) {
        self.query = query
        self.tag = tag
        self.result = result
    }

    public mutating func invalidate() {
        query = nil
        tag = nil
        result = []
    }
}
