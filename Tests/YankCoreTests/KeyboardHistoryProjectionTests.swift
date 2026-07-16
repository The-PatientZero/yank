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
