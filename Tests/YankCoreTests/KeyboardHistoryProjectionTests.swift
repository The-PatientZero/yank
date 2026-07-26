import Foundation
import Testing
@testable import YankCore

@Suite struct KeyboardHistoryProjectionTests {
    @Test func keepsOnlyBoundedInsertableTextInOrder() {
        let first = ClipboardItem.text("first")
        let image = ClipboardItem.image(filename: "\(UUID().uuidString).png")
        var deleted = ClipboardItem.text("deleted")
        deleted.deletedAt = Date()
        let oversized = ClipboardItem.text("123456")
        let last = ClipboardItem.text("last")

        let projection = KeyboardHistoryProjection(
            items: [first, image, deleted, last, oversized],
            generatedAt: Date(timeIntervalSince1970: 10),
            maxItems: 2,
            maxEncodedBytes: 1_024
        )

        #expect(projection.items.map(\.id) == [first.id, last.id])
        #expect(projection.items.map(\.textContent) == ["first", "last"])
    }

    @Test func roundTripsCurrentVersion() throws {
        let projection = KeyboardHistoryProjection(
            items: [.text("hello")],
            generatedAt: Date(timeIntervalSince1970: 20)
        )

        let decoded = try KeyboardHistoryProjection.decode(projection.encoded())

        #expect(decoded.version == KeyboardHistoryProjection.currentVersion)
        #expect(decoded.generatedAt == projection.generatedAt)
        #expect(decoded.items.first?.textContent == "hello")
    }

    @Test func stripsHeavyMetadataFromTheKeyboardDTO() throws {
        let metadata = "search-marker-" + String(repeating: "x", count: 100_000)
        let item = ClipboardItem(
            type: .text,
            sourceApp: "Tests",
            textContent: "visible text",
            tags: [metadata],
            ocrText: metadata,
            searchIndex: metadata,
            aiTags: [metadata],
            aiTitle: metadata
        )

        let data = try KeyboardHistoryProjection(items: [item]).encoded()
        let decoded = try KeyboardHistoryProjection.decode(data)
        let projected = try #require(decoded.items.first)

        #expect(data.count < 1_024)
        #expect(projected.textContent == "visible text")
        #expect(projected.searchIndex == nil)
        #expect(projected.ocrText == nil)
        #expect(projected.tags.isEmpty)
        #expect(projected.aiTags.isEmpty)
    }

    @Test func encodedProjectionNeverExceedsItsByteBudget() throws {
        let items = (0..<100).map { index in
            ClipboardItem.text("\(index)-" + String(repeating: "content", count: 100))
        }
        let byteBudget = 2_048
        let projection = KeyboardHistoryProjection(
            items: items,
            maxItems: items.count,
            maxEncodedBytes: byteBudget
        )

        let data = try projection.encoded()

        #expect(data.count <= byteBudget)
        #expect(projection.items.count < items.count)
    }

    @Test func encodedByteBudgetStopsAtTheFirstOverflowingCandidate() throws {
        let emptyBytes = try KeyboardHistoryProjection(items: []).encoded().count
        let byteBudget = emptyBytes + 256
        let oversized = ClipboardItem.text(String(repeating: "x", count: byteBudget))
        let laterSmallItem = ClipboardItem.text("would fit if scanning continued")

        let projection = KeyboardHistoryProjection(
            items: [oversized, laterSmallItem],
            maxEncodedBytes: byteBudget
        )

        #expect(projection.items.isEmpty)
        #expect(try projection.encoded().count <= byteBudget)
    }

    @Test(arguments: [100, 500, 1_000])
    func remainsBoundedAtSupportedHistoryScales(itemCount: Int) throws {
        let items = (0..<itemCount).map { ClipboardItem.text("clip-\($0)") }

        let projection = KeyboardHistoryProjection(items: items)
        let data = try projection.encoded()

        #expect(projection.items.count == min(itemCount, KeyboardHistoryProjection.defaultMaxItems))
        #expect(data.count <= KeyboardHistoryProjection.defaultMaxEncodedBytes)
    }

    @Test func protectedOverflowDoesNotExpandTheCandidateWindow() {
        let protectedOverflow = (0..<KeyboardHistoryProjection.defaultMaxCandidates).map { index in
            var item = ClipboardItem.image(filename: "protected-\(index).png")
            item.isPinned = index.isMultiple(of: 2)
            item.isBookmarked = !item.isPinned
            return item
        }
        let eligiblePastTheBound = ClipboardItem.text("must not be scanned")

        let projection = KeyboardHistoryProjection(
            items: protectedOverflow + [eligiblePastTheBound]
        )

        #expect(protectedOverflow.allSatisfy { $0.isProtected })
        #expect(projection.items.isEmpty)
    }

    @Test func decodeRejectsFilesBeyondTheByteBudgetBeforeParsing() {
        let byteBudget = 64
        let oversized = Data(repeating: 0x20, count: byteBudget + 1)

        #expect(throws: KeyboardHistoryProjection.Error.encodedSizeExceeded(byteBudget)) {
            try KeyboardHistoryProjection.decode(oversized, maxEncodedBytes: byteBudget)
        }
    }

    @Test func rejectsUnsupportedVersions() throws {
        let data = Data(#"{"version":99,"generatedAt":0,"items":[]}"#.utf8)

        #expect(throws: KeyboardHistoryProjection.Error.unsupportedVersion(99)) {
            try KeyboardHistoryProjection.decode(data)
        }
    }
}
