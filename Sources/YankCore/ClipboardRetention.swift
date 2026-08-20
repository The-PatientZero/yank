import Foundation

/// Pure age-based retention (time-window cap). Protected items
/// (pinned / bookmarked / tagged) are always kept. No I/O — fully testable.
enum ClipboardRetention {
    struct CapResult: Equatable, Sendable {
        var items: [ClipboardItem]
        var removedItems: [ClipboardItem]
        var blobReferencesToDelete: [ClipboardBlobReference]
    }

    struct EnforcementResult: Equatable, Sendable {
        var items: [ClipboardItem]
        var tombstones: [UUID: Date]
        var expiredItems: [ClipboardItem]
        var cappedItems: [ClipboardItem]
        var blobReferencesToDelete: [ClipboardBlobReference]
        var prunedTombstoneCount: Int

        var didChange: Bool {
            !expiredItems.isEmpty || !cappedItems.isEmpty || prunedTombstoneCount > 0
        }
    }

    /// Items that should expire because they are older than `days`.
    /// `days <= 0` disables expiry. Protected items are never expired.
    static func expiredItems(_ items: [ClipboardItem], olderThanDays days: Int, now: Date) -> [ClipboardItem] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return items.filter { !$0.isProtected && $0.timestamp < cutoff }
    }

    /// Trim to the newest `limit` clips, always keeping protected (pinned / bookmarked
    /// / tagged) ones — even if that pushes the result past `limit`. `limit <= 0`
    /// disables the cap. Result is sorted newest-first. Shared by both stores.
    static func capped(_ items: [ClipboardItem], limit: Int) -> [ClipboardItem] {
        cap(items, limit: limit).items
    }

    static func cap(_ items: [ClipboardItem], limit: Int) -> CapResult {
        guard limit > 0, items.count > limit else {
            return CapResult(
                items: items.sorted { $0.timestamp > $1.timestamp },
                removedItems: [],
                blobReferencesToDelete: []
            )
        }
        let kept = items.filter(\.isProtected).sorted { $0.timestamp > $1.timestamp }
        let budget = max(0, limit - kept.count)
        let fresh = items.filter { !$0.isProtected }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(budget)
        // Both runs are already newest-first; merge them in one pass instead of re-sorting the union.
        let capped = mergedNewestFirst(kept, Array(fresh))
        let keptIDs = Set(capped.map(\.id))
        let removed = items.filter { !keptIDs.contains($0.id) }
        return CapResult(
            items: capped,
            removedItems: removed,
            blobReferencesToDelete: ClipboardBlobCleanup.referencesToDelete(removing: removed, keeping: capped)
        )
    }

    /// Whether tightening to `limit` would actually delete anything. Protected clips consume
    /// budget but are never evicted, so a mostly-pinned/bookmarked/tagged history can sit above
    /// a new cap with nothing removed — a destructive warning would be a lie. Mirrors `cap`, minus building the result.
    static func wouldEvict(_ items: [ClipboardItem], limit: Int) -> Bool {
        guard limit > 0 else { return false }
        // Counted in place rather than via `filter`: the settings screen asks this for every
        // tier on every render, so an allocation per tier is not worth paying.
        var protectedCount = 0
        for item in items where item.isProtected { protectedCount += 1 }
        let budget = max(0, limit - protectedCount)
        return items.count - protectedCount > budget
    }

    /// Merge two newest-first runs into one newest-first array (ties keep `a`'s element first).
    private static func mergedNewestFirst(_ a: [ClipboardItem], _ b: [ClipboardItem]) -> [ClipboardItem] {
        var result: [ClipboardItem] = []
        result.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i].timestamp >= b[j].timestamp {
                result.append(a[i]); i += 1
            } else {
                result.append(b[j]); j += 1
            }
        }
        if i < a.count { result.append(contentsOf: a[i...]) }
        if j < b.count { result.append(contentsOf: b[j...]) }
        return result
    }

    static func enforce(
        items: [ClipboardItem],
        tombstones: [UUID: Date],
        historyLimit: Int,
        retentionDays: Int,
        now: Date
    ) -> EnforcementResult {
        let originalItems = items
        var nextItems = items
        var nextTombstones = tombstones
        var expired: [ClipboardItem] = []

        if retentionDays > 0 {
            expired = expiredItems(nextItems, olderThanDays: retentionDays, now: now)
            if !expired.isEmpty {
                let result = ClipboardMutations.removeItems(
                    ids: Set(expired.map(\.id)),
                    from: nextItems,
                    now: now
                )
                nextItems = result.items
                for (id, date) in result.tombstones {
                    nextTombstones[id] = date
                }
            }
        }

        var capped: [ClipboardItem] = []
        if historyLimit > 0, nextItems.count > historyLimit {
            let result = cap(nextItems, limit: historyLimit)
            nextItems = result.items
            capped = result.removedItems
        }

        let beforePruneCount = nextTombstones.count
        nextTombstones = prunedTombstones(nextTombstones, now: now)

        return EnforcementResult(
            items: nextItems,
            tombstones: nextTombstones,
            expiredItems: expired,
            cappedItems: capped,
            blobReferencesToDelete: ClipboardBlobCleanup.referencesRemoved(from: originalItems, keeping: nextItems),
            prunedTombstoneCount: beforePruneCount - nextTombstones.count
        )
    }

    // MARK: - Tombstone Age-Out

    static let tombstoneHorizonDays = 120

    static func prunedTombstones(
        _ tombstones: [UUID: Date],
        now: Date,
        horizonDays: Int = tombstoneHorizonDays
    ) -> [UUID: Date] {
        guard horizonDays > 0 else { return tombstones }
        let cutoff = now.addingTimeInterval(-Double(horizonDays) * 86_400)
        // Keep a tombstone only while it is strictly younger than the horizon: a delete that
        // is exactly `horizonDays` old (date == cutoff, age == horizon) ages out, matching the
        // `now - date >= horizon` rule above.
        return tombstones.filter { $0.value > cutoff }
    }
}
