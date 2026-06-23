import Testing
import Foundation
@testable import YankCore

@Suite struct ClipboardMutationsTests {
    private func item(_ n: Int, tags: [String] = [], mod: Double = 0) -> ClipboardItem {
        ClipboardItem(
            id: clipID(n),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            textContent: "item-\(n)",
            tags: tags,
            modifiedAt: Date(timeIntervalSinceReferenceDate: mod),
            deviceOrigin: "device-A"
        )
    }

    private let now = Date(timeIntervalSinceReferenceDate: 9_000)

    @Test func togglePinFlipsAndStampsModifiedAt() {
        var items = [item(1)]
        ClipboardMutations.togglePin(&items, id: clipID(1), now: now)
        #expect(items[0].isPinned)
        #expect(items[0].modifiedAt == now)
        ClipboardMutations.togglePin(&items, id: clipID(1), now: now)
        #expect(!(items[0].isPinned))
    }

    @Test func toggleBookmarkFlips() {
        var items = [item(1)]
        ClipboardMutations.toggleBookmark(&items, id: clipID(1), now: now)
        #expect(items[0].isBookmarked)
    }

    @Test func addTagAppendsOnceAndDedupes() {
        var items = [item(1, tags: ["a"], mod: 100)]
        ClipboardMutations.addTag("b", id: clipID(1), in: &items, now: now)
        #expect(items[0].tags == ["a", "b"])
        #expect(items[0].modifiedAt == now)

        // Adding a tag that already exists is a no-op and must not re-stamp modifiedAt.
        let stamp = items[0].modifiedAt
        ClipboardMutations.addTag("b", id: clipID(1), in: &items, now: Date(timeIntervalSinceReferenceDate: 50_000))
        #expect(items[0].tags == ["a", "b"])
        #expect(items[0].modifiedAt == stamp)
    }

    @Test func removeTag() {
        var items = [item(1, tags: ["a", "b"])]
        ClipboardMutations.removeTag("a", id: clipID(1), in: &items, now: now)
        #expect(items[0].tags == ["b"])
        #expect(items[0].modifiedAt == now)
    }

    @Test func setOCRText() {
        var items = [item(1)]
        ClipboardMutations.setOCRText("hello", id: clipID(1), in: &items, now: now)
        #expect(items[0].ocrText == "hello")
        #expect(items[0].modifiedAt == now)
    }

    @Test func moveToTopReordersAndReportsChange() {
        var items = [item(1), item(2), item(3)]
        let moved = ClipboardMutations.moveToTop(clipID(3), in: &items, now: now)
        #expect(moved)
        #expect(items.map(\.id) == [clipID(3), clipID(1), clipID(2)])
        #expect(items[0].modifiedAt == now)
    }

    @Test func moveToTopOnFrontItemIsNoOp() {
        var items = [item(1), item(2)]
        let moved = ClipboardMutations.moveToTop(clipID(1), in: &items, now: now)
        #expect(!(moved))
        #expect(items.map(\.id) == [clipID(1), clipID(2)])
    }

    @Test func moveSelectionToTopPreservesSelectionOrderAndMutatesOnce() {
        var items = [item(1, mod: 100), item(2, mod: 100), item(3, mod: 100), item(4, mod: 100)]

        let moved = ClipboardMutations.moveToTop([clipID(2), clipID(4)], in: &items, now: now)

        #expect(moved)
        #expect(items.map(\.id) == [clipID(2), clipID(4), clipID(1), clipID(3)])
        #expect(items[0].modifiedAt == now)
        #expect(items[1].modifiedAt == now)
        #expect(items[2].modifiedAt == Date(timeIntervalSinceReferenceDate: 100))
    }

    @Test func moveSelectionToTopNoOpsWhenOrderAlreadyMatches() {
        var items = [item(1, mod: 100), item(2, mod: 100), item(3, mod: 100)]

        let moved = ClipboardMutations.moveToTop([clipID(1), clipID(2)], in: &items, now: now)

        #expect(!moved)
        #expect(items.map(\.id) == [clipID(1), clipID(2), clipID(3)])
        #expect(items[0].modifiedAt == Date(timeIntervalSinceReferenceDate: 100))
    }

    @Test func allTagsAreUniqueAndSorted() {
        let items = [item(1, tags: ["work", "todo"]), item(2, tags: ["todo", "idea"])]
        #expect(ClipboardMutations.allTags(items) == ["idea", "todo", "work"])
    }

    @Test func setPinnedAppliesToSelectionAndStampsOnlyChanged() {
        var items = [item(1, mod: 100), item(2, mod: 100), item(3, mod: 100)]
        items[1].isPinned = true   // item 2 already pinned → should not be re-stamped
        ClipboardMutations.setPinned(true, ids: [clipID(1), clipID(2)], in: &items, now: now)
        #expect(items[0].isPinned)
        #expect(items[0].modifiedAt == now)             // changed → stamped
        #expect(items[1].modifiedAt == Date(timeIntervalSinceReferenceDate: 100)) // no-op → untouched
        #expect(!(items[2].isPinned))                    // outside selection → untouched
    }

    @Test func setPinnedFalseUnpinsSelection() {
        var items = [item(1), item(2)]
        items[0].isPinned = true
        items[1].isPinned = true
        ClipboardMutations.setPinned(false, ids: [clipID(1), clipID(2)], in: &items, now: now)
        #expect(!(items[0].isPinned))
        #expect(!(items[1].isPinned))
    }

    @Test func setBookmarkedAppliesToSelection() {
        var items = [item(1, mod: 100), item(2, mod: 100)]
        ClipboardMutations.setBookmarked(true, ids: [clipID(2)], in: &items, now: now)
        #expect(!(items[0].isBookmarked))
        #expect(items[1].isBookmarked)
        #expect(items[1].modifiedAt == now)
    }
}
