import Testing
import Foundation
@testable import YankCore

@Suite struct ClipQueryTests {
    private func item(_ n: Int, text: String, app: String? = nil,
                      tags: [String] = [], pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(id: clipID(n), type: .text, sourceApp: app, textContent: text,
                      isPinned: pinned, tags: tags)
    }

    private var items: [ClipboardItem] {
        [
            item(1, text: "hello world", app: "Safari", tags: ["work"]),
            item(2, text: "swift code", app: "Xcode", tags: ["swift", "code"]),
            item(3, text: "pinned note", app: "Notes", tags: ["work"], pinned: true),
            item(4, text: "groceries")
        ]
    }

    @Test func emptyQueryReturnsAllPinnedFirst() {
        let result = ClipQuery.filter(items, search: "", activeTag: nil)
        #expect(result.first?.id == clipID(3))           // pinned floats up
        #expect(result.count == 4)
    }

    @Test func appFilter() {
        let result = ClipQuery.filter(items, search: "@xcode", activeTag: nil)
        #expect(result.map(\.id) == [clipID(2)])
    }

    @Test func tagPrefixFilterCaseInsensitive() {
        let result = ClipQuery.filter(items, search: "#SWI", activeTag: nil)
        #expect(result.map(\.id) == [clipID(2)])
    }

    @Test func plainTextMatch() {
        let result = ClipQuery.filter(items, search: "groc", activeTag: nil)
        #expect(result.map(\.id) == [clipID(4)])
    }

    @Test func activeTagAndsWithSearch() {
        // active tag "work" → items 1 & 3; pinned (3) floats first.
        let tagged = ClipQuery.filter(items, search: "", activeTag: "work")
        #expect(tagged.map(\.id) == [clipID(3), clipID(1)])
        // ANDed with a text search that only matches item 1.
        let both = ClipQuery.filter(items, search: "hello", activeTag: "work")
        #expect(both.map(\.id) == [clipID(1)])
    }

    @Test func bareSigilIsNotAFilter() {
        // "@" / "#" alone (count == 1) fall through to "show all".
        #expect(ClipQuery.filter(items, search: "#", activeTag: nil).count == 4)
        #expect(ClipQuery.filter(items, search: "@", activeTag: nil).count == 4)
    }

    /// Tags written before the shared normalization rule can carry uppercase. They are inside
    /// the compatibility boundary, so both the sigil search and the chip must still find them.
    @Test func storedTagCaseDoesNotHideAClip() {
        let legacy = [
            item(1, text: "design note", tags: ["Design-System"]),
            item(2, text: "other", tags: ["misc"])
        ]

        #expect(ClipQuery.filter(legacy, search: "#design", activeTag: nil).map(\.id) == [clipID(1)])
        #expect(ClipQuery.filter(legacy, search: "#DESIGN", activeTag: nil).map(\.id) == [clipID(1)])
        #expect(ClipQuery.filter(legacy, search: "", activeTag: "design-system").map(\.id) == [clipID(1)])
        #expect(ClipQuery.filter(legacy, search: "", activeTag: "Design-System").map(\.id) == [clipID(1)])
    }

    /// The documented ordering contract: pinned first, and input order preserved inside each
    /// group. Asserted with more than one item per group so a non-stable sort would show.
    @Test func inputOrderIsPreservedWithinPinnedAndUnpinnedGroups() {
        let ordered = [
            item(1, text: "a"),
            item(2, text: "b", pinned: true),
            item(3, text: "c"),
            item(4, text: "d", pinned: true),
            item(5, text: "e")
        ]

        let result = ClipQuery.filter(ordered, search: "", activeTag: nil)

        #expect(result.map(\.id) == [clipID(2), clipID(4), clipID(1), clipID(3), clipID(5)])
    }
}
