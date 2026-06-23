import Foundation
import Testing
@testable import YankCore

@Suite struct ClipboardBlobCleanupTests {
    private let now = Date(timeIntervalSinceReferenceDate: 2_000)

    private func filename(_ index: Int, extension pathExtension: String) -> String {
        "\(clipID(index).uuidString).\(pathExtension)"
    }

    private func image(_ index: Int, filename: String, richFilename: String? = nil) -> ClipboardItem {
        ClipboardItem(
            id: clipID(index),
            type: .image,
            timestamp: now.addingTimeInterval(Double(index)),
            imageFilename: filename,
            richFilename: richFilename
        )
    }

    private func largeText(_ index: Int, filename: String) -> ClipboardItem {
        ClipboardItem(
            id: clipID(index),
            type: .text,
            timestamp: now.addingTimeInterval(Double(index)),
            textContent: "preview-\(index)",
            textFilename: filename
        )
    }

    @Test func referencesToDeleteIncludesAllBlobKinds() {
        let imageFilename = filename(10, extension: "png")
        let richFilename = filename(11, extension: "plist")
        let textFilename = filename(12, extension: "txt")
        let removed = [
            image(1, filename: imageFilename, richFilename: richFilename),
            largeText(2, filename: textFilename),
            ClipboardItem(id: clipID(3), type: .text, timestamp: now, textContent: "inline")
        ]

        let references = Set(ClipboardBlobCleanup.referencesToDelete(removing: removed))

        #expect(references == [
            ClipboardBlobReference(kind: .image, filename: imageFilename),
            ClipboardBlobReference(kind: .rich, filename: richFilename),
            ClipboardBlobReference(kind: .text, filename: textFilename)
        ])
    }

    @Test func referencesToDeleteKeepsFilenamesStillReferencedByLiveItems() {
        let sharedFilename = filename(20, extension: "png")
        let removedFilename = filename(21, extension: "txt")
        let keptFilename = filename(22, extension: "txt")
        let removed = [
            image(1, filename: sharedFilename),
            largeText(2, filename: removedFilename)
        ]
        let kept = [
            image(3, filename: sharedFilename),
            largeText(4, filename: keptFilename)
        ]

        let references = ClipboardBlobCleanup.referencesToDelete(removing: removed, keeping: kept)

        #expect(references == [
            ClipboardBlobReference(kind: .text, filename: removedFilename)
        ])
    }

    @Test func referencesRemovedCleansReplacedAndCappedBlobFilenames() {
        let oldTextFilename = filename(30, extension: "txt")
        let newTextFilename = filename(31, extension: "txt")
        let cappedImageFilename = filename(32, extension: "png")
        let sharedImageFilename = filename(33, extension: "png")
        let previous = [
            largeText(1, filename: oldTextFilename),
            image(2, filename: cappedImageFilename),
            image(3, filename: sharedImageFilename)
        ]
        let next = [
            largeText(1, filename: newTextFilename),
            image(4, filename: sharedImageFilename)
        ]

        let references = Set(ClipboardBlobCleanup.referencesRemoved(from: previous, keeping: next))

        #expect(references == [
            ClipboardBlobReference(kind: .image, filename: cappedImageFilename),
            ClipboardBlobReference(kind: .text, filename: oldTextFilename)
        ])
    }
}
