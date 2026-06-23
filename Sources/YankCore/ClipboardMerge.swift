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
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs
        }
        if lhs.isDeleted != rhs.isDeleted {
            return lhs.isDeleted ? lhs : rhs
        }
        return lhs.id.uuidString >= rhs.id.uuidString ? lhs : rhs
    }

    private static func newestFirst(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        lhs.timestamp != rhs.timestamp
            ? lhs.timestamp > rhs.timestamp
            : lhs.id.uuidString > rhs.id.uuidString
    }
}
