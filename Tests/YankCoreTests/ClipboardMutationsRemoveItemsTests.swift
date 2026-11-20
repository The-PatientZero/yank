import Foundation
import Testing
@testable import YankCore

@Suite struct ClipboardMutationsRemoveItemsTests {
    private let now = Date(timeIntervalSinceReferenceDate: 5_000)

    private func blobName(_ index: Int, extension pathExtension: String) -> String {
        "\(clipID(index).uuidString).\(pathExtension)"
    }

    private func text(_ index: Int) -> ClipboardItem {
        ClipboardItem(id: clipID(index), type: .text, timestamp: now, textContent: "item-\(index)")
    }

    private func image(_ index: Int, filename: String) -> ClipboardItem {
        ClipboardItem(id: clipID(index), type: .image, timestamp: now, imageFilename: filename)
    }

    @Test func removesMatchingIdsAndKeepsTheRest() {
        let items = [text(1), text(2), text(3)]
        let result = ClipboardMutations.removeItems(ids: [clipID(2)], from: items, now: now)
        #expect(result.items.map(\.id) == [clipID(1), clipID(3)])
    }

    @Test func tombstonesEveryRemovedIdAtNow() {
        let items = [text(1), text(2), text(3)]
        let result = ClipboardMutations.removeItems(ids: [clipID(1), clipID(3)], from: items, now: now)
        #expect(result.tombstones == [clipID(1): now, clipID(3): now])
    }

    @Test func reportsOrphanedBlobReferences() {
        let removedFilename = blobName(10, extension: "png")
        let items = [image(1, filename: removedFilename), text(2)]
        let result = ClipboardMutations.removeItems(ids: [clipID(1)], from: items, now: now)
        #expect(result.blobReferencesToDelete == [
            ClipboardBlobReference(kind: .image, filename: removedFilename)
        ])
    }

    @Test func keepsBlobsStillReferencedByLiveItems() {
        // Two clips share a blob filename; deleting one must not orphan the shared blob.
        let shared = blobName(10, extension: "png")
        let items = [image(1, filename: shared), image(2, filename: shared)]
        let result = ClipboardMutations.removeItems(ids: [clipID(1)], from: items, now: now)
        #expect(result.blobReferencesToDelete.isEmpty)
        #expect(result.items.map(\.id) == [clipID(2)])
    }

    @Test func emptyIdSetIsANoOp() {
        let items = [text(1), text(2)]
        let result = ClipboardMutations.removeItems(ids: [], from: items, now: now)
        #expect(result.items == items)
        #expect(result.tombstones.isEmpty)
        #expect(result.blobReferencesToDelete.isEmpty)
    }

    @Test func unknownIdsAreIgnored() {
        let items = [text(1)]
        let result = ClipboardMutations.removeItems(ids: [clipID(99)], from: items, now: now)
        #expect(result.items == items)
        #expect(result.tombstones.isEmpty)
    }
}
