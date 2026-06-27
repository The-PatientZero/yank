import Foundation

/// Pure, in-place edits on a clip list — shared by the macOS `ClipboardStore` and the
/// iOS `ClipStore` so pin / bookmark / tag / OCR edits behave identically and stamp
/// `modifiedAt` for last-writer-wins sync. Each store calls these, then persists and
/// lets the transport push. Pure (no I/O), so it's unit-tested directly.
enum ClipboardMutations {
    static func togglePin(_ items: inout [ClipboardItem], id: UUID, now: Date = Date()) {
        update(&items, id: id, now: now) { $0.isPinned.toggle() }
    }

    static func toggleBookmark(_ items: inout [ClipboardItem], id: UUID, now: Date = Date()) {
        update(&items, id: id, now: now) { $0.isBookmarked.toggle() }
    }

    static func setOCRText(_ text: String, id: UUID, in items: inout [ClipboardItem], now: Date = Date()) {
        update(&items, id: id, now: now) { $0.ocrText = text }
    }

    /// Store on-device AI suggestions and stamp when enrichment ran (also marks the clip
    /// enriched even when empty, so it isn't re-evaluated on every change).
    static func setAIEnrichment(tags: [String], title: String?, id: UUID, in items: inout [ClipboardItem], now: Date = Date()) {
        update(&items, id: id, now: now) {
            $0.aiTags = tags
            $0.aiTitle = title
            $0.aiEnrichedAt = now
        }
    }

    /// Adds a tag if absent. No-op (and no `modifiedAt` bump) when the tag is already present.
    static func addTag(_ tag: String, id: UUID, in items: inout [ClipboardItem], now: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !items[index].tags.contains(tag) else { return }
        items[index].tags.append(tag)
        items[index].modifiedAt = now
    }

    static func removeTag(_ tag: String, id: UUID, in items: inout [ClipboardItem], now: Date = Date()) {
        update(&items, id: id, now: now) { $0.tags.removeAll { $0 == tag } }
    }

    /// Floats the item to the front (most-recent). Returns whether the order changed,
    /// so callers can skip a needless persist when it was already on top.
    @discardableResult
    static func moveToTop(_ id: UUID, in items: inout [ClipboardItem], now: Date = Date()) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), index != 0 else { return false }
        var moved = items.remove(at: index)
        moved.modifiedAt = now
        items.insert(moved, at: 0)
        return true
    }

    /// Float an ordered selection to the front in one mutation. The final order preserves
    /// the caller's selection order, then appends every other clip in its existing order.
    /// Returns false when the order is already identical, so stores can skip needless
    /// persistence, notifications, and sync churn.
    @discardableResult
    static func moveToTop(_ idsInOrder: [UUID], in items: inout [ClipboardItem], now: Date = Date()) -> Bool {
        guard !idsInOrder.isEmpty else { return false }

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var selected: [ClipboardItem] = []
        selected.reserveCapacity(idsInOrder.count)

        for id in idsInOrder where seen.insert(id).inserted {
            if let item = byID[id] {
                selected.append(item)
            }
        }
        guard !selected.isEmpty else { return false }

        let selectedIDs = Set(selected.map(\.id))
        let nextIDs = selected.map(\.id) + items.lazy.filter { !selectedIDs.contains($0.id) }.map(\.id)
        guard nextIDs != items.map(\.id) else { return false }

        var next = selected + items.filter { !selectedIDs.contains($0.id) }
        for index in next.indices where selectedIDs.contains(next[index].id) {
            next[index].modifiedAt = now
        }
        items = next
        return true
    }

    /// Batch pin/unpin (multi-select). Only stamps `modifiedAt` on items that actually
    /// change, so a no-op edit doesn't churn the sync clock.
    static func setPinned(_ pinned: Bool, ids: Set<UUID>, in items: inout [ClipboardItem], now: Date = Date()) {
        for index in items.indices where ids.contains(items[index].id) && items[index].isPinned != pinned {
            items[index].isPinned = pinned
            items[index].modifiedAt = now
        }
    }

    /// Batch bookmark/un-bookmark (multi-select). Stamps only the items that change.
    static func setBookmarked(_ bookmarked: Bool, ids: Set<UUID>, in items: inout [ClipboardItem], now: Date = Date()) {
        for index in items.indices where ids.contains(items[index].id) && items[index].isBookmarked != bookmarked {
            items[index].isBookmarked = bookmarked
            items[index].modifiedAt = now
        }
    }

    /// The sorted, de-duplicated set of tags across all clips.
    static func allTags(_ items: [ClipboardItem]) -> [String] {
        Array(Set(items.flatMap { $0.tags })).sorted()
    }

    /// Outcome of a pure batch removal: the new item list, the tombstone marks to record
    /// (id → delete time), and the blob references the caller can now delete from disk
    /// (those no longer referenced by any kept clip). The store resolves the references
    /// to URLs in its own directory layout and removes the files — keeping all I/O local
    /// while the membership/tombstone/blob-liveness decisions stay pure and tested.
    struct RemovalResult: Equatable, Sendable {
        var items: [ClipboardItem]
        var tombstones: [UUID: Date]
        var blobReferencesToDelete: [ClipboardBlobReference]
    }

    /// Remove the given ids, tombstoning each so the deletion propagates via sync, and
    /// report which blob references are now orphaned. Shared by both stores' delete /
    /// clear / overflow-trim glue so the tombstone-and-cleanup behaviour can't drift.
    static func removeItems(
        ids: Set<UUID>,
        from items: [ClipboardItem],
        now: Date = Date()
    ) -> RemovalResult {
        guard !ids.isEmpty else {
            return RemovalResult(items: items, tombstones: [:], blobReferencesToDelete: [])
        }
        let removed = items.filter { ids.contains($0.id) }
        let kept = items.filter { !ids.contains($0.id) }
        let tombstones = Dictionary(uniqueKeysWithValues: removed.map { ($0.id, now) })
        let blobReferencesToDelete = ClipboardBlobCleanup.referencesToDelete(
            removing: removed,
            keeping: kept
        )
        return RemovalResult(items: kept, tombstones: tombstones, blobReferencesToDelete: blobReferencesToDelete)
    }

    private static func update(_ items: inout [ClipboardItem], id: UUID, now: Date,
                               _ mutate: (inout ClipboardItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        mutate(&item)
        item.modifiedAt = now
        items[index] = item
    }
}
