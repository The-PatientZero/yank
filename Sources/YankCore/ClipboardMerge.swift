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
        var winner = winnerByWriteClock(lhs, rhs)
        // AI enrichment is derived metadata, computed only on macOS, that rides `modifiedAt`.
        // A metadata edit (pin/tag) from a device that never enriched would otherwise win the
        // last-writer race and erase it. Resolve the AI fields on their own clock so the most
        // recent enrichment survives regardless of which side won the item itself.
        let enriched = freshestEnrichment(lhs, rhs)
        winner.aiTags = enriched.aiTags
        winner.aiTitle = enriched.aiTitle
        winner.aiEnrichedAt = enriched.aiEnrichedAt
        return winner
    }

    private static func winnerByWriteClock(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> ClipboardItem {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs
        }
        if lhs.isDeleted != rhs.isDeleted {
            return lhs.isDeleted ? lhs : rhs
        }
        return lhs.id.uuidString >= rhs.id.uuidString ? lhs : rhs
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
