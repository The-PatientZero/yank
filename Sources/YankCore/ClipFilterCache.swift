import Foundation

/// Memoises one `ClipQuery.filter` result for the query that produced it.
///
/// Both platforms' history views read the filtered list several times per render — the list
/// itself, the header count, sectioning, and every selection summary derived from it — so
/// without this each render recomputes the same filter and sort. The store invalidates the
/// cache whenever `items` changes; a hit is then a two-field compare.
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
