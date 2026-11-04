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
        // At enqueue, not at commit: a copy made inside the undo window must not be dropped.
        resetCaptureSuppression()
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
        blobDeletionsAwaitingSnapshot.formUnion(result.blobReferencesToDelete)
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

    /// All tags across items, memoised and recomputed only when `items` changes.
    var allTags: [String] { cachedTags }

    /// Search / `#tag` / `@app`-filtered, pinned-first. Memoised until `items` changes,
    /// since callers re-read this on every render.
    func filteredItems(search: String, activeTag: String?) -> [ClipboardItem] {
        filterCache.filtered(items, pending: pendingDeletion, search: search, activeTag: activeTag)
    }

    func addTag(_ tag: String, to item: ClipboardItem) {
        ClipboardMutations.addTag(tag, id: item.id, in: &items)
        persist()
    }

    func removeTag(_ tag: String, from item: ClipboardItem) {
        ClipboardMutations.removeTag(tag, id: item.id, in: &items)
        persist()
    }

    func setOCRText(_ text: String?, for item: ClipboardItem) {
        guard let text, ClipboardItem.isUsableOCRText(text) else { return }
        ClipboardMutations.setOCRText(text, id: item.id, in: &items)
        persist()
    }

    func setAIEnrichment(tags: [String], title: String?, for item: ClipboardItem) {
        ClipboardMutations.setAIEnrichment(tags: tags, title: title, id: item.id, in: &items)
        persist()
    }

    func moveToTop(_ item: ClipboardItem) {
        if ClipboardMutations.moveToTop(item.id, in: &items) { persist() }
    }

    func moveToTop(_ selectedItems: [ClipboardItem]) {
        let ids = selectedItems.map(\.id)
        if ClipboardMutations.moveToTop(ids, in: &items) { persist() }
    }

    func clear() {
        pendingDeletion = nil
        resetCaptureSuppression()
        heldElements = []
        let result = ClipboardMutations.removeItems(ids: Set(items.map(\.id)), from: items)
        blobDeletionsAwaitingSnapshot.formUnion(result.blobReferencesToDelete)
        recordTombstones(result.tombstones)
        items = result.items
        persist()
    }
}
