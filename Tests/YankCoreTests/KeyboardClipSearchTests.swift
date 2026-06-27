import Foundation
import Testing
@testable import YankCore

@Suite struct KeyboardClipSearchTests {
    @Test func insertableItemsKeepOnlyLiveTextClips() {
        let text = ClipboardItem(id: clipID(1), type: .text, textContent: "Alpha")
        let image = ClipboardItem(id: clipID(2), type: .image, imageFilename: "image.png")
        let deleted = ClipboardItem(
            id: clipID(3),
            type: .text,
            textContent: "Deleted",
            deletedAt: Date(timeIntervalSinceReferenceDate: 1)
        )

        let insertable = KeyboardClipSearch.insertableItems(from: [text, image, deleted])

        #expect(insertable.map(\.id) == [clipID(1)])
    }

    @Test func emptyQueryReturnsRecentPrefix() {
        let items = [
            ClipboardItem(id: clipID(1), type: .text, textContent: "one"),
            ClipboardItem(id: clipID(2), type: .text, textContent: "two"),
            ClipboardItem(id: clipID(3), type: .text, textContent: "three")
        ]

        let results = KeyboardClipSearch.results(from: items, query: "", emptyLimit: 2, searchLimit: 10)

        #expect(results.map(\.id) == [clipID(1), clipID(2)])
    }

    @Test func resultsSkipDeletedAndNonTextClips() {
        let items = [
            ClipboardItem(id: clipID(1), type: .image, imageFilename: "image.png"),
            ClipboardItem(id: clipID(2), type: .text, textContent: "keep me"),
            ClipboardItem(id: clipID(3), type: .text, textContent: "gone",
                          deletedAt: Date(timeIntervalSinceReferenceDate: 1))
        ]

        let results = KeyboardClipSearch.results(from: items, query: "", emptyLimit: 10, searchLimit: 10)

        #expect(results.map(\.id) == [clipID(2)])
    }

    @Test func searchIsCaseAndDiacriticInsensitive() {
        let items = [
            ClipboardItem(id: clipID(1), type: .text, textContent: "Cafe notes"),
            ClipboardItem(id: clipID(2), type: .text, textContent: "Résumé draft"),
            ClipboardItem(id: clipID(3), type: .text, textContent: "shopping list")
        ]

        let cafeResults = KeyboardClipSearch.results(from: items, query: "CAFÉ", emptyLimit: 10, searchLimit: 10)
        let resumeResults = KeyboardClipSearch.results(from: items, query: "resume", emptyLimit: 10, searchLimit: 10)

        #expect(cafeResults.map(\.id) == [clipID(1)])
        #expect(resumeResults.map(\.id) == [clipID(2)])
    }

    @Test func searchUsesSearchLimit() {
        let items = [
            ClipboardItem(id: clipID(1), type: .text, textContent: "needle one"),
            ClipboardItem(id: clipID(2), type: .text, textContent: "needle two"),
            ClipboardItem(id: clipID(3), type: .text, textContent: "needle three")
        ]

        let results = KeyboardClipSearch.results(from: items, query: "needle", emptyLimit: 10, searchLimit: 2)

        #expect(results.map(\.id) == [clipID(1), clipID(2)])
    }
}
