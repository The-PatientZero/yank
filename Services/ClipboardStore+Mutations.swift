import Foundation

@MainActor
extension ClipboardStore {
    func delete(_ item: ClipboardItem) {
        softDelete([item])
    }

    func deleteItems(_ deleteItems: [ClipboardItem]) {
        softDelete(deleteItems)
    }

    private func softDelete(_ toDelete: [ClipboardItem]) {
        commitPendingDeleteIfNeeded()
        pendingDeletion = PendingDeletion(items: toDelete, enqueuedAt: Date())
        Feedback.emit(.delete)
    }

    func undoPendingDelete() {
        pendingDeletion = nil
    }

    func commitPendingDeleteIfNeeded() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        let ids = Set(pending.items.map(\.id))
        let result = ClipboardMutations.removeItems(ids: ids, from: items)
        blobStore.deleteBlobReferences(result.blobReferencesToDelete)
        recordTombstones(result.tombstones)
        items = result.items
        persist()
    }

    func togglePin(for item: ClipboardItem) {
        ClipboardMutations.togglePin(&items, id: item.id)
        persist()
        Feedback.emit(.pin)
    }

    func toggleBookmark(for item: ClipboardItem) {
        ClipboardMutations.toggleBookmark(&items, id: item.id)
        persist()
    }

    /// Memoised tags, recomputed only when `items` changes. Same shape the
    /// views already read, so call sites are unchanged.
    var allTags: [String] { cachedTags }

    /// Search / `#tag` / `@app`-filtered, pinned-first — memoised until `items` changes,
    /// so the window's many per-render reads (header count, stream, sectioning, and the
    /// selection summaries derived from it) share one filter + sort instead of recomputing.
    func filteredItems(search: String, activeTag: String?) -> [ClipboardItem] {
        if let cached = filterCache.result(query: search, tag: activeTag) {
            return cached
        }
        let visible = PendingDeletePolicy.visibleItems(items, pending: pendingDeletion)
        let result = ClipQuery.filter(visible, search: search, activeTag: activeTag)
        filterCache.store(result, query: search, tag: activeTag)
        return result
    }

    func addTag(_ tag: String, to item: ClipboardItem) {
        ClipboardMutations.addTag(tag, id: item.id, in: &items)
        persist()
    }

    func removeTag(_ tag: String, from item: ClipboardItem) {
        ClipboardMutations.removeTag(tag, id: item.id, in: &items)
        persist()
    }

    func setOCRText(_ text: String, for item: ClipboardItem) {
        ClipboardMutations.setOCRText(text, id: item.id, in: &items)
        persist()
    }

    func setAIEnrichment(tags: [String], title: String?, for item: ClipboardItem) {
        ClipboardMutations.setAIEnrichment(tags: tags, title: title, id: item.id, in: &items)
        persist()
    }

    /// Move an item to the top of the list (most recent position)
    func moveToTop(_ item: ClipboardItem) {
        if ClipboardMutations.moveToTop(item.id, in: &items) { persist() }
    }

    func moveToTop(_ selectedItems: [ClipboardItem]) {
        let ids = selectedItems.map(\.id)
        if ClipboardMutations.moveToTop(ids, in: &items) { persist() }
    }

    func clear() {
        let result = ClipboardMutations.removeItems(ids: Set(items.map(\.id)), from: items)
        blobStore.deleteBlobReferences(result.blobReferencesToDelete)
        recordTombstones(result.tombstones)
        items = result.items
        persist()
    }
}
