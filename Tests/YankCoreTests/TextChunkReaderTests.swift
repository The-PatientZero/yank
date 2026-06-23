import Foundation
import Testing
@testable import YankCore

@Suite struct TextChunkReaderTests {
    @Test func inlineTextUsesOriginalSizeWhenPresent() throws {
        let item = ClipboardItem(
            type: .text,
            textContent: "abcdef",
            originalSizeBytes: 64
        )

        let page = try #require(TextChunkReader.page(for: item, textURL: nil, charCount: 3))

        #expect(page.text == "abc")
        #expect(page.totalBytes == 64)
        #expect(!page.reachedEOF)
    }

    @Test func fileBackedTextReadsOnlyRequestedPage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankTextChunkReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.txt")
        try "abcdefghij".write(to: url, atomically: true, encoding: .utf8)
        let item = ClipboardItem(type: .text, textFilename: "clip.txt", originalSizeBytes: nil)

        let page = try #require(TextChunkReader.page(for: item, textURL: url, charCount: 4))

        #expect(page.text == "abcd")
        #expect(page.totalBytes == 10)
        #expect(!page.reachedEOF)
    }

    @Test func fileReadFailureReportsError() {
        let item = ClipboardItem(type: .text, textFilename: "missing.txt")
        var reportedError: (any Error)?

        let page = TextChunkReader.page(
            for: item,
            textURL: URL(fileURLWithPath: "/tmp/yank-missing-\(UUID().uuidString).txt"),
            charCount: 4,
            onError: { reportedError = $0 }
        )

        #expect(page == nil)
        #expect(reportedError != nil)
    }
}
