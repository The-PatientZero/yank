import Foundation

struct PendingDeletion: Equatable, Sendable {
    let items: [ClipboardItem]
    let enqueuedAt: Date
}

enum PendingDeletePolicy {

    static let undoWindowSeconds: TimeInterval = 10

    static func canUndo(_ pending: PendingDeletion, now: Date = Date()) -> Bool {
        now.timeIntervalSince(pending.enqueuedAt) < undoWindowSeconds
    }

    static func visibleItems(
        _ items: [ClipboardItem],
        pending: PendingDeletion?
    ) -> [ClipboardItem] {
        guard let pending else { return items }
        let hiddenIDs = Set(pending.items.map(\.id))
        return items.filter { !hiddenIDs.contains($0.id) }
    }

    static func commitDeletion(
        _ items: [ClipboardItem],
        pending: PendingDeletion
    ) -> [ClipboardItem] {
        let hiddenIDs = Set(pending.items.map(\.id))
        return items.filter { !hiddenIDs.contains($0.id) }
    }
}
