import Foundation

/// Pure conflict resolution for sync: last-writer-wins by `modifiedAt`,
/// with tombstones retained so deletions keep propagating. No I/O — exhaustively testable.
public enum ClipboardMerge {
    /// Reconcile two item sets into one canonical set (tombstones included), newest-first.
    public static func reconcile(_ a: [ClipboardItem], _ b: [ClipboardItem]) -> [ClipboardItem] {
        var winners: [UUID: ClipboardItem] = [:]
        for item in a + b {
            if let existing = winners[item.id] {
                winners[item.id] = preferred(existing, item)
            } else {
                winners[item.id] = item
            }
        }
        return winners.values.sorted(by: newestFirst)
    }

    /// The live items a UI should show: tombstones filtered out, order preserved.
    public static func visible(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { !$0.isDeleted }
    }

    private static func preferred(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> ClipboardItem {
        let (winnerByClock, loser) = orderedByWriteClock(lhs, rhs)
        var winner = winnerByClock
        // AI enrichment is derived metadata, computed only on macOS, that rides `modifiedAt`.
        // A metadata edit (pin/tag) from a device that never enriched would otherwise win the
        // last-writer race and erase it. Resolve the AI fields on their own clock so the most
        // recent enrichment survives regardless of which side won the item itself.
        let enriched = freshestEnrichment(lhs, rhs)
        winner.aiTags = enriched.aiTags
        winner.aiTitle = enriched.aiTitle
        winner.aiEnrichedAt = enriched.aiEnrichedAt
        // richFilename references a local rich-content blob that sync never transports (there is
        // no CloudKit mapping for it). A device only ever has its own reference and there is no
        // clock to compare, so losing the last-writer race must not erase it: carry it across from
        // the losing side rather than let the cleanup pass treat it as unreferenced and delete it.
        if winner.richFilename == nil {
            winner.richFilename = loser.richFilename
        }
        return winner
    }

    private static func orderedByWriteClock(
        _ lhs: ClipboardItem, _ rhs: ClipboardItem
    ) -> (winner: ClipboardItem, loser: ClipboardItem) {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt ? (lhs, rhs) : (rhs, lhs)
        }
        if lhs.isDeleted != rhs.isDeleted {
            return lhs.isDeleted ? (lhs, rhs) : (rhs, lhs)
        }
        return lhs.id.uuidString >= rhs.id.uuidString ? (lhs, rhs) : (rhs, lhs)
    }

    /// The side whose enrichment ran most recently (an un-enriched side, `aiEnrichedAt == nil`,
    /// always loses to an enriched one). When neither ran, the fields are empty on both.
    private static func freshestEnrichment(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> ClipboardItem {
        switch (lhs.aiEnrichedAt, rhs.aiEnrichedAt) {
        case let (l?, r?): return l >= r ? lhs : rhs
        case (.some, nil): return lhs
        case (nil, .some): return rhs
        case (nil, nil): return lhs
        }
    }

    private static func newestFirst(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        lhs.timestamp != rhs.timestamp
            ? lhs.timestamp > rhs.timestamp
            : lhs.id.uuidString > rhs.id.uuidString
    }
}
