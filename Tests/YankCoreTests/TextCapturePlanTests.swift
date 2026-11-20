import Foundation
import Testing
@testable import YankCore

@Suite struct TextCapturePlanTests {
    @Test func smallTextStaysInline() {
        let plan = TextCapturePlan.make(
            for: "small note",
            inlineLimit: 50,
            previewLength: 5,
            maxStoredBytes: 1_000
        )

        if case .inline(let text) = plan.storage {
            #expect(text == "small note")
        } else {
            Issue.record("Expected inline storage")
        }
        #expect(plan.byteCount == "small note".utf8.count)
    }

    @Test func largeStoredTextGetsPreviewSizeAndSearchIndex() {
        let text = "prefix " + String(repeating: "body ", count: 20) + "needle"
        let plan = TextCapturePlan.make(
            for: text,
            inlineLimit: 10,
            previewLength: 12,
            maxStoredBytes: 1_000
        )

        if case .fileBacked(let preview, let fullText, let originalSizeBytes, let searchIndex) = plan.storage {
            #expect(preview == String(text.prefix(12)))
            #expect(fullText == text)
            #expect(originalSizeBytes == text.utf8.count)
            #expect(ClipboardSearchIndex.matches(searchIndex, query: "needle"))
        } else {
            Issue.record("Expected file-backed storage")
        }
    }

    @Test func oversizedTextIsTruncated() {
        let text = "abcdef"
        let plan = TextCapturePlan.make(
            for: text,
            inlineLimit: 2,
            previewLength: 3,
            maxStoredBytes: 4
        )

        if case .truncated(let preview, let originalSizeBytes) = plan.storage {
            #expect(preview == "abc")
            #expect(originalSizeBytes == text.utf8.count)
        } else {
            Issue.record("Expected truncated storage")
        }
    }
}
