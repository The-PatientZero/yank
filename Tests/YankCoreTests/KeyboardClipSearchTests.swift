import Foundation
import Testing
@testable import YankCore

@Suite struct KeyboardClipSearchTests {
    @Test func listableItemsKeepOnlyLiveTextClips() {
        let text = ClipboardItem(id: clipID(1), type: .text, textContent: "Alpha")
        let image = ClipboardItem(id: clipID(2), type: .image, imageFilename: "image.png")
        let deleted = ClipboardItem(
            id: clipID(3),
            type: .text,
            textContent: "Deleted",
            deletedAt: Date(timeIntervalSinceReferenceDate: 1)
        )

        let insertable = KeyboardClipSearch.listableItems(from: [text, image, deleted])

        #expect(insertable.map(\.id) == [clipID(1)])
    }
}
