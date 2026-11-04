import Foundation

struct PendingDeletion: Equatable, Sendable {
    let items: [ClipboardItem]
}

enum PendingDeletePolicy {

    static let undoWindowSeconds: TimeInterval = 10

    /// Undo-banner confirmation text, shared so the macOS and iOS banners can't drift.
    static func deletedMessage(count: Int) -> String {
        count == 1 ? "Clip deleted" : "\(count) clips deleted"
    }

    static func visibleItems(
        _ items: [ClipboardItem],
        pending: PendingDeletion?
    ) -> [ClipboardItem] {
        guard let pending else { return items }
        let hiddenIDs = Set(pending.items.map(\.id))
        return items.filter { !hiddenIDs.contains($0.id) }
    }
}
