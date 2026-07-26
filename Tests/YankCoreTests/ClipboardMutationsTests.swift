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

    @Test("Duplicate refresh preserves identity and annotations while adopting the new capture")
    func duplicateRefreshPreservesAnnotationsAndRefreshesCaptureFields() {
        let existing = ClipboardItem(
            id: clipID(1),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            sourceApp: "Old App",
            textContent: "same",
            isPinned: true,
            isBookmarked: true,
            tags: ["saved"],
            ocrText: "ocr",
            aiTags: ["topic"],
            aiTitle: "Legacy",
            aiEnrichedAt: Date(timeIntervalSinceReferenceDate: 150),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 200),
            deviceOrigin: "device-old"
        )
        let incoming = ClipboardItem(
            id: clipID(2),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 500),
            sourceApp: "New App",
            textContent: "same",
            hasRichContent: true,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 600),
            deviceOrigin: "device-new"
        )
        var items = [item(3), existing]

        let refreshed = ClipboardMutations.refreshDuplicateCapture(
            existingID: existing.id,
            with: incoming,
            in: &items
        )

        #expect(refreshed)
        #expect(items.map(\.id) == [existing.id, clipID(3)])
        #expect(items[0].timestamp == incoming.timestamp)
        #expect(items[0].sourceApp == incoming.sourceApp)
        #expect(items[0].hasRichContent)
        #expect(items[0].modifiedAt == incoming.modifiedAt)
        #expect(items[0].deviceOrigin == incoming.deviceOrigin)
        #expect(items[0].isPinned)
        #expect(items[0].isBookmarked)
        #expect(items[0].tags == ["saved"])
        #expect(items[0].ocrText == "ocr")
        #expect(items[0].aiTags == ["topic"])
        #expect(items[0].aiTitle == "Legacy")
        #expect(items[0].aiEnrichedAt == Date(timeIntervalSinceReferenceDate: 150))
    }

    @Test("Duplicate refresh mutates an item that is already first")
    func duplicateRefreshUpdatesFrontItem() {
        let existing = item(1, mod: 100)
        let incoming = ClipboardItem(
            id: clipID(2),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 500),
            textContent: existing.textContent,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 600),
            deviceOrigin: "device-new"
        )
        var items = [existing, item(3)]

        let refreshed = ClipboardMutations.refreshDuplicateCapture(
            existingID: existing.id,
            with: incoming,
            in: &items
        )

        #expect(refreshed)
        #expect(items[0].id == existing.id)
        #expect(items[0].timestamp == incoming.timestamp)
        #expect(items[0].modifiedAt == incoming.modifiedAt)
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
