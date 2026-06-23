import Testing
import Foundation
@testable import YankCore

@Suite("PendingDeletePolicy")
struct PendingDeleteTests {

    private func item(_ n: Int) -> ClipboardItem {
        ClipboardItem(
            id: clipID(n),
            type: .text,
            textContent: "item-\(n)",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 0),
            deviceOrigin: "test"
        )
    }

    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("canUndo returns true within window")
    func canUndoWithinWindow() {
        let pending = PendingDeletion(items: [item(1)], enqueuedAt: now)
        let checkTime = now.addingTimeInterval(5)
        #expect(PendingDeletePolicy.canUndo(pending, now: checkTime))
    }

    @Test("canUndo returns false after window expires")
    func canUndoAfterWindowExpires() {
        let pending = PendingDeletion(items: [item(1)], enqueuedAt: now)
        let checkTime = now.addingTimeInterval(PendingDeletePolicy.undoWindowSeconds + 1)
        #expect(!PendingDeletePolicy.canUndo(pending, now: checkTime))
    }

    @Test("visibleItems hides pending items")
    func visibleItemsHidesPending() {
        let items = [item(1), item(2), item(3)]
        let pending = PendingDeletion(items: [item(2)], enqueuedAt: now)
        let visible = PendingDeletePolicy.visibleItems(items, pending: pending)
        #expect(visible.map(\.id) == [clipID(1), clipID(3)])
    }

    @Test("visibleItems with nil pending returns all items")
    func visibleItemsWithNilPendingReturnsAll() {
        let items = [item(1), item(2)]
        let visible = PendingDeletePolicy.visibleItems(items, pending: nil)
        #expect(visible.count == 2)
    }

    @Test("commitDeletion removes pending items from full list")
    func commitDeletionRemovesPendingItems() {
        let items = [item(1), item(2), item(3)]
        let pending = PendingDeletion(items: [item(1), item(3)], enqueuedAt: now)
        let result = PendingDeletePolicy.commitDeletion(items, pending: pending)
        #expect(result.map(\.id) == [clipID(2)])
    }

    @Test("multi-item pending deletion hides all items")
    func multiItemPendingHidesAll() {
        let items = [item(1), item(2), item(3), item(4)]
        let pending = PendingDeletion(items: [item(1), item(3)], enqueuedAt: now)
        let visible = PendingDeletePolicy.visibleItems(items, pending: pending)
        #expect(visible.map(\.id) == [clipID(2), clipID(4)])
    }
}
