import Foundation

/// Pure, in-place edits on a clip list — shared by the macOS `ClipboardStore` and iOS `ClipStore`
/// so pin/bookmark/tag/OCR edits behave identically and stamp `modifiedAt` for last-writer-wins
/// sync. No I/O; callers persist and push after calling these.
enum ClipboardMutations {
    static func togglePin(_ items: inout [ClipboardItem], id: UUID, now: Date = Date()) {
        update(&items, id: id, now: now) { $0.isPinned.toggle() }
    }

    static func toggleBookmark(_ items: inout [ClipboardItem], id: UUID, now: Date = Date()) {
        update(&items, id: id, now: now) { $0.isBookmarked.toggle() }
    }

    /// Stores recognized text as is. Nil, blank text and the legacy no-result sentence change
    /// nothing (no `modifiedAt` bump), so an empty run never becomes stored content.
    static func setOCRText(_ text: String?, id: UUID, in items: inout [ClipboardItem], now: Date = Date()) {
        guard let text, ClipboardItem.isUsableOCRText(text) else { return }
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
        var item = items[index]
        item.tags.append(tag)
        stampEdit(&item, from: items[index], now: now)
        items[index] = item
    }

    static func removeTag(_ tag: String, id: UUID, in items: inout [ClipboardItem], now: Date = Date()) {
        update(&items, id: id, now: now) { $0.tags.removeAll { $0 == tag } }
    }

    /// Spacing between the capture times of clips reused together, so their relative order survives
    /// a re-sort by capture time.
    private static let reuseTimestampStep: TimeInterval = 0.01

    /// Reuses a clip: floats it to the front and makes `now` its capture time, so it stays the
    /// newest clip through sync, sectioning and retention. Reusing the frontmost clip still refreshes
    /// it. Returns false only when the clip does not exist.
    @discardableResult
    static func moveToTop(_ id: UUID, in items: inout [ClipboardItem], now: Date = Date()) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let original = items.remove(at: index)
        var moved = original
        moved.timestamp = now
        stampEdit(&moved, from: original, now: now)
        items.insert(moved, at: 0)
        return true
    }

    /// Reuses an ordered selection in one mutation: the caller's order first, then every other clip
    /// in its existing order. The first clip gets `now` as its capture time and each following clip
    /// a slightly earlier one, so the selection keeps its relative order after a re-sort. Returns
    /// false only when none of the ids exists.
    @discardableResult
    static func moveToTop(_ idsInOrder: [UUID], in items: inout [ClipboardItem], now: Date = Date()) -> Bool {
        guard !idsInOrder.isEmpty else { return false }

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var selected: [ClipboardItem] = []
        selected.reserveCapacity(idsInOrder.count)

        for id in idsInOrder where seen.insert(id).inserted {
            if let original = byID[id] {
                var item = original
                item.timestamp = now.addingTimeInterval(-Double(selected.count) * reuseTimestampStep)
                stampEdit(&item, from: original, now: now)
                selected.append(item)
            }
        }
        guard !selected.isEmpty else { return false }

        let selectedIDs = Set(selected.map(\.id))
        items = selected + items.filter { !selectedIDs.contains($0.id) }
        return true
    }

    /// Replace a duplicate's capture-owned fields while preserving its stable identity and
    /// user/derived annotations. Unlike `moveToTop`, refreshing an already-frontmost item is
    /// still a mutation because its capture timestamp and attribution advance.
    @discardableResult
    static func refreshDuplicateCapture(
        existingID: UUID,
        with incoming: ClipboardItem,
        in items: inout [ClipboardItem]
    ) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == existingID }) else { return false }
        let existing = items.remove(at: index)
        let refreshed = ClipboardItem(
            id: existing.id,
            type: incoming.type,
            timestamp: incoming.timestamp,
            sourceApp: incoming.sourceApp,
            textContent: incoming.textContent,
            textFilename: incoming.textFilename,
            imageFilename: incoming.imageFilename,
            richFilename: incoming.richFilename,
            hasRichContent: incoming.hasRichContent,
            isPinned: existing.isPinned,
            isBookmarked: existing.isBookmarked,
            tags: existing.tags,
            ocrText: existing.ocrText,
            isTruncated: incoming.isTruncated,
            originalSizeBytes: incoming.originalSizeBytes,
            searchIndex: incoming.searchIndex,
            aiTags: existing.aiTags,
            aiTitle: existing.aiTitle,
            aiEnrichedAt: existing.aiEnrichedAt,
            modifiedAt: incoming.modifiedAt,
            deletedAt: incoming.deletedAt,
            deviceOrigin: incoming.deviceOrigin,
            annotationClocks: existing.annotationClocks ?? AnnotationClocks(allAt: existing.modifiedAt)
        )
        items.insert(refreshed, at: 0)
        return true
    }

    /// Batch pin/unpin (multi-select). Only stamps `modifiedAt` on items that actually
    /// change, so a no-op edit doesn't churn the sync clock.
    static func setPinned(_ pinned: Bool, ids: Set<UUID>, in items: inout [ClipboardItem], now: Date = Date()) {
        for index in items.indices where ids.contains(items[index].id) && items[index].isPinned != pinned {
            var item = items[index]
            item.isPinned = pinned
            stampEdit(&item, from: items[index], now: now)
            items[index] = item
        }
    }

    /// Batch bookmark/un-bookmark (multi-select). Stamps only the items that change.
    static func setBookmarked(_ bookmarked: Bool, ids: Set<UUID>, in items: inout [ClipboardItem], now: Date = Date()) {
        for index in items.indices where ids.contains(items[index].id) && items[index].isBookmarked != bookmarked {
            var item = items[index]
            item.isBookmarked = bookmarked
            stampEdit(&item, from: items[index], now: now)
            items[index] = item
        }
    }

    /// The sorted, de-duplicated set of tags across all clips.
    static func allTags(_ items: [ClipboardItem]) -> [String] {
        Array(Set(items.flatMap { $0.tags })).sorted()
    }

    /// Outcome of a pure batch removal: the new item list, tombstone marks (id → delete time), and
    /// blob references now orphaned. The caller resolves references to URLs and deletes the files,
    /// keeping I/O local while membership/tombstone/blob-liveness decisions stay pure and tested.
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
        stampEdit(&item, from: items[index], now: now)
        items[index] = item
    }

    /// Stamps `modifiedAt` and the change time of each of pin, bookmark and tags whose value the
    /// edit really changed. Missing clocks are first filled in from the old `modifiedAt`, so a
    /// reuse, OCR or AI edit (which change none) never claims a pin, bookmark or tag change.
    private static func stampEdit(_ item: inout ClipboardItem, from before: ClipboardItem, now: Date) {
        var clocks = before.annotationClocks ?? AnnotationClocks(allAt: before.modifiedAt)
        if item.isPinned != before.isPinned { clocks.pinnedAt = now }
        if item.isBookmarked != before.isBookmarked { clocks.bookmarkedAt = now }
        if item.tags != before.tags { clocks.tagsAt = now }
        item.annotationClocks = clocks
        item.modifiedAt = now
    }
}
